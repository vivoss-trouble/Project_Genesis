use genesis_contracts::wire::{
    GENESIS_ABI_VERSION, GENESIS_ERROR_NONE, GENESIS_STATUS_ERROR, GENESIS_STATUS_TAINTED,
    GenesisPayload, GenesisPluginApi, GenesisResponse, GenesisSlice,
};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, sync_channel};
use std::thread::{self, JoinHandle};
use std::time::Duration;

struct WorkerRequest {
    tick_id: u64,
    timestamp_ms: u64,
    kind: u32,
    data: Vec<u8>,
}

pub struct PluginWorker {
    sender: Option<SyncSender<WorkerRequest>>,
    receiver: Option<Receiver<GenesisResponse>>,
    api: GenesisPluginApi,
    handle: Option<JoinHandle<()>>,
    shutdown_handle: Option<JoinHandle<()>>,
    pub is_tainted: bool,
}

impl PluginWorker {
    pub fn new(api: GenesisPluginApi) -> Self {
        let (tx_in, rx_in) = sync_channel::<WorkerRequest>(1);
        let (tx_out, rx_out) = sync_channel::<GenesisResponse>(1);
        let api_clone = api;

        let handle = thread::spawn(move || {
            while let Ok(request) = rx_in.recv() {
                let payload = GenesisPayload {
                    abi_version: GENESIS_ABI_VERSION,
                    tick_id: request.tick_id,
                    timestamp_ms: request.timestamp_ms,
                    kind: request.kind,
                    data: GenesisSlice::from_slice(&request.data),
                };

                // FFI panic 被捕获：不会 unwind stack，而是返回 fallback response
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    (api_clone.on_event)(payload)
                }));

                match result {
                    Ok(response) => match tx_out.try_send(response) {
                        Ok(()) => {}
                        Err(std::sync::mpsc::TrySendError::Full(resp))
                        | Err(std::sync::mpsc::TrySendError::Disconnected(resp)) => {
                            eprintln!("[Watchdog] recv_timeout lost, freeing response buffer");
                            (api_clone.free_response)(resp);
                        }
                    },
                    Err(panic_payload) => {
                        eprintln!("[Watchdog] Plugin panic captured: {:?}", panic_payload);
                        // 构造 fallback response 并尝试发送
                        let err_resp =
                            GenesisResponse::empty(GENESIS_STATUS_ERROR, GENESIS_ERROR_NONE);
                        match tx_out.try_send(err_resp) {
                            Ok(()) => {}
                            Err(std::sync::mpsc::TrySendError::Full(resp))
                            | Err(std::sync::mpsc::TrySendError::Disconnected(resp)) => {
                                (api_clone.free_response)(resp);
                            }
                        }
                    }
                }
            }
        });

        Self {
            sender: Some(tx_in),
            receiver: Some(rx_out),
            api,
            handle: Some(handle),
            shutdown_handle: None,
            is_tainted: false,
        }
    }

    pub fn dispatch(
        &mut self,
        tick_id: u64,
        timestamp_ms: u64,
        kind: u32,
        data: &[u8],
        timeout: Duration,
    ) -> GenesisResponse {
        if self.is_tainted {
            return tainted_response();
        }

        let request = WorkerRequest {
            tick_id,
            timestamp_ms,
            kind,
            data: data.to_vec(),
        };

        let Some(sender) = &self.sender else {
            self.taint();
            return tainted_response();
        };

        if sender.send(request).is_err() {
            self.taint();
            return tainted_response();
        }

        let Some(receiver) = &self.receiver else {
            self.taint();
            return tainted_response();
        };

        match receiver.recv_timeout(timeout) {
            Ok(response) => response,
            Err(RecvTimeoutError::Timeout) | Err(RecvTimeoutError::Disconnected) => {
                self.taint();
                tainted_response()
            }
        }
    }

    pub fn free_response(&self, response: GenesisResponse) {
        if response.status != GENESIS_STATUS_TAINTED {
            (self.api.free_response)(response);
        }
    }

    pub fn shutdown(&mut self) {
        if self.shutdown_handle.is_some() {
            return;
        }
        let shutdown = self.api.shutdown;
        match thread::Builder::new()
            .name("Genesis-Plugin-Shutdown".to_string())
            .spawn(move || (shutdown)())
        {
            Ok(handle) => {
                self.shutdown_handle = Some(handle);
            }
            Err(error) => {
                eprintln!("[Watchdog] plugin shutdown thread spawn failed: {error}");
            }
        }
    }

    pub fn retire(&mut self) {
        self.taint();
    }

    pub fn try_reap(&mut self) -> bool {
        if let Some(handle) = self.shutdown_handle.as_ref()
            && !handle.is_finished()
        {
            return false;
        }
        if let Some(handle) = self.shutdown_handle.take() {
            let _ = handle.join();
        }

        let Some(handle) = self.handle.as_ref() else {
            return true;
        };
        if !handle.is_finished() {
            return false;
        }
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
        true
    }

    pub fn is_shutdown_pending(&self) -> bool {
        self.shutdown_handle
            .as_ref()
            .is_some_and(|handle| !handle.is_finished())
    }

    fn taint(&mut self) {
        self.is_tainted = true;
        self.sender.take();
        self.receiver.take();
    }
}

fn tainted_response() -> GenesisResponse {
    GenesisResponse::empty(GENESIS_STATUS_TAINTED, GENESIS_ERROR_NONE)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    extern "C" fn noop_on_event(_: GenesisPayload) -> GenesisResponse {
        GenesisResponse::empty(GENESIS_STATUS_ERROR, GENESIS_ERROR_NONE)
    }

    extern "C" fn noop_free_response(_: GenesisResponse) {}

    extern "C" fn slow_shutdown() {
        std::thread::sleep(Duration::from_millis(500));
    }

    #[test]
    fn shutdown_does_not_block_caller_on_plugin_code() {
        let api = GenesisPluginApi {
            abi_version: GENESIS_ABI_VERSION,
            plugin_id: GenesisSlice::empty(),
            on_event: noop_on_event,
            free_response: noop_free_response,
            shutdown: slow_shutdown,
        };
        let mut worker = PluginWorker::new(api);

        let started = Instant::now();
        worker.shutdown();
        assert!(started.elapsed() < Duration::from_millis(250));

        worker.retire();
        while !worker.try_reap() {
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn shutdown_pending_is_observable_until_reaped() {
        let api = GenesisPluginApi {
            abi_version: GENESIS_ABI_VERSION,
            plugin_id: GenesisSlice::empty(),
            on_event: noop_on_event,
            free_response: noop_free_response,
            shutdown: slow_shutdown,
        };
        let mut worker = PluginWorker::new(api);

        worker.shutdown();
        assert!(worker.is_shutdown_pending());

        worker.retire();
        while !worker.try_reap() {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!worker.is_shutdown_pending());
    }
}
