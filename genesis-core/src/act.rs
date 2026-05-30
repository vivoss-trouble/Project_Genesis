use serde::{Deserialize, Serialize};
use serde_json::Value;
use socket2::{Domain, SockAddr, Socket, Type};
use std::collections::VecDeque;
use std::io::Write;
use std::os::fd::{FromRawFd, IntoRawFd};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, TrySendError, sync_channel};
use std::thread;
use std::time::Duration;

use crate::audit::{AuditEvent, AuditLogger};

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or_default()
}

const ACTUATOR_SOCKET_PATH: &str = "/tmp/genesis_act.sock";
const DEFAULT_DYNAMIC_ACTUATOR_SOCKET_PATH: &str = "/tmp/genesis_dynamic_act.sock";
const OS_ACTUATOR_SOCKET_ENV: &str = "GENESIS_OS_ACT_SOCKET";
const DYNAMIC_ACTUATOR_SOCKET_ENV: &str = "GENESIS_DYNAMIC_ACT_SOCKET";
pub const MAX_VERIFIABLE_WAIT_MS: u64 = 2_000;
pub const COORDINATE_ABS_LIMIT: f64 = 1_000_000.0;
pub const TARGET_ID_MAX_LEN: usize = 64;
const ACTUATOR_CONNECT_TIMEOUT: Duration = Duration::from_millis(10);
const ACTUATOR_WRITE_TIMEOUT: Duration = Duration::from_millis(10);

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(tag = "type")]
pub enum WaitExpectedState {
    #[serde(rename = "element_visible")]
    ElementVisible { selector: String },
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(tag = "act")]
pub enum GenesisAction {
    #[serde(rename = "noop")]
    Noop { reason: Option<String> },

    #[serde(rename = "click")]
    Click { target: String, reason: String },

    #[serde(rename = "type")]
    Type {
        target: String,
        text: String,
        reason: String,
    },

    #[serde(rename = "key")]
    Key { code: String, reason: String },

    #[serde(rename = "wait")]
    Wait {
        ms: u64,
        expected_state: WaitExpectedState,
        reason: String,
    },

    #[serde(rename = "click_point")]
    ClickPoint {
        target_id: String,
        x: f64,
        y: f64,
        frame_id: u64,
        reason: String,
    },

    #[serde(rename = "assert_ui_state")]
    AssertUiState {
        target: String,
        expected: String,
        reason: String,
    },
}

