use lazarus_artifact_runner::WasmArtifactExecutor;
use std::fs;
use std::path::Path;

mod artifact;
mod corpus;
mod correlator;
mod hash;
mod oracle;
mod prompt;
mod safety;
mod types;
mod validation;

use artifact::compile_candidate_source;
use corpus::split_corpus;
use hash::stable_hash_bytes;
use validation::{summarize_mismatches, validate_cases};

#[cfg(test)]
use lazarus_breakwater::StateSnapshot;
#[cfg(test)]
use oracle::{extract_oracle_text, extract_rust_source, oracle_request_body};
#[cfg(test)]
use serde_json::Value;

pub use correlator::{JavaMethodSource, MethodCorpus, correlate_snapshots_by_trace_tag};
pub use oracle::{OpenAiOracleAdapter, OracleHttpConfig, OracleHttpProtocol};
pub use prompt::{CompiledPrompt, PromptCompiler, PromptCompilerConfig};
pub use safety::{
    DEFAULT_MAX_BRANCH_TOKENS, DEFAULT_MAX_SOURCE_BYTES, DEFAULT_MAX_SOURCE_LINES,
    analyze_maintainability, validate_source_policy, validate_source_policy_for_input,
};
pub use types::*;

pub fn synthesize_with_oracle<O: OracleClient>(
    oracle: &mut O,
    input: &SynthesisInput,
    config: &SynthesizerConfig,
) -> Result<SynthesisReport, String> {
    input.validate()?;
    config.validate()?;
    fs::create_dir_all(&config.out_dir).map_err(|error| error.to_string())?;

    let split = split_corpus(input, config.training_percent)?;
    let executor = match &config.precompiled_cache_dir {
        Some(cache_dir) => WasmArtifactExecutor::new_with_precompiled_cache_dir(cache_dir)?,
        None => WasmArtifactExecutor::new()?,
    };
    let mut feedback = Vec::new();
    let mut iterations = Vec::new();

    for iteration in 1..=config.max_iterations {
        let prompt = OraclePrompt {
            iteration,
            function_name: config.function_name.clone(),
            input_order: input.input_order.clone(),
            legacy_source: input.legacy_source.clone(),
            visible_state_snapshots: split.visible_state_snapshots.clone(),
            visible_behavior_cases: split.training_cases.clone(),
            prior_feedback: feedback.clone(),
        };
        let candidate = oracle.propose(&prompt)?;
        let source_hash = stable_hash_bytes(candidate.rust_source.as_bytes());
        let policy = validate_source_policy_for_input(&candidate.rust_source, input);
        if !policy.accepted {
            let message = format!(
                "source policy rejected candidate {source_hash}: {}",
                policy.violations.join("; ")
            );
            feedback.push(OracleFeedback {
                kind: "policy_rejected".to_string(),
                message: message.clone(),
            });
            iterations.push(IterationReport {
                iteration,
                candidate_hash: source_hash,
                policy,
                compiled: false,
                compile_error: Some(message),
                mismatches: Vec::new(),
            });
            continue;
        }

        let artifact = match compile_candidate_source(
            &candidate.rust_source,
            &source_hash,
            &input.input_order,
            config,
        ) {
            Ok(artifact) => artifact,
            Err(error) => {
                feedback.push(OracleFeedback {
                    kind: "compile_error".to_string(),
                    message: error.clone(),
                });
                iterations.push(IterationReport {
                    iteration,
                    candidate_hash: source_hash,
                    policy,
                    compiled: false,
                    compile_error: Some(error),
                    mismatches: Vec::new(),
                });
                continue;
            }
        };

        let mut mismatches = Vec::new();
        mismatches.extend(validate_cases(
            iteration,
            CorpusSplit::Training,
            &split.training_cases,
            &artifact,
            &executor,
            config.fuel,
        ));
        mismatches.extend(validate_cases(
            iteration,
            CorpusSplit::Blind,
            &split.blind_cases,
            &artifact,
            &executor,
            config.fuel,
        ));

        if mismatches.is_empty() {
            iterations.push(IterationReport {
                iteration,
                candidate_hash: source_hash.clone(),
                policy,
                compiled: true,
                compile_error: None,
                mismatches,
            });
            return Ok(SynthesisReport {
                verdict: SynthesisVerdict::Accepted,
                iterations,
                training_case_count: split.training_cases.len(),
                blind_case_count: split.blind_cases.len(),
                visible_snapshot_count: split.visible_state_snapshots.len(),
                accepted_source_hash: Some(source_hash),
                accepted_source: Some(candidate.rust_source),
                artifact: Some(artifact),
                feedback,
            });
        }

        let message = summarize_mismatches(&mismatches);
        feedback.push(OracleFeedback {
            kind: "semantic_mismatch".to_string(),
            message,
        });
        iterations.push(IterationReport {
            iteration,
            candidate_hash: source_hash,
            policy,
            compiled: true,
            compile_error: None,
            mismatches,
        });
    }

    let verdict = iterations
        .last()
        .map(|last| {
            if !last.policy.accepted {
                SynthesisVerdict::PolicyRejected
            } else if !last.compiled {
                SynthesisVerdict::CompileFailed
            } else {
                SynthesisVerdict::ManualInterventionRequired
            }
        })
        .unwrap_or(SynthesisVerdict::ManualInterventionRequired);

    Ok(SynthesisReport {
        verdict,
        iterations,
        training_case_count: split.training_cases.len(),
        blind_case_count: split.blind_cases.len(),
        visible_snapshot_count: split.visible_state_snapshots.len(),
        accepted_source_hash: None,
        accepted_source: None,
        artifact: None,
        feedback,
    })
}

