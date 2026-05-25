use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, TrySendError, sync_channel};
use std::thread;
use std::time::Duration;

use crate::audit::{AuditEvent, AuditLogger};

const ACTUATOR_SOCKET_PATH: &str = "/tmp/genesis_act.sock";

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
    Wait { ms: u64, reason: String },

    #[serde(rename = "assert_ui_state")]
    AssertUiState {
        target: String,
        expected: String,
        reason: String,
    },
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
    pub dispatched_tick_id: u64,
    pub source_tick_id: u64,
    pub action: GenesisAction,
}

impl ActDispatcher {
    pub fn new(queue_capacity: usize, auditor: AuditLogger) -> Self {
        let (sender, receiver) = sync_channel::<ActionCommand>(queue_capacity);
        let worker_auditor = auditor.clone();

        thread::spawn(move || {
            while let Ok(command) = receiver.recv() {
                execute_action(command, &worker_auditor);
            }
        });

        Self {
            sender,
            auditor,
            next_sequence: Arc::new(AtomicU64::new(1)),
            pending_actions: Arc::new(Mutex::new(VecDeque::new())),
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
        let pending_action = action.clone();
        let command = ActionCommand {
            action_id: action_id.clone(),
            tick_id,
            source_tick_id,
            action,
        };

        match self.sender.try_send(command) {
            Ok(()) => {
                self.pending_actions
                    .lock()
                    .expect("pending action ledger poisoned")
                    .push_back(PendingAction {
                        action_id: action_id.clone(),
                        dispatched_tick_id: tick_id,
                        source_tick_id,
                        action: pending_action,
                    });
                self.auditor.log(AuditEvent::ActionDispatched {
                    tick_id,
                    source_tick_id,
                    action_id,
                });
                true
            }
            Err(TrySendError::Full(command)) => {
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
            if action.dispatched_tick_id < current_tick_id {
                ready.push(action);
            } else {
                retained.push_back(action);
            }
        }

        *pending = retained;
        ready
    }
}

fn execute_action(command: ActionCommand, auditor: &AuditLogger) {
    if let Err(err) = send_to_external_actuator(&command.action) {
        println!("[Actuator] local actuator unavailable: {}", err);
        auditor.log(AuditEvent::FailureObserved {
            tick_id: command.tick_id,
            component: "Actuator".to_string(),
            error: err,
        });
    }

    match command.action {
        GenesisAction::Noop { reason } => {
            println!(
                "[Actuator] noop id={} source_tick={} reason={}",
                command.action_id,
                command.source_tick_id,
                reason.unwrap_or_default()
            );
        }
        GenesisAction::Click { target, reason } => {
            println!(
                "[Actuator] click id={} source_tick={} target={} reason={}",
                command.action_id, command.source_tick_id, target, reason
            );
        }
        GenesisAction::Type {
            target,
            text,
            reason,
        } => {
            println!(
                "[Actuator] type id={} source_tick={} target={} text={} reason={}",
                command.action_id, command.source_tick_id, target, text, reason
            );
        }
        GenesisAction::Key { code, reason } => {
            println!(
                "[Actuator] key id={} source_tick={} code={} reason={}",
                command.action_id, command.source_tick_id, code, reason
            );
        }
        GenesisAction::Wait { ms, reason } => {
            println!(
                "[Actuator] wait id={} source_tick={} ms={} reason={}",
                command.action_id, command.source_tick_id, ms, reason
            );
            thread::sleep(Duration::from_millis(ms));
        }
        GenesisAction::AssertUiState {
            target,
            expected,
            reason,
        } => {
            println!(
                "[Actuator] assert id={} source_tick={} target={} expected={} reason={}",
                command.action_id, command.source_tick_id, target, expected, reason
            );
        }
    }
}

fn send_to_external_actuator(action: &GenesisAction) -> Result<(), String> {
    let mut stream = UnixStream::connect(ACTUATOR_SOCKET_PATH).map_err(|err| err.to_string())?;
    let mut frame = serde_json::to_vec(action).map_err(|err| err.to_string())?;
    frame.push(b'\n');
    stream.write_all(&frame).map_err(|err| err.to_string())
}
