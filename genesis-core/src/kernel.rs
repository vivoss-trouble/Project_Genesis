mod native_plugin;
mod plan_runtime;
mod plugin_common;
mod wasm_plugin;

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::act::{ActDispatcher, ActHealth, BrainActionEnvelope};
use crate::audit::{AuditEvent, AuditHealth, AuditLogger, PlanStep, VerificationResult};
use crate::verify::verify_pending_action;

const PLUGIN_CALL_TIMEOUT: Duration = Duration::from_millis(15);
const NATIVE_SHUTDOWN_STUCK_AFTER: Duration = Duration::from_millis(250);

use native_plugin::{LoadedPlugin, load_native_plugin, trigger_loaded_plugin};
use plan_runtime::PlanRuntime;
use wasm_plugin::{LoadedWasmPlugin, load_wasm_plugin_from_path, trigger_loaded_wasm_plugin};

pub struct GenesisKernel {
    plugins: HashMap<String, LoadedPlugin>,
    wasm_plugins: HashMap<String, LoadedWasmPlugin>,
    retired_plugins: Vec<LoadedPlugin>,
    native_reload_rejected_count: u64,
    act_dispatcher: ActDispatcher,
    auditor: AuditLogger,
    plan_runtime: PlanRuntime,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct KernelHealth {
    pub native_plugin_count: usize,
    pub wasm_plugin_count: usize,
    pub retired_plugin_count: usize,
    pub native_reload_rejected_count: u64,
    pub native_shutdown_stuck_count: usize,
    pub active_plan_id: Option<String>,
    pub active_plan_step_index: Option<u32>,
    pub active_plan_awaiting_action: bool,
    pub act: ActHealth,
    pub audit: AuditHealth,
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
            wasm_plugins: HashMap::new(),
            retired_plugins: Vec::new(),
            native_reload_rejected_count: 0,
            act_dispatcher: ActDispatcher::new(4, auditor.clone()),
            auditor,
            plan_runtime: PlanRuntime::new(),
        }
    }

    pub fn load_wasm_plugin(&mut self, path: &str) -> Result<(), String> {
        self.wasm_plugins
            .insert(path.to_string(), load_wasm_plugin_from_path(path)?);
        Ok(())
    }

    pub fn health(&self) -> KernelHealth {
        KernelHealth {
            native_plugin_count: self.plugins.len(),
            wasm_plugin_count: self.wasm_plugins.len(),
            retired_plugin_count: self.retired_plugins.len(),
            native_reload_rejected_count: self.native_reload_rejected_count,
            native_shutdown_stuck_count: self
                .retired_plugins
                .iter()
                .filter(|plugin| {
                    plugin.worker.is_shutdown_pending()
                        && plugin.retired_at.is_some_and(|retired_at| {
                            retired_at.elapsed() >= NATIVE_SHUTDOWN_STUCK_AFTER
                        })
                })
                .count(),
            active_plan_id: self.plan_runtime.active_plan_id(),
            active_plan_step_index: self.plan_runtime.active_plan_step_index(),
            active_plan_awaiting_action: self.plan_runtime.is_awaiting_action(),
            act: self.act_dispatcher.health(),
            audit: self.auditor.health(),
        }
    }

    pub fn load_plugin(&mut self, path: &str) -> Result<(), String> {
        self.reap_retired_plugins();
        self.plugins
            .insert(path.to_string(), load_native_plugin(path)?);
        Ok(())
    }

    pub fn reload_plugin(&mut self, path: &str) -> Result<(), String> {
        self.reap_retired_plugins();
        if self
            .retired_plugins
            .iter()
            .any(|plugin| plugin.path == path)
        {
            self.native_reload_rejected_count += 1;
            self.auditor.log(AuditEvent::FailureObserved {
                tick_id: 0,
                component: "NativePluginReload".to_string(),
                error: format!(
                    "native plugin reload rejected: prior generation is still retiring for {path}"
                ),
            });
            return Err(format!(
                "native plugin reload rejected: prior generation is still retiring for {path}"
            ));
        }
        if let Some(mut plugin) = self.plugins.remove(path) {
            plugin.worker.shutdown();
            plugin.worker.retire();
            plugin.retired_at = Some(Instant::now());
            self.retired_plugins.push(plugin);
        }
        self.load_plugin(path) // 接入新器官
    }

    pub fn trigger_all(&mut self, tick_id: u64, payload: &str) {
        self.reap_retired_plugins();
        if self.plugins.is_empty() && self.wasm_plugins.is_empty() {
            println!("[突触传导] 🫀 脉冲跳动... 但暂无器官接入。");
            return;
        }

        let act_dispatcher = self.act_dispatcher.clone();
        let auditor = self.auditor.clone();
        let allow_plan_draft = self.plan_runtime.allows_plan_draft();
        let mut allow_action_dispatch = self.plan_runtime.allows_action_dispatch();
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
                    allow_action_dispatch = false;
                }
                BrainDispatch::None => {}
            }
        }

        for plugin in self.wasm_plugins.values() {
            trigger_loaded_wasm_plugin(plugin, tick_id, payload, &auditor);
        }

        if let Some(action_id) = dispatched_plan_action {
            self.plan_runtime.bind_action(action_id);
        }
        if let Some(plan) = drafted_plan {
            self.plan_runtime
                .activate_plan(tick_id, plan, &self.auditor);
        }
    }

    pub fn verify_pending_outcomes(
        &mut self,
        tick_id: u64,
        payload: &str,
    ) -> Option<serde_json::Value> {
        let mut latest_failure = None;
        for pending in self.act_dispatcher.take_pending_for_verification(tick_id) {
            let (result, mut evidence) =
                verify_pending_action(&pending.action_id, &pending.action, payload);
            attach_delivery_evidence(&mut evidence, &pending);
            println!(
                "[Verifier] 🔎 action={} dispatched_tick={} result={:?}",
                pending.action_id, pending.queued_tick_id, result
            );
            if let Some(outcome) = failed_outcome_payload(tick_id, &pending, &result, &evidence) {
                latest_failure = Some(outcome);
            }
            if self.plan_runtime.action_matches_step(&pending.action_id) {
                self.plan_runtime
                    .apply_verification(tick_id, &result, &self.auditor);
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
        self.plan_runtime.active_step_payload()
    }

    fn reap_retired_plugins(&mut self) {
        self.retired_plugins
            .retain_mut(|plugin| !plugin.worker.try_reap());
    }
}

fn attach_delivery_evidence(evidence: &mut serde_json::Value, pending: &crate::act::PendingAction) {
    let delivery = serde_json::json!({
        "status": pending.delivery_status(),
        "queued_tick_id": pending.queued_tick_id,
        "dispatched_at_ms": pending.dispatched_at_ms,
    });
    match evidence {
        serde_json::Value::Object(object) => {
            object.insert("delivery".to_string(), delivery);
        }
        _ => {
            *evidence = serde_json::json!({
                "verifier_evidence": evidence,
                "delivery": delivery,
            });
        }
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

#[cfg(test)]
mod tests {
    use super::{GenesisKernel, unwrap_brain_decision};
    use crate::audit::AuditLogger;
    use serde_json::json;
    use std::fs;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

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

    #[test]
    fn kernel_loads_and_triggers_wasm_plugin() {
        let wasm_path = write_wasm_fixture();
        let mut kernel = GenesisKernel::new(AuditLogger::new(16));

        kernel
            .load_wasm_plugin(wasm_path.to_str().expect("utf-8 fixture path"))
            .expect("load wasm plugin");
        let health = kernel.health();
        assert_eq!(health.native_plugin_count, 0);
        assert_eq!(health.wasm_plugin_count, 1);
        assert_eq!(health.retired_plugin_count, 0);
        assert!(health.active_plan_id.is_none());
        kernel.trigger_all(42, "core-wasm-payload");
    }

    fn write_wasm_fixture() -> PathBuf {
        let response =
            br#"{"schema_version":1,"status":"ok","error_code":null,"data":{"core":"ok"}}"#;
        let response_len = response.len();
        let response_wat = wat_string(response);
        let wasm = wat::parse_str(format!(
            r#"
            (module
              (memory (export "memory") 1 2)
              (global $heap (mut i32) (i32.const 4096))
              (data (i32.const 2048) "{response_wat}")
              (func (export "genesis_plugin_api_version") (result i32)
                i32.const 1)
              (func (export "genesis_alloc") (param $len i32) (result i32)
                global.get $heap
                global.get $heap
                local.get $len
                i32.add
                global.set $heap)
              (func (export "genesis_dealloc") (param $ptr i32) (param $len i32))
              (func (export "genesis_handle") (param $ptr i32) (param $len i32) (result i64)
                i64.const {packed})
            )
            "#,
            packed = ((2048_u64) << 32) | response_len as u64
        ))
        .expect("valid wat fixture");
        let path = unique_temp_dir().join("core-wasm-fixture.wasm");
        fs::write(&path, wasm).expect("write wasm fixture");
        path
    }

    fn wat_string(bytes: &[u8]) -> String {
        let mut out = String::new();
        for byte in bytes {
            match *byte {
                b'"' => out.push_str("\\\""),
                b'\\' => out.push_str("\\\\"),
                0x20..=0x7e => out.push(*byte as char),
                _ => out.push_str(&format!("\\{:02x}", byte)),
            }
        }
        out
    }

    fn unique_temp_dir() -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "genesis-core-wasm-loader-{}-{nanos}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }
}
