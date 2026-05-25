use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::io::{BufWriter, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, TrySendError, sync_channel};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

const AUDIT_LOG_PATH: &str = ".genesis-state/audit.jsonl";

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(tag = "type", content = "payload")]
pub enum AuditEvent {
    TickStarted {
        tick_id: u64,
    },
    SenseCaptured {
        tick_id: u64,
        state_json: String,
    },
    PluginResponded {
        tick_id: u64,
        plugin_id: String,
        status: u32,
        error_code: u32,
        latency_ms: u64,
        data_hash: u64,
        data_preview: String,
    },
    BrainActionDecoded {
        tick_id: u64,
        source_tick_id: u64,
        action_id: String,
        action_json: String,
    },
    ActionDispatched {
        tick_id: u64,
        source_tick_id: u64,
        action_id: String,
    },
    OutcomeObserved {
        tick_id: u64,
        action_id: String,
        source_tick_id: u64,
        dispatched_tick_id: u64,
        result: VerificationResult,
        evidence: Value,
    },
    ActionDropped {
        tick_id: u64,
        action_id: Option<String>,
        reason: String,
    },
    FailureObserved {
        tick_id: u64,
        component: String,
        error: String,
    },
    AuditDropped {
        count: u64,
    },
    ReplaySnapshot {
        label: String,
        path: String,
    },
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(tag = "status", content = "detail")]
pub enum VerificationResult {
    Verified,
    Failed { reason: String },
    Timeout,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct AuditRecord {
    pub timestamp_ms: u64,
    #[serde(flatten)]
    pub event: AuditEvent,
}

#[derive(Clone)]
pub struct AuditLogger {
    sender: SyncSender<AuditEvent>,
    dropped_count: Arc<AtomicU64>,
}

impl AuditLogger {
    pub fn new(capacity: usize) -> Self {
        let (sender, receiver) = sync_channel::<AuditEvent>(capacity);
        let dropped_count = Arc::new(AtomicU64::new(0));
        let worker_dropped_count = dropped_count.clone();

        fs::create_dir_all(".genesis-state").expect("无法创建审计物理舱");

        thread::Builder::new()
            .name("Genesis-Audit-Worker".to_string())
            .spawn(move || {
                let file = OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(AUDIT_LOG_PATH)
                    .expect("致命错误：无法打开 audit.jsonl");
                let mut writer = BufWriter::new(file);

                while let Ok(event) = receiver.recv() {
                    let dropped = worker_dropped_count.swap(0, Ordering::Relaxed);
                    if dropped > 0 {
                        let record = AuditRecord {
                            timestamp_ms: current_ts(),
                            event: AuditEvent::AuditDropped { count: dropped },
                        };
                        write_record(&mut writer, &record);
                    }

                    let record = AuditRecord {
                        timestamp_ms: current_ts(),
                        event,
                    };
                    write_record(&mut writer, &record);
                }
            })
            .expect("无法启动审计线程");

        let logger = Self {
            sender,
            dropped_count,
        };

        if let Some(path) = capture_anchor_snapshot() {
            logger.log(AuditEvent::ReplaySnapshot {
                label: "anchor-mmap".to_string(),
                path,
            });
        }

        logger
    }

    pub fn log(&self, event: AuditEvent) {
        match self.sender.try_send(event) {
            Ok(()) => {}
            Err(TrySendError::Full(_)) => {
                self.dropped_count.fetch_add(1, Ordering::Relaxed);
            }
            Err(TrySendError::Disconnected(_)) => {}
        }
    }
}

fn write_record(writer: &mut BufWriter<std::fs::File>, record: &AuditRecord) {
    if let Ok(json) = serde_json::to_string(record) {
        let _ = writeln!(writer, "{}", json);
        let _ = writer.flush();
    }
}

fn current_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

fn capture_anchor_snapshot() -> Option<String> {
    let source = std::path::Path::new(".genesis-state/anchor.mmap");
    if !source.exists() {
        return None;
    }

    let snapshot_dir = std::path::Path::new(".genesis-state/replay-snapshots");
    fs::create_dir_all(snapshot_dir).ok()?;

    let snapshot_path = snapshot_dir.join(format!("anchor-{}.mmap", current_ts()));
    fs::copy(source, &snapshot_path).ok()?;
    snapshot_path.to_str().map(|path| path.to_string())
}
