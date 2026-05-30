use lazarus_contracts::{LazarusJob, LazarusJobEvent, LazarusJobState};
use lazarus_orchestrator::{StateTransition, next_state};
use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest as _, Sha256};
use std::collections::BTreeMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub const ORCHESTRATOR_STORE_SCHEMA_VERSION: u32 = 1;

pub struct SqliteOrchestratorStore {
    conn: Connection,
}

impl SqliteOrchestratorStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, String> {
        let conn = Connection::open(path).map_err(|error| error.to_string())?;
        let store = Self { conn };
        store.init_schema()?;
        Ok(store)
    }

    pub fn create_job(&mut self, job: &LazarusJob) -> Result<(), String> {
        job.validate()?;
        let evidence_json = serde_json::to_string(&job.evidence).map_err(|e| e.to_string())?;
        self.conn
            .execute(
                "INSERT INTO lazarus_jobs (
                    job_id, codebase_id, contract_version, state, evidence_json, updated_at_ms
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    job.job_id,
                    job.codebase_id,
                    job.contract_version,
                    state_to_json(job.state)?,
                    evidence_json,
                    now_ms()?
                ],
            )
            .map(|_| ())
            .map_err(|error| error.to_string())
    }

    pub fn load_job(&self, job_id: &str) -> Result<Option<LazarusJob>, String> {
        self.conn
            .query_row(
                "SELECT contract_version, codebase_id, state, evidence_json
                 FROM lazarus_jobs WHERE job_id = ?1",
                params![job_id],
                |row| {
                    let contract_version: u32 = row.get(0)?;
                    let codebase_id: String = row.get(1)?;
                    let state_json: String = row.get(2)?;
                    let evidence_json: String = row.get(3)?;
                    let state = serde_json::from_str::<LazarusJobState>(&state_json)
                        .map_err(to_sql_error)?;
                    let evidence = serde_json::from_str::<BTreeMap<String, String>>(&evidence_json)
                        .map_err(to_sql_error)?;
                    Ok(LazarusJob {
                        contract_version,
                        job_id: job_id.to_string(),
                        codebase_id,
                        state,
                        evidence,
                    })
                },
            )
            .optional()
            .map_err(|error| error.to_string())
    }

    pub fn apply_event(
        &mut self,
        job_id: &str,
        event: LazarusJobEvent,
    ) -> Result<StateTransition, String> {
        let tx = self.conn.transaction().map_err(|error| error.to_string())?;
        let mut job = tx
            .query_row(
                "SELECT contract_version, codebase_id, state, evidence_json
                 FROM lazarus_jobs WHERE job_id = ?1",
                params![job_id],
                |row| {
                    let contract_version: u32 = row.get(0)?;
                    let codebase_id: String = row.get(1)?;
                    let state_json: String = row.get(2)?;
                    let evidence_json: String = row.get(3)?;
                    let state = serde_json::from_str::<LazarusJobState>(&state_json)
                        .map_err(to_sql_error)?;
                    let evidence = serde_json::from_str::<BTreeMap<String, String>>(&evidence_json)
                        .map_err(to_sql_error)?;
                    Ok(LazarusJob {
                        contract_version,
                        job_id: job_id.to_string(),
                        codebase_id,
                        state,
                        evidence,
                    })
                },
            )
            .optional()
            .map_err(|error| error.to_string())?
            .ok_or_else(|| format!("unknown Lazarus job: {job_id}"))?;

        let from = job.state;
        let to = next_state(from, &event)?;
        attach_evidence(&mut job, &event);
        job.state = to;
        let event_json = serde_json::to_string(&event).map_err(|error| error.to_string())?;
        let event_hash = transition_hash(job_id, from, to, &event_json)?;
        let evidence_json = serde_json::to_string(&job.evidence).map_err(|e| e.to_string())?;
        tx.execute(
            "UPDATE lazarus_jobs
             SET state = ?1, evidence_json = ?2, updated_at_ms = ?3
             WHERE job_id = ?4",
            params![state_to_json(to)?, evidence_json, now_ms()?, job_id],
        )
        .map_err(|error| error.to_string())?;
        tx.execute(
            "INSERT INTO lazarus_transitions (
                job_id, from_state, to_state, event_json, event_hash, created_at_ms
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                job_id,
                state_to_json(from)?,
                state_to_json(to)?,
                event_json,
                event_hash,
                now_ms()?
            ],
        )
        .map_err(|error| error.to_string())?;
        tx.commit().map_err(|error| error.to_string())?;

        Ok(StateTransition {
            job_id: job_id.to_string(),
            from,
            to,
            event,
        })
    }

    pub fn transition_count(&self, job_id: &str) -> Result<u64, String> {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM lazarus_transitions WHERE job_id = ?1",
                params![job_id],
                |row| row.get::<_, u64>(0),
            )
            .map_err(|error| error.to_string())
    }

    fn init_schema(&self) -> Result<(), String> {
        self.conn
            .execute_batch(
                "
                PRAGMA journal_mode = WAL;
                PRAGMA foreign_keys = ON;
                CREATE TABLE IF NOT EXISTS lazarus_schema (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    schema_version INTEGER NOT NULL
                );
                INSERT INTO lazarus_schema(singleton, schema_version)
                    VALUES (1, 1)
                    ON CONFLICT(singleton) DO NOTHING;
                CREATE TABLE IF NOT EXISTS lazarus_jobs (
                    job_id TEXT PRIMARY KEY,
                    codebase_id TEXT NOT NULL,
                    contract_version INTEGER NOT NULL,
                    state TEXT NOT NULL,
                    evidence_json TEXT NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS lazarus_transitions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    job_id TEXT NOT NULL,
                    from_state TEXT NOT NULL,
                    to_state TEXT NOT NULL,
                    event_json TEXT NOT NULL,
                    event_hash TEXT NOT NULL UNIQUE,
                    created_at_ms INTEGER NOT NULL,
                    FOREIGN KEY(job_id) REFERENCES lazarus_jobs(job_id)
                );
                CREATE INDEX IF NOT EXISTS idx_lazarus_transitions_job
                    ON lazarus_transitions(job_id, id);
                ",
            )
            .map_err(|error| error.to_string())
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
        LazarusJobEvent::Approved { approver } => {
            job.evidence
                .insert("approver".to_string(), approver.clone());
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
        LazarusJobEvent::ManualReviewRequested { reason } => {
            job.evidence
                .insert("manual_review_reason".to_string(), reason.clone());
        }
    }
}

