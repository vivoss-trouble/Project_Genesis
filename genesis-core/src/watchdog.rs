use genesis_contracts::wire::{
    GENESIS_ABI_VERSION, GENESIS_ERROR_NONE, GENESIS_STATUS_TAINTED, GenesisPayload,
    GenesisPluginApi, GenesisResponse, GenesisSlice,
};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, sync_channel};
use std::thread;
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
    pub is_tainted: bool,
}

impl PluginWorker {
    pub fn new(api: GenesisPluginApi) -> Self {
        let (tx_in, rx_in) = sync_channel::<WorkerRequest>(1);
        let (tx_out, rx_out) = sync_channel::<GenesisResponse>(1);
        let api_clone = api;

        thread::spawn(move || {
            while let Ok(request) = rx_in.recv() {
                let payload = GenesisPayload {
                    abi_version: GENESIS_ABI_VERSION,
                    tick_id: request.tick_id,
                    timestamp_ms: request.timestamp_ms,
                    kind: request.kind,
                    data: GenesisSlice::from_slice(&request.data),
                };

                let response = (api_clone.on_event)(payload);

                if let Err(err) = tx_out.send(response) {
                    (api_clone.free_response)(err.0);
                    break;
                }
            }
        });

        Self {
            sender: Some(tx_in),
            receiver: Some(rx_out),
            api,
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

    pub fn shutdown(&self) {
        (self.api.shutdown)();
    }

    pub fn retire(&mut self) {
        self.taint();
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
