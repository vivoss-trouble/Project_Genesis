use lazarus_contracts::{LazarusJobEvent, LazarusJobState};
use lazarus_converter_pipeline::CompileReceipt;
use lazarus_orchestrator::{
    LazarusOrchestrator, ShadowLedger, ShadowLedgerSummary, StateTransition,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use std::fs;
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CutoverGateConfig {
    pub min_shadow_samples: u64,
    pub require_artifact_files: bool,
    pub require_rollback_runbook: bool,
}

impl Default for CutoverGateConfig {
    fn default() -> Self {
        Self {
            min_shadow_samples: 1,
            require_artifact_files: true,
            require_rollback_runbook: true,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CutoverGateInput {
    pub compile_receipt: CompileReceipt,
    pub runbook_path: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CutoverGateReport {
    pub accepted: bool,
    pub reasons: Vec<String>,
    pub runbook_hash: Option<String>,
    pub artifact_hash: Option<String>,
    pub shadow_summary: Option<ShadowLedgerSummaryDto>,
    pub transition: Option<StateTransition>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShadowLedgerSummaryDto {
    pub total: u64,
    pub matches: u64,
    pub mismatches: u64,
    pub errors: u64,
}

impl From<ShadowLedgerSummary> for ShadowLedgerSummaryDto {
    fn from(value: ShadowLedgerSummary) -> Self {
        Self {
            total: value.total,
            matches: value.matches,
            mismatches: value.mismatches,
            errors: value.errors,
        }
    }
}

pub fn prepare_cutover(
    orchestrator: &mut LazarusOrchestrator,
    job_id: &str,
    input: &CutoverGateInput,
    config: &CutoverGateConfig,
) -> Result<CutoverGateReport, String> {
    let Some(job) = orchestrator.job(job_id) else {
        return Err(format!("unknown Lazarus job: {job_id}"));
    };

    let mut reasons = Vec::new();
    let evidence = job.evidence.clone();
    if job.state != LazarusJobState::Approved {
        reasons.push(format!(
            "job state must be Approved before cutover preparation, got {:?}",
            job.state
        ));
    }

    require_evidence(&evidence, "graph_hash", &mut reasons);
    require_evidence(&evidence, "ir_hash", &mut reasons);
    require_evidence(&evidence, "equivalence_report_hash", &mut reasons);
    require_evidence(&evidence, "artifact_hash", &mut reasons);
    require_evidence(&evidence, "shadow_ledger_path", &mut reasons);
    require_evidence(&evidence, "shadow_sample_count", &mut reasons);
    require_evidence(&evidence, "shadow_mismatch_count", &mut reasons);
    require_evidence(&evidence, "approver", &mut reasons);

    let artifact_hash = validate_compile_receipt(&input.compile_receipt, config, &mut reasons);
    if let (Some(expected), Some(actual)) = (evidence.get("artifact_hash"), artifact_hash.as_ref())
        && expected != actual
    {
        reasons.push(format!(
            "compiled artifact hash mismatch: job evidence has {expected}, receipt has {actual}"
        ));
    }

    let shadow_summary = evidence
        .get("shadow_ledger_path")
        .and_then(|path| summarize_shadow_ledger(path, &mut reasons));
    if let Some(summary) = shadow_summary.as_ref()
        && summary.total < config.min_shadow_samples
    {
        reasons.push(format!(
            "shadow sample count {} is below required minimum {}",
            summary.total, config.min_shadow_samples
        ));
    }
    if let Some(summary) = shadow_summary.as_ref() {
        if !summary.is_promotion_clean() {
            reasons.push(format!(
                "shadow ledger is not clean: total={}, matches={}, mismatches={}, errors={}",
                summary.total, summary.matches, summary.mismatches, summary.errors
            ));
        }
        if let Some(recorded) = evidence.get("shadow_sample_count") {
            match recorded.parse::<u64>() {
                Ok(value) if value == summary.total => {}
                Ok(value) => reasons.push(format!(
                    "shadow sample count evidence mismatch: evidence={value}, ledger={}",
                    summary.total
                )),
                Err(_) => reasons.push(format!(
                    "shadow_sample_count evidence is not a u64: {recorded}"
                )),
            }
        }
        if let Some(recorded) = evidence.get("shadow_mismatch_count") {
            match recorded.parse::<u64>() {
                Ok(value) if value == summary.mismatches => {}
                Ok(value) => reasons.push(format!(
                    "shadow mismatch count evidence mismatch: evidence={value}, ledger={}",
                    summary.mismatches
                )),
                Err(_) => reasons.push(format!(
                    "shadow_mismatch_count evidence is not a u64: {recorded}"
                )),
            }
        }
    }

    let runbook_hash = validate_runbook(
        &input.runbook_path,
        config.require_rollback_runbook,
        &mut reasons,
    );
    if !reasons.is_empty() {
        return Ok(CutoverGateReport {
            accepted: false,
            reasons,
            runbook_hash,
            artifact_hash,
            shadow_summary: shadow_summary.map(Into::into),
            transition: None,
        });
    }

    let runbook_hash = runbook_hash.ok_or_else(|| "runbook hash missing".to_string())?;
    let transition = orchestrator.apply(
        job_id,
        LazarusJobEvent::CutoverPrepared {
            runbook_hash: runbook_hash.clone(),
        },
    )?;

    Ok(CutoverGateReport {
        accepted: true,
        reasons: Vec::new(),
        runbook_hash: Some(runbook_hash),
        artifact_hash,
        shadow_summary: shadow_summary.map(Into::into),
        transition: Some(transition),
    })
}

fn require_evidence(
    evidence: &std::collections::BTreeMap<String, String>,
    key: &str,
    reasons: &mut Vec<String>,
) {
    if evidence
        .get(key)
        .is_none_or(|value| value.trim().is_empty())
    {
        reasons.push(format!("missing required job evidence: {key}"));
    }
}

fn validate_compile_receipt(
    receipt: &CompileReceipt,
    config: &CutoverGateConfig,
    reasons: &mut Vec<String>,
) -> Option<String> {
    if config.require_artifact_files && !receipt.artifact_path.is_file() {
        reasons.push(format!(
            "generated source artifact does not exist: {}",
            receipt.artifact_path.display()
        ));
    }
    if config.require_artifact_files && !receipt.output_path.is_file() {
        reasons.push(format!(
            "compiled artifact does not exist: {}",
            receipt.output_path.display()
        ));
    }

    match fs::read(&receipt.artifact_path) {
        Ok(bytes) => {
            let actual = hex_sha256(&bytes);
            if actual != receipt.artifact_hash {
                reasons.push(format!(
                    "compile receipt hash mismatch: receipt={}, actual={actual}",
                    receipt.artifact_hash
                ));
            }
            Some(actual)
        }
        Err(error) => {
            reasons.push(format!(
                "failed to read generated source artifact {}: {error}",
                receipt.artifact_path.display()
            ));
            None
        }
    }
}

fn summarize_shadow_ledger(path: &str, reasons: &mut Vec<String>) -> Option<ShadowLedgerSummary> {
    match ShadowLedger::new(PathBuf::from(path)).summarize() {
        Ok(summary) => Some(summary),
        Err(error) => {
            reasons.push(format!("failed to summarize shadow ledger {path}: {error}"));
            None
        }
    }
}

fn validate_runbook(
    path: &PathBuf,
    require_rollback: bool,
    reasons: &mut Vec<String>,
) -> Option<String> {
    match fs::read(path) {
        Ok(bytes) if bytes.iter().any(|byte| !byte.is_ascii_whitespace()) => {
            if require_rollback {
                let body = String::from_utf8_lossy(&bytes).to_ascii_lowercase();
                if !body.contains("rollback") {
                    reasons.push(format!(
                        "runbook must contain rollback instructions: {}",
                        path.display()
                    ));
                }
            }
            Some(hex_sha256(&bytes))
        }
        Ok(_) => {
            reasons.push(format!("runbook is empty: {}", path.display()));
            None
        }
        Err(error) => {
            reasons.push(format!(
                "failed to read runbook {}: {error}",
                path.display()
            ));
            None
        }
    }
}

fn hex_sha256(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::{DecisionExpr, DecisionIr};
    use lazarus_contracts::{LazarusJobEvent, ShadowReport, ShadowVerdict};
    use lazarus_converter_pipeline::{ConverterConfig, compile_artifact, convert_verified_ir};
    use lazarus_orchestrator::ShadowLedger;
    use std::collections::BTreeMap;

    #[test]
    fn clean_evidence_prepares_cutover() {
        let root = test_dir("clean");
        let config = ConverterConfig::new("fees", "compute_fee", root.join("artifact"));
        let mut verified = verified_orchestrator();
        let conversion =
            convert_verified_ir(&mut verified, "job-1", &sample_ir(), &config).unwrap();
        let compile =
            compile_artifact(&mut verified, "job-1", &conversion.artifact, &config).unwrap();
        let mut orchestrator =
            approved_orchestrator(&root, &compile.receipt.artifact_hash, true, 0);
        let runbook_path = root.join("runbook.md");
        fs::write(
            &runbook_path,
            "rollback: restore legacy route\ncutover: hold traffic, swap route, monitor\n",
        )
        .unwrap();

        let report = prepare_cutover(
            &mut orchestrator,
            "job-1",
            &CutoverGateInput {
                compile_receipt: compile.receipt,
                runbook_path,
            },
            &CutoverGateConfig {
                min_shadow_samples: 2,
                require_artifact_files: true,
                require_rollback_runbook: true,
            },
        )
        .unwrap();

        assert!(report.accepted);
        assert!(report.reasons.is_empty());
        assert_eq!(
            orchestrator.job("job-1").unwrap().state,
            LazarusJobState::CutoverReady
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn mismatched_shadow_blocks_cutover_without_state_change() {
        let root = test_dir("mismatch");
        let config = ConverterConfig::new("fees", "compute_fee", root.join("artifact"));
        let mut verified = verified_orchestrator();
        let conversion =
            convert_verified_ir(&mut verified, "job-1", &sample_ir(), &config).unwrap();
        let compile =
            compile_artifact(&mut verified, "job-1", &conversion.artifact, &config).unwrap();
        let mut orchestrator =
            approved_orchestrator(&root, &compile.receipt.artifact_hash, false, 0);
        let runbook_path = root.join("runbook.md");
        fs::write(
            &runbook_path,
            "rollback: keep legacy route\ncutover: stop on mismatch\n",
        )
        .unwrap();

        let report = prepare_cutover(
            &mut orchestrator,
            "job-1",
            &CutoverGateInput {
                compile_receipt: compile.receipt,
                runbook_path,
            },
            &CutoverGateConfig::default(),
        )
        .unwrap();

        assert!(!report.accepted);
        assert!(
            report
                .reasons
                .iter()
                .any(|reason| reason.contains("shadow ledger is not clean"))
        );
        assert_eq!(
            orchestrator.job("job-1").unwrap().state,
            LazarusJobState::Approved
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn missing_approval_blocks_cutover() {
        let root = test_dir("state");
        let config = ConverterConfig::new("fees", "compute_fee", root.join("artifact"));
        let mut verified = verified_orchestrator();
        let conversion =
            convert_verified_ir(&mut verified, "job-1", &sample_ir(), &config).unwrap();
        let compile =
            compile_artifact(&mut verified, "job-1", &conversion.artifact, &config).unwrap();
        let mut orchestrator =
            compiled_orchestrator(&root, &compile.receipt.artifact_hash, true, 0);
        let runbook_path = root.join("runbook.md");
        fs::write(
            &runbook_path,
            "rollback: do not switch route\ncutover: requires approval\n",
        )
        .unwrap();

        let report = prepare_cutover(
            &mut orchestrator,
            "job-1",
            &CutoverGateInput {
                compile_receipt: compile.receipt,
                runbook_path,
            },
            &CutoverGateConfig::default(),
        )
        .unwrap();

        assert!(!report.accepted);
        assert!(
            report
                .reasons
                .iter()
                .any(|reason| reason.contains("job state must be Approved"))
        );
        assert_eq!(
            orchestrator.job("job-1").unwrap().state,
            LazarusJobState::PromotionCandidate
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn runbook_without_rollback_blocks_cutover() {
        let root = test_dir("rollback");
        let config = ConverterConfig::new("fees", "compute_fee", root.join("artifact"));
        let mut verified = verified_orchestrator();
        let conversion =
            convert_verified_ir(&mut verified, "job-1", &sample_ir(), &config).unwrap();
        let compile =
            compile_artifact(&mut verified, "job-1", &conversion.artifact, &config).unwrap();
        let mut orchestrator =
            approved_orchestrator(&root, &compile.receipt.artifact_hash, true, 0);
        let runbook_path = root.join("runbook.md");
        fs::write(&runbook_path, "cutover: switch route only\n").unwrap();

        let report = prepare_cutover(
            &mut orchestrator,
            "job-1",
            &CutoverGateInput {
                compile_receipt: compile.receipt,
                runbook_path,
            },
            &CutoverGateConfig::default(),
        )
        .unwrap();

        assert!(!report.accepted);
        assert!(
            report
                .reasons
                .iter()
                .any(|reason| reason.contains("rollback"))
        );
        assert_eq!(
            orchestrator.job("job-1").unwrap().state,
            LazarusJobState::Approved
        );
        let _ = fs::remove_dir_all(root);
    }

    fn approved_orchestrator(
        root: &std::path::Path,
        artifact_hash: &str,
        clean_shadow: bool,
        reported_mismatches: u64,
    ) -> LazarusOrchestrator {
        let mut orchestrator =
            compiled_orchestrator(root, artifact_hash, clean_shadow, reported_mismatches);
        orchestrator
            .apply(
                "job-1",
                LazarusJobEvent::Approved {
                    approver: "risk-officer".to_string(),
                },
            )
            .unwrap();
        orchestrator
    }

    fn compiled_orchestrator(
        root: &std::path::Path,
        artifact_hash: &str,
        clean_shadow: bool,
        reported_mismatches: u64,
    ) -> LazarusOrchestrator {
        let mut orchestrator = verified_orchestrator();
        orchestrator
            .apply(
                "job-1",
                LazarusJobEvent::RustGenerated {
                    artifact_hash: artifact_hash.to_string(),
                },
            )
            .unwrap();
        orchestrator
            .apply(
                "job-1",
                LazarusJobEvent::CompilePassed {
                    artifact_hash: artifact_hash.to_string(),
                },
            )
            .unwrap();
        let ledger_path = root.join("shadow.jsonl");
        write_shadow_ledger(&ledger_path, clean_shadow);
        orchestrator
            .apply(
                "job-1",
                LazarusJobEvent::ShadowStarted {
                    ledger_path: ledger_path.to_string_lossy().into_owned(),
                },
            )
            .unwrap();
        orchestrator
            .apply(
                "job-1",
                LazarusJobEvent::ShadowPromotionCandidate {
                    sample_count: 2,
                    mismatch_count: reported_mismatches,
                },
            )
            .unwrap();
        orchestrator
    }

    fn verified_orchestrator() -> LazarusOrchestrator {
        let mut orchestrator = LazarusOrchestrator::new();
        orchestrator.create_job("job-1", "bank-core").unwrap();
        orchestrator
            .apply(
                "job-1",
                LazarusJobEvent::ScanCompleted {
                    graph_hash: "1".repeat(64),
                },
            )
            .unwrap();
        orchestrator
            .apply(
                "job-1",
                LazarusJobEvent::IrExtracted {
                    ir_hash: "2".repeat(64),
                },
            )
            .unwrap();
        orchestrator
            .apply(
                "job-1",
                LazarusJobEvent::BoundedVerificationPassed {
                    report_hash: "3".repeat(64),
                },
            )
            .unwrap();
        orchestrator
    }

    fn write_shadow_ledger(path: &std::path::Path, clean: bool) {
        let ledger = ShadowLedger::new(path);
        ledger
            .append(&ShadowReport {
                request_id: "req-1".to_string(),
                operation: "fee".to_string(),
                verdict: ShadowVerdict::Match,
                primary_hash: Some("a".repeat(64)),
                shadow_hash: Some("a".repeat(64)),
                diff: BTreeMap::new(),
                elapsed_ms: 2,
                error: None,
            })
            .unwrap();
        ledger
            .append(&ShadowReport {
                request_id: "req-2".to_string(),
                operation: "fee".to_string(),
                verdict: if clean {
                    ShadowVerdict::Match
                } else {
                    ShadowVerdict::Mismatch
                },
                primary_hash: Some("b".repeat(64)),
                shadow_hash: Some(if clean { "b" } else { "c" }.repeat(64)),
                diff: BTreeMap::new(),
                elapsed_ms: 3,
                error: None,
            })
            .unwrap();
    }

    fn sample_ir() -> DecisionIr {
        DecisionIr {
            ir_id: "sample-ir".to_string(),
            source_unit_id: "bank/src/lib.rs".to_string(),
            input_domains: BTreeMap::from([("input".to_string(), vec![0, 1, 2])]),
            expression: DecisionExpr::Mul {
                left: Box::new(DecisionExpr::Var {
                    name: "input".to_string(),
                }),
                right: Box::new(DecisionExpr::Const { value: 2 }),
            },
            side_effects: Vec::new(),
            invariants: Vec::new(),
        }
    }

    fn test_dir(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "lazarus-cutover-gate-{label}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }
}