impl GenesisAction {
    pub fn validate_for_dispatch(&self) -> Result<(), String> {
        match self {
            GenesisAction::Wait {
                ms,
                expected_state: WaitExpectedState::ElementVisible { selector },
                ..
            } => {
                if *ms > MAX_VERIFIABLE_WAIT_MS {
                    return Err(format!(
                        "wait ms outside next-tick verification budget: {ms} > {MAX_VERIFIABLE_WAIT_MS}"
                    ));
                }
                if selector.trim().is_empty() {
                    return Err("wait expected selector must not be empty".to_string());
                }
            }
            GenesisAction::ClickPoint {
                target_id, x, y, ..
            } => {
                if target_id.trim().is_empty() || target_id.len() > TARGET_ID_MAX_LEN {
                    return Err("click_point target_id outside length bounds".to_string());
                }
                if !x.is_finite() || !y.is_finite() {
                    return Err("click_point coordinates must be finite".to_string());
                }
                if x.abs() > COORDINATE_ABS_LIMIT || y.abs() > COORDINATE_ABS_LIMIT {
                    return Err(format!(
                        "click_point coordinates outside abs limit: {COORDINATE_ABS_LIMIT}"
                    ));
                }
            }
            _ => {}
        }

        Ok(())
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct BrainActionEnvelope {
    pub tick: u64,
    #[serde(flatten)]
    pub action: GenesisAction,
}

#[derive(Clone)]
pub struct ActDispatcher {
    sender: SyncSender<ActionCommand>,
    auditor: AuditLogger,
    next_sequence: Arc<AtomicU64>,
    pending_actions: Arc<Mutex<VecDeque<PendingAction>>>,
}

struct ActionCommand {
    action_id: String,
    tick_id: u64,
    source_tick_id: u64,
    action: GenesisAction,
}

#[derive(Clone, Debug)]
pub struct PendingAction {
    pub action_id: String,
    pub queued_tick_id: u64,
    pub source_tick_id: u64,
    pub dispatched_at_ms: u64,
    delivery_status: Arc<AtomicU8>,
    pub action: GenesisAction,
}

/// 区分入队与真实投递，避免审计链混淆。
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryStatus {
    Queued,
    Sent,
    Fallback,
}

impl PendingAction {
    pub fn delivery_status(&self) -> DeliveryStatus {
        DeliveryStatus::from_u8(self.delivery_status.load(Ordering::Acquire))
    }

    fn is_delivery_terminal(&self) -> bool {
        self.delivery_status().is_terminal()
    }
}

impl DeliveryStatus {
    fn as_u8(self) -> u8 {
        match self {
            DeliveryStatus::Queued => 0,
            DeliveryStatus::Sent => 1,
            DeliveryStatus::Fallback => 2,
        }
    }

    fn from_u8(value: u8) -> Self {
        match value {
            1 => DeliveryStatus::Sent,
            2 => DeliveryStatus::Fallback,
            _ => DeliveryStatus::Queued,
        }
    }

    fn is_terminal(self) -> bool {
        matches!(self, DeliveryStatus::Sent | DeliveryStatus::Fallback)
    }
}

impl ActDispatcher {
    pub fn new(queue_capacity: usize, auditor: AuditLogger) -> Self {
        let (sender, receiver) = sync_channel::<ActionCommand>(queue_capacity);
        let worker_auditor = auditor.clone();
        let pending_actions = Arc::new(Mutex::new(VecDeque::<PendingAction>::new()));
        let worker_pending_actions = pending_actions.clone();

        thread::spawn(move || {
            while let Ok(command) = receiver.recv() {
                let action_id = command.action_id.clone();
                let delivery_status = execute_action(command, &worker_auditor);
                if let Ok(mut pending) = worker_pending_actions.lock()
                    && let Some(action) = pending
                        .iter_mut()
                        .find(|action| action.action_id == action_id)
                {
                    action
                        .delivery_status
                        .store(delivery_status.as_u8(), Ordering::Release);
                }
            }
        });

        Self {
            sender,
            auditor,
            next_sequence: Arc::new(AtomicU64::new(1)),
            pending_actions,
        }
    }

    pub fn next_action_id(&self, tick_id: u64) -> String {
        let sequence = self.next_sequence.fetch_add(1, Ordering::Relaxed);
        format!("act-{tick_id}-{sequence}")
    }

    pub fn dispatch_reserved(
        &self,
        tick_id: u64,
        source_tick_id: u64,
        action_id: String,
        action: GenesisAction,
    ) -> bool {
        let pending_action_with_status = PendingAction {
            action_id: action_id.clone(),
            queued_tick_id: tick_id,
            source_tick_id,
            dispatched_at_ms: now_ms(),
            delivery_status: Arc::new(AtomicU8::new(DeliveryStatus::Queued.as_u8())),
            action: action.clone(),
        };
        let command = ActionCommand {
            action_id: action_id.clone(),
            tick_id,
            source_tick_id,
            action,
        };

        let mut pending = self
            .pending_actions
            .lock()
            .expect("pending action ledger poisoned");
        pending.push_back(pending_action_with_status);

        match self.sender.try_send(command) {
            Ok(()) => {
                drop(pending);
                // 记录 ActionQueued，而非模糊的 ActionDispatched。
                // "Queued" = 已成功入队；后续 verify_pending_outcomes 确认 delivery。
                self.auditor.log(AuditEvent::ActionQueued {
                    tick_id,
                    source_tick_id,
                    action_id: action_id.clone(),
                });
                #[allow(deprecated)]
                self.auditor.log(AuditEvent::ActionDispatched {
                    tick_id,
                    source_tick_id,
                    action_id,
                });
                true
            }
            Err(TrySendError::Full(command)) => {
                remove_latest_pending_action(&mut pending, &command.action_id);
                drop(pending);
                println!(
                    "[Act Dispatcher] ⚠️ 执行器繁忙，丢弃动作 {}: {:?}",
                    command.action_id, command.action
                );
                self.auditor.log(AuditEvent::ActionDropped {
                    tick_id: command.tick_id,
                    action_id: Some(command.action_id),
                    reason: "actuator queue full".to_string(),
                });
                false
            }
            Err(TrySendError::Disconnected(command)) => {
                remove_latest_pending_action(&mut pending, &command.action_id);
                drop(pending);
                println!(
                    "[Act Dispatcher] 🚨 执行器离线，丢弃动作 {}: {:?}",
                    command.action_id, command.action
                );
                self.auditor.log(AuditEvent::ActionDropped {
                    tick_id: command.tick_id,
                    action_id: Some(command.action_id),
                    reason: "actuator worker disconnected".to_string(),
                });
                false
            }
        }
    }

    pub fn take_pending_for_verification(&self, current_tick_id: u64) -> Vec<PendingAction> {
        let mut pending = self
            .pending_actions
            .lock()
            .expect("pending action ledger poisoned");
        let mut ready = Vec::new();
        let mut retained = VecDeque::new();

        while let Some(action) = pending.pop_front() {
            if action.queued_tick_id < current_tick_id && action.is_delivery_terminal() {
                ready.push(action);
            } else {
                retained.push_back(action);
            }
        }

        *pending = retained;
        ready
    }
}

fn remove_latest_pending_action(pending: &mut VecDeque<PendingAction>, action_id: &str) {
    if let Some(index) = pending
        .iter()
        .rposition(|action| action.action_id == action_id)
    {
        pending.remove(index);
    }
}

fn execute_action(command: ActionCommand, auditor: &AuditLogger) -> DeliveryStatus {
    // 先执行外部 Actuator，结果绑定到 delivery_result
    let delivery_result = match send_to_external_actuator(&command.action_id, &command.action) {
        Ok(()) => DeliveryStatus::Sent,
        Err(err) => {
            println!(
                "[Actuator] ⚠️ local actuator unavailable ({}): {}",
                command.action_id, err
            );
            auditor.log(AuditEvent::FailureObserved {
                tick_id: command.tick_id,
                component: "Actuator".to_string(),
                error: format!(
                    "send_to_external_actuator failed for {}: {}",
                    command.action_id, err
                ),
            });
            DeliveryStatus::Fallback
        }
    };

    // match 块现在使用 delivery_result，区分成功和失败
    let result_suffix = if matches!(delivery_result, DeliveryStatus::Sent) {
        " → sent"
    } else {
        " → fallback (local)"
    };

    match command.action {
        GenesisAction::Noop { reason } => {
            println!(
                "[Actuator] noop id={} source_tick={} reason={}{result_suffix}",
                command.action_id,
                command.source_tick_id,
                reason.unwrap_or_default(),
            );
        }
        GenesisAction::Click { target, reason } => {
            println!(
                "[Actuator] click id={} source_tick={} target={} reason={}{result_suffix}",
                command.action_id, command.source_tick_id, target, &reason
            );
        }
        GenesisAction::Type {
            target,
            text,
            reason,
        } => {
            println!(
                "[Actuator] type id={} source_tick={} target={} text={} reason={}{result_suffix}",
                command.action_id, command.source_tick_id, target, &text, &reason
            );
        }
        GenesisAction::Key { code, reason } => {
            println!(
                "[Actuator] key id={} source_tick={} code={} reason={}{result_suffix}",
                command.action_id, command.source_tick_id, code, &reason
            );
        }
        GenesisAction::Wait {
            ms,
            expected_state,
            reason,
        } => {
            println!(
                "[Actuator] passive wait id={} source_tick={} ms={} expected={:?} reason={}{result_suffix}",
                command.action_id, command.source_tick_id, ms, expected_state, &reason
            );
        }
        GenesisAction::ClickPoint {
            target_id,
            x,
            y,
            frame_id,
            reason,
        } => {
            println!(
                "[Actuator] click_point id={} source_tick={} target_id={} x={} y={} frame_id={} reason={}{result_suffix}",
                command.action_id, command.source_tick_id, target_id, x, y, frame_id, &reason
            );
        }
        GenesisAction::AssertUiState {
            target,
            expected,
            reason,
        } => {
            println!(
                "[Actuator] assert id={} source_tick={} target={} expected={} reason={}{result_suffix}",
                command.action_id, command.source_tick_id, target, expected, &reason
            );
        }
    }

    delivery_result
}

fn send_to_external_actuator(action_id: &str, action: &GenesisAction) -> Result<(), String> {
    let socket_path = match action {
        GenesisAction::ClickPoint { .. } => std::env::var(OS_ACTUATOR_SOCKET_ENV)
            .or_else(|_| std::env::var(DYNAMIC_ACTUATOR_SOCKET_ENV))
            .unwrap_or_else(|_| DEFAULT_DYNAMIC_ACTUATOR_SOCKET_PATH.to_string()),
        _ => ACTUATOR_SOCKET_PATH.to_string(),
    };
    let mut stream = connect_unix_stream_with_timeout(&socket_path, ACTUATOR_CONNECT_TIMEOUT)?;
    stream
        .set_write_timeout(Some(ACTUATOR_WRITE_TIMEOUT))
        .map_err(|err| err.to_string())?;
    let mut frame = if matches!(action, GenesisAction::ClickPoint { .. }) {
        let mut value = serde_json::to_value(action).map_err(|err| err.to_string())?;
        let Some(object) = value.as_object_mut() else {
            return Err("click_point action did not serialize as object".to_string());
        };
        object.insert(
            "action_id".to_string(),
            Value::String(action_id.to_string()),
        );
        serde_json::to_vec(&value).map_err(|err| err.to_string())?
    } else {
        serde_json::to_vec(action).map_err(|err| err.to_string())?
    };
    frame.push(b'\n');
    stream.write_all(&frame).map_err(|err| err.to_string())
}

fn connect_unix_stream_with_timeout(path: &str, timeout: Duration) -> Result<UnixStream, String> {
    let socket = Socket::new(Domain::UNIX, Type::STREAM, None).map_err(|err| err.to_string())?;
    let address = SockAddr::unix(path).map_err(|err| err.to_string())?;
    socket
        .connect_timeout(&address, timeout)
        .map_err(|err| err.to_string())?;
    let fd = socket.into_raw_fd();
    Ok(unsafe { UnixStream::from_raw_fd(fd) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audit::AuditLogger;

    #[test]
    fn wait_accepts_next_tick_condition_within_budget() {
        let action = GenesisAction::Wait {
            ms: MAX_VERIFIABLE_WAIT_MS,
            expected_state: WaitExpectedState::ElementVisible {
                selector: "a".to_string(),
            },
            reason: "one tick".to_string(),
        };
        assert!(action.validate_for_dispatch().is_ok());
    }

    #[test]
    fn wait_rejects_duration_beyond_next_tick_budget() {
        let action = GenesisAction::Wait {
            ms: MAX_VERIFIABLE_WAIT_MS + 1,
            expected_state: WaitExpectedState::ElementVisible {
                selector: "a".to_string(),
            },
            reason: "too late".to_string(),
        };
        assert!(action.validate_for_dispatch().is_err());
    }

    #[test]
    fn click_point_accepts_finite_protocol_coordinates() {
        let action = GenesisAction::ClickPoint {
            target_id: "heal".to_string(),
            x: -20.0,
            y: 9999.0,
            frame_id: 42,
            reason: "let arena judge world facts".to_string(),
        };
        assert!(action.validate_for_dispatch().is_ok());
    }

    #[test]
    fn click_point_rejects_nonphysical_protocol_values() {
        let action = GenesisAction::ClickPoint {
            target_id: "heal".to_string(),
            x: f64::INFINITY,
            y: 0.0,
            frame_id: 42,
            reason: "bad".to_string(),
        };
        assert!(action.validate_for_dispatch().is_err());
    }

    #[test]
    fn verifier_retains_actions_until_delivery_reaches_terminal_state() {
        let dispatcher = ActDispatcher::new(1, AuditLogger::new(16));
        {
            let mut pending = dispatcher.pending_actions.lock().unwrap();
            pending.push_back(PendingAction {
                action_id: "act-test-queued".to_string(),
                queued_tick_id: 1,
                source_tick_id: 1,
                dispatched_at_ms: 1,
                delivery_status: Arc::new(AtomicU8::new(DeliveryStatus::Queued.as_u8())),
                action: GenesisAction::Noop {
                    reason: Some("not delivered yet".to_string()),
                },
            });
        }

        assert!(dispatcher.take_pending_for_verification(2).is_empty());
        assert_eq!(dispatcher.pending_actions.lock().unwrap().len(), 1);
    }
}
