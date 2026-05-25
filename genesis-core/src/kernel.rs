// genesis-core/src/kernel.rs
use genesis_contracts::wire::{
    GENESIS_ABI_VERSION, GENESIS_STATUS_ERROR, GENESIS_STATUS_OK, GENESIS_STATUS_REJECTED,
    GENESIS_STATUS_TAINTED, GENESIS_STATUS_THINKING, GENESIS_STATUS_TIMEOUT, GenesisPluginApi,
    GenesisResponse, GenesisSlice,
};
use libloading::{Library, Symbol};
use std::collections::HashMap;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::act::{ActDispatcher, BrainActionEnvelope};
use crate::audit::{AuditEvent, AuditLogger, VerificationResult};
use crate::verify::verify_action;
use crate::watchdog::PluginWorker;

const PLUGIN_CALL_TIMEOUT: Duration = Duration::from_millis(15);

struct LoadedPlugin {
    _lib: Library,
    worker: PluginWorker,
    name: String,
}

pub struct GenesisKernel {
    plugins: HashMap<String, LoadedPlugin>,
    retired_plugins: Vec<LoadedPlugin>,
    act_dispatcher: ActDispatcher,
    auditor: AuditLogger,
}

impl GenesisKernel {
    pub fn new(auditor: AuditLogger) -> Self {
        Self {
            plugins: HashMap::new(),
            retired_plugins: Vec::new(),
            act_dispatcher: ActDispatcher::new(4, auditor.clone()),
            auditor,
        }
    }

    pub fn load_plugin(&mut self, path: &str) -> Result<(), String> {
        unsafe {
            let lib = Library::new(path).map_err(|e| e.to_string())?;

            let entry: Symbol<extern "C" fn() -> GenesisPluginApi> = lib
                .get(b"genesis_plugin_entry")
                .map_err(|e| e.to_string())?;
            let api = entry();

            if api.abi_version != GENESIS_ABI_VERSION {
                return Err(format!(
                    "ABI version mismatch: core={}, plugin={}",
                    GENESIS_ABI_VERSION, api.abi_version
                ));
            }

            let name = slice_to_string(api.plugin_id);
            println!(
                "[微核] 🩸 插件 [{}] 已通过 ABI v{} 接入神经网！",
                name, api.abi_version
            );

            self.plugins.insert(
                path.to_string(),
                LoadedPlugin {
                    _lib: lib,
                    worker: PluginWorker::new(api),
                    name,
                },
            );
        }
        Ok(())
    }

    pub fn reload_plugin(&mut self, path: &str) -> Result<(), String> {
        if let Some(mut plugin) = self.plugins.remove(path) {
            plugin.worker.shutdown();
            plugin.worker.retire();
            self.retired_plugins.push(plugin);
        }
        self.load_plugin(path) // 接入新器官
    }

    pub fn trigger_all(&mut self, tick_id: u64, payload: &str) {
        if self.plugins.is_empty() {
            println!("[突触传导] 🫀 脉冲跳动... 但暂无器官接入。");
            return;
        }

        let act_dispatcher = self.act_dispatcher.clone();
        let auditor = self.auditor.clone();

        for plugin in self.plugins.values_mut() {
            trigger_loaded_plugin(plugin, tick_id, payload, &act_dispatcher, &auditor);
        }
    }

    pub fn verify_pending_outcomes(
        &mut self,
        tick_id: u64,
        payload: &str,
    ) -> Option<serde_json::Value> {
        let mut latest_failure = None;
        for pending in self.act_dispatcher.take_pending_for_verification(tick_id) {
            let (result, evidence) = verify_action(&pending.action, payload);
            println!(
                "[Verifier] 🔎 action={} dispatched_tick={} result={:?}",
                pending.action_id, pending.dispatched_tick_id, result
            );
            if let Some(outcome) = failed_outcome_payload(tick_id, &pending, &result, &evidence) {
                latest_failure = Some(outcome);
            }
            self.auditor.log(AuditEvent::OutcomeObserved {
                tick_id,
                action_id: pending.action_id,
                source_tick_id: pending.source_tick_id,
                dispatched_tick_id: pending.dispatched_tick_id,
                result,
                evidence,
            });
        }
        latest_failure
    }
}

fn failed_outcome_payload(
    tick_id: u64,
    pending: &crate::act::PendingAction,
    result: &VerificationResult,
    evidence: &serde_json::Value,
) -> Option<serde_json::Value> {
    match result {
        VerificationResult::Verified => None,
        VerificationResult::Failed { reason } => Some(serde_json::json!({
            "action_id": pending.action_id,
            "source_tick_id": pending.source_tick_id,
            "dispatched_tick_id": pending.dispatched_tick_id,
            "observed_tick_id": tick_id,
            "status": "Failed",
            "reason": reason,
            "action": &pending.action,
            "evidence": evidence,
        })),
        VerificationResult::Timeout => Some(serde_json::json!({
            "action_id": pending.action_id,
            "source_tick_id": pending.source_tick_id,
            "dispatched_tick_id": pending.dispatched_tick_id,
            "observed_tick_id": tick_id,
            "status": "Timeout",
            "reason": "verification_timeout",
            "action": &pending.action,
            "evidence": evidence,
        })),
    }
}

