mod diff;
mod queue;
mod tokio_pool;
mod types;

pub use diff::execute_shadow_request;
pub use tokio_pool::run_shadow_pool_blocking;
pub use types::*;

use lazarus_contracts::LazarusJobEvent;
use lazarus_orchestrator::{LazarusOrchestrator, ShadowLedger};

pub fn run_shadow_batch(
    orchestrator: &mut LazarusOrchestrator,
    job_id: &str,
    requests: &[ShadowRequest],
    primary: &ShadowEndpoint,
    shadow: &ShadowEndpoint,
    config: &ShadowRunnerConfig,
) -> Result<ShadowRunOutput, String> {
    config.validate()?;
    let ledger = ShadowLedger::new(&config.ledger_path);
    let started_transition = match orchestrator.job(job_id) {
        Some(job) if matches!(job.state, lazarus_contracts::LazarusJobState::Compiled) => {
            Some(orchestrator.apply(
                job_id,
                LazarusJobEvent::ShadowStarted {
                    ledger_path: ledger.path().to_string_lossy().into_owned(),
                },
            )?)
        }
        Some(job) if matches!(job.state, lazarus_contracts::LazarusJobState::ShadowRunning) => None,
        Some(job) => {
            return Err(format!(
                "shadow batch requires Compiled or ShadowRunning state, got {:?}",
                job.state
            ));
        }
        None => return Err(format!("unknown Lazarus job: {job_id}")),
    };

    let mut reports = Vec::new();
    for request in requests {
        request.validate()?;
        let report = execute_shadow_request(request, primary, shadow, config);
        ledger.append(&report)?;
        reports.push(report);
    }
    let summary = ledger.summarize()?;

    Ok(ShadowRunOutput {
        started_transition,
        reports,
        summary,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::{LazarusJobEvent, LazarusJobState, ShadowVerdict};
    use serde_json::Value;
    use std::path::PathBuf;
    use std::sync::Arc;

    #[test]
    fn batch_writes_clean_ledger_and_enters_shadow_running() {
        let root = test_dir("clean");
        let ledger_path = root.join("shadow.jsonl");
        let mut orchestrator = compiled_orchestrator();
        let requests = vec![
            ShadowRequest {
                request_id: "req-1".to_string(),
                operation: "fee".to_string(),
                payload: serde_json::json!({"amount": 10}),
            },
            ShadowRequest {
                request_id: "req-2".to_string(),
                operation: "fee".to_string(),
                payload: serde_json::json!({"amount": 20}),
            },
        ];
        let primary = |payload: &Value| {
            Ok(serde_json::json!({
                "fee": payload["amount"].as_i64().unwrap() * 2,
                "trace": "legacy"
            }))
        };
        let shadow = |payload: &Value| {
            assert_eq!(payload["_lazarus_shadow_mode"], Value::Bool(true));
            Ok(serde_json::json!({
                "fee": payload["amount"].as_i64().unwrap() * 2,
                "trace": "refactored"
            }))
        };
        let mut config = ShadowRunnerConfig::new(&ledger_path);
        config.ignored_fields.insert("trace".to_string());

        let output = run_shadow_batch(
            &mut orchestrator,
            "job-1",
            &requests,
            &primary,
            &shadow,
            &config,
        )
        .unwrap();

        assert_eq!(output.reports.len(), 2);
        assert_eq!(output.summary.total, 2);
        assert_eq!(output.summary.matches, 2);
        assert!(output.summary.is_promotion_clean());
        assert_eq!(
            orchestrator.job("job-1").unwrap().state,
            LazarusJobState::ShadowRunning
        );
        assert!(ledger_path.is_file());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn mismatch_is_recorded_without_panic() {
        let request = ShadowRequest {
            request_id: "req-1".to_string(),
            operation: "fee".to_string(),
            payload: serde_json::json!({"amount": 10}),
        };
        let primary = |_: &Value| Ok(serde_json::json!({"fee": 20}));
        let shadow = |_: &Value| Ok(serde_json::json!({"fee": 21}));
        let config = ShadowRunnerConfig::new(std::env::temp_dir().join("unused-shadow.jsonl"));

        let report = execute_shadow_request(&request, &primary, &shadow, &config);

        assert_eq!(report.verdict, ShadowVerdict::Mismatch);
        assert!(report.diff.contains_key("$.fee"));
    }

    #[test]
    fn async_queue_drops_when_capacity_is_full_without_blocking() {
        let root = test_dir("async_drop");
        let ledger_path = root.join("shadow.jsonl");
        let primary: Arc<SharedShadowEndpoint> = Arc::new(|payload: &Value| {
            std::thread::sleep(std::time::Duration::from_millis(40));
            Ok(serde_json::json!({"fee": payload["amount"].as_i64().unwrap() * 2}))
        });
        let shadow: Arc<SharedShadowEndpoint> = Arc::new(|payload: &Value| {
            Ok(serde_json::json!({"fee": payload["amount"].as_i64().unwrap() * 2}))
        });
        let mut config = AsyncShadowQueueConfig::new(1, &ledger_path);
        config.batch_size = 1;
        config.runner.inject_shadow_marker = false;
        let queue = AsyncShadowQueue::start(primary, shadow, config).unwrap();

        let mut dropped_full = 0;
        for index in 0..20 {
            let outcome = queue
                .try_enqueue_report(ShadowRequest {
                    request_id: format!("req-{index}"),
                    operation: "fee".to_string(),
                    payload: serde_json::json!({"amount": index}),
                })
                .unwrap();
            if outcome == EnqueueOutcome::DroppedFull {
                dropped_full += 1;
            }
        }
        let stats = queue.stop().unwrap();

        assert!(dropped_full > 0, "{stats:?}");
        assert!(stats.dropped > 0, "{stats:?}");
        assert!(stats.processed > 0, "{stats:?}");
        assert!(ledger_path.is_file());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn async_worker_retires_after_lifecycle_limit() {
        let root = test_dir("retire");
        let ledger_path = root.join("shadow.jsonl");
        let primary: Arc<SharedShadowEndpoint> =
            Arc::new(|payload: &Value| Ok(serde_json::json!({"fee": payload["amount"]})));
        let shadow: Arc<SharedShadowEndpoint> =
            Arc::new(|payload: &Value| Ok(serde_json::json!({"fee": payload["amount"]})));
        let mut config = AsyncShadowQueueConfig::new(4, &ledger_path);
        config.batch_size = 1;
        config.max_worker_tasks = Some(2);
        config.runner.inject_shadow_marker = false;
        let queue = AsyncShadowQueue::start(primary, shadow, config).unwrap();

        for index in 0..4 {
            queue
                .try_enqueue(ShadowRequest {
                    request_id: format!("req-{index}"),
                    operation: "fee".to_string(),
                    payload: serde_json::json!({"amount": index}),
                })
                .unwrap();
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
        let stats = queue.stop().unwrap();

        assert!(stats.worker_retired, "{stats:?}");
        assert!(stats.processed >= 2, "{stats:?}");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn supervised_queue_respawns_retired_workers() {
        let root = test_dir("supervisor");
        let ledger_path = root.join("shadow.jsonl");
        let primary: Arc<SharedShadowEndpoint> =
            Arc::new(|payload: &Value| Ok(serde_json::json!({"fee": payload["amount"]})));
        let shadow: Arc<SharedShadowEndpoint> =
            Arc::new(|payload: &Value| Ok(serde_json::json!({"fee": payload["amount"]})));
        let mut config = AsyncShadowQueueConfig::new(16, &ledger_path);
        config.batch_size = 1;
        config.max_worker_tasks = Some(2);
        config.runner.inject_shadow_marker = false;
        let queue = SupervisedShadowQueue::start(primary, shadow, config).unwrap();

        for index in 0..6 {
            queue
                .try_enqueue(ShadowRequest {
                    request_id: format!("req-{index}"),
                    operation: "fee".to_string(),
                    payload: serde_json::json!({"amount": index}),
                })
                .unwrap();
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
        let stats = queue.stop().unwrap();

        assert_eq!(stats.dropped, 0, "{stats:?}");
        assert!(stats.processed >= 6, "{stats:?}");
        assert!(stats.restarts >= 3, "{stats:?}");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn supervised_queue_reports_capacity_drops() {
        let root = test_dir("supervisor_drop_report");
        let ledger_path = root.join("shadow.jsonl");
        let primary: Arc<SharedShadowEndpoint> = Arc::new(|payload: &Value| {
            std::thread::sleep(std::time::Duration::from_millis(40));
            Ok(serde_json::json!({"fee": payload["amount"].as_i64().unwrap() * 2}))
        });
        let shadow: Arc<SharedShadowEndpoint> = Arc::new(|payload: &Value| {
            Ok(serde_json::json!({"fee": payload["amount"].as_i64().unwrap() * 2}))
        });
        let mut config = AsyncShadowQueueConfig::new(1, &ledger_path);
        config.batch_size = 1;
        config.runner.inject_shadow_marker = false;
        let queue = SupervisedShadowQueue::start(primary, shadow, config).unwrap();

        let mut dropped_full = 0;
        for index in 0..20 {
            let outcome = queue
                .try_enqueue_report(ShadowRequest {
                    request_id: format!("req-{index}"),
                    operation: "fee".to_string(),
                    payload: serde_json::json!({"amount": index}),
                })
                .unwrap();
            if outcome == EnqueueOutcome::DroppedFull {
                dropped_full += 1;
            }
        }
        let stats = queue.stop().unwrap();

        assert!(dropped_full > 0, "{stats:?}");
        assert!(stats.dropped > 0, "{stats:?}");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn supervised_queue_runs_worker_pool_with_single_ledger_writer() {
        let root = test_dir("supervisor_pool");
        let ledger_path = root.join("shadow.jsonl");
        let primary: Arc<SharedShadowEndpoint> = Arc::new(|payload: &Value| {
            std::thread::sleep(std::time::Duration::from_millis(2));
            Ok(serde_json::json!({"fee": payload["amount"]}))
        });
        let shadow: Arc<SharedShadowEndpoint> =
            Arc::new(|payload: &Value| Ok(serde_json::json!({"fee": payload["amount"]})));
        let mut config = AsyncShadowQueueConfig::new(64, &ledger_path);
        config.batch_size = 2;
        config.max_worker_tasks = Some(8);
        config.worker_concurrency = 4;
        config.runner.inject_shadow_marker = false;
        let queue = SupervisedShadowQueue::start(primary, shadow, config).unwrap();

        for index in 0..32 {
            queue
                .try_enqueue(ShadowRequest {
                    request_id: format!("req-{index}"),
                    operation: "fee".to_string(),
                    payload: serde_json::json!({"amount": index}),
                })
                .unwrap();
        }
        std::thread::sleep(std::time::Duration::from_millis(150));
        let stats = queue.stop().unwrap();

        assert_eq!(stats.dropped, 0, "{stats:?}");
        assert!(stats.processed >= 32, "{stats:?}");
        assert!(stats.restarts >= 4, "{stats:?}");
        assert!(ledger_path.is_file());
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn tokio_shadow_pool_uses_spawn_blocking_and_single_writer() {
        let root = test_dir("tokio_pool");
        let ledger_path = root.join("shadow.jsonl");
        let primary: Arc<SharedShadowEndpoint> = Arc::new(|payload: &Value| {
            Ok(serde_json::json!({"fee": payload["amount"].as_i64().unwrap() * 2}))
        });
        let shadow: Arc<SharedShadowEndpoint> = Arc::new(|payload: &Value| {
            Ok(serde_json::json!({"fee": payload["amount"].as_i64().unwrap() * 2}))
        });
        let mut config = TokioShadowPoolConfig::new(&ledger_path);
        config.worker_concurrency = 4;
        config.batch_size = 3;
        config.ledger_capacity = 4;
        config.runner.inject_shadow_marker = false;
        let requests = (0..12)
            .map(|index| ShadowRequest {
                request_id: format!("req-{index}"),
                operation: "fee".to_string(),
                payload: serde_json::json!({"amount": index}),
            })
            .collect::<Vec<_>>();

        let stats = run_shadow_pool_blocking(requests, primary, shadow, config)
            .await
            .unwrap();
        let summary = ShadowLedger::new(&ledger_path).summarize().unwrap();

        assert_eq!(stats.processed, 12, "{stats:?}");
        assert_eq!(stats.batches, 4, "{stats:?}");
        assert_eq!(summary.total, 12);
        assert!(summary.is_promotion_clean());
        let _ = std::fs::remove_dir_all(root);
    }

    fn compiled_orchestrator() -> LazarusOrchestrator {
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
            .apply(
                "job-1",
                LazarusJobEvent::RustGenerated {
                    artifact_hash: "4".repeat(64),
                },
            )
            .unwrap();
        orchestrator
            .apply(
                "job-1",
                LazarusJobEvent::CompilePassed {
                    artifact_hash: "4".repeat(64),
                },
            )
            .unwrap();
        orchestrator
    }

    fn test_dir(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "lazarus-shadow-runner-{label}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }
}
