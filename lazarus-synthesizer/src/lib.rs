use lazarus_artifact_runner::{WasmArtifact, WasmArtifactExecutor};
use lazarus_breakwater::StateSnapshot;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest as _, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::runtime::Runtime;

pub const DEFAULT_MAX_ITERATIONS: usize = 5;
pub const DEFAULT_TRAINING_PERCENT: u8 = 30;
pub const DEFAULT_SYNTHESIS_FUEL: u64 = 20_000;
pub const DEFAULT_MAX_SOURCE_BYTES: usize = 64 * 1024;
pub const DEFAULT_MAX_SOURCE_LINES: usize = 240;
pub const DEFAULT_MAX_BRANCH_TOKENS: usize = 64;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SynthesisVerdict {
    Accepted,
    CompileFailed,
    SemanticMismatch,
    PolicyRejected,
    ManualInterventionRequired,
}

#[derive(Clone, Debug)]
pub struct SynthesizerConfig {
    pub function_name: String,
    pub out_dir: PathBuf,
    pub rustc_bin: PathBuf,
    pub max_iterations: usize,
    pub training_percent: u8,
    pub fuel: u64,
    pub precompiled_cache_dir: Option<PathBuf>,
}

impl SynthesizerConfig {
    pub fn new(function_name: impl Into<String>, out_dir: impl Into<PathBuf>) -> Self {
        Self {
            function_name: function_name.into(),
            out_dir: out_dir.into(),
            rustc_bin: PathBuf::from("rustc"),
            max_iterations: DEFAULT_MAX_ITERATIONS,
            training_percent: DEFAULT_TRAINING_PERCENT,
            fuel: DEFAULT_SYNTHESIS_FUEL,
            precompiled_cache_dir: None,
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        validate_identifier(&self.function_name, "function_name")?;
        if self.max_iterations == 0 {
            return Err("max_iterations must be > 0".to_string());
        }
        if self.training_percent > 100 {
            return Err("training_percent must be <= 100".to_string());
        }
        if self.fuel == 0 {
            return Err("fuel must be > 0".to_string());
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BehaviorCase {
    pub case_id: String,
    pub payload: Value,
    pub expected: Value,
}

impl BehaviorCase {
    pub fn validate(&self) -> Result<(), String> {
        require_non_empty("case_id", &self.case_id)?;
        if !self.payload.is_object() {
            return Err(format!(
                "case {} payload must be a JSON object",
                self.case_id
            ));
        }
        self.expected
            .get("value")
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("case {} expected.value must be i64", self.case_id))?;
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SynthesisInput {
    pub legacy_source: String,
    pub input_order: Vec<String>,
    pub state_snapshots: Vec<StateSnapshot>,
    pub behavior_cases: Vec<BehaviorCase>,
}

impl SynthesisInput {
    pub fn validate(&self) -> Result<(), String> {
        require_non_empty("legacy_source", &self.legacy_source)?;
        if self.input_order.is_empty() {
            return Err("input_order must not be empty".to_string());
        }
        let mut seen = BTreeSet::new();
        for input in &self.input_order {
            validate_identifier(input, "input_order")?;
            if !seen.insert(input) {
                return Err(format!("duplicate input_order entry: {input}"));
            }
        }
        if self.behavior_cases.is_empty() {
            return Err("behavior_cases must not be empty".to_string());
        }
        for snapshot in &self.state_snapshots {
            snapshot.validate_ingestable()?;
        }
        for case in &self.behavior_cases {
            case.validate()?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct OracleFeedback {
    pub kind: String,
    pub message: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct OraclePrompt {
    pub iteration: usize,
    pub function_name: String,
    pub input_order: Vec<String>,
    pub legacy_source: String,
    pub visible_state_snapshots: Vec<StateSnapshot>,
    pub visible_behavior_cases: Vec<BehaviorCase>,
    pub prior_feedback: Vec<OracleFeedback>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OracleCandidate {
    pub rust_source: String,
    pub rationale: String,
}

pub trait OracleClient {
    fn propose(&mut self, prompt: &OraclePrompt) -> Result<OracleCandidate, String>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PromptStage {
    InitialGeneration,
    CompileFix,
    SemanticFix,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PromptCompilerConfig {
    pub max_snapshot_bytes: usize,
    pub max_rows_per_dependency: usize,
    pub max_headers: usize,
    pub max_string_bytes: usize,
    pub max_feedback_chars: usize,
    pub max_legacy_source_chars: usize,
}

impl Default for PromptCompilerConfig {
    fn default() -> Self {
        Self {
            max_snapshot_bytes: 32 * 1024,
            max_rows_per_dependency: 5,
            max_headers: 16,
            max_string_bytes: 2048,
            max_feedback_chars: 12 * 1024,
            max_legacy_source_chars: 64 * 1024,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompiledPrompt {
    pub stage: PromptStage,
    pub text: String,
    pub prompt_hash: String,
}

#[derive(Clone, Debug)]
pub struct PromptCompiler {
    config: PromptCompilerConfig,
    initial_generation_template: String,
    compile_fix_template: String,
    semantic_fix_template: String,
}

impl Default for PromptCompiler {
    fn default() -> Self {
        Self {
            config: PromptCompilerConfig::default(),
            initial_generation_template: INITIAL_GENERATION_TEMPLATE.to_string(),
            compile_fix_template: COMPILE_FIX_TEMPLATE.to_string(),
            semantic_fix_template: SEMANTIC_FIX_TEMPLATE.to_string(),
        }
    }
}

impl PromptCompiler {
    pub fn new(config: PromptCompilerConfig) -> Self {
        Self {
            config,
            ..Self::default()
        }
    }

    pub fn with_template(mut self, stage: PromptStage, template: impl Into<String>) -> Self {
        match stage {
            PromptStage::InitialGeneration => self.initial_generation_template = template.into(),
            PromptStage::CompileFix => self.compile_fix_template = template.into(),
            PromptStage::SemanticFix => self.semantic_fix_template = template.into(),
        }
        self
    }

    pub fn compile(
        &self,
        stage: PromptStage,
        prompt: &OraclePrompt,
    ) -> Result<CompiledPrompt, String> {
        let snapshots = prompt
            .visible_state_snapshots
            .iter()
            .map(|snapshot| minify_state_snapshot(snapshot, &self.config))
            .collect::<Vec<_>>();
        let snapshots_json =
            serde_json::to_string_pretty(&snapshots).map_err(|error| error.to_string())?;
        let cases_json = serde_json::to_string_pretty(&prompt.visible_behavior_cases)
            .map_err(|error| error.to_string())?;
        let feedback_json = serde_json::to_string_pretty(&trim_feedback(
            &prompt.prior_feedback,
            self.config.max_feedback_chars,
        ))
        .map_err(|error| error.to_string())?;
        let input_order_json =
            serde_json::to_string(&prompt.input_order).map_err(|error| error.to_string())?;
        let legacy_source =
            truncate_str(&prompt.legacy_source, self.config.max_legacy_source_chars);
        let template = match stage {
            PromptStage::InitialGeneration => &self.initial_generation_template,
            PromptStage::CompileFix => &self.compile_fix_template,
            PromptStage::SemanticFix => &self.semantic_fix_template,
        };
        let text = render_prompt_template(
            template,
            minijinja::context! {
                iteration => prompt.iteration,
                function_name => prompt.function_name,
                input_order_json => input_order_json,
                legacy_source => legacy_source,
                snapshots_json => snapshots_json,
                behavior_cases_json => cases_json,
                prior_feedback_json => feedback_json,
            },
        )?;
        let prompt_hash = stable_hash_bytes(text.as_bytes());
        Ok(CompiledPrompt {
            stage,
            text,
            prompt_hash,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct JavaMethodSource {
    pub method_tag: String,
    pub source: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MethodCorpus {
    pub method_tag: String,
    pub legacy_source: String,
    pub snapshots: Vec<StateSnapshot>,
}

pub fn correlate_snapshots_by_trace_tag(
    sources: &[JavaMethodSource],
    snapshots: &[StateSnapshot],
) -> BTreeMap<String, MethodCorpus> {
    let source_by_tag = sources
        .iter()
        .map(|source| (source.method_tag.clone(), source.source.clone()))
        .collect::<BTreeMap<_, _>>();
    let mut corpora = BTreeMap::new();
    for snapshot in snapshots {
        let Some(method_tag) = snapshot.trace_tags.get("business_method") else {
            continue;
        };
        let Some(source) = source_by_tag.get(method_tag) else {
            continue;
        };
        corpora
            .entry(method_tag.clone())
            .or_insert_with(|| MethodCorpus {
                method_tag: method_tag.clone(),
                legacy_source: source.clone(),
                snapshots: Vec::new(),
            })
            .snapshots
            .push(snapshot.clone());
    }
    corpora
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OracleHttpProtocol {
    OpenAiResponses,
    OpenAiChat,
    OllamaGenerate,
}

impl OracleHttpProtocol {
    fn from_env_value(value: &str) -> Result<Self, String> {
        match value {
            "openai_responses" | "responses" => Ok(Self::OpenAiResponses),
            "openai_chat" | "chat_completions" | "chat" => Ok(Self::OpenAiChat),
            "ollama_generate" | "ollama" => Ok(Self::OllamaGenerate),
            _ => Err(format!(
                "unsupported LAZARUS_ORACLE_PROTOCOL: {value}; expected openai_responses, openai_chat, or ollama_generate"
            )),
        }
    }
}

#[derive(Clone, Debug)]
pub struct OracleHttpConfig {
    pub endpoint: String,
    pub api_key: String,
    pub model: String,
    pub protocol: OracleHttpProtocol,
    pub max_retries: usize,
    pub base_backoff_ms: u64,
    pub max_concurrency: usize,
    pub timeout_ms: u64,
    pub max_output_tokens: u64,
    pub max_prompt_chars: usize,
    pub log_dir: Option<PathBuf>,
}

impl OracleHttpConfig {
    pub fn openai_from_env() -> Result<Self, String> {
        let protocol = env::var("LAZARUS_ORACLE_PROTOCOL")
            .ok()
            .map(|value| OracleHttpProtocol::from_env_value(&value))
            .transpose()?
            .unwrap_or_else(|| {
                if env::var("LAZARUS_LM_ENDPOINT").is_ok() {
                    OracleHttpProtocol::OpenAiChat
                } else {
                    OracleHttpProtocol::OpenAiResponses
                }
            });
        let api_key = env::var("LAZARUS_ORACLE_API_KEY")
            .or_else(|_| env::var("LAZARUS_OPENAI_API_KEY"))
            .or_else(|_| env::var("LAZARUS_LM_API_KEY"))
            .unwrap_or_default();
        if protocol == OracleHttpProtocol::OpenAiResponses && api_key.trim().is_empty() {
            return Err(
                "LAZARUS_ORACLE_API_KEY is required for openai_responses protocol".to_string(),
            );
        }
        Ok(Self {
            endpoint: env::var("LAZARUS_ORACLE_ENDPOINT")
                .or_else(|_| env::var("LAZARUS_OPENAI_ENDPOINT"))
                .or_else(|_| env::var("LAZARUS_LM_ENDPOINT"))
                .unwrap_or_else(|_| default_oracle_endpoint(protocol).to_string()),
            api_key,
            model: env::var("LAZARUS_ORACLE_MODEL")
                .or_else(|_| env::var("LAZARUS_OPENAI_MODEL"))
                .or_else(|_| env::var("LAZARUS_LM_MODEL"))
                .unwrap_or_else(|_| "gpt-4.1".to_string()),
            protocol,
            max_retries: env::var("LAZARUS_ORACLE_MAX_RETRIES")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(3),
            base_backoff_ms: env::var("LAZARUS_ORACLE_BASE_BACKOFF_MS")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(250),
            max_concurrency: env::var("LAZARUS_ORACLE_MAX_CONCURRENCY")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(1),
            timeout_ms: env::var("LAZARUS_ORACLE_TIMEOUT_MS")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(60_000),
            max_output_tokens: env::var("LAZARUS_ORACLE_MAX_OUTPUT_TOKENS")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(2_048),
            max_prompt_chars: env::var("LAZARUS_ORACLE_MAX_PROMPT_CHARS")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(120_000),
            log_dir: env::var("LAZARUS_ORACLE_LOG_DIR").ok().map(PathBuf::from),
        })
    }
}

pub struct OpenAiOracleAdapter {
    client: reqwest::Client,
    config: OracleHttpConfig,
    prompt_compiler: PromptCompiler,
    limiter: ConcurrencyLimiter,
    runtime: Runtime,
}

impl OpenAiOracleAdapter {
    pub fn new(config: OracleHttpConfig, prompt_compiler: PromptCompiler) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_millis(config.timeout_ms))
            .build()
            .map_err(|error| error.to_string())?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_io()
            .enable_time()
            .build()
            .map_err(|error| error.to_string())?;
        Ok(Self {
            client,
            limiter: ConcurrencyLimiter::new(config.max_concurrency.max(1)),
            config,
            prompt_compiler,
            runtime,
        })
    }

    pub fn from_env() -> Result<Self, String> {
        Self::new(
            OracleHttpConfig::openai_from_env()?,
            PromptCompiler::default(),
        )
    }
}

impl OracleClient for OpenAiOracleAdapter {
    fn propose(&mut self, prompt: &OraclePrompt) -> Result<OracleCandidate, String> {
        let stage = infer_prompt_stage(&prompt.prior_feedback);
        let compiled = self.prompt_compiler.compile(stage, prompt)?;
        if compiled.text.chars().count() > self.config.max_prompt_chars {
            return Err(format!(
                "oracle prompt exceeds LAZARUS_ORACLE_MAX_PROMPT_CHARS: {} > {}",
                compiled.text.chars().count(),
                self.config.max_prompt_chars
            ));
        }
        let _permit = self.limiter.acquire();
        self.runtime.block_on(async {
            let mut last_error = None;
            for attempt in 0..=self.config.max_retries {
                match self.request_candidate(&compiled, attempt).await {
                    Ok(candidate) => return Ok(candidate),
                    Err(error) if error.retryable && attempt < self.config.max_retries => {
                        last_error = Some(error.message);
                        let multiplier = 1u64 << attempt.min(8);
                        let delay = self.config.base_backoff_ms.saturating_mul(multiplier);
                        tokio::time::sleep(Duration::from_millis(delay)).await;
                    }
                    Err(error) => return Err(error.message),
                }
            }
            Err(last_error.unwrap_or_else(|| "oracle request failed".to_string()))
        })
    }
}

impl OpenAiOracleAdapter {
    async fn request_candidate(
        &self,
        compiled: &CompiledPrompt,
        attempt: usize,
    ) -> Result<OracleCandidate, OracleHttpError> {
        let request_body = oracle_request_body(&self.config, &compiled.text);
        let mut request = self.client.post(&self.config.endpoint).json(&request_body);
        if !self.config.api_key.trim().is_empty() {
            request = request.bearer_auth(&self.config.api_key);
        }
        let response = tokio::time::timeout(
            Duration::from_millis(self.config.timeout_ms),
            request.send(),
        )
        .await
        .map_err(|_| OracleHttpError::retryable("oracle request timed out".to_string()))?
        .map_err(|error| OracleHttpError::retryable(error.to_string()))?;
        let status = response.status();
        let body_text = response
            .text()
            .await
            .map_err(|error| OracleHttpError::retryable(error.to_string()))?;
        self.write_oracle_log(
            compiled,
            attempt,
            status.as_u16(),
            &request_body,
            &body_text,
        )
        .map_err(OracleHttpError::fatal)?;
        if !status.is_success() {
            let message = format!("oracle HTTP {}: {}", status.as_u16(), body_text);
            if is_retryable_http_status(status.as_u16()) {
                return Err(OracleHttpError::retryable(message));
            }
            return Err(OracleHttpError::fatal(message));
        }
        let body: Value = serde_json::from_str(&body_text)
            .map_err(|error| OracleHttpError::fatal(format!("invalid oracle JSON: {error}")))?;
        let text = extract_oracle_text(&body, self.config.protocol)
            .ok_or_else(|| OracleHttpError::fatal(format!("missing oracle text: {body}")))?;
        let rust_source = extract_rust_source(&text);
        Ok(OracleCandidate {
            rust_source,
            rationale: format!(
                "{:?} response via {}",
                self.config.protocol, self.config.model
            ),
        })
    }

    fn write_oracle_log(
        &self,
        compiled: &CompiledPrompt,
        attempt: usize,
        status: u16,
        request_body: &Value,
        response_body: &str,
    ) -> Result<(), String> {
        let Some(log_dir) = &self.config.log_dir else {
            return Ok(());
        };
        fs::create_dir_all(log_dir).map_err(|error| error.to_string())?;
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis())
            .unwrap_or_default();
        let path = log_dir.join(format!(
            "oracle-{}-{}-attempt-{}.json",
            now_ms, compiled.prompt_hash, attempt
        ));
        let record = json!({
            "timestamp_ms": now_ms,
            "endpoint": self.config.endpoint,
            "model": self.config.model,
            "stage": compiled.stage,
            "prompt_hash": compiled.prompt_hash,
            "attempt": attempt,
            "status": status,
            "request": request_body,
            "response_body": response_body,
        });
        fs::write(
            path,
            serde_json::to_vec_pretty(&record).map_err(|error| error.to_string())?,
        )
        .map_err(|error| error.to_string())
    }
}

#[derive(Clone)]
struct ConcurrencyLimiter {
    state: Arc<(Mutex<usize>, Condvar)>,
    max: usize,
}

impl ConcurrencyLimiter {
    fn new(max: usize) -> Self {
        Self {
            state: Arc::new((Mutex::new(0), Condvar::new())),
            max,
        }
    }

    fn acquire(&self) -> ConcurrencyPermit {
        let (lock, condvar) = &*self.state;
        let mut in_flight = lock.lock().expect("limiter mutex poisoned");
        while *in_flight >= self.max {
            in_flight = condvar.wait(in_flight).expect("limiter mutex poisoned");
        }
        *in_flight += 1;
        ConcurrencyPermit {
            state: Arc::clone(&self.state),
        }
    }
}

struct ConcurrencyPermit {
    state: Arc<(Mutex<usize>, Condvar)>,
}

impl Drop for ConcurrencyPermit {
    fn drop(&mut self) {
        let (lock, condvar) = &*self.state;
        let mut in_flight = lock.lock().expect("limiter mutex poisoned");
        *in_flight = in_flight.saturating_sub(1);
        condvar.notify_one();
    }
}

struct OracleHttpError {
    message: String,
    retryable: bool,
}

impl OracleHttpError {
    fn retryable(message: String) -> Self {
        Self {
            message,
            retryable: true,
        }
    }

    fn fatal(message: String) -> Self {
        Self {
            message,
            retryable: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SourcePolicyReport {
    pub accepted: bool,
    pub violations: Vec<String>,
    pub maintainability: MaintainabilityReport,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MaintainabilityReport {
    pub accepted: bool,
    pub source_bytes: usize,
    pub source_lines: usize,
    pub branch_tokens: usize,
    pub max_source_bytes: usize,
    pub max_source_lines: usize,
    pub max_branch_tokens: usize,
    pub violations: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CompileFailure {
    pub iteration: usize,
    pub stderr: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SemanticMismatch {
    pub iteration: usize,
    pub split: CorpusSplit,
    pub case_id: String,
    pub payload: Value,
    pub expected: Value,
    pub actual: Option<Value>,
    pub error: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CorpusSplit {
    Training,
    Blind,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct IterationReport {
    pub iteration: usize,
    pub candidate_hash: String,
    pub policy: SourcePolicyReport,
    pub compiled: bool,
    pub compile_error: Option<String>,
    pub mismatches: Vec<SemanticMismatch>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SynthesisReport {
    pub verdict: SynthesisVerdict,
    pub iterations: Vec<IterationReport>,
    pub training_case_count: usize,
    pub blind_case_count: usize,
    pub visible_snapshot_count: usize,
    pub accepted_source_hash: Option<String>,
    pub accepted_source: Option<String>,
    pub artifact: Option<WasmArtifact>,
    pub feedback: Vec<OracleFeedback>,
}

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
        let policy = validate_source_policy(&candidate.rust_source);
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

pub fn validate_source_policy(source: &str) -> SourcePolicyReport {
    let forbidden = [
        "std::fs",
        "std::net",
        "std::process",
        "std::os",
        "std::ffi",
        "std::alloc",
        "Command::",
        "include_str!",
        "include_bytes!",
        "extern crate",
        "serde",
        "serde_json",
        "from_raw_parts",
        "Vec::from_raw_parts",
        "unsafe {",
        "unsafe fn",
    ];
    let mut violations = forbidden
        .iter()
        .filter(|token| source.contains(**token))
        .map(|token| format!("forbidden token: {token}"))
        .collect::<Vec<_>>();
    let maintainability = analyze_maintainability(source);
    violations.extend(
        maintainability
            .violations
            .iter()
            .map(|violation| format!("maintainability: {violation}")),
    );
    SourcePolicyReport {
        accepted: violations.is_empty(),
        violations,
        maintainability,
    }
}

pub fn analyze_maintainability(source: &str) -> MaintainabilityReport {
    let source_bytes = source.len();
    let source_lines = source.lines().count();
    let branch_tokens = count_branch_tokens(source);
    let mut violations = Vec::new();
    if source_bytes > DEFAULT_MAX_SOURCE_BYTES {
        violations.push(format!(
            "source_bytes {} exceeds {}",
            source_bytes, DEFAULT_MAX_SOURCE_BYTES
        ));
    }
    if source_lines > DEFAULT_MAX_SOURCE_LINES {
        violations.push(format!(
            "source_lines {} exceeds {}",
            source_lines, DEFAULT_MAX_SOURCE_LINES
        ));
    }
    if branch_tokens > DEFAULT_MAX_BRANCH_TOKENS {
        violations.push(format!(
            "branch_tokens {} exceeds {}",
            branch_tokens, DEFAULT_MAX_BRANCH_TOKENS
        ));
    }
    MaintainabilityReport {
        accepted: violations.is_empty(),
        source_bytes,
        source_lines,
        branch_tokens,
        max_source_bytes: DEFAULT_MAX_SOURCE_BYTES,
        max_source_lines: DEFAULT_MAX_SOURCE_LINES,
        max_branch_tokens: DEFAULT_MAX_BRANCH_TOKENS,
        violations,
    }
}

struct CorpusPlan {
    visible_state_snapshots: Vec<StateSnapshot>,
    training_cases: Vec<BehaviorCase>,
    blind_cases: Vec<BehaviorCase>,
}

fn split_corpus(input: &SynthesisInput, training_percent: u8) -> Result<CorpusPlan, String> {
    let visible_state_snapshots = split_items(&input.state_snapshots, training_percent)?
        .0
        .into_iter()
        .cloned()
        .collect();
    let (training_cases, blind_cases) = split_items(&input.behavior_cases, training_percent)?;
    Ok(CorpusPlan {
        visible_state_snapshots,
        training_cases: training_cases.into_iter().cloned().collect(),
        blind_cases: blind_cases.into_iter().cloned().collect(),
    })
}

fn split_items<T: Serialize>(
    items: &[T],
    training_percent: u8,
) -> Result<(Vec<&T>, Vec<&T>), String> {
    if items.is_empty() {
        return Ok((Vec::new(), Vec::new()));
    }
    let mut indexed = items
        .iter()
        .map(|item| {
            serde_json::to_vec(item)
                .map(|bytes| (stable_hash_bytes(&bytes), item))
                .map_err(|error| error.to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    indexed.sort_by(|left, right| left.0.cmp(&right.0));
    let mut training_count = (indexed.len() * training_percent as usize).div_ceil(100);
    if training_count == 0 && !indexed.is_empty() {
        training_count = 1;
    }
    if indexed.len() > 1 && training_count >= indexed.len() {
        training_count = indexed.len() - 1;
    }
    let training = indexed
        .iter()
        .take(training_count)
        .map(|(_, item)| *item)
        .collect();
    let blind = indexed
        .iter()
        .skip(training_count)
        .map(|(_, item)| *item)
        .collect();
    Ok((training, blind))
}

fn compile_candidate_source(
    source: &str,
    source_hash: &str,
    input_order: &[String],
    config: &SynthesizerConfig,
) -> Result<WasmArtifact, String> {
    let source_path = config
        .out_dir
        .join(format!("{}_{}.rs", config.function_name, source_hash));
    let wasm_path = config
        .out_dir
        .join(format!("{}_{}.wasm", config.function_name, source_hash));
    fs::write(&source_path, source).map_err(|error| error.to_string())?;
    let output = Command::new(&config.rustc_bin)
        .arg("--target=wasm32-wasip1")
        .arg("--crate-type=cdylib")
        .arg("--edition=2024")
        .arg(&source_path)
        .arg("-o")
        .arg(&wasm_path)
        .output()
        .map_err(|error| format!("failed to spawn rustc for synthesized wasm: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "rustc synthesized wasm build failed with status {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(WasmArtifact {
        source_path,
        wasm_path,
        source_hash: source_hash.to_string(),
        input_order: input_order.to_vec(),
        function_name: config.function_name.clone(),
    })
}

fn validate_cases(
    iteration: usize,
    split: CorpusSplit,
    cases: &[BehaviorCase],
    artifact: &WasmArtifact,
    executor: &WasmArtifactExecutor,
    fuel: u64,
) -> Vec<SemanticMismatch> {
    cases
        .iter()
        .filter_map(
            |case| match executor.execute_as_json(artifact, &case.payload, fuel) {
                Ok(actual) if actual == case.expected => None,
                Ok(actual) => Some(SemanticMismatch {
                    iteration,
                    split,
                    case_id: case.case_id.clone(),
                    payload: case.payload.clone(),
                    expected: case.expected.clone(),
                    actual: Some(actual),
                    error: None,
                }),
                Err(error) => Some(SemanticMismatch {
                    iteration,
                    split,
                    case_id: case.case_id.clone(),
                    payload: case.payload.clone(),
                    expected: case.expected.clone(),
                    actual: None,
                    error: Some(error),
                }),
            },
        )
        .collect()
}

fn summarize_mismatches(mismatches: &[SemanticMismatch]) -> String {
    mismatches
        .iter()
        .take(5)
        .map(|mismatch| {
            format!(
                "{:?} case {} payload={} expected={} actual={} error={}",
                mismatch.split,
                mismatch.case_id,
                mismatch.payload,
                mismatch.expected,
                mismatch
                    .actual
                    .as_ref()
                    .map(Value::to_string)
                    .unwrap_or_else(|| "null".to_string()),
                mismatch.error.as_deref().unwrap_or("")
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn render_prompt_template<S: Serialize>(template: &str, context: S) -> Result<String, String> {
    let mut env = minijinja::Environment::new();
    env.add_template("prompt", template)
        .map_err(|error| error.to_string())?;
    env.get_template("prompt")
        .map_err(|error| error.to_string())?
        .render(context)
        .map_err(|error| error.to_string())
}

fn infer_prompt_stage(feedback: &[OracleFeedback]) -> PromptStage {
    match feedback.last().map(|item| item.kind.as_str()) {
        Some("compile_error") => PromptStage::CompileFix,
        Some("semantic_mismatch") => PromptStage::SemanticFix,
        _ => PromptStage::InitialGeneration,
    }
}

fn minify_state_snapshot(snapshot: &StateSnapshot, config: &PromptCompilerConfig) -> Value {
    let headers = snapshot
        .upstream
        .headers
        .iter()
        .take(config.max_headers)
        .map(|(key, value)| {
            (
                key.clone(),
                Value::String(truncate_str(value, config.max_string_bytes)),
            )
        })
        .collect::<Map<_, _>>();
    let dependencies = snapshot
        .downstream_dependencies
        .iter()
        .map(|dependency| {
            let rows = dependency
                .rows
                .iter()
                .take(config.max_rows_per_dependency)
                .map(|row| {
                    row.iter()
                        .map(|(key, value)| {
                            (key.clone(), truncate_value(value, config.max_string_bytes))
                        })
                        .collect::<Map<_, _>>()
                })
                .collect::<Vec<_>>();
            let row_count_visible = rows.len();
            let row_count_captured = dependency.rows.len();
            json!({
                "dependency_id": &dependency.dependency_id,
                "kind": &dependency.kind,
                "target": &dependency.target,
                "query_or_request": &dependency.query_or_request,
                "rows": rows,
                "row_count_visible": row_count_visible,
                "row_count_captured": row_count_captured,
                "response": truncate_value(&dependency.response, config.max_string_bytes),
                "deterministic": dependency.deterministic
            })
        })
        .collect::<Vec<_>>();
    let mutations = snapshot
        .mutation_intents
        .iter()
        .map(|intent| {
            json!({
                "intent_id": &intent.intent_id,
                "kind": &intent.kind,
                "target": &intent.target,
                "statement_or_request": &intent.statement_or_request,
                "params": truncate_value(&intent.params, config.max_string_bytes)
            })
        })
        .collect::<Vec<_>>();
    let mut compact = json!({
        "snapshot_id": &snapshot.snapshot_id,
        "trace_id": &snapshot.trace_id,
        "operation": &snapshot.operation,
        "status": &snapshot.status,
        "trace_tags": &snapshot.trace_tags,
        "context": {
            "locale": &snapshot.context.locale,
            "principal": &snapshot.context.principal,
            "thread_name": &snapshot.context.thread_name
        },
        "upstream": {
            "method": &snapshot.upstream.method,
            "uri": &snapshot.upstream.uri,
            "headers": headers,
            "body": truncate_value(&snapshot.upstream.body, config.max_string_bytes),
            "raw_body_sha256": &snapshot.upstream.raw_body_sha256
        },
        "downstream_dependencies": dependencies,
        "mutation_intents": mutations
    });
    while serde_json::to_vec(&compact).map_or(usize::MAX, |bytes| bytes.len())
        > config.max_snapshot_bytes
    {
        let Some(deps) = compact
            .get_mut("downstream_dependencies")
            .and_then(Value::as_array_mut)
        else {
            break;
        };
        if deps.pop().is_none() {
            compact["upstream"]["body"] = Value::String("<truncated>".to_string());
            break;
        }
    }
    compact
}

fn truncate_value(value: &Value, max_string_bytes: usize) -> Value {
    match value {
        Value::String(text) => Value::String(truncate_str(text, max_string_bytes)),
        Value::Array(items) => Value::Array(
            items
                .iter()
                .take(32)
                .map(|item| truncate_value(item, max_string_bytes))
                .collect(),
        ),
        Value::Object(map) => Value::Object(
            map.iter()
                .take(64)
                .map(|(key, value)| (key.clone(), truncate_value(value, max_string_bytes)))
                .collect(),
        ),
        other => other.clone(),
    }
}

fn trim_feedback(feedback: &[OracleFeedback], max_chars: usize) -> Vec<OracleFeedback> {
    feedback
        .iter()
        .rev()
        .take(4)
        .rev()
        .map(|item| OracleFeedback {
            kind: item.kind.clone(),
            message: truncate_str(&item.message, max_chars),
        })
        .collect()
}

fn truncate_str(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_string();
    }
    let mut truncated = value.chars().take(max_chars).collect::<String>();
    truncated.push_str("\n<truncated>");
    truncated
}

fn default_oracle_endpoint(protocol: OracleHttpProtocol) -> &'static str {
    match protocol {
        OracleHttpProtocol::OpenAiResponses => "https://api.openai.com/v1/responses",
        OracleHttpProtocol::OpenAiChat => "http://127.0.0.1:1234/v1/chat/completions",
        OracleHttpProtocol::OllamaGenerate => "http://127.0.0.1:11434/api/generate",
    }
}

fn oracle_request_body(config: &OracleHttpConfig, prompt: &str) -> Value {
    match config.protocol {
        OracleHttpProtocol::OpenAiResponses => json!({
            "model": config.model,
            "input": prompt,
            "temperature": 0.0,
            "max_output_tokens": config.max_output_tokens,
            "store": false
        }),
        OracleHttpProtocol::OpenAiChat => json!({
            "model": config.model,
            "messages": [
                {
                    "role": "user",
                    "content": prompt
                }
            ],
            "temperature": 0.0,
            "max_tokens": config.max_output_tokens
        }),
        OracleHttpProtocol::OllamaGenerate => json!({
            "model": config.model,
            "prompt": prompt,
            "stream": false,
            "options": {
                "temperature": 0.0,
                "num_predict": config.max_output_tokens
            }
        }),
    }
}

fn extract_oracle_text(value: &Value, protocol: OracleHttpProtocol) -> Option<String> {
    match protocol {
        OracleHttpProtocol::OpenAiResponses => extract_openai_text(value),
        OracleHttpProtocol::OpenAiChat => extract_openai_chat_text(value),
        OracleHttpProtocol::OllamaGenerate => value
            .get("response")
            .and_then(Value::as_str)
            .map(str::to_string),
    }
}

fn extract_openai_text(value: &Value) -> Option<String> {
    if let Some(text) = value.get("output_text").and_then(Value::as_str) {
        return Some(text.to_string());
    }
    let output = value.get("output")?.as_array()?;
    let mut text = String::new();
    for item in output {
        if let Some(content) = item.get("content").and_then(Value::as_array) {
            for part in content {
                if let Some(part_text) = part.get("text").and_then(Value::as_str) {
                    text.push_str(part_text);
                    text.push('\n');
                }
            }
        }
    }
    if text.trim().is_empty() {
        None
    } else {
        Some(text)
    }
}

fn extract_openai_chat_text(value: &Value) -> Option<String> {
    let choices = value.get("choices")?.as_array()?;
    let mut text = String::new();
    for choice in choices {
        if let Some(content) = choice
            .get("message")
            .and_then(|message| message.get("content"))
            .and_then(Value::as_str)
        {
            text.push_str(content);
            text.push('\n');
        }
    }
    if text.trim().is_empty() {
        None
    } else {
        Some(text)
    }
}

fn extract_rust_source(text: &str) -> String {
    if let Some(source) = extract_fenced_block(text, "```rust") {
        return source;
    }
    if let Some(source) = extract_fenced_block(text, "```") {
        return source;
    }
    text.trim().to_string()
}

fn extract_fenced_block(text: &str, marker: &str) -> Option<String> {
    let start = text.find(marker)?;
    let after_marker = &text[start + marker.len()..];
    let after_newline = after_marker
        .strip_prefix('\n')
        .or_else(|| after_marker.strip_prefix("\r\n"))
        .unwrap_or(after_marker);
    let end = after_newline.find("```")?;
    Some(after_newline[..end].trim().to_string())
}

fn is_retryable_http_status(status: u16) -> bool {
    matches!(status, 429 | 500 | 502 | 503 | 504)
}

fn count_branch_tokens(source: &str) -> usize {
    source
        .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
        .filter(|token| matches!(*token, "if" | "else" | "match" | "for" | "while" | "loop"))
        .count()
}

fn validate_identifier(value: &str, field: &str) -> Result<(), String> {
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return Err(format!("{field} is required"));
    };
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return Err(format!("{field} must start with '_' or ASCII letter"));
    }
    if !chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric()) {
        return Err(format!(
            "{field} must contain only ASCII letters, digits, and '_'"
        ));
    }
    Ok(())
}

fn require_non_empty(field: &str, value: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        Err(format!("{field} must not be empty"))
    } else {
        Ok(())
    }
}

fn stable_hash_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

#[allow(dead_code)]
fn path_is_file(path: &Path) -> bool {
    path.is_file()
}

const INITIAL_GENERATION_TEMPLATE: &str = include_str!("../templates/initial_synthesis.jinja");
const COMPILE_FIX_TEMPLATE: &str = include_str!("../templates/compile_feedback.jinja");
const SEMANTIC_FIX_TEMPLATE: &str = include_str!("../templates/semantic_feedback.jinja");

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_breakwater::{
        DependencyKind, DownstreamDependency, MutationIntent, MutationKind, SnapshotContext,
        SnapshotLimits, StateSnapshotInput, UpstreamRequest,
    };
    use std::collections::BTreeMap;

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
