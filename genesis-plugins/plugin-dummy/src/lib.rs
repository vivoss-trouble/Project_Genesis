use genesis_contracts::declare_genesis_plugin;
use genesis_contracts::sdk::{GenesisContext, GenesisPlugin, GenesisResult};
use genesis_contracts::wire::GENESIS_ERROR_INVALID_INPUT;

pub struct DummyPlugin;

impl DummyPlugin {
    pub fn new() -> Self {
        Self
    }
}

impl Default for DummyPlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl GenesisPlugin for DummyPlugin {
    fn name(&self) -> &'static str {
        "shield-gateway"
    }

    fn on_event(&self, ctx: GenesisContext, payload: &[u8]) -> GenesisResult {
        if payload.is_empty() {
            return GenesisResult::error(GENESIS_ERROR_INVALID_INPUT, b"Empty payload".to_vec());
        }

        let input = String::from_utf8_lossy(payload);
        println!(
            "🤖 [Shield插件 ABI v1] 清洗 Tick {} 的神经脉冲: {}",
            ctx.tick_id, input
        );

        if input.contains("KILL") {
            panic!("malicious payload triggered panic");
        }

        GenesisResult::ok(
            format!("Shield cleaned [{}] at Tick: {}", input, ctx.tick_id).into_bytes(),
        )
    }
}

declare_genesis_plugin!(DummyPlugin, DummyPlugin::new);
