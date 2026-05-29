// genesis-core/src/kernel.rs
use genesis_contracts::wire::{
    GENESIS_ABI_VERSION, GENESIS_STATUS_ERROR, GENESIS_STATUS_OK, GENESIS_STATUS_REJECTED,
    GENESIS_STATUS_TAINTED, GENESIS_STATUS_THINKING, GENESIS_STATUS_TIMEOUT, GenesisPluginApi,
    GenesisResponse, GenesisSlice,
};
use libloading::{Library, Symbol};
use serde::Deserialize;
use std::collections::HashMap;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::act::{ActDispatcher, BrainActionEnvelope};
use crate::audit::{AuditEvent, AuditLogger, PlanStep, VerificationResult};
use crate::verify::verify_pending_action;
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
    active_plan: Option<ActivePlan>,
}

struct ActivePlan {
    plan_id: String,
    steps: Vec<PlanStep>,
    current_index: usize,
    awaiting_action_id: Option<String>,
}

enum BrainDispatch {
    None,
    Plan(PlanDraftEnvelope),
    ActionDispatched(String),
}

impl GenesisKernel {
    pub fn new(auditor: AuditLogger) -> Self {
        Self {
            plugins: HashMap::new(),
            retired_plugins: Vec::new(),
            act_dispatcher: ActDispatcher::new(4, auditor.clone()),
            auditor,
            active_plan: None,
        }
    }

