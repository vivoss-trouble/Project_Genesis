use crate::{
    AsyncShadowQueue, AsyncShadowQueueConfig, AsyncShadowQueueStats, EnqueueOutcome,
    ShadowEndpoint, ShadowRequest, ShadowRunnerConfig, SharedShadowEndpoint, SupervisedShadowQueue,
    SupervisedShadowQueueStats, execute_shadow_request,
};
use lazarus_contracts::ShadowReport;
use lazarus_orchestrator::ShadowLedger;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TryRecvError, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

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
        self.try_enqueue_report(request).map(|_| ())
    }

    pub fn try_enqueue_report(&self, request: ShadowRequest) -> Result<EnqueueOutcome, String> {
        request.validate()?;
        let sender = self
            .sender
            .as_ref()
            .ok_or_else(|| "async shadow queue stopped".to_string())?;
        match sender.try_send(request) {
            Ok(()) => {
                self.enqueued.fetch_add(1, Ordering::Relaxed);
                Ok(EnqueueOutcome::Queued)
            }
            Err(TrySendError::Full(_)) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                Ok(EnqueueOutcome::DroppedFull)
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
        self.try_enqueue_report(request).map(|_| ())
    }

    pub fn try_enqueue_report(&self, request: ShadowRequest) -> Result<EnqueueOutcome, String> {
        request.validate()?;
        let sender = self
            .sender
            .as_ref()
            .ok_or_else(|| "supervised shadow queue stopped".to_string())?;
        match sender.try_send(request) {
            Ok(()) => {
                self.enqueued.fetch_add(1, Ordering::Relaxed);
                Ok(EnqueueOutcome::Queued)
            }
            Err(TrySendError::Full(_)) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                Ok(EnqueueOutcome::DroppedFull)
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
