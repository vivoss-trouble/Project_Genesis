use lazarus_artifact_runner::{WasmArtifactExecutor, WasmRunnerConfig, compile_wasm_artifact};
use lazarus_contracts::{DecisionExpr, DecisionIr, EquivalenceVerdict, LazarusJobEvent};
use lazarus_converter_pipeline::{ConverterConfig, compile_artifact, convert_verified_ir};
use lazarus_cutover_gate::{CutoverGateConfig, CutoverGateInput, prepare_cutover};
use lazarus_evidence_pack::{EvidencePackInput, EvidenceSigner, write_evidence_pack};
use lazarus_orchestrator::LazarusOrchestrator;
use lazarus_promotion_controller::{PromotionPolicy, evaluate_and_promote};
use lazarus_shadow_runner::{ShadowRequest, ShadowRunnerConfig, run_shadow_batch};
use lazarus_verification_pipeline::{
    PipelineConfig, find_ir_by_function_target, run_bounded_verification_stage,
    run_scan_extract_stage,
};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

mod commands;

use commands::corpus::{run_corpus_ingest, run_corpus_report};
use commands::synthesis::run_synthesis_smoke;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args = std::env::args().collect::<Vec<_>>();
    match args.get(1).map(String::as_str) {
        Some("lazarus-smoke") => run_lazarus_smoke(&args[2..]),
        Some("corpus-ingest") => run_corpus_ingest(&args[2..]),
        Some("corpus-report") => run_corpus_report(&args[2..]),
        Some("synthesis-smoke") => run_synthesis_smoke(&args[2..]),
        _ => {
            eprintln!(
                "usage:\n  genesis-cli lazarus-smoke <crate-root> <legacy-fn> <refactored-fn> <out-dir>\n  genesis-cli corpus-ingest <snapshot-file-or-dir> <out-dir>\n  genesis-cli corpus-report <snapshot-file-or-dir> <report-json>\n  genesis-cli synthesis-smoke <snapshot-file-or-dir> <business-method> <java-source-file> <out-dir>"
            );
            Ok(())
        }
    }
}

fn run_lazarus_smoke(args: &[String]) -> Result<(), String> {
    if args.len() != 4 {
        return Err(
            "usage: genesis-cli lazarus-smoke <crate-root> <legacy-fn> <refactored-fn> <out-dir>"
                .to_string(),
        );
    }
    let crate_root = PathBuf::from(&args[0]);
    let legacy_fn = &args[1];
    let refactored_fn = &args[2];
    let out_dir = PathBuf::from(&args[3]);
    fs::create_dir_all(&out_dir).map_err(|error| error.to_string())?;

    let mut orchestrator = LazarusOrchestrator::new();
    orchestrator.create_job("cli-smoke", "cli-smoke")?;
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    let config = PipelineConfig::repo_default(repo_root);
    let scan_extract =
        run_scan_extract_stage(&[crate_root], &mut orchestrator, "cli-smoke", &config)?;
    let legacy = find_ir_by_function_target(&scan_extract.extract.irs, legacy_fn)
        .ok_or_else(|| format!("legacy function not extracted: {legacy_fn}"))?;
    let refactored = find_ir_by_function_target(&scan_extract.extract.irs, refactored_fn)
        .ok_or_else(|| format!("refactored function not extracted: {refactored_fn}"))?;
    let verification = run_bounded_verification_stage(
        &mut orchestrator,
        "cli-smoke",
        legacy,
        refactored,
        &config,
    )?;
    if verification.report.verdict != EquivalenceVerdict::Equivalent {
        return Err(format!(
            "bounded verification did not pass: {:?}",
            verification.report
        ));
    }

    let converter_config = ConverterConfig::new("lazarus_generated", refactored_fn, &out_dir);
    let conversion = convert_verified_ir(
        &mut orchestrator,
        "cli-smoke",
        refactored,
        &converter_config,
    )?;
    let compile = compile_artifact(
        &mut orchestrator,
        "cli-smoke",
        &conversion.artifact,
        &converter_config,
    )?;
    let wasm_config = WasmRunnerConfig::new(refactored_fn, &out_dir);
    let wasm = compile_wasm_artifact(refactored, &wasm_config)?;
    let wasm_executor = WasmArtifactExecutor::new()?;

    let requests = shadow_requests_from_ir(legacy)?;
    let legacy_ir = legacy.clone();
    let wasm_for_shadow = wasm.clone();
    let wasm_fuel = wasm_config.fuel;
    let primary = move |payload: &Value| evaluate_payload(&legacy_ir, payload);
    let shadow =
        move |payload: &Value| wasm_executor.execute_as_json(&wasm_for_shadow, payload, wasm_fuel);
    let mut shadow_config = ShadowRunnerConfig::new(out_dir.join("shadow-ledger.jsonl"));
    shadow_config
        .ignored_fields
        .insert("_lazarus_shadow_mode".to_string());
    let shadow_output = run_shadow_batch(
        &mut orchestrator,
        "cli-smoke",
        &requests,
        &primary,
        &shadow,
        &shadow_config,
    )?;
    if !shadow_output.summary.is_promotion_clean() {
        return Err(format!(
            "shadow run was not clean: {:?}",
            shadow_output.summary
        ));
    }

    let promotion =
        evaluate_and_promote(&mut orchestrator, "cli-smoke", &PromotionPolicy::default())?;
    if !promotion.promoted {
        return Err(format!("promotion blocked: {:?}", promotion.reasons));
    }
    orchestrator.apply(
        "cli-smoke",
        LazarusJobEvent::Approved {
            approver: "cli-smoke".to_string(),
        },
    )?;
    let runbook_path = out_dir.join("cutover-runbook.md");
    fs::write(
        &runbook_path,
        "rollback: keep legacy route available\ncutover: switch after clean shadow run\n",
    )
    .map_err(|error| error.to_string())?;
    let cutover = prepare_cutover(
        &mut orchestrator,
        "cli-smoke",
        &CutoverGateInput {
            compile_receipt: compile.receipt.clone(),
            runbook_path: runbook_path.clone(),
        },
        &CutoverGateConfig {
            min_shadow_samples: requests.len() as u64,
            require_artifact_files: true,
            require_rollback_runbook: true,
        },
    )?;
    if !cutover.accepted {
        return Err(format!("cutover gate blocked: {:?}", cutover.reasons));
    }
    let evidence = write_evidence_pack(&EvidencePackInput {
        job: orchestrator.job("cli-smoke").unwrap().clone(),
        compile_receipt: compile.receipt,
        cutover_report: cutover,
        shadow_ledger_path: shadow_config.ledger_path.clone(),
        runbook_path,
        output_dir: out_dir.join("evidence"),
        signer: EvidenceSigner::from_env_or_deterministic_test_signer(),
    })?;

    println!(
        "lazarus-smoke passed: target=wasm32-wasip1, units={}, irs={}, shadow_samples={}, state={:?}, evidence={}",
        scan_extract.summary.scan_unit_count,
        scan_extract.summary.ir_count,
        requests.len(),
        orchestrator.job("cli-smoke").unwrap().state,
        evidence.manifest_path.display()
    );
    Ok(())
}