    pub fn load_plugin(&mut self, path: &str) -> Result<(), String> {
        unsafe {
            let lib = Library::new(path).map_err(|e| e.to_string())?;

            let entry: Symbol<extern "C" fn() -> GenesisPluginApi> = lib
                .get(b"genesis_plugin_entry")
                .map_err(|e| e.to_string())?;
            let api = entry();

            // ABI 版本硬门：mismatch 时拒绝加载，防止 C ABI 不变量被破坏导致 UBO。
            if api.abi_version != GENESIS_ABI_VERSION {
                return Err(format!(
                    "unsupported ABI version: core={}, plugin={}",
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
        let allow_plan_draft = self.active_plan.is_none();
        let allow_action_dispatch = self
            .active_plan
            .as_ref()
            .is_none_or(|plan| plan.awaiting_action_id.is_none());
        let mut drafted_plan = None;
        let mut dispatched_plan_action = None;

        for plugin in self.plugins.values_mut() {
            match trigger_loaded_plugin(
                plugin,
                tick_id,
                payload,
                &act_dispatcher,
                &auditor,
                allow_plan_draft,
                allow_action_dispatch,
            ) {
                BrainDispatch::Plan(plan) => drafted_plan = Some(plan),
                BrainDispatch::ActionDispatched(action_id) => {
                    dispatched_plan_action = Some(action_id);
                }
                BrainDispatch::None => {}
            }
        }

        if let Some(action_id) = dispatched_plan_action {
            self.bind_plan_action(action_id);
        }
        if let Some(plan) = drafted_plan {
            self.activate_plan(tick_id, plan);
        }
    }

    pub fn verify_pending_outcomes(
        &mut self,
        tick_id: u64,
        payload: &str,
    ) -> Option<serde_json::Value> {
        let mut latest_failure = None;
        for pending in self.act_dispatcher.take_pending_for_verification(tick_id) {
            let (result, evidence) =
                verify_pending_action(&pending.action_id, &pending.action, payload);
            println!(
                "[Verifier] 🔎 action={} dispatched_tick={} result={:?}",
                pending.action_id, pending.queued_tick_id, result
            );
            if let Some(outcome) = failed_outcome_payload(tick_id, &pending, &result, &evidence) {
                latest_failure = Some(outcome);
            }
            if self.action_matches_active_step(&pending.action_id) {
                self.apply_plan_verification(tick_id, &result);
            }
            self.auditor.log(AuditEvent::OutcomeObserved {
                tick_id,
                action_id: pending.action_id,
                source_tick_id: pending.source_tick_id,
                dispatched_tick_id: pending.queued_tick_id,
                result,
                evidence,
            });
        }
        latest_failure
    }

    pub fn active_step_payload(&self) -> Option<serde_json::Value> {
        let plan = self.active_plan.as_ref()?;
        if plan.awaiting_action_id.is_some() {
            return None;
        }
        let step = plan.steps.get(plan.current_index)?;
        Some(serde_json::json!({
            "plan_id": plan.plan_id,
            "step_index": step.step_index,
            "intent": step.intent,
            "target_selector": step.target_selector,
        }))
    }

    fn activate_plan(&mut self, tick_id: u64, plan: PlanDraftEnvelope) {
        if plan.steps.is_empty() {
            self.auditor.log(AuditEvent::FailureObserved {
                tick_id,
                component: "PlannerDecoder".to_string(),
                error: format!("empty plan ignored: {}", plan.plan_id),
            });
            return;
        }

        println!(
            "[Planner] 🧭 Tick {} activated plan {} source Tick {} goal={} steps={}",
            tick_id,
            plan.plan_id,
            plan.tick,
            plan.goal,
            plan.steps.len()
        );
        self.auditor.log(AuditEvent::PlanDrafted {
            tick_id,
            source_tick_id: plan.tick,
            plan_id: plan.plan_id.clone(),
            goal: plan.goal,
            steps: plan.steps.clone(),
        });
        self.active_plan = Some(ActivePlan {
            plan_id: plan.plan_id.clone(),
            steps: plan.steps,
            current_index: 0,
            awaiting_action_id: None,
        });
        self.auditor.log(AuditEvent::PlanActivated {
            tick_id,
            plan_id: plan.plan_id,
        });
        self.log_current_step(tick_id);
    }

    fn apply_plan_verification(&mut self, tick_id: u64, result: &VerificationResult) {
        let Some(plan) = self.active_plan.as_ref() else {
            return;
        };
        let plan_id = plan.plan_id.clone();
        let from_step = plan.current_index as u32;

        match result {
            VerificationResult::Verified => {
                let next_index = plan.current_index + 1;
                self.auditor.log(AuditEvent::PlanAdvanced {
                    tick_id,
                    plan_id: plan_id.clone(),
                    from_step,
                    to_step: next_index as u32,
                });

                if next_index >= plan.steps.len() {
                    self.active_plan = None;
                    return;
                }

                if let Some(plan) = self.active_plan.as_mut() {
                    plan.current_index = next_index;
                    plan.awaiting_action_id = None;
                }
                self.log_current_step(tick_id);
            }
            VerificationResult::Failed { reason } => {
                self.auditor.log(AuditEvent::PlanAborted {
                    tick_id,
                    plan_id,
                    at_step: from_step,
                    reason: reason.clone(),
                });
                self.active_plan = None;
            }
            VerificationResult::Timeout => {
                self.auditor.log(AuditEvent::PlanAborted {
                    tick_id,
                    plan_id,
                    at_step: from_step,
                    reason: "verification_timeout".to_string(),
                });
                self.active_plan = None;
            }
        }
    }

    fn bind_plan_action(&mut self, action_id: String) {
        let Some(plan) = self.active_plan.as_mut() else {
            return;
        };
        if plan.awaiting_action_id.is_none() {
            plan.awaiting_action_id = Some(action_id);
        }
    }

    fn action_matches_active_step(&self, action_id: &str) -> bool {
        self.active_plan
            .as_ref()
            .and_then(|plan| plan.awaiting_action_id.as_deref())
            == Some(action_id)
    }

    fn log_current_step(&self, tick_id: u64) {
        let Some(plan) = self.active_plan.as_ref() else {
            return;
        };
        let Some(step) = plan.steps.get(plan.current_index) else {
            // Plan has no steps left — emit final StepActivated
            self.auditor.log(AuditEvent::StepActivated {
                tick_id,
                plan_id: plan.plan_id.clone(),
                step_index: 0,
                intent: "<plan_complete>".to_string(),
            });
            return;
        };

        let awaiting = plan.awaiting_action_id.is_some();
        eprintln!(
            "[Plan] 📋 Step {} activated: id={} index={} intent={} awaiting_action={}",
            tick_id, plan.plan_id, step.step_index, step.intent, awaiting,
        );
        self.auditor.log(AuditEvent::StepActivated {
            tick_id,
            plan_id: plan.plan_id.clone(),
            step_index: step.step_index,
            intent: step.intent.clone(),
        });
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
            "dispatched_tick_id": pending.queued_tick_id,
            "observed_tick_id": tick_id,
            "status": "Failed",
            "reason": reason,
            "action": &pending.action,
            "evidence": evidence,
        })),
        VerificationResult::Timeout => Some(serde_json::json!({
            "action_id": pending.action_id,
            "source_tick_id": pending.source_tick_id,
            "dispatched_tick_id": pending.queued_tick_id,
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
    allow_plan_draft: bool,
    allow_action_dispatch: bool,
) -> BrainDispatch {
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
        return dispatch_brain_action(
            tick_id,
            &action_data,
            act_dispatcher,
            auditor,
            allow_plan_draft,
            allow_action_dispatch,
        );
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

    BrainDispatch::None
}

fn dispatch_brain_action(
    tick_id: u64,
    action_data: &str,
    act_dispatcher: &ActDispatcher,
    auditor: &AuditLogger,
    allow_plan_draft: bool,
    allow_action_dispatch: bool,
) -> BrainDispatch {
    let (decision_data, advisory_meta) = unwrap_brain_decision(action_data);
    if let Some(meta) = advisory_meta {
        if meta.is_valid() {
            auditor.log(AuditEvent::MemoryAdvisoryAttached {
                tick_id,
                scope: meta.scope,
                sample_count: meta.sample_count,
                hash: meta.hash,
            });
        } else {
            auditor.log(AuditEvent::FailureObserved {
                tick_id,
                component: "MemoryAdvisoryDecoder".to_string(),
                error: "invalid advisory metadata envelope".to_string(),
            });
        }
    }

    if let Ok(plan) = serde_json::from_str::<PlanDraftEnvelope>(&decision_data) {
        if allow_plan_draft {
            return BrainDispatch::Plan(plan);
        }
        auditor.log(AuditEvent::FailureObserved {
            tick_id,
            component: "PlannerDecoder".to_string(),
            error: format!(
                "plan draft rejected while active step is awaiting tactical action: {}",
                plan.plan_id
            ),
        });
        return BrainDispatch::None;
    }

    match serde_json::from_str::<BrainActionEnvelope>(&decision_data) {
        Ok(decision) => {
            if !allow_action_dispatch {
                auditor.log(AuditEvent::FailureObserved {
                    tick_id,
                    component: "PlannerCursor".to_string(),
                    error: "tactical action rejected while prior step outcome is pending"
                        .to_string(),
                });
                return BrainDispatch::None;
            }
            if let Err(error) = decision.action.validate_for_dispatch() {
                auditor.log(AuditEvent::FailureObserved {
                    tick_id,
                    component: "BrainActionDecoder".to_string(),
                    error: format!("unsafe action rejected: {error}"),
                });
                return BrainDispatch::None;
            }
            let action_id = act_dispatcher.next_action_id(tick_id);
            println!(
                "[Act Dispatcher] 🎯 Tick {} decoded source Tick {} action {}: {:?}",
                tick_id, decision.tick, action_id, decision.action
            );
            auditor.log(AuditEvent::BrainActionDecoded {
                tick_id,
                source_tick_id: decision.tick,
                action_id: action_id.clone(),
                action_json: decision_data,
            });
            if act_dispatcher.dispatch_reserved(
                tick_id,
                decision.tick,
                action_id.clone(),
                decision.action,
            ) {
                return BrainDispatch::ActionDispatched(action_id);
            }
        }
        Err(err) => {
            println!(
                "[Act Dispatcher] 🚨 Brain generated invalid action JSON: {} | raw={}",
                err, decision_data
            );
            auditor.log(AuditEvent::FailureObserved {
                tick_id,
                component: "BrainActionDecoder".to_string(),
                error: format!("invalid action JSON: {err}"),
            });
        }
    }

    BrainDispatch::None
}

fn unwrap_brain_decision(action_data: &str) -> (String, Option<AdvisoryMeta>) {
    let Ok(packet) = serde_json::from_str::<BrainDecisionPacket>(action_data) else {
        return (action_data.to_string(), None);
    };

    (
        serde_json::to_string(&packet.action).unwrap_or_else(|_| action_data.to_string()),
        packet.advisory_meta,
    )
}

#[derive(Deserialize)]
struct BrainDecisionPacket {
    action: serde_json::Value,
    advisory_meta: Option<AdvisoryMeta>,
}

#[derive(Deserialize)]
struct AdvisoryMeta {
    scope: String,
    sample_count: u64,
    hash: String,
}

impl AdvisoryMeta {
    fn is_valid(&self) -> bool {
        self.scope == "active_step_target"
            && self.sample_count <= 100
            && self.hash.len() == 16
            && self.hash.bytes().all(|byte| byte.is_ascii_hexdigit())
    }
}

#[derive(Deserialize)]
struct PlanDraftEnvelope {
    tick: u64,
    plan_id: String,
    goal: String,
    steps: Vec<PlanStep>,
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

#[cfg(test)]
mod tests {
    use super::unwrap_brain_decision;
    use serde_json::json;

    #[test]
    fn keeps_plain_brain_action_backward_compatible() {
        let action = r#"{"tick":7,"act":"noop","reason":"observe"}"#;
        let (decoded, advisory) = unwrap_brain_decision(action);

        assert_eq!(decoded, action);
        assert!(advisory.is_none());
    }

    #[test]
    fn unwraps_advisory_without_merging_it_into_action_data() {
        let packet = r#"{"action":{"tick":7,"act":"noop","reason":"observe"},"advisory_meta":{"scope":"active_step_target","sample_count":2,"hash":"0123456789abcdef"}}"#;
        let (decoded, advisory) = unwrap_brain_decision(packet);
        let advisory = advisory.expect("advisory metadata");

        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&decoded).expect("action JSON"),
            json!({"tick": 7, "act": "noop", "reason": "observe"})
        );
        assert!(advisory.is_valid());
        assert!(!decoded.contains("advisory_meta"));
    }

    #[test]
    fn rejects_unbounded_advisory_metadata() {
        let packet = r#"{"action":{"tick":7,"act":"noop","reason":"observe"},"advisory_meta":{"scope":"active_step_target","sample_count":101,"hash":"0123456789abcdef"}}"#;
        let (_, advisory) = unwrap_brain_decision(packet);

        assert!(!advisory.expect("advisory metadata").is_valid());
    }
}
