use lazarus_contracts::{LazarusJobEvent, LazarusJobState};
use lazarus_orchestrator::{
    LazarusOrchestrator, ShadowLedger, ShadowLedgerSummary, StateTransition,
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PromotionPolicy {
    pub min_shadow_samples: u64,
    pub max_mismatches: u64,
    pub max_errors: u64,
}

impl Default for PromotionPolicy {
    fn default() -> Self {
        Self {
            min_shadow_samples: 1,
            max_mismatches: 0,
            max_errors: 0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PromotionReport {
    pub promoted: bool,
    pub reasons: Vec<String>,
    pub summary: PromotionSummary,
    pub transition: Option<StateTransition>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PromotionSummary {
    pub total: u64,
    pub matches: u64,
    pub mismatches: u64,
    pub errors: u64,
}

impl From<ShadowLedgerSummary> for PromotionSummary {
    fn from(value: ShadowLedgerSummary) -> Self {
        Self {
            total: value.total,
            matches: value.matches,
            mismatches: value.mismatches,
            errors: value.errors,
        }
    }
}

pub fn evaluate_and_promote(
    orchestrator: &mut LazarusOrchestrator,
    job_id: &str,
    policy: &PromotionPolicy,
) -> Result<PromotionReport, String> {
    let Some(job) = orchestrator.job(job_id) else {
        return Err(format!("unknown Lazarus job: {job_id}"));
    };
    if job.state != LazarusJobState::ShadowRunning {
        return Err(format!(
            "promotion evaluation requires ShadowRunning state, got {:?}",
            job.state
        ));
    }
    let ledger_path = job
        .evidence
        .get("shadow_ledger_path")
        .ok_or_else(|| "missing shadow_ledger_path evidence".to_string())?
        .clone();
    let summary = ShadowLedger::new(PathBuf::from(&ledger_path)).summarize()?;
    let reasons = evaluate_summary(&summary, policy);
    if !reasons.is_empty() {
        return Ok(PromotionReport {
            promoted: false,
            reasons,
            summary: summary.into(),
            transition: None,
        });
    }

    let transition = orchestrator.apply(
        job_id,
        LazarusJobEvent::ShadowPromotionCandidate {
            sample_count: summary.total,
            mismatch_count: summary.mismatches,
        },
    )?;

    Ok(PromotionReport {
        promoted: true,
        reasons: Vec::new(),
        summary: summary.into(),
        transition: Some(transition),
    })
}

fn evaluate_summary(summary: &ShadowLedgerSummary, policy: &PromotionPolicy) -> Vec<String> {
    let mut reasons = Vec::new();
    if summary.total < policy.min_shadow_samples {
        reasons.push(format!(
            "shadow sample count {} is below required minimum {}",
            summary.total, policy.min_shadow_samples
        ));
    }
    if summary.mismatches > policy.max_mismatches {
        reasons.push(format!(
            "shadow mismatch count {} exceeds maximum {}",
            summary.mismatches, policy.max_mismatches
        ));
    }
    if summary.errors > policy.max_errors {
        reasons.push(format!(
            "shadow error count {} exceeds maximum {}",
            summary.errors, policy.max_errors
        ));
    }
    if summary.matches + summary.mismatches + summary.errors != summary.total {
        reasons.push("shadow ledger summary is internally inconsistent".to_string());
    }
    reasons
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::{LazarusJobEvent, ShadowReport, ShadowVerdict};
    use lazarus_orchestrator::ShadowLedger;
    use serde_json::Value;
    use std::collections::BTreeMap;

    #[test]
    fn clean_ledger_promotes_job() {
        let root = test_dir("clean");
        let ledger_path = root.join("shadow.jsonl");
        write_report(&ledger_path, ShadowVerdict::Match);
        write_report(&ledger_path, ShadowVerdict::Match);
        let mut orchestrator = shadow_running_orchestrator(&ledger_path);

        let report =
            evaluate_and_promote(&mut orchestrator, "job-1", &PromotionPolicy::default()).unwrap();

        assert!(report.promoted);
        assert_eq!(report.summary.total, 2);
        assert_eq!(
            orchestrator.job("job-1").unwrap().state,
            LazarusJobState::PromotionCandidate
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn mismatch_blocks_without_state_change() {
        let root = test_dir("mismatch");
        let ledger_path = root.join("shadow.jsonl");
        write_report(&ledger_path, ShadowVerdict::Match);
        write_report(&ledger_path, ShadowVerdict::Mismatch);
        let mut orchestrator = shadow_running_orchestrator(&ledger_path);

        let report =
            evaluate_and_promote(&mut orchestrator, "job-1", &PromotionPolicy::default()).unwrap();

        assert!(!report.promoted);
        assert!(
            report
                .reasons
                .iter()
                .any(|reason| reason.contains("mismatch"))
        );
        assert_eq!(
            orchestrator.job("job-1").unwrap().state,
            LazarusJobState::ShadowRunning
        );
        let _ = std::fs::remove_dir_all(root);
    }

    fn shadow_running_orchestrator(ledger_path: &std::path::Path) -> LazarusOrchestrator {
        let mut orchestrator = LazarusOrchestrator::new();
        orchestrator.create_job("job-1", "bank-core").unwrap();
        for event in [
            LazarusJobEvent::ScanCompleted {
                graph_hash: "1".repeat(64),
            },
            LazarusJobEvent::IrExtracted {
                ir_hash: "2".repeat(64),
            },
            LazarusJobEvent::BoundedVerificationPassed {
                report_hash: "3".repeat(64),
            },
            LazarusJobEvent::RustGenerated {
                artifact_hash: "4".repeat(64),
            },
            LazarusJobEvent::CompilePassed {
                artifact_hash: "4".repeat(64),
            },
            LazarusJobEvent::ShadowStarted {
                ledger_path: ledger_path.to_string_lossy().into_owned(),
            },
        ] {
            orchestrator.apply("job-1", event).unwrap();
        }
        orchestrator
    }

    fn write_report(path: &std::path::Path, verdict: ShadowVerdict) {
        ShadowLedger::new(path)
            .append(&ShadowReport {
                request_id: format!("req-{verdict:?}"),
                operation: "fee".to_string(),
                verdict,
                primary_hash: Some("a".repeat(64)),
                shadow_hash: Some("a".repeat(64)),
                diff: BTreeMap::<String, Value>::new(),
                elapsed_ms: 1,
                error: None,
            })
            .unwrap();
    }

    fn test_dir(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "lazarus-promotion-controller-{label}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }
}
