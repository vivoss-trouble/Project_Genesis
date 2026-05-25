// genesis-contracts/src/sdk.rs
// =====================================================================
// Genesis Rust SDK: safe plugin ergonomics over the hard C ABI.
// =====================================================================

use crate::wire::*;

pub struct GenesisContext {
    pub tick_id: u64,
    pub timestamp_ms: u64,
    pub kind: u32,
}

pub struct GenesisResult {
    pub status: u32,
    pub error_code: u32,
    pub data: Vec<u8>,
}

impl GenesisResult {
    pub fn ok(data: Vec<u8>) -> Self {
        Self {
            status: GENESIS_STATUS_OK,
            error_code: GENESIS_ERROR_NONE,
            data,
        }
    }

    pub fn thinking() -> Self {
        Self {
            status: GENESIS_STATUS_THINKING,
            error_code: GENESIS_ERROR_NONE,
            data: Vec::new(),
        }
    }

    pub fn rejected(data: Vec<u8>) -> Self {
        Self {
            status: GENESIS_STATUS_REJECTED,
            error_code: GENESIS_ERROR_NONE,
            data,
        }
    }

    pub fn error(error_code: u32, data: Vec<u8>) -> Self {
        Self {
            status: GENESIS_STATUS_ERROR,
            error_code,
            data,
        }
    }
}

pub trait GenesisPlugin: Send + Sync + 'static {
    fn name(&self) -> &'static str;
    fn on_event(&self, ctx: GenesisContext, payload: &[u8]) -> GenesisResult;

    fn shutdown(&self) {}
}

pub fn vec_to_buffer(mut vec: Vec<u8>) -> GenesisBuffer {
    vec.shrink_to_fit();
    let buffer = GenesisBuffer {
        ptr: vec.as_mut_ptr(),
        len: vec.len(),
        cap: vec.capacity(),
    };
    std::mem::forget(vec);
    buffer
}

/// # Safety
///
/// The buffer must have been allocated by this plugin SDK with `vec_to_buffer`.
pub unsafe fn buffer_to_vec(buffer: GenesisBuffer) -> Vec<u8> {
    if buffer.ptr.is_null() || buffer.cap == 0 {
        return Vec::new();
    }

    unsafe { Vec::from_raw_parts(buffer.ptr, buffer.len, buffer.cap) }
}

#[macro_export]
macro_rules! declare_genesis_plugin {
    ($plugin_type:ty, $constructor:expr) => {
        static PLUGIN_INSTANCE: std::sync::OnceLock<$plugin_type> = std::sync::OnceLock::new();

        fn __genesis_plugin_instance() -> &'static $plugin_type {
            PLUGIN_INSTANCE.get_or_init(|| ($constructor)())
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn genesis_plugin_entry() -> $crate::wire::GenesisPluginApi {
            let plugin = __genesis_plugin_instance();
            let plugin_id = <$plugin_type as $crate::sdk::GenesisPlugin>::name(plugin);

            $crate::wire::GenesisPluginApi {
                abi_version: $crate::wire::GENESIS_ABI_VERSION,
                plugin_id: $crate::wire::GenesisSlice::from_slice(plugin_id.as_bytes()),
                on_event: ffi_on_event,
                free_response: ffi_free_response,
                shutdown: ffi_shutdown,
            }
        }

        extern "C" fn ffi_on_event(
            payload: $crate::wire::GenesisPayload,
        ) -> $crate::wire::GenesisResponse {
            if payload.abi_version != $crate::wire::GENESIS_ABI_VERSION {
                return $crate::wire::GenesisResponse {
                    status: $crate::wire::GENESIS_STATUS_ERROR,
                    error_code: $crate::wire::GENESIS_ERROR_UNSUPPORTED_ABI,
                    data: $crate::sdk::vec_to_buffer(b"Unsupported ABI version".to_vec()),
                };
            }

            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let payload_slice = if payload.data.ptr.is_null() || payload.data.len == 0 {
                    &[]
                } else {
                    unsafe { std::slice::from_raw_parts(payload.data.ptr, payload.data.len) }
                };

                let ctx = $crate::sdk::GenesisContext {
                    tick_id: payload.tick_id,
                    timestamp_ms: payload.timestamp_ms,
                    kind: payload.kind,
                };

                <$plugin_type as $crate::sdk::GenesisPlugin>::on_event(
                    __genesis_plugin_instance(),
                    ctx,
                    payload_slice,
                )
            }));

            match result {
                Ok(response) => $crate::wire::GenesisResponse {
                    status: response.status,
                    error_code: response.error_code,
                    data: $crate::sdk::vec_to_buffer(response.data),
                },
                Err(_) => $crate::wire::GenesisResponse {
                    status: $crate::wire::GENESIS_STATUS_ERROR,
                    error_code: $crate::wire::GENESIS_ERROR_PANIC,
                    data: $crate::sdk::vec_to_buffer(b"Plugin panicked".to_vec()),
                },
            }
        }

        extern "C" fn ffi_free_response(response: $crate::wire::GenesisResponse) {
            unsafe {
                let _ = $crate::sdk::buffer_to_vec(response.data);
            }
        }

        extern "C" fn ffi_shutdown() {
            <$plugin_type as $crate::sdk::GenesisPlugin>::shutdown(__genesis_plugin_instance());
        }
    };
}
