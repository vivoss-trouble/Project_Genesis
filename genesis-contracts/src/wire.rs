// genesis-contracts/src/wire.rs
// =====================================================================
// Genesis ABI v1: the hard C boundary between core and dylib plugins.
// =====================================================================

pub const GENESIS_ABI_VERSION: u32 = 1;

pub const GENESIS_STATUS_OK: u32 = 0;
pub const GENESIS_STATUS_THINKING: u32 = 1;
pub const GENESIS_STATUS_REJECTED: u32 = 2;
pub const GENESIS_STATUS_ERROR: u32 = 3;
pub const GENESIS_STATUS_TIMEOUT: u32 = 4;
pub const GENESIS_STATUS_TAINTED: u32 = 5;

pub const GENESIS_ERROR_NONE: u32 = 0;
pub const GENESIS_ERROR_PANIC: u32 = 1;
pub const GENESIS_ERROR_INVALID_INPUT: u32 = 2;
pub const GENESIS_ERROR_RESPONSE_TOO_LARGE: u32 = 3;
pub const GENESIS_ERROR_UNSUPPORTED_ABI: u32 = 4;
pub const GENESIS_ERROR_INTERNAL: u32 = 5;

#[repr(C)]
#[derive(Copy, Clone, Debug)]
pub struct GenesisSlice {
    pub ptr: *const u8,
    pub len: usize,
}

impl GenesisSlice {
    pub fn empty() -> Self {
        Self {
            ptr: std::ptr::null(),
            len: 0,
        }
    }

    pub fn from_slice(slice: &[u8]) -> Self {
        Self {
            ptr: slice.as_ptr(),
            len: slice.len(),
        }
    }
}

// The ABI only uses slices as borrowed views. The core must keep the owner
// alive while another thread can observe the pointer.
unsafe impl Send for GenesisSlice {}
unsafe impl Sync for GenesisSlice {}

#[repr(C)]
#[derive(Debug)]
pub struct GenesisBuffer {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}

impl GenesisBuffer {
    pub fn empty() -> Self {
        Self {
            ptr: std::ptr::null_mut(),
            len: 0,
            cap: 0,
        }
    }
}

// Response buffers transfer ownership across the ABI and may cross the core's
// worker channel before being released by the plugin that allocated them.
unsafe impl Send for GenesisBuffer {}

#[repr(C)]
#[derive(Copy, Clone, Debug)]
pub struct GenesisPayload {
    pub abi_version: u32,
    pub tick_id: u64,
    pub timestamp_ms: u64,
    pub kind: u32,
    pub data: GenesisSlice,
}

#[repr(C)]
#[derive(Debug)]
pub struct GenesisResponse {
    pub status: u32,
    pub error_code: u32,
    pub data: GenesisBuffer,
}

impl GenesisResponse {
    pub fn empty(status: u32, error_code: u32) -> Self {
        Self {
            status,
            error_code,
            data: GenesisBuffer::empty(),
        }
    }
}

unsafe impl Send for GenesisResponse {}

pub type OnEventFn = extern "C" fn(payload: GenesisPayload) -> GenesisResponse;
pub type FreeResponseFn = extern "C" fn(response: GenesisResponse);
pub type ShutdownFn = extern "C" fn();

#[repr(C)]
#[derive(Copy, Clone)]
pub struct GenesisPluginApi {
    pub abi_version: u32,
    pub plugin_id: GenesisSlice,
    pub on_event: OnEventFn,
    pub free_response: FreeResponseFn,
    pub shutdown: ShutdownFn,
}
