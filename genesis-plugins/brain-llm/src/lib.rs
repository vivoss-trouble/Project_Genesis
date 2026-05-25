use genesis_contracts::declare_genesis_plugin;
use genesis_contracts::sdk::{GenesisContext, GenesisPlugin, GenesisResult};
use genesis_contracts::wire::{GENESIS_ERROR_INTERNAL, GENESIS_ERROR_INVALID_INPUT};
use serde::{Deserialize, Serialize};
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

    fn poll_task(&self) -> GenesisResult {
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

                        return GenesisResult::ok(response.action.into_bytes());
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
            self.poll_task()
        }
    }

    fn shutdown(&self) {
        if let Ok(mut state) = self.state.lock() {
            *state = BrainState::Idle;
        }
    }
}

declare_genesis_plugin!(BrainPlugin, BrainPlugin::new);
