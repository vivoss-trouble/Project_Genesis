use lazarus_contracts::{LazarusJobEvent, ShadowReport, ShadowVerdict};
use lazarus_orchestrator::{
    LazarusOrchestrator, ShadowLedger, ShadowLedgerSummary, StateTransition,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest as _, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TryRecvError, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Instant;
use tokio::sync::{Semaphore, mpsc};
use tokio::task::JoinSet;

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
    pub reports: Vec<ShadowReport>,
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
    sender: Option<SyncSender<ShadowRequest>>,
    stop: Arc<AtomicBool>,
    enqueued: Arc<AtomicU64>,
    dropped: Arc<AtomicU64>,
    processed: Arc<AtomicU64>,
    retired: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AsyncShadowQueueStats {
    pub enqueued: u64,
    pub dropped: u64,
    pub processed: u64,
    pub worker_retired: bool,
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
    sender: Option<SyncSender<ShadowRequest>>,
    stop: Arc<AtomicBool>,
    enqueued: Arc<AtomicU64>,
    dropped: Arc<AtomicU64>,
    processed: Arc<AtomicU64>,
    restarts: Arc<AtomicU64>,
    panics: Arc<AtomicU64>,
    supervisor: Option<JoinHandle<()>>,
}

impl AsyncShadowQueue {
    pub fn start(
        primary: Arc<SharedShadowEndpoint>,
        shadow: Arc<SharedShadowEndpoint>,
        config: AsyncShadowQueueConfig,
    ) -> Result<Self, String> {
        config.validate()?;
        let (sender, receiver) = sync_channel(config.capacity);
        let stop = Arc::new(AtomicBool::new(false));
        let enqueued = Arc::new(AtomicU64::new(0));
        let dropped = Arc::new(AtomicU64::new(0));
        let processed = Arc::new(AtomicU64::new(0));
        let retired = Arc::new(AtomicBool::new(false));
        let worker_stop = Arc::clone(&stop);
        let worker_processed = Arc::clone(&processed);
        let worker_retired = Arc::clone(&retired);
        let handle = thread::spawn(move || {
            let ledger = ShadowLedger::new(&config.runner.ledger_path);
            let mut batch = Vec::with_capacity(config.batch_size);
            loop {
                if worker_stop.load(Ordering::Relaxed) {
                    match receiver.try_recv() {
                        Ok(request) => batch.push(request),
                        Err(TryRecvError::Empty | TryRecvError::Disconnected) => {
                            flush_batch(
                                &ledger,
                                &mut batch,
                                primary.as_ref(),
                                shadow.as_ref(),
                                &config.runner,
                                &worker_processed,
                            );
                            break;
                        }
                    }
                } else {
                    match receiver.recv() {
                        Ok(request) => batch.push(request),
                        Err(_) => break,
                    }
                }

                while batch.len() < config.batch_size {
                    match receiver.try_recv() {
                        Ok(request) => batch.push(request),
                        Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
                    }
                }
                flush_batch(
                    &ledger,
                    &mut batch,
                    primary.as_ref(),
                    shadow.as_ref(),
                    &config.runner,
                    &worker_processed,
                );
                if config
                    .max_worker_tasks
                    .is_some_and(|limit| worker_processed.load(Ordering::Relaxed) >= limit)
                {
                    worker_retired.store(true, Ordering::Relaxed);
                    break;
                }
            }
        });

        Ok(Self {
            stop,
            enqueued,
            dropped,
            processed,
            retired,
            sender: Some(sender),
            handle: Some(handle),
        })
    }

    pub fn try_enqueue(&self, request: ShadowRequest) -> Result<(), String> {
        request.validate()?;
        let sender = self
            .sender
            .as_ref()
            .ok_or_else(|| "async shadow queue stopped".to_string())?;
        match sender.try_send(request) {
            Ok(()) => {
                self.enqueued.fetch_add(1, Ordering::Relaxed);
                Ok(())
            }
            Err(TrySendError::Full(_)) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                Ok(())
            }
            Err(TrySendError::Disconnected(_)) => {
                Err("async shadow queue disconnected".to_string())
            }
        }
    }

    pub fn stats(&self) -> AsyncShadowQueueStats {
        AsyncShadowQueueStats {
            enqueued: self.enqueued.load(Ordering::Relaxed),
            dropped: self.dropped.load(Ordering::Relaxed),
            processed: self.processed.load(Ordering::Relaxed),
            worker_retired: self.retired.load(Ordering::Relaxed),
        }
    }

    pub fn stop(mut self) -> Result<AsyncShadowQueueStats, String> {
        self.stop.store(true, Ordering::Relaxed);
        drop(self.sender.take());
        if let Some(handle) = self.handle.take() {
            handle
                .join()
                .map_err(|_| "async shadow worker panicked".to_string())?;
        }
        Ok(self.stats())
    }
}

