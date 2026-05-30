use lazarus_contracts::{
    LazarusJob, LazarusJobEvent, LazarusJobState, ShadowReport, ShadowVerdict,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StateTransition {
    pub job_id: String,
    pub from: LazarusJobState,
    pub to: LazarusJobState,
    pub event: LazarusJobEvent,
}

#[derive(Default)]
pub struct LazarusOrchestrator {
    jobs: BTreeMap<String, LazarusJob>,
}

impl LazarusOrchestrator {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn create_job(
        &mut self,
        job_id: impl Into<String>,
        codebase_id: impl Into<String>,
    ) -> Result<&LazarusJob, String> {
        let job = LazarusJob::new(job_id, codebase_id);
        job.validate()?;
        if self.jobs.contains_key(&job.job_id) {
            return Err(format!("duplicate Lazarus job: {}", job.job_id));
        }
        let key = job.job_id.clone();
        self.jobs.insert(key.clone(), job);
        self.jobs
            .get(&key)
            .ok_or_else(|| "job disappeared after insert".to_string())
    }

    pub fn job(&self, job_id: &str) -> Option<&LazarusJob> {
        self.jobs.get(job_id)
    }

    pub fn apply(
        &mut self,
        job_id: &str,
        event: LazarusJobEvent,
    ) -> Result<StateTransition, String> {
        let job = self
            .jobs
            .get_mut(job_id)
            .ok_or_else(|| format!("unknown Lazarus job: {job_id}"))?;
        let from = job.state;
        let to = next_state(from, &event)?;
        attach_evidence(job, &event);
        job.state = to;
        Ok(StateTransition {
            job_id: job_id.to_string(),
            from,
            to,
            event,
        })
    }
}

pub fn next_state(
    current: LazarusJobState,
    event: &LazarusJobEvent,
) -> Result<LazarusJobState, String> {
    use LazarusJobEvent as Event;
    use LazarusJobState as State;

    if matches!(
        current,
        State::FailedWithEvidence | State::ManualReview | State::CutoverReady
    ) {
        return match event {
            Event::ManualReviewRequested { .. } if current == State::FailedWithEvidence => {
                Ok(State::ManualReview)
            }
            _ => Err(format!(
                "terminal state {current:?} rejects event {event:?}"
            )),
        };
    }

    match (current, event) {
        (_, Event::Failed { .. }) => Ok(State::FailedWithEvidence),
        (_, Event::ManualReviewRequested { .. }) => Ok(State::ManualReview),
        (State::Discovered, Event::ScanCompleted { .. }) => Ok(State::Scanned),
        (State::Scanned, Event::IrExtracted { .. }) => Ok(State::IrExtracted),
        (State::IrExtracted, Event::BoundedVerificationPassed { .. }) => Ok(State::VerifiedBounded),
        (State::VerifiedBounded, Event::RustGenerated { .. }) => Ok(State::Generated),
        (State::Generated, Event::CompilePassed { .. }) => Ok(State::Compiled),
        (State::Compiled, Event::ShadowStarted { .. }) => Ok(State::ShadowRunning),
        (
            State::ShadowRunning,
            Event::ShadowPromotionCandidate {
                sample_count,
                mismatch_count,
            },
        ) if *sample_count > 0 && *mismatch_count == 0 => Ok(State::PromotionCandidate),
        (State::PromotionCandidate, Event::Approved { .. }) => Ok(State::Approved),
        (State::Approved, Event::CutoverPrepared { .. }) => Ok(State::CutoverReady),
        _ => Err(format!(
            "invalid transition from {current:?} with event {event:?}"
        )),
    }
}

fn attach_evidence(job: &mut LazarusJob, event: &LazarusJobEvent) {
    match event {
        LazarusJobEvent::ScanCompleted { graph_hash } => {
            job.evidence
                .insert("graph_hash".to_string(), graph_hash.clone());
        }
        LazarusJobEvent::IrExtracted { ir_hash } => {
            job.evidence.insert("ir_hash".to_string(), ir_hash.clone());
        }
        LazarusJobEvent::BoundedVerificationPassed { report_hash } => {
            job.evidence
                .insert("equivalence_report_hash".to_string(), report_hash.clone());
        }
        LazarusJobEvent::RustGenerated { artifact_hash }
        | LazarusJobEvent::CompilePassed { artifact_hash } => {
            job.evidence
                .insert("artifact_hash".to_string(), artifact_hash.clone());
        }
        LazarusJobEvent::ShadowStarted { ledger_path } => {
            job.evidence
                .insert("shadow_ledger_path".to_string(), ledger_path.clone());
        }
        LazarusJobEvent::CutoverPrepared { runbook_hash } => {
            job.evidence
                .insert("runbook_hash".to_string(), runbook_hash.clone());
        }
        LazarusJobEvent::Failed {
            reason,
            evidence_hash,
        } => {
            job.evidence
                .insert("failure_reason".to_string(), reason.clone());
            job.evidence
                .insert("failure_evidence_hash".to_string(), evidence_hash.clone());
        }
        LazarusJobEvent::Approved { approver } => {
            job.evidence
                .insert("approver".to_string(), approver.clone());
        }
        LazarusJobEvent::ShadowPromotionCandidate {
            sample_count,
            mismatch_count,
        } => {
            job.evidence
                .insert("shadow_sample_count".to_string(), sample_count.to_string());
            job.evidence.insert(
                "shadow_mismatch_count".to_string(),
                mismatch_count.to_string(),
            );
        }
        LazarusJobEvent::ManualReviewRequested { reason } => {
            job.evidence
                .insert("manual_review_reason".to_string(), reason.clone());
        }
    }
}

#[derive(Clone, Debug)]
pub struct ShadowLedger {
    path: PathBuf,
}

impl ShadowLedger {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn append(&self, report: &ShadowReport) -> Result<(), String> {
        self.append_many(std::slice::from_ref(report))
    }

    pub fn append_many(&self, reports: &[ShadowReport]) -> Result<(), String> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).map_err(|err| err.to_string())?;
        }
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .map_err(|err| err.to_string())?;
        for report in reports {
            let json = serde_json::to_string(report).map_err(|err| err.to_string())?;
            writeln!(file, "{json}").map_err(|err| err.to_string())?;
        }
        Ok(())
    }

    pub fn summarize(&self) -> Result<ShadowLedgerSummary, String> {
        let file = File::open(&self.path).map_err(|err| err.to_string())?;
        let mut summary = ShadowLedgerSummary::default();
        for (index, line) in BufReader::new(file).lines().enumerate() {
            let line = line.map_err(|err| {
                format!("failed to read shadow report at line {}: {err}", index + 1)
            })?;
            if line.trim().is_empty() {
                continue;
            }
            let report: ShadowReport = serde_json::from_str(&line)
                .map_err(|err| format!("invalid shadow report at line {}: {err}", index + 1))?;
            summary.total += 1;
            match report.verdict {
                ShadowVerdict::Match => summary.matches += 1,
                ShadowVerdict::Mismatch => summary.mismatches += 1,
                _ => summary.errors += 1,
            }
        }
        Ok(summary)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ShadowLedgerSummary {
    pub total: u64,
    pub matches: u64,
    pub mismatches: u64,
    pub errors: u64,
}

impl ShadowLedgerSummary {
    pub fn is_promotion_clean(&self) -> bool {
        self.total > 0 && self.matches == self.total && self.mismatches == 0 && self.errors == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::{LazarusJobEvent, ShadowReport, ShadowVerdict};

    #[test]
    fn enforces_ordered_job_transitions() {
        let mut orchestrator = LazarusOrchestrator::new();
        orchestrator.create_job("job-1", "bank-core").unwrap();

        assert!(
            orchestrator
                .apply(
                    "job-1",
                    LazarusJobEvent::IrExtracted {
                        ir_hash: "0123456789abcdef".to_string()
                    }
                )
                .is_err()
        );

        orchestrator
            .apply(
                "job-1",
                LazarusJobEvent::ScanCompleted {
                    graph_hash: "0123456789abcdef".to_string(),
                },
            )
            .unwrap();
        assert_eq!(
            orchestrator.job("job-1").unwrap().state,
            LazarusJobState::Scanned
        );
    }

    #[test]
    fn refuses_promotion_when_shadow_has_mismatches() {
        let event = LazarusJobEvent::ShadowPromotionCandidate {
            sample_count: 100,
            mismatch_count: 1,
        };
        assert!(next_state(LazarusJobState::ShadowRunning, &event).is_err());
    }

    #[test]
    fn shadow_ledger_summarizes_clean_runs() {
        let path = std::env::temp_dir().join(format!(
            "lazarus-shadow-ledger-{}.jsonl",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let ledger = ShadowLedger::new(&path);
        ledger
            .append(&ShadowReport {
                request_id: "req-1".to_string(),
                operation: "balance".to_string(),
                verdict: ShadowVerdict::Match,
                primary_hash: Some("a".repeat(64)),
                shadow_hash: Some("a".repeat(64)),
                diff: Default::default(),
                elapsed_ms: 3,
                error: None,
            })
            .unwrap();
        let summary = ledger.summarize().unwrap();
        assert!(summary.is_promotion_clean());
        let _ = std::fs::remove_file(&path);
    }
}
