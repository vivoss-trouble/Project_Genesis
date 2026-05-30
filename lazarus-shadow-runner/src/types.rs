use lazarus_orchestrator::{ShadowLedgerSummary, StateTransition};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::mpsc::SyncSender;
use std::thread::JoinHandle;

pub type ShadowEndpoint = dyn Fn(&Value) -> Result<Value, String>;
pub type SharedShadowEndpoint = dyn Fn(&Value) -> Result<Value, String> + Send + Sync + 'static;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ShadowRequest {
    pub request_id: String,
    pub operation: String,
    pub payload: Value,
}

impl ShadowRequest {
    pub fn validate(&self) -> Result<(), String> {
        if self.request_id.trim().is_empty() {
            return Err("request_id is required".to_string());
        }
        if self.operation.trim().is_empty() {
            return Err("operation is required".to_string());
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ShadowRunnerConfig {
    pub ledger_path: PathBuf,
    pub ignored_fields: BTreeSet<String>,
    pub numeric_tolerance: f64,
    pub inject_shadow_marker: bool,
}

impl ShadowRunnerConfig {
    pub fn new(ledger_path: impl Into<PathBuf>) -> Self {
        Self {
            ledger_path: ledger_path.into(),
            ignored_fields: BTreeSet::new(),
            numeric_tolerance: 0.0,
            inject_shadow_marker: true,
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.numeric_tolerance < 0.0 {
            return Err("numeric_tolerance must be non-negative".to_string());
        }
        if self.ledger_path.as_os_str().is_empty() {
            return Err("ledger_path is required".to_string());
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ShadowRunOutput {
    pub started_transition: Option<StateTransition>,
    pub reports: Vec<lazarus_contracts::ShadowReport>,
    pub summary: ShadowLedgerSummary,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TokioShadowPoolConfig {
    pub worker_concurrency: usize,
    pub batch_size: usize,
    pub ledger_capacity: usize,
    pub runner: ShadowRunnerConfig,
}

impl TokioShadowPoolConfig {
    pub fn new(ledger_path: impl Into<PathBuf>) -> Self {
        Self {
            worker_concurrency: 1,
            batch_size: 64,
            ledger_capacity: 64,
            runner: ShadowRunnerConfig::new(ledger_path),
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.worker_concurrency == 0 {
            return Err("tokio shadow worker_concurrency must be > 0".to_string());
        }
        if self.batch_size == 0 {
            return Err("tokio shadow batch_size must be > 0".to_string());
        }
        if self.ledger_capacity == 0 {
            return Err("tokio shadow ledger_capacity must be > 0".to_string());
        }
        self.runner.validate()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TokioShadowPoolStats {
    pub processed: u64,
    pub batches: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AsyncShadowQueueConfig {
    pub capacity: usize,
    pub batch_size: usize,
    pub max_worker_tasks: Option<u64>,
    pub worker_concurrency: usize,
    pub runner: ShadowRunnerConfig,
}

impl AsyncShadowQueueConfig {
    pub fn new(capacity: usize, ledger_path: impl Into<PathBuf>) -> Self {
        Self {
            capacity,
            batch_size: 64,
            max_worker_tasks: None,
            worker_concurrency: 1,
            runner: ShadowRunnerConfig::new(ledger_path),
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.capacity == 0 {
            return Err("async shadow queue capacity must be > 0".to_string());
        }
        if self.batch_size == 0 {
            return Err("async shadow queue batch_size must be > 0".to_string());
        }
        if self.max_worker_tasks == Some(0) {
            return Err("async shadow worker max_worker_tasks must be > 0".to_string());
        }
        if self.worker_concurrency == 0 {
            return Err("async shadow worker_concurrency must be > 0".to_string());
        }
        self.runner.validate()
    }
}

#[derive(Debug)]
pub struct AsyncShadowQueue {
    pub(crate) sender: Option<SyncSender<ShadowRequest>>,
    pub(crate) stop: Arc<AtomicBool>,
    pub(crate) enqueued: Arc<AtomicU64>,
    pub(crate) dropped: Arc<AtomicU64>,
    pub(crate) processed: Arc<AtomicU64>,
    pub(crate) retired: Arc<AtomicBool>,
    pub(crate) handle: Option<JoinHandle<()>>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AsyncShadowQueueStats {
    pub enqueued: u64,
    pub dropped: u64,
    pub processed: u64,
    pub worker_retired: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EnqueueOutcome {
    Queued,
    DroppedFull,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SupervisedShadowQueueStats {
    pub enqueued: u64,
    pub dropped: u64,
    pub processed: u64,
    pub restarts: u64,
    pub panics: u64,
}

#[derive(Debug)]
pub struct SupervisedShadowQueue {
    pub(crate) sender: Option<SyncSender<ShadowRequest>>,
    pub(crate) stop: Arc<AtomicBool>,
    pub(crate) enqueued: Arc<AtomicU64>,
    pub(crate) dropped: Arc<AtomicU64>,
    pub(crate) processed: Arc<AtomicU64>,
    pub(crate) restarts: Arc<AtomicU64>,
    pub(crate) panics: Arc<AtomicU64>,
    pub(crate) supervisor: Option<JoinHandle<()>>,
}
