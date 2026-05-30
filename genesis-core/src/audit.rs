use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, TrySendError, sync_channel};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

const DEFAULT_AUDIT_LOG_PATH: &str = ".genesis-state/audit.jsonl";
const DEFAULT_AUDIT_MAX_BYTES: u64 = 64 * 1024 * 1024;

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
    MemoryAdvisoryAttached {
        tick_id: u64,
        scope: String,
        sample_count: u64,
        hash: String,
    },
    PlanDrafted {
        tick_id: u64,
        source_tick_id: u64,
        plan_id: String,
        goal: String,
        steps: Vec<PlanStep>,
    },
    PlanActivated {
        tick_id: u64,
        plan_id: String,
    },
    StepActivated {
        tick_id: u64,
        plan_id: String,
        step_index: u32,
        intent: String,
    },
    PlanAdvanced {
        tick_id: u64,
        plan_id: String,
        from_step: u32,
        to_step: u32,
    },
    PlanAborted {
        tick_id: u64,
        plan_id: String,
        at_step: u32,
        reason: String,
    },
    /// 旧语义：ActionDispatched（已废弃，保留向后兼容）
    #[deprecated(since = "0.1.0", note = "use ActionQueued instead")]
    ActionDispatched {
        tick_id: u64,
        source_tick_id: u64,
        action_id: String,
    },

    /// 新语义：ActionQueued — 动作已成功入队，等待 actuator 投递。
    /// 与旧版不同，此事件明确区分 "queued" 和 "delivered"。
    ActionQueued {
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
pub struct PlanStep {
    pub step_index: u32,
    pub intent: String,
    pub target_selector: Option<String>,
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
        let audit_path = audit_log_path();
        let audit_max_bytes = audit_max_bytes();

        thread::Builder::new()
            .name("Genesis-Audit-Worker".to_string())
            .spawn(move || {
                let mut writer = open_audit_writer(&audit_path)
                    .expect("致命错误：无法打开 audit.jsonl");

                while let Ok(event) = receiver.recv() {
                    let dropped = worker_dropped_count.swap(0, Ordering::Relaxed);
                    if dropped > 0 {
                        let record = AuditRecord {
                            timestamp_ms: current_ts(),
                            event: AuditEvent::AuditDropped { count: dropped },
                        };
                        rotate_audit_if_needed(&audit_path, audit_max_bytes, &mut writer);
                        write_record(&mut writer, &record);
                    }

                    let record = AuditRecord {
                        timestamp_ms: current_ts(),
                        event,
                    };
                    rotate_audit_if_needed(&audit_path, audit_max_bytes, &mut writer);
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
                // 队列满时递增 dropped count；worker 会在下次 recv 时生成
                // AuditDropped 记录，确保审计链完整。
                self.dropped_count.fetch_add(1, Ordering::Relaxed);
            }
            Err(TrySendError::Disconnected(_)) => {
                // worker 已退出：写入 eprintln 并递增 dropped count。
                self.dropped_count.fetch_add(1, Ordering::Relaxed);
                eprintln!("[Audit] ⚠️ event dropped due to disconnected sender");
            }
        }
    }
}

fn audit_log_path() -> PathBuf {
    std::env::var_os("GENESIS_AUDIT_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_AUDIT_LOG_PATH))
}

fn audit_max_bytes() -> u64 {
    std::env::var("GENESIS_AUDIT_MAX_BYTES")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|bytes| *bytes > 0)
        .unwrap_or(DEFAULT_AUDIT_MAX_BYTES)
}

fn open_audit_writer(path: &Path) -> std::io::Result<BufWriter<std::fs::File>> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map(BufWriter::new)
}

fn rotate_audit_if_needed(
    path: &Path,
    max_bytes: u64,
    writer: &mut BufWriter<std::fs::File>,
) {
    let Ok(metadata) = writer.get_ref().metadata() else {
        return;
    };
    if metadata.len() < max_bytes {
        return;
    }
    if writer.flush().is_err() {
        eprintln!("[Audit] flush failed before log rotation");
        return;
    }
    let Some(rotated_path) = next_rotated_audit_path(path) else {
        eprintln!("[Audit] unable to allocate rotated audit path");
        return;
    };
    if let Err(error) = fs::rename(path, &rotated_path) {
        eprintln!("[Audit] rotation rename failed: {error}");
        return;
    }
    match open_audit_writer(path) {
        Ok(next_writer) => *writer = next_writer,
        Err(error) => eprintln!("[Audit] reopen after rotation failed: {error}"),
    }
}

fn next_rotated_audit_path(path: &Path) -> Option<PathBuf> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let stem = path.file_stem()?.to_str()?;
    let extension = path.extension().and_then(|value| value.to_str());
    for suffix in 0..100 {
        let filename = match extension {
            Some(extension) if suffix == 0 => {
                format!("{stem}.{}.{}", current_ts(), extension)
            }
            Some(extension) => {
                format!("{stem}.{}-{suffix}.{}", current_ts(), extension)
            }
            None if suffix == 0 => format!("{stem}.{}", current_ts()),
            None => format!("{stem}.{}-{suffix}", current_ts()),
        };
        let candidate = parent.join(filename);
        if !candidate.exists() {
            return Some(candidate);
        }
    }
    None
}

fn write_record(writer: &mut BufWriter<std::fs::File>, record: &AuditRecord) {
    // Step 1: Serialize to JSON
    let json = match serde_json::to_string(record) {
        Ok(json) => json,
        Err(e) => {
            eprintln!(
                "[Audit] serialization failed for tick={}: {}",
                record.timestamp_ms, e
            );
            return;
        }
    };

    // Step 2: Write line to buffer
    if writeln!(writer, "{}", json).is_err() {
        eprintln!(
            "[Audit] write failed for tick={}, attempting flush and retry",
            record.timestamp_ms
        );
        let _ = writer.flush();
        return;
    }

    // Step 3: Flush to disk - the critical path that was previously swallowing errors
    if writer.flush().is_err() {
        eprintln!(
            "[Audit] flush failed for tick={}, data remains buffered",
            record.timestamp_ms
        );
        // Don't lose data: keep it in buffer, will be flushed on next write or drop.
        // Critical path is not blocked (no break/return).
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotates_audit_file_at_configured_size_limit() {
        let root = std::env::temp_dir().join(format!(
            "genesis-audit-rotation-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let path = root.join("audit.jsonl");
        let mut writer = open_audit_writer(&path).unwrap();
        writeln!(writer, "{{\"seed\":true}}").unwrap();
        writer.flush().unwrap();

        rotate_audit_if_needed(&path, 1, &mut writer);
        write_record(
            &mut writer,
            &AuditRecord {
                timestamp_ms: 1,
                event: AuditEvent::AuditDropped { count: 1 },
            },
        );

        let active_body = fs::read_to_string(&path).unwrap();
        assert!(active_body.contains("\"AuditDropped\""));
        let rotated_count = fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_str()
                    .is_some_and(|name| {
                        name != "audit.jsonl"
                            && name.starts_with("audit.")
                            && name.ends_with(".jsonl")
                    })
            })
            .count();
        assert_eq!(rotated_count, 1);
        let _ = fs::remove_dir_all(root);
    }
}
