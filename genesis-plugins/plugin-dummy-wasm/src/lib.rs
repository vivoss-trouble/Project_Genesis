#![cfg_attr(target_arch = "wasm32", no_std)]

extern crate alloc;

use alloc::format;
use genesis_plugin_sdk::{
    GenesisPlugin, PluginError, PluginRequest, PluginResponse, export_plugin,
};

#[cfg(target_arch = "wasm32")]
#[global_allocator]
static ALLOC: wee_alloc::WeeAlloc = wee_alloc::WeeAlloc::INIT;

#[cfg(target_arch = "wasm32")]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}

pub struct DummyWasmPlugin;

impl GenesisPlugin for DummyWasmPlugin {
    fn handle(req: PluginRequest) -> Result<PluginResponse, PluginError> {
        let tick_id = req
            .payload
            .get("tick_id")
            .and_then(|value| value.as_u64())
            .unwrap_or(0);
        let payload = req
            .payload
            .get("payload")
            .and_then(|value| value.as_str())
            .unwrap_or("");

        if payload.is_empty() {
            return Err(PluginError::new("invalid_input", "Empty payload"));
        }

        if payload.contains("KILL") {
            panic!("malicious payload triggered panic");
        }

        Ok(PluginResponse::ok(serde_json::json!({
            "plugin_id": "shield-gateway",
            "data": format!("Shield cleaned [{payload}] at Tick: {tick_id}")
        })))
    }
}

export_plugin!(DummyWasmPlugin);