impl SupervisedShadowQueue {
    pub fn start(
        primary: Arc<SharedShadowEndpoint>,
        shadow: Arc<SharedShadowEndpoint>,
        config: AsyncShadowQueueConfig,
    ) -> Result<Self, String> {
        config.validate()?;
        let (sender, receiver) = sync_channel(config.capacity);
        let receiver = Arc::new(Mutex::new(receiver));
        let stop = Arc::new(AtomicBool::new(false));
        let enqueued = Arc::new(AtomicU64::new(0));
        let dropped = Arc::new(AtomicU64::new(0));
        let processed = Arc::new(AtomicU64::new(0));
        let restarts = Arc::new(AtomicU64::new(0));
        let panics = Arc::new(AtomicU64::new(0));

        let supervisor_stop = Arc::clone(&stop);
        let supervisor_processed = Arc::clone(&processed);
        let supervisor_restarts = Arc::clone(&restarts);
        let supervisor_panics = Arc::clone(&panics);
        let supervisor = thread::spawn(move || {
            let (report_sender, report_receiver) = sync_channel(config.capacity.max(1));
            let writer = spawn_ledger_writer(
                report_receiver,
                config.runner.clone(),
                Arc::clone(&supervisor_processed),
            );
            while !supervisor_stop.load(Ordering::Relaxed) {
                supervisor_restarts.fetch_add(config.worker_concurrency as u64, Ordering::Relaxed);
                let mut workers = Vec::with_capacity(config.worker_concurrency);
                for _ in 0..config.worker_concurrency {
                    workers.push(spawn_supervised_worker(
                        Arc::clone(&receiver),
                        report_sender.clone(),
                        Arc::clone(&primary),
                        Arc::clone(&shadow),
                        config.clone(),
                        Arc::clone(&supervisor_stop),
                    ));
                }
                for worker in workers {
                    if worker.join().is_err() {
                        supervisor_panics.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
            drop(report_sender);
            let _ = writer.join();
        });

        Ok(Self {
            sender: Some(sender),
            stop,
            enqueued,
            dropped,
            processed,
            restarts,
            panics,
            supervisor: Some(supervisor),
        })
    }

    pub fn try_enqueue(&self, request: ShadowRequest) -> Result<(), String> {
        request.validate()?;
        let sender = self
            .sender
            .as_ref()
            .ok_or_else(|| "supervised shadow queue stopped".to_string())?;
        match sender.try_send(request) {
            Ok(()) => {
                self.enqueued.fetch_add(1, Ordering::Relaxed);
                Ok(())
            }
            Err(TrySendError::Full(_)) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                Ok(())
            }
            Err(TrySendError::Disconnected(_)) => {
                Err("supervised shadow queue disconnected".to_string())
            }
        }
    }

    pub fn stats(&self) -> SupervisedShadowQueueStats {
        SupervisedShadowQueueStats {
            enqueued: self.enqueued.load(Ordering::Relaxed),
            dropped: self.dropped.load(Ordering::Relaxed),
            processed: self.processed.load(Ordering::Relaxed),
            restarts: self.restarts.load(Ordering::Relaxed),
            panics: self.panics.load(Ordering::Relaxed),
        }
    }

    pub fn stop(mut self) -> Result<SupervisedShadowQueueStats, String> {
        self.stop.store(true, Ordering::Relaxed);
        drop(self.sender.take());
        if let Some(supervisor) = self.supervisor.take() {
            supervisor
                .join()
                .map_err(|_| "shadow supervisor panicked".to_string())?;
        }
        Ok(self.stats())
    }
}

pub async fn run_shadow_pool_blocking(
    requests: Vec<ShadowRequest>,
    primary: Arc<SharedShadowEndpoint>,
    shadow: Arc<SharedShadowEndpoint>,
    config: TokioShadowPoolConfig,
) -> Result<TokioShadowPoolStats, String> {
    config.validate()?;
    for request in &requests {
        request.validate()?;
    }

    let (report_sender, mut report_receiver) =
        mpsc::channel::<Vec<ShadowReport>>(config.ledger_capacity);
    let writer_config = config.runner.clone();
    let writer = tokio::spawn(async move {
        let ledger = ShadowLedger::new(&writer_config.ledger_path);
        let mut processed = 0_u64;
        while let Some(reports) = report_receiver.recv().await {
            let count = reports.len() as u64;
            let ledger = ledger.clone();
            tokio::task::spawn_blocking(move || ledger.append_many(&reports))
                .await
                .map_err(|error| format!("tokio ledger writer join error: {error}"))??;
            processed = processed.saturating_add(count);
        }
        Ok::<u64, String>(processed)
    });

    let semaphore = Arc::new(Semaphore::new(config.worker_concurrency));
    let mut workers = JoinSet::new();
    for chunk in requests.chunks(config.batch_size) {
        let batch = chunk.to_vec();
        let permit = Arc::clone(&semaphore)
            .acquire_owned()
            .await
            .map_err(|_| "tokio shadow semaphore closed".to_string())?;
        let report_sender = report_sender.clone();
        let primary = Arc::clone(&primary);
        let shadow = Arc::clone(&shadow);
        let runner = config.runner.clone();
        workers.spawn(async move {
            let _permit = permit;
            let reports = tokio::task::spawn_blocking(move || {
                batch
                    .into_iter()
                    .map(|request| {
                        execute_shadow_request(&request, primary.as_ref(), shadow.as_ref(), &runner)
                    })
                    .collect::<Vec<_>>()
            })
            .await
            .map_err(|error| format!("tokio shadow worker join error: {error}"))?;
            report_sender
                .send(reports)
                .await
                .map_err(|_| "tokio shadow ledger writer stopped".to_string())
        });
    }
    drop(report_sender);

    let mut batches = 0_u64;
    while let Some(result) = workers.join_next().await {
        result.map_err(|error| format!("tokio shadow worker task failed: {error}"))??;
        batches = batches.saturating_add(1);
    }
    let processed = writer
        .await
        .map_err(|error| format!("tokio shadow ledger writer task failed: {error}"))??;

    Ok(TokioShadowPoolStats { processed, batches })
}

fn spawn_supervised_worker(
    receiver: Arc<Mutex<Receiver<ShadowRequest>>>,
    report_sender: SyncSender<Vec<ShadowReport>>,
    primary: Arc<SharedShadowEndpoint>,
    shadow: Arc<SharedShadowEndpoint>,
    config: AsyncShadowQueueConfig,
    stop: Arc<AtomicBool>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut handled_by_worker = 0_u64;
        let mut batch = Vec::with_capacity(config.batch_size);
        loop {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            let received = {
                let lock = receiver.lock();
                let Ok(receiver) = lock else {
                    break;
                };
                receiver.recv()
            };
            match received {
                Ok(request) => batch.push(request),
                Err(_) => break,
            }
            while batch.len() < config.batch_size {
                let next = {
                    let lock = receiver.lock();
                    let Ok(receiver) = lock else {
                        break;
                    };
                    receiver.try_recv()
                };
                match next {
                    Ok(request) => batch.push(request),
                    Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
                }
            }
            let count = batch.len() as u64;
            flush_batch_to_writer(
                &mut batch,
                primary.as_ref(),
                shadow.as_ref(),
                &config.runner,
                &report_sender,
            );
            handled_by_worker = handled_by_worker.saturating_add(count);
            if config
                .max_worker_tasks
                .is_some_and(|limit| handled_by_worker >= limit)
            {
                break;
            }
        }
    })
}

