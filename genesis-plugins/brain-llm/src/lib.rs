use genesis_contracts::declare_genesis_plugin;
use genesis_contracts::sdk::{GenesisContext, GenesisPlugin, GenesisResult};
use genesis_contracts::wire::{GENESIS_ERROR_INTERNAL, GENESIS_ERROR_INVALID_INPUT};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::Mutex;

const SOCKET_PATH: &str = "/tmp/genesis_brain.sock";

#[derive(Serialize)]
struct BrainRequest<'a> {
    task_id: String,
    tick_id: u64,
    timestamp_ms: u64,
    payload: &'a str,
}

#[derive(Deserialize)]
struct BrainResponse {
    task_id: String,
    status: String,
    action: String,
}

enum BrainState {
    Idle,
    Pending {
        task_id: String,
        stream: UnixStream,
        read_buf: Vec<u8>,
    },
}

pub struct BrainPlugin {
    state: Mutex<BrainState>,
}

impl BrainPlugin {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(BrainState::Idle),
        }
    }

    fn submit_task(&self, ctx: GenesisContext, payload: &[u8]) -> GenesisResult {
        if payload.is_empty() {
            return GenesisResult::error(
                GENESIS_ERROR_INVALID_INPUT,
                b"Empty brain payload".to_vec(),
            );
        }

        let payload = String::from_utf8_lossy(payload);
        let task_id = format!("brain-{}-{}", ctx.timestamp_ms, ctx.tick_id);
        let request = BrainRequest {
            task_id: task_id.clone(),
            tick_id: ctx.tick_id,
            timestamp_ms: ctx.timestamp_ms,
            payload: &payload,
        };

        let mut frame = match serde_json::to_vec(&request) {
            Ok(frame) => frame,
            Err(err) => {
                return GenesisResult::error(GENESIS_ERROR_INTERNAL, err.to_string().into_bytes());
            }
        };
        frame.push(b'\n');

        let mut stream = match UnixStream::connect(SOCKET_PATH) {
            Ok(stream) => stream,
            Err(err) => {
                return GenesisResult::error(
                    GENESIS_ERROR_INTERNAL,
                    format!("brain daemon unavailable: {}", err).into_bytes(),
                );
            }
        };

        if let Err(err) = stream.write_all(&frame) {
            return GenesisResult::error(
                GENESIS_ERROR_INTERNAL,
                format!("brain task submit failed: {}", err).into_bytes(),
            );
        }

        if let Err(err) = stream.set_nonblocking(true) {
            return GenesisResult::error(
                GENESIS_ERROR_INTERNAL,
                format!("brain nonblocking setup failed: {}", err).into_bytes(),
            );
        }

        let mut state = self.state.lock().expect("brain state mutex poisoned");
        *state = BrainState::Pending {
            task_id,
            stream,
            read_buf: Vec::with_capacity(4096),
        };

        GenesisResult::thinking()
    }

    fn poll_task(&self, payload: &[u8]) -> GenesisResult {
        let mut state = self.state.lock().expect("brain state mutex poisoned");
        let BrainState::Pending {
            task_id,
            stream,
            read_buf,
        } = &mut *state
        else {
            return GenesisResult::thinking();
        };

        let mut chunk = [0u8; 1024];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) => {
                    *state = BrainState::Idle;
                    return GenesisResult::error(
                        GENESIS_ERROR_INTERNAL,
                        b"brain daemon closed before response".to_vec(),
                    );
                }
                Ok(n) => {
                    read_buf.extend_from_slice(&chunk[..n]);
                    if let Some(newline) = read_buf.iter().position(|byte| *byte == b'\n') {
                        let frame = read_buf[..newline].to_vec();
                        let response = match serde_json::from_slice::<BrainResponse>(&frame) {
                            Ok(response) => response,
                            Err(err) => {
                                *state = BrainState::Idle;
                                return GenesisResult::error(
                                    GENESIS_ERROR_INTERNAL,
                                    format!("invalid brain response: {}", err).into_bytes(),
                                );
                            }
                        };

                        let expected_task_id = task_id.clone();
                        *state = BrainState::Idle;
                        if response.task_id != expected_task_id {
                            return GenesisResult::error(
                                GENESIS_ERROR_INTERNAL,
                                b"brain response task mismatch".to_vec(),
                            );
                        }

                        if response.status != "ok" {
                            return GenesisResult::error(
                                GENESIS_ERROR_INTERNAL,
                                response.action.into_bytes(),
                            );
                        }

                        let action = resolve_cerebellum_action_data(&response.action, payload);
                        return GenesisResult::ok(action.into_bytes());
                    }
                }
                Err(err) if err.kind() == ErrorKind::WouldBlock => {
                    return GenesisResult::thinking();
                }
                Err(err) => {
                    *state = BrainState::Idle;
                    return GenesisResult::error(
                        GENESIS_ERROR_INTERNAL,
                        format!("brain poll failed: {}", err).into_bytes(),
                    );
                }
            }
        }
    }
}