fn trigger_loaded_plugin(
    plugin: &mut LoadedPlugin,
    tick_id: u64,
    payload: &str,
    act_dispatcher: &ActDispatcher,
    auditor: &AuditLogger,
) {
    let started_at = Instant::now();
    let response = plugin.worker.dispatch(
        tick_id,
        current_timestamp_ms(),
        0,
        payload.as_bytes(),
        PLUGIN_CALL_TIMEOUT,
    );

    let status_code = response.status;
    let error_code = response.error_code;
    let action_data = response_data_to_string(&response);
    plugin.worker.free_response(response);
    let latency_ms = started_at.elapsed().as_millis() as u64;

    let status = match status_code {
        GENESIS_STATUS_OK => "OK",
        GENESIS_STATUS_THINKING => "THINKING",
        GENESIS_STATUS_REJECTED => "REJECTED",
        GENESIS_STATUS_ERROR => "ERROR",
        GENESIS_STATUS_TIMEOUT => "TIMEOUT",
        GENESIS_STATUS_TAINTED => "TAINTED",
        _ => "UNKNOWN",
    };

    println!(
        "[突触传导] ✨ [{}] status={}({}) error={} action={}",
        plugin.name, status, status_code, error_code, action_data
    );

    auditor.log(AuditEvent::PluginResponded {
        tick_id,
        plugin_id: plugin.name.clone(),
        status: status_code,
        error_code,
        latency_ms,
        data_hash: fnv1a64(action_data.as_bytes()),
        data_preview: preview(&action_data, 240),
    });

    if plugin.name == "brain-llm" && status_code == GENESIS_STATUS_OK {
        dispatch_brain_action(tick_id, &action_data, act_dispatcher, auditor);
    } else if matches!(
        status_code,
        GENESIS_STATUS_REJECTED
            | GENESIS_STATUS_ERROR
            | GENESIS_STATUS_TIMEOUT
            | GENESIS_STATUS_TAINTED
    ) {
        auditor.log(AuditEvent::FailureObserved {
            tick_id,
            component: plugin.name.clone(),
            error: format!("plugin returned status={status}({status_code}) error={error_code}"),
        });
    }

    if status_code == GENESIS_STATUS_TAINTED {
        println!(
            "[看门狗] 🚨 插件 [{}] 已污染，等待热重载接管下一轮时间线。",
            plugin.name
        );
    }
}

fn dispatch_brain_action(
    tick_id: u64,
    action_data: &str,
    act_dispatcher: &ActDispatcher,
    auditor: &AuditLogger,
) {
    match serde_json::from_str::<BrainActionEnvelope>(action_data) {
        Ok(decision) => {
            let action_id = act_dispatcher.next_action_id(tick_id);
            println!(
                "[Act Dispatcher] 🎯 Tick {} decoded source Tick {} action {}: {:?}",
                tick_id, decision.tick, action_id, decision.action
            );
            auditor.log(AuditEvent::BrainActionDecoded {
                tick_id,
                source_tick_id: decision.tick,
                action_id: action_id.clone(),
                action_json: action_data.to_string(),
            });
            act_dispatcher.dispatch_reserved(tick_id, decision.tick, action_id, decision.action);
        }
        Err(err) => {
            println!(
                "[Act Dispatcher] 🚨 Brain generated invalid action JSON: {} | raw={}",
                err, action_data
            );
            auditor.log(AuditEvent::FailureObserved {
                tick_id,
                component: "BrainActionDecoder".to_string(),
                error: format!("invalid action JSON: {err}"),
            });
        }
    }
}

fn current_timestamp_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

fn slice_to_string(slice: GenesisSlice) -> String {
    if slice.ptr.is_null() || slice.len == 0 {
        return "<unnamed-plugin>".to_string();
    }

    let bytes = unsafe { std::slice::from_raw_parts(slice.ptr, slice.len) };
    String::from_utf8_lossy(bytes).into_owned()
}

fn response_data_to_string(response: &GenesisResponse) -> String {
    if response.data.ptr.is_null() || response.data.len == 0 {
        return String::new();
    }

    let bytes = unsafe { std::slice::from_raw_parts(response.data.ptr, response.data.len) };
    String::from_utf8_lossy(bytes).into_owned()
}

fn preview(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in bytes {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}