fn spawn_ledger_writer(
    receiver: Receiver<Vec<ShadowReport>>,
    config: ShadowRunnerConfig,
    processed: Arc<AtomicU64>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let ledger = ShadowLedger::new(&config.ledger_path);
        while let Ok(reports) = receiver.recv() {
            let count = reports.len() as u64;
            if ledger.append_many(&reports).is_ok() {
                processed.fetch_add(count, Ordering::Relaxed);
            }
        }
    })
}

fn flush_batch_to_writer(
    batch: &mut Vec<ShadowRequest>,
    primary: &ShadowEndpoint,
    shadow: &ShadowEndpoint,
    config: &ShadowRunnerConfig,
    report_sender: &SyncSender<Vec<ShadowReport>>,
) {
    if batch.is_empty() {
        return;
    }
    let reports = batch
        .drain(..)
        .map(|request| execute_shadow_request(&request, primary, shadow, config))
        .collect::<Vec<_>>();
    let _ = report_sender.send(reports);
}

fn flush_batch(
    ledger: &ShadowLedger,
    batch: &mut Vec<ShadowRequest>,
    primary: &ShadowEndpoint,
    shadow: &ShadowEndpoint,
    config: &ShadowRunnerConfig,
    processed: &AtomicU64,
) {
    if batch.is_empty() {
        return;
    }
    let reports = batch
        .drain(..)
        .map(|request| execute_shadow_request(&request, primary, shadow, config))
        .collect::<Vec<_>>();
    let count = reports.len() as u64;
    if ledger.append_many(&reports).is_ok() {
        processed.fetch_add(count, Ordering::Relaxed);
    }
}

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