#[allow(dead_code)]
fn path_is_file(path: &Path) -> bool {
    path.is_file()
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_breakwater::{
        DependencyKind, DownstreamDependency, MutationIntent, MutationKind, SnapshotContext,
        SnapshotLimits, StateSnapshotInput, UpstreamRequest,
    };
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    struct ScriptedOracle {
        sources: Vec<String>,
    }

    impl ScriptedOracle {
        fn new(sources: Vec<String>) -> Self {
            Self { sources }
        }
    }

    impl OracleClient for ScriptedOracle {
        fn propose(&mut self, _prompt: &OraclePrompt) -> Result<OracleCandidate, String> {
            if self.sources.is_empty() {
                return Err("oracle exhausted".to_string());
            }
            Ok(OracleCandidate {
                rust_source: self.sources.remove(0),
                rationale: "scripted".to_string(),
            })
        }
    }

    #[test]
    fn oracle_protocol_builds_local_chat_request_body() {
        let config = OracleHttpConfig {
            endpoint: "http://127.0.0.1:1234/v1/chat/completions".to_string(),
            api_key: String::new(),
            model: "local-model".to_string(),
            protocol: OracleHttpProtocol::OpenAiChat,
            max_retries: 0,
            base_backoff_ms: 1,
            max_concurrency: 1,
            timeout_ms: 1_000,
            max_output_tokens: 128,
            max_prompt_chars: 10_000,
            log_dir: None,
        };
        let body = oracle_request_body(&config, "make rust");
        assert_eq!(body["model"], "local-model");
        assert_eq!(body["messages"][0]["content"], "make rust");
        assert_eq!(body["max_tokens"], 128);
    }

    #[test]
    fn oracle_protocol_extracts_chat_and_ollama_text() {
        let chat = serde_json::json!({
            "choices": [
                {
                    "message": {
                        "content": "```rust\npub fn compute(id: i64) -> i64 { id }\n```"
                    }
                }
            ]
        });
        let ollama = serde_json::json!({
            "response": "pub fn compute(id: i64) -> i64 { id }"
        });

        assert!(
            extract_oracle_text(&chat, OracleHttpProtocol::OpenAiChat)
                .unwrap()
                .contains("compute")
        );
        assert_eq!(
            extract_oracle_text(&ollama, OracleHttpProtocol::OllamaGenerate).unwrap(),
            "pub fn compute(id: i64) -> i64 { id }"
        );
    }

    #[test]
    fn local_lm_env_does_not_require_api_key() {
        temp_env::with_vars(
            [
                ("LAZARUS_ORACLE_PROTOCOL", Some("openai_chat")),
                (
                    "LAZARUS_LM_ENDPOINT",
                    Some("http://127.0.0.1:1234/v1/chat/completions"),
                ),
                ("LAZARUS_LM_MODEL", Some("local-model")),
                ("LAZARUS_ORACLE_API_KEY", None),
                ("LAZARUS_OPENAI_API_KEY", None),
                ("LAZARUS_LM_API_KEY", None),
            ],
            || {
                let config = OracleHttpConfig::openai_from_env().unwrap();
                assert_eq!(config.protocol, OracleHttpProtocol::OpenAiChat);
                assert_eq!(config.api_key, "");
                assert_eq!(config.model, "local-model");
            },
        );
    }

    #[test]
    fn synthesis_loop_recovers_from_compile_and_semantic_failures() {
        let root = temp_root("synth-ok");
        let mut config = SynthesizerConfig::new("compute", &root);
        config.max_iterations = 4;
        config.training_percent = 34;
        config.precompiled_cache_dir = Some(root.join("cwasm"));
        let input = sample_input();
        let mut oracle = ScriptedOracle::new(vec![
            bad_compile_source(),
            source_returning("amount.saturating_add(1)"),
            source_returning("amount.saturating_mul(2)"),
        ]);

        let report = synthesize_with_oracle(&mut oracle, &input, &config).unwrap();

        assert_eq!(report.verdict, SynthesisVerdict::Accepted);
        assert_eq!(report.iterations.len(), 3);
        assert!(report.iterations[0].compile_error.is_some());
        assert!(!report.iterations[1].mismatches.is_empty());
        assert!(
            report.iterations[1]
                .mismatches
                .iter()
                .any(|mismatch| mismatch.split == CorpusSplit::Blind)
        );
        assert_eq!(report.training_case_count, 2);
        assert_eq!(report.blind_case_count, 2);
        assert!(report.artifact.unwrap().wasm_path.is_file());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn blind_split_blocks_overfit_candidate() {
        let root = temp_root("synth-overfit");
        let mut config = SynthesizerConfig::new("compute", &root);
        config.max_iterations = 1;
        config.training_percent = 34;
        let input = sample_input();
        let mut oracle =
            ScriptedOracle::new(vec![source_returning("if amount == 2 { 4 } else { 0 }")]);

        let report = synthesize_with_oracle(&mut oracle, &input, &config).unwrap();

        assert_eq!(report.verdict, SynthesisVerdict::ManualInterventionRequired);
        assert_eq!(report.training_case_count, 2);
        assert_eq!(report.blind_case_count, 2);
        assert!(
            report.iterations[0]
                .mismatches
                .iter()
                .any(|mismatch| mismatch.split == CorpusSplit::Blind)
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn policy_rejects_single_case_literal_replay_before_compile() {
        let root = temp_root("synth-literal-replay");
        let mut config = SynthesizerConfig::new("compute", &root);
        config.max_iterations = 1;
        config.training_percent = 100;
        let input = SynthesisInput {
            legacy_source: "long compute(long amount) { return amount * 2; }".to_string(),
            input_order: vec!["amount".to_string()],
            state_snapshots: Vec::new(),
            behavior_cases: vec![case("c1", 2, 4)],
        };
        let mut oracle = ScriptedOracle::new(vec![source_returning("4")]);

        let report = synthesize_with_oracle(&mut oracle, &input, &config).unwrap();

        assert_eq!(report.verdict, SynthesisVerdict::PolicyRejected);
        assert!(!report.iterations[0].policy.accepted);
        assert!(
            report.iterations[0]
                .policy
                .violations
                .iter()
                .any(|violation| violation.contains("expected numeric result literal 4"))
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn policy_rejects_expected_string_literal_replay() {
        let input = SynthesisInput {
            legacy_source: "String role() { return user.getRole(); }".to_string(),
            input_order: vec!["user_id".to_string()],
            state_snapshots: Vec::new(),
            behavior_cases: vec![BehaviorCase {
                case_id: "c1".to_string(),
                payload: serde_json::json!({"user_id": 7}),
                expected: serde_json::json!({"value": "admin"}),
            }],
        };

        let report = validate_source_policy_for_input(
            r#"pub fn role(_user_id: i64) -> &'static str { "admin" }"#,
            &input,
        );

        assert!(!report.accepted);
        assert!(
            report
                .violations
                .iter()
                .any(|violation| violation.contains("expected string literal 'admin'"))
        );
    }

    #[test]
    fn policy_rejects_filesystem_escape() {
        let report = validate_source_policy("fn f() { let _ = std::fs::read(\"/tmp/x\"); }");
        assert!(!report.accepted);
        assert!(
            report
                .violations
                .iter()
                .any(|violation| violation.contains("std::fs"))
        );
    }

    #[test]
    fn policy_rejects_unmaintainable_branch_explosion() {
        let source = (0..80)
            .map(|index| format!("if amount == {index} {{ return {index}; }}"))
            .collect::<Vec<_>>()
            .join("\n");

        let report = validate_source_policy(&source);

        assert!(!report.accepted);
        assert!(!report.maintainability.accepted);
        assert!(
            report
                .violations
                .iter()
                .any(|violation| violation.contains("branch_tokens"))
        );
    }

    #[test]
    fn prompt_compiler_trims_snapshot_noise_and_preserves_trace_tag() {
        let snapshot = tagged_snapshot("com.bank.TransferService.execute");
        let prompt = OraclePrompt {
            iteration: 1,
            function_name: "compute".to_string(),
            input_order: vec!["amount".to_string()],
            legacy_source: "long execute(long amount) { return amount * 2; }".to_string(),
            visible_state_snapshots: vec![snapshot],
            visible_behavior_cases: vec![case("c1", 2, 4)],
            prior_feedback: Vec::new(),
        };
        let compiler = PromptCompiler::new(PromptCompilerConfig {
            max_snapshot_bytes: 4096,
            max_rows_per_dependency: 1,
            max_headers: 1,
            max_string_bytes: 24,
            max_feedback_chars: 256,
            max_legacy_source_chars: 1024,
        });

        let compiled = compiler
            .compile(PromptStage::InitialGeneration, &prompt)
            .unwrap();

        assert!(compiled.text.contains("```json"));
        assert!(compiled.text.contains("com.bank.TransferService.execute"));
        assert!(compiled.text.contains("<truncated>"));
        assert!(!compiled.text.contains("x-extra-header"));
    }

    #[test]
    fn correlator_routes_snapshots_to_java_method_source() {
        let snapshot = tagged_snapshot("com.bank.TransferService.execute");
        let sources = vec![JavaMethodSource {
            method_tag: "com.bank.TransferService.execute".to_string(),
            source: "class TransferService { long execute(long x) { return x; } }".to_string(),
        }];

        let routed = correlate_snapshots_by_trace_tag(&sources, &[snapshot]);

        let corpus = routed.get("com.bank.TransferService.execute").unwrap();
        assert_eq!(corpus.snapshots.len(), 1);
        assert!(corpus.legacy_source.contains("TransferService"));
    }

    #[test]
    fn extracts_rust_code_block_from_oracle_response() {
        let text = "explanation\n```rust\npub fn x() -> i32 { 1 }\n```\nmore";

        assert_eq!(extract_rust_source(text), "pub fn x() -> i32 { 1 }");
    }

    fn sample_input() -> SynthesisInput {
        SynthesisInput {
            legacy_source: "long compute(long amount) { return amount * 2; }".to_string(),
            input_order: vec!["amount".to_string()],
            state_snapshots: Vec::new(),
            behavior_cases: vec![
                case("c1", 2, 4),
                case("c2", 3, 6),
                case("c3", 4, 8),
                case("c4", 5, 10),
            ],
        }
    }

    fn case(case_id: &str, amount: i64, expected: i64) -> BehaviorCase {
        BehaviorCase {
            case_id: case_id.to_string(),
            payload: serde_json::json!({ "amount": amount }),
            expected: serde_json::json!({ "value": expected }),
        }
    }

    fn bad_compile_source() -> String {
        "#![no_std]\n#[panic_handler]\nfn panic(_: &core::panic::PanicInfo) -> ! { loop {} }\n#[unsafe(no_mangle)]\npub extern \"C\" fn compute(amount: i64) -> i64 { amount.saturating_mul( }\n".to_string()
    }

    fn source_returning(expr: &str) -> String {
        format!(
            "#![no_std]\n\
#[panic_handler]\n\
fn panic(_: &core::panic::PanicInfo) -> ! {{ loop {{}} }}\n\
#[unsafe(no_mangle)]\n\
pub extern \"C\" fn compute(amount: i64) -> i64 {{ {expr} }}\n"
        )
    }

    fn tagged_snapshot(method: &str) -> StateSnapshot {
        let mut snapshot = StateSnapshot::new(StateSnapshotInput {
            snapshot_id: "snap-1".to_string(),
            trace_id: "trace-1".to_string(),
            operation: "transfer".to_string(),
            context: SnapshotContext {
                captured_at_unix_ms: 1,
                epoch_unix_ms: 1,
                locale: Some("en_US".to_string()),
                principal: Some("user-1".to_string()),
                thread_name: Some("http-1".to_string()),
                env: BTreeMap::new(),
            },
            upstream: UpstreamRequest {
                method: "POST".to_string(),
                uri: "/transfer".to_string(),
                headers: BTreeMap::from([
                    ("authorization".to_string(), "***".to_string()),
                    ("x-extra-header".to_string(), "drop-me".to_string()),
                ]),
                body: serde_json::json!({"amount": "123456789012345678901234567890"}),
                raw_body_sha256: None,
            },
            downstream_dependencies: vec![DownstreamDependency {
                dependency_id: "dep-1".to_string(),
                kind: DependencyKind::JdbcRead,
                target: "accounts".to_string(),
                query_or_request: Some("select balance, note from accounts".to_string()),
                rows: vec![
                    BTreeMap::from([
                        ("balance".to_string(), serde_json::json!(100)),
                        (
                            "note".to_string(),
                            serde_json::json!(
                                "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
                            ),
                        ),
                    ]),
                    BTreeMap::from([("balance".to_string(), serde_json::json!(200))]),
                ],
                response: Value::Null,
                deterministic: true,
            }],
            mutation_intents: vec![MutationIntent {
                intent_id: "mut-1".to_string(),
                kind: MutationKind::DbUpdate,
                target: "accounts".to_string(),
                statement_or_request: Some("update accounts set balance = ?".to_string()),
                params: serde_json::json!({"amount": 100}),
            }],
            limits: SnapshotLimits::default(),
        })
        .unwrap();
        snapshot
            .trace_tags
            .insert("business_method".to_string(), method.to_string());
        snapshot.snapshot_hash = snapshot.compute_hash().unwrap();
        snapshot
    }

    fn temp_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "lazarus-{name}-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        root
    }
}