fn state_to_json(state: LazarusJobState) -> Result<String, String> {
    serde_json::to_string(&state).map_err(|error| error.to_string())
}

fn transition_hash(
    job_id: &str,
    from: LazarusJobState,
    to: LazarusJobState,
    event_json: &str,
) -> Result<String, String> {
    let material = serde_json::json!({
        "job_id": job_id,
        "from": from,
        "to": to,
        "event": event_json,
    });
    let bytes = serde_json::to_vec(&material).map_err(|error| error.to_string())?;
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    Ok(format!("{:x}", hasher.finalize()))
}

fn now_ms() -> Result<u64, String> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| error.to_string())?
        .as_millis()
        .min(u128::from(u64::MAX)) as u64)
}

fn to_sql_error(error: impl std::error::Error + Send + Sync + 'static) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persists_job_and_transitions_across_reopen() {
        let path = test_db("persist");
        {
            let mut store = SqliteOrchestratorStore::open(&path).unwrap();
            store
                .create_job(&LazarusJob::new("job-1", "bank-core"))
                .unwrap();
            store
                .apply_event(
                    "job-1",
                    LazarusJobEvent::ScanCompleted {
                        graph_hash: "1".repeat(64),
                    },
                )
                .unwrap();
            store
                .apply_event(
                    "job-1",
                    LazarusJobEvent::IrExtracted {
                        ir_hash: "2".repeat(64),
                    },
                )
                .unwrap();
            assert_eq!(store.transition_count("job-1").unwrap(), 2);
        }
        {
            let store = SqliteOrchestratorStore::open(&path).unwrap();
            let job = store.load_job("job-1").unwrap().unwrap();
            assert_eq!(job.state, LazarusJobState::IrExtracted);
            assert_eq!(job.evidence.get("graph_hash"), Some(&"1".repeat(64)));
            assert_eq!(store.transition_count("job-1").unwrap(), 2);
        }
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn rejects_invalid_transition_transactionally() {
        let path = test_db("invalid");
        let mut store = SqliteOrchestratorStore::open(&path).unwrap();
        store
            .create_job(&LazarusJob::new("job-1", "bank-core"))
            .unwrap();

        let error = store
            .apply_event(
                "job-1",
                LazarusJobEvent::IrExtracted {
                    ir_hash: "2".repeat(64),
                },
            )
            .unwrap_err();

        assert!(error.contains("invalid transition"));
        assert_eq!(
            store.load_job("job-1").unwrap().unwrap().state,
            LazarusJobState::Discovered
        );
        assert_eq!(store.transition_count("job-1").unwrap(), 0);
        let _ = std::fs::remove_file(path);
    }

    fn test_db(label: &str) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "lazarus-orchestrator-store-{label}-{}.sqlite",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        path
    }
}