impl GenesisPlugin for BrainPlugin {
    fn name(&self) -> &'static str {
        "brain-llm"
    }

    fn on_event(&self, ctx: GenesisContext, payload: &[u8]) -> GenesisResult {
        let is_idle = matches!(
            *self.state.lock().expect("brain state mutex poisoned"),
            BrainState::Idle
        );
        if is_idle {
            self.submit_task(ctx, payload)
        } else {
            self.poll_task(payload)
        }
    }

    fn shutdown(&self) {
        if let Ok(mut state) = self.state.lock() {
            *state = BrainState::Idle;
        }
    }
}

fn resolve_cerebellum_action_data(action_data: &str, payload: &[u8]) -> String {
    let Ok(mut value) = serde_json::from_str::<Value>(action_data) else {
        return action_data.to_string();
    };
    let payload = serde_json::from_slice::<Value>(payload).unwrap_or(Value::Null);

    if let Some(action) = value.get_mut("action") {
        let resolved = resolve_cerebellum_action_value(action.take(), &payload);
        *action = resolved;
        return serde_json::to_string(&value).unwrap_or_else(|_| action_data.to_string());
    }

    let resolved = resolve_cerebellum_action_value(value, &payload);
    serde_json::to_string(&resolved).unwrap_or_else(|_| action_data.to_string())
}

fn resolve_cerebellum_action_value(action: Value, payload: &Value) -> Value {
    if action.get("act").and_then(Value::as_str) != Some("aim_dynamic") {
        return action;
    }

    let tick = action.get("tick").and_then(Value::as_u64).unwrap_or(0);
    let Some(target_id) = action.get("target_id").and_then(Value::as_str) else {
        return noop(tick, "cerebellum missing target_id");
    };

    let Some(dynamic_state) = payload.get("dynamic_state") else {
        return noop(tick, "cerebellum missing dynamic_state");
    };
    let Some(targets) = dynamic_state.get("targets").and_then(Value::as_array) else {
        return noop(tick, "cerebellum missing dynamic targets");
    };

    let Some(target) = targets
        .iter()
        .find(|item| item.get("id").and_then(Value::as_str) == Some(target_id))
    else {
        return noop(tick, "cerebellum target_id not present in current frame");
    };

    let Some(x) = target.get("x").and_then(Value::as_f64) else {
        return noop(tick, "cerebellum target missing x");
    };
    let Some(y) = target.get("y").and_then(Value::as_f64) else {
        return noop(tick, "cerebellum target missing y");
    };
    let Some(w) = target.get("w").and_then(Value::as_f64) else {
        return noop(tick, "cerebellum target missing w");
    };
    let Some(h) = target.get("h").and_then(Value::as_f64) else {
        return noop(tick, "cerebellum target missing h");
    };
    let frame_id = dynamic_state
        .get("frame_id")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let reason = action
        .get("reason")
        .and_then(Value::as_str)
        .unwrap_or("aim_dynamic");

    json!({
        "tick": tick,
        "act": "click_point",
        "target_id": target_id,
        "x": x + w / 2.0,
        "y": y + h / 2.0,
        "frame_id": frame_id,
        "reason": format!("cerebellum shooter resolved: {}", truncate(reason, 200)),
    })
}

fn noop(tick: u64, reason: &str) -> Value {
    json!({
        "tick": tick,
        "act": "noop",
        "reason": reason,
    })
}

fn truncate(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

declare_genesis_plugin!(BrainPlugin, BrainPlugin::new);

#[cfg(test)]
mod tests {
    use super::resolve_cerebellum_action_data;
    use serde_json::Value;

    #[test]
    fn resolves_aim_dynamic_against_current_payload_frame() {
        let action = r#"{"tick":7,"act":"aim_dynamic","target_id":"heal","reason":"shoot"}"#;
        let payload = br#"{"dynamic_state":{"frame_id":99,"targets":[{"id":"heal","x":10.0,"y":20.0,"w":30.0,"h":10.0}]}}"#;

        let resolved = resolve_cerebellum_action_data(action, payload);
        let value: Value = serde_json::from_str(&resolved).expect("resolved action");

        assert_eq!(value["act"], "click_point");
        assert_eq!(value["target_id"], "heal");
        assert_eq!(value["frame_id"], 99);
        assert_eq!(value["x"], 25.0);
        assert_eq!(value["y"], 25.0);
    }

    #[test]
    fn preserves_advisory_packet_while_resolving_action() {
        let action = r#"{"action":{"tick":7,"act":"aim_dynamic","target_id":"heal","reason":"shoot"},"advisory_meta":{"scope":"active_step_target","sample_count":2,"hash":"0123456789abcdef"}}"#;
        let payload = br#"{"dynamic_state":{"frame_id":11,"targets":[{"id":"heal","x":1.0,"y":2.0,"w":6.0,"h":8.0}]}}"#;

        let resolved = resolve_cerebellum_action_data(action, payload);
        let value: Value = serde_json::from_str(&resolved).expect("resolved packet");

        assert_eq!(value["action"]["act"], "click_point");
        assert_eq!(value["action"]["x"], 4.0);
        assert_eq!(value["action"]["y"], 6.0);
        assert_eq!(value["advisory_meta"]["hash"], "0123456789abcdef");
    }
}
