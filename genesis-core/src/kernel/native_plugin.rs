use genesis_contracts::wire::{
    GENESIS_ABI_VERSION, GENESIS_STATUS_ERROR, GENESIS_STATUS_OK, GENESIS_STATUS_REJECTED,
    GENESIS_STATUS_TAINTED, GENESIS_STATUS_THINKING, GENESIS_STATUS_TIMEOUT, GenesisPluginApi,
    GenesisResponse, GenesisSlice,
};
use libloading::{Library, Symbol};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use crate::act::ActDispatcher;
use crate::audit::{AuditEvent, AuditLogger};
use crate::watchdog::PluginWorker;

use super::plugin_common::{fnv1a64, preview};
use super::{BrainDispatch, PLUGIN_CALL_TIMEOUT, dispatch_brain_action};

pub(super) struct LoadedPlugin {
    pub(super) path: String,
    pub(super) name: String,
    pub(super) worker: PluginWorker,
    pub(super) _lib: Library,
    pub(super) retired_at: Option<Instant>,
}

pub(super) fn load_native_plugin(path: &str) -> Result<LoadedPlugin, String> {
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

        Ok(LoadedPlugin {
            path: path.to_string(),
            name,
            worker: PluginWorker::new(api),
            _lib: lib,
            retired_at: None,
        })
    }
}

pub(super) fn trigger_loaded_plugin(
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
