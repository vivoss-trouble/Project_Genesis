#[cfg(test)]
mod tests {
    use lazarus_artifact_runner::{WasmArtifactExecutor, WasmRunnerConfig, compile_wasm_artifact};
    use lazarus_breakwater::{HydrationPlan, TrafficSnapshot, hydrate_snapshots, shadow_requests};
    use lazarus_contracts::LazarusJobEvent;
    use lazarus_converter_pipeline::{ConverterConfig, compile_artifact, convert_verified_ir};
    use lazarus_cutover_gate::{CutoverGateConfig, CutoverGateInput, prepare_cutover};
    use lazarus_evidence_pack::{EvidencePackInput, EvidenceSigner, write_evidence_pack};
    use lazarus_orchestrator::LazarusOrchestrator;
    use lazarus_promotion_controller::{PromotionPolicy, evaluate_and_promote};
    use lazarus_shadow_runner::{ShadowRunnerConfig, run_shadow_batch};
    use lazarus_verification_pipeline::{
        PipelineConfig, find_ir_by_function_target, run_bounded_verification_stage,
        run_scan_extract_stage,
    };
    use serde_json::Value;
    use std::fs;
    use std::path::{Path, PathBuf};

    #[test]
    fn full_lazarus_path_reaches_cutover_ready() {
        let root = fixture("full_path");
        let out_dir = root.join("target/lazarus");
        let runbook_path = root.join("runbook.md");
        fs::write(
            &runbook_path,
            "rollback: restore legacy route\ncutover: switch read-only traffic first\n",
        )
        .unwrap();

        let mut orchestrator = LazarusOrchestrator::new();
        orchestrator.create_job("job-1", "full_path").unwrap();
        let config =
            PipelineConfig::repo_default(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".."));

        let scan_extract = run_scan_extract_stage(
            std::slice::from_ref(&root),
            &mut orchestrator,
            "job-1",
            &config,
        )
        .unwrap();
        let legacy = find_ir_by_function_target(&scan_extract.extract.irs, "legacy_fee").unwrap();
        let refactored =
            find_ir_by_function_target(&scan_extract.extract.irs, "refactored_fee").unwrap();
        let verification =
            run_bounded_verification_stage(&mut orchestrator, "job-1", legacy, refactored, &config)
                .unwrap();
        assert_eq!(
            verification.report.verdict,
            lazarus_contracts::EquivalenceVerdict::Equivalent
        );

        let converter_config = ConverterConfig::new("fees", "compute_fee", &out_dir);
        let conversion =
            convert_verified_ir(&mut orchestrator, "job-1", refactored, &converter_config).unwrap();
        let compile = compile_artifact(
            &mut orchestrator,
            "job-1",
            &conversion.artifact,
            &converter_config,
        )
        .unwrap();
        let wasm_config = WasmRunnerConfig::new("compute_fee", &out_dir);
        let wasm = compile_wasm_artifact(refactored, &wasm_config).unwrap();
        let wasm_executor = WasmArtifactExecutor::new().unwrap();

        let snapshots = vec![
            TrafficSnapshot::new(
                "req-1",
                "fee",
                1_700_000_000,
                serde_json::json!({"amount": 1, "request_id": "a"}),
                Vec::new(),
            )
            .unwrap(),
            TrafficSnapshot::new(
                "req-2",
                "fee",
                1_700_000_001,
                serde_json::json!({"amount": 3, "request_id": "b"}),
                Vec::new(),
            )
            .unwrap(),
        ];
        let hydration_plan = HydrationPlan::new(
            "fee",
            std::collections::BTreeMap::from([(
                "amount".to_string(),
                "/payload/amount".to_string(),
            )]),
        );
        let replays = hydrate_snapshots(&snapshots, refactored, &hydration_plan).unwrap();
        let requests = shadow_requests(&replays);
        let primary = |payload: &Value| {
            Ok(serde_json::json!({
                "value": payload["amount"].as_i64().unwrap() * 2,
                "trace": "legacy"
            }))
        };
        let wasm_fuel = wasm_config.fuel;
        let shadow =
            move |payload: &Value| wasm_executor.execute_as_json(&wasm, payload, wasm_fuel);
        let mut shadow_config = ShadowRunnerConfig::new(root.join("shadow-ledger.jsonl"));
        shadow_config.ignored_fields.insert("trace".to_string());
        shadow_config.inject_shadow_marker = false;
        let shadow_output = run_shadow_batch(
            &mut orchestrator,
            "job-1",
            &requests,
            &primary,
            &shadow,
            &shadow_config,
        )
        .unwrap();
        assert!(shadow_output.summary.is_promotion_clean());

        let promotion =
            evaluate_and_promote(&mut orchestrator, "job-1", &PromotionPolicy::default()).unwrap();
        assert!(promotion.promoted);
        orchestrator
            .apply(
                "job-1",
                LazarusJobEvent::Approved {
                    approver: "risk-officer".to_string(),
                },
            )
            .unwrap();

        let cutover = prepare_cutover(
            &mut orchestrator,
            "job-1",
            &CutoverGateInput {
                compile_receipt: compile.receipt.clone(),
                runbook_path: runbook_path.clone(),
            },
            &CutoverGateConfig {
                min_shadow_samples: 2,
                require_artifact_files: true,
                require_rollback_runbook: true,
            },
        )
        .unwrap();

        assert!(cutover.accepted, "{:?}", cutover.reasons);
        assert_eq!(
            orchestrator.job("job-1").unwrap().state,
            lazarus_contracts::LazarusJobState::CutoverReady
        );
        let evidence = write_evidence_pack(&EvidencePackInput {
            job: orchestrator.job("job-1").unwrap().clone(),
            compile_receipt: compile.receipt,
            cutover_report: cutover,
            shadow_ledger_path: shadow_config.ledger_path.clone(),
            runbook_path,
            output_dir: out_dir.join("evidence"),
            signer: EvidenceSigner::deterministic_test_signer(),
        })
        .unwrap();
        assert!(evidence.manifest_path.is_file());

        let _ = fs::remove_dir_all(root);
    }

    fn fixture(name: &str) -> PathBuf {
        let root = std::env::temp_dir()
            .join(format!("lazarus-e2e-fixtures-{}", std::process::id()))
            .join(name);
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(
            root.join("Cargo.toml"),
            format!("[package]\nname = \"{name}\"\nversion = \"0.1.0\"\nedition = \"2024\"\n"),
        )
        .unwrap();
        fs::write(
            root.join("src/lib.rs"),
            "pub fn legacy_fee(amount: i64) -> i64 { amount * 2 }\n\
             pub fn refactored_fee(amount: i64) -> i64 { amount + amount }\n",
        )
        .unwrap();
        assert_path(&root);
        root
    }

    fn assert_path(path: &Path) {
        assert!(path.exists(), "path missing: {}", path.display());
    }
}
