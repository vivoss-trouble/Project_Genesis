use crate::{
    ShadowRequest, SharedShadowEndpoint, TokioShadowPoolConfig, TokioShadowPoolStats,
    execute_shadow_request,
};
use lazarus_contracts::ShadowReport;
use lazarus_orchestrator::ShadowLedger;
use std::sync::Arc;
use tokio::sync::{Semaphore, mpsc};
use tokio::task::JoinSet;

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