pub fn execute_shadow_request(
    request: &ShadowRequest,
    primary: &ShadowEndpoint,
    shadow: &ShadowEndpoint,
    config: &ShadowRunnerConfig,
) -> ShadowReport {
    let start = Instant::now();
    let primary_result = primary(&request.payload);
    let shadow_payload = if config.inject_shadow_marker {
        inject_shadow_marker(request.payload.clone())
    } else {
        request.payload.clone()
    };
    let shadow_result = shadow(&shadow_payload);

    let elapsed_ms = start.elapsed().as_millis().min(u128::from(u64::MAX)) as u64;
    match (primary_result, shadow_result) {
        (Err(error), _) => report(
            request,
            ShadowVerdict::PrimaryError,
            None,
            None,
            BTreeMap::new(),
            elapsed_ms,
            Some(error),
        ),
        (Ok(primary_value), Err(error)) => report(
            request,
            ShadowVerdict::ShadowError,
            Some(&primary_value),
            None,
            BTreeMap::new(),
            elapsed_ms,
            Some(error),
        ),
        (Ok(primary_value), Ok(shadow_value)) => {
            let left = strip_ignored(&primary_value, &config.ignored_fields);
            let right = strip_ignored(&shadow_value, &config.ignored_fields);
            let diff = semantic_diff(&left, &right, config.numeric_tolerance, "$");
            report(
                request,
                if diff.is_empty() {
                    ShadowVerdict::Match
                } else {
                    ShadowVerdict::Mismatch
                },
                Some(&left),
                Some(&right),
                diff,
                elapsed_ms,
                None,
            )
        }
    }
}

