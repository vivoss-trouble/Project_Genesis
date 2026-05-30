use genesis_contracts::wire::{GENESIS_STATUS_ERROR, GENESIS_STATUS_OK};
use genesis_plugin_sdk::{PluginRequest, PluginStatus};
use genesis_wasm_plugin_runner::{
    LinearMemoryTransport, PluginError as WasmPluginError, WasmPluginLimits, WasmPluginTransport,
};
use std::fs;
use std::time::Instant;

use crate::audit::{AuditEvent, AuditLogger};

use super::plugin_common::{fnv1a64, preview};

pub(super) struct LoadedWasmPlugin {
    pub(super) name: String,
    transport: LinearMemoryTransport,
}

pub(super) fn load_wasm_plugin_from_path(path: &str) -> Result<LoadedWasmPlugin, String> {
    let wasm_bytes = fs::read(path).map_err(|error| error.to_string())?;
    let name = wasm_plugin_name_from_path(path);
    let transport = LinearMemoryTransport::from_bytes(
        name.clone(),
        &wasm_bytes,
        WasmPluginLimits {
            max_input_bytes: 64 * 1024,
            max_output_bytes: 64 * 1024,
            max_fuel: 100_000,
            max_memory_bytes: 2 * 1024 * 1024,
        },
    )
    .map_err(|error| error.to_string())?;
    println!("[微核] 🧊 Wasm 插件 [{}] 已进入沙盒隔离区。", name);
    Ok(LoadedWasmPlugin { name, transport })
}

pub(super) fn trigger_loaded_wasm_plugin(
    plugin: &LoadedWasmPlugin,
    tick_id: u64,
    payload: &str,
    auditor: &AuditLogger,
) {
    let started_at = Instant::now();
    let request = match PluginRequest::new(
        plugin.name.clone(),
        format!("tick-{tick_id}-{}", plugin.name),
        serde_json::json!({
            "tick_id": tick_id,
            "payload": payload,
        }),
    ) {
        Ok(request) => request,
        Err(error) => {
            auditor.log(AuditEvent::FailureObserved {
                tick_id,
                component: plugin.name.clone(),
                error: format!("failed to create wasm plugin request: {error}"),
            });
            return;
        }
    };

    match plugin.transport.invoke(request) {
        Ok(response) => {
            let latency_ms = started_at.elapsed().as_millis() as u64;
            let status_code = match response.status {
                PluginStatus::Ok => GENESIS_STATUS_OK,
                PluginStatus::Error => GENESIS_STATUS_ERROR,
            };
            let error_code = if response.error_code.is_some() { 1 } else { 0 };
            let data_preview = response.data.to_string();
            println!(
                "[突触传导] 🧊 [{}] wasm status={:?} data={}",
                plugin.name, response.status, data_preview
            );
            auditor.log(AuditEvent::PluginResponded {
                tick_id,
                plugin_id: plugin.name.clone(),
                status: status_code,
                error_code,
                latency_ms,
                data_hash: fnv1a64(data_preview.as_bytes()),
                data_preview: preview(&data_preview, 240),
            });
            if matches!(response.status, PluginStatus::Error) {
                auditor.log(AuditEvent::FailureObserved {
                    tick_id,
                    component: plugin.name.clone(),
                    error: format!(
                        "wasm plugin returned error: {}",
                        response
                            .error_code
                            .unwrap_or_else(|| "unknown_error".to_string())
                    ),
                });
            }
        }
        Err(error) => {
            let detail = wasm_plugin_error_detail(&error);
            println!(
                "[突触传导] 🧊 [{}] wasm invocation failed: {}",
                plugin.name, detail
            );
            auditor.log(AuditEvent::FailureObserved {
                tick_id,
                component: plugin.name.clone(),
                error: detail,
            });
        }
    }
}

fn wasm_plugin_name_from_path(path: &str) -> String {
    std::path::Path::new(path)
        .file_stem()
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "wasm-plugin".to_string())
}

fn wasm_plugin_error_detail(error: &WasmPluginError) -> String {
    match error {
        WasmPluginError::FatalPluginCrash(audit) => format!(
            "fatal wasm plugin crash phase={} kind={} request={} message={}",
            audit.phase, audit.trap_kind, audit.request_id, audit.trap_message
        ),
        other => other.to_string(),
    }
}