fn shadow_requests_from_ir(ir: &DecisionIr) -> Result<Vec<ShadowRequest>, String> {
    let domains = ir.input_domains.iter().collect::<Vec<_>>();
    let mut rows = Vec::new();
    build_domain_rows(&domains, 0, &mut BTreeMap::new(), &mut rows);
    Ok(rows
        .into_iter()
        .take(100)
        .enumerate()
        .map(|(index, row)| ShadowRequest {
            request_id: format!("case-{index}"),
            operation: ir.ir_id.clone(),
            payload: serde_json::to_value(row).expect("BTreeMap<String, i64> serializes"),
        })
        .collect())
}

fn build_domain_rows(
    domains: &[(&String, &Vec<i64>)],
    index: usize,
    current: &mut BTreeMap<String, i64>,
    rows: &mut Vec<BTreeMap<String, i64>>,
) {
    if index == domains.len() {
        rows.push(current.clone());
        return;
    }
    let (name, values) = domains[index];
    for value in values.iter().take(10) {
        current.insert(name.clone(), *value);
        build_domain_rows(domains, index + 1, current, rows);
    }
    current.remove(name);
}

fn evaluate_payload(ir: &DecisionIr, payload: &Value) -> Result<Value, String> {
    let map = payload
        .as_object()
        .ok_or_else(|| "shadow payload must be a JSON object".to_string())?;
    let mut vars = BTreeMap::new();
    for name in ir.input_domains.keys() {
        if name == "__unit" {
            vars.insert(name.clone(), 0);
            continue;
        }
        let value = map
            .get(name)
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("missing i64 payload field: {name}"))?;
        vars.insert(name.clone(), value);
    }
    Ok(serde_json::json!({"value": eval_expr(&ir.expression, &vars)?}))
}

fn eval_expr(expr: &DecisionExpr, vars: &BTreeMap<String, i64>) -> Result<i64, String> {
    match expr {
        DecisionExpr::Const { value } => Ok(*value),
        DecisionExpr::Var { name } => vars
            .get(name)
            .copied()
            .ok_or_else(|| format!("unknown variable: {name}")),
        DecisionExpr::Add { left, right } => {
            Ok(eval_expr(left, vars)?.saturating_add(eval_expr(right, vars)?))
        }
        DecisionExpr::Sub { left, right } => {
            Ok(eval_expr(left, vars)?.saturating_sub(eval_expr(right, vars)?))
        }
        DecisionExpr::Mul { left, right } => {
            Ok(eval_expr(left, vars)?.saturating_mul(eval_expr(right, vars)?))
        }
        DecisionExpr::Min { left, right } => Ok(std::cmp::min(
            eval_expr(left, vars)?,
            eval_expr(right, vars)?,
        )),
        DecisionExpr::Max { left, right } => Ok(std::cmp::max(
            eval_expr(left, vars)?,
            eval_expr(right, vars)?,
        )),
        DecisionExpr::Abs { value } => Ok(eval_expr(value, vars)?.saturating_abs()),
    }
}

#[allow(dead_code)]
fn assert_path(path: &Path) -> Result<(), String> {
    if path.exists() {
        Ok(())
    } else {
        Err(format!("path does not exist: {}", path.display()))
    }
}