fn report(
    request: &ShadowRequest,
    verdict: ShadowVerdict,
    primary: Option<&Value>,
    shadow: Option<&Value>,
    diff: BTreeMap<String, Value>,
    elapsed_ms: u64,
    error: Option<String>,
) -> ShadowReport {
    ShadowReport {
        request_id: request.request_id.clone(),
        operation: request.operation.clone(),
        verdict,
        primary_hash: primary.map(stable_hash),
        shadow_hash: shadow.map(stable_hash),
        diff,
        elapsed_ms,
        error,
    }
}

fn inject_shadow_marker(mut value: Value) -> Value {
    if let Value::Object(map) = &mut value {
        map.insert("_lazarus_shadow_mode".to_string(), Value::Bool(true));
    }
    value
}

fn strip_ignored(value: &Value, ignored_fields: &BTreeSet<String>) -> Value {
    match value {
        Value::Object(map) => {
            let mut stripped = Map::new();
            for (key, value) in map {
                if !ignored_fields.contains(key) {
                    stripped.insert(key.clone(), strip_ignored(value, ignored_fields));
                }
            }
            Value::Object(stripped)
        }
        Value::Array(items) => Value::Array(
            items
                .iter()
                .map(|item| strip_ignored(item, ignored_fields))
                .collect(),
        ),
        _ => value.clone(),
    }
}

fn semantic_diff(
    left: &Value,
    right: &Value,
    tolerance: f64,
    path: &str,
) -> BTreeMap<String, Value> {
    let mut diff = BTreeMap::new();
    match (left, right) {
        (Value::Object(left_map), Value::Object(right_map)) => {
            let keys = left_map
                .keys()
                .chain(right_map.keys())
                .cloned()
                .collect::<BTreeSet<_>>();
            for key in keys {
                let child_path = format!("{path}.{key}");
                match (left_map.get(&key), right_map.get(&key)) {
                    (Some(left_value), Some(right_value)) => {
                        diff.extend(semantic_diff(
                            left_value,
                            right_value,
                            tolerance,
                            &child_path,
                        ));
                    }
                    (Some(left_value), None) => {
                        diff.insert(
                            child_path,
                            serde_json::json!({"left": left_value, "right": "<missing>"}),
                        );
                    }
                    (None, Some(right_value)) => {
                        diff.insert(
                            child_path,
                            serde_json::json!({"left": "<missing>", "right": right_value}),
                        );
                    }
                    (None, None) => {}
                }
            }
        }
        (Value::Array(left_items), Value::Array(right_items)) => {
            if left_items.len() != right_items.len() {
                diff.insert(
                    format!("{path}.length"),
                    serde_json::json!({"left": left_items.len(), "right": right_items.len()}),
                );
            }
            for (index, (left_value, right_value)) in
                left_items.iter().zip(right_items.iter()).enumerate()
            {
                diff.extend(semantic_diff(
                    left_value,
                    right_value,
                    tolerance,
                    &format!("{path}[{index}]"),
                ));
            }
        }
        _ if values_equal(left, right, tolerance) => {}
        _ => {
            diff.insert(
                path.to_string(),
                serde_json::json!({"left": left, "right": right}),
            );
        }
    }
    diff
}

fn values_equal(left: &Value, right: &Value, tolerance: f64) -> bool {
    match (left, right) {
        (Value::Number(left_num), Value::Number(right_num)) => {
            match (left_num.as_f64(), right_num.as_f64()) {
                (Some(left), Some(right)) => (left - right).abs() <= tolerance,
                _ => left == right,
            }
        }
        _ => left == right,
    }
}

fn stable_hash(value: &Value) -> String {
    let stable = serde_json::to_vec(value).expect("serde_json::Value serialization cannot fail");
    let mut hasher = Sha256::new();
    hasher.update(stable);
    format!("{:x}", hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::{LazarusJobEvent, LazarusJobState};

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

        for index in 0..20 {
            queue
                .try_enqueue(ShadowRequest {
                    request_id: format!("req-{index}"),
                    operation: "fee".to_string(),
                    payload: serde_json::json!({"amount": index}),
                })
                .unwrap();
        }
        let stats = queue.stop().unwrap();

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
