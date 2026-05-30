use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest as _, Sha256};
use std::fmt;

pub const GENESIS_WASM_PLUGIN_API_VERSION: u32 = 1;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PluginRequest {
    pub schema_version: u32,
    pub plugin_id: String,
    pub request_id: String,
    pub payload_hash: String,
    pub payload: Value,
}

impl PluginRequest {
    pub fn new(
        plugin_id: impl Into<String>,
        request_id: impl Into<String>,
        payload: Value,
    ) -> Result<Self, PluginError> {
        let payload_hash = stable_json_hash(&payload)?;
        Ok(Self {
            schema_version: GENESIS_WASM_PLUGIN_API_VERSION,
            plugin_id: plugin_id.into(),
            request_id: request_id.into(),
            payload_hash,
            payload,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PluginStatus {
    Ok,
    Error,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PluginResponse {
    pub schema_version: u32,
    pub status: PluginStatus,
    pub error_code: Option<String>,
    pub data: Value,
}

impl PluginResponse {
    pub fn ok(data: Value) -> Self {
        Self {
            schema_version: GENESIS_WASM_PLUGIN_API_VERSION,
            status: PluginStatus::Ok,
            error_code: None,
            data,
        }
    }

    pub fn error(error: PluginError) -> Self {
        Self {
            schema_version: GENESIS_WASM_PLUGIN_API_VERSION,
            status: PluginStatus::Error,
            error_code: Some(error.code),
            data: serde_json::json!({ "message": error.message }),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PluginError {
    pub code: String,
    pub message: String,
}

impl PluginError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

impl fmt::Display for PluginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for PluginError {}

pub trait GenesisPlugin {
    fn handle(req: PluginRequest) -> Result<PluginResponse, PluginError>;
}

#[macro_export]
macro_rules! export_plugin {
    ($plugin_type:ty) => {
        #[unsafe(no_mangle)]
        pub extern "C" fn genesis_plugin_api_version() -> u32 {
            $crate::GENESIS_WASM_PLUGIN_API_VERSION
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn genesis_alloc(len: u32) -> u32 {
            $crate::__abi::alloc(len)
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn genesis_dealloc(ptr: u32, len: u32) {
            unsafe {
                $crate::__abi::dealloc(ptr, len);
            }
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn genesis_handle(ptr: u32, len: u32) -> u64 {
            unsafe { $crate::__abi::handle::<$plugin_type>(ptr, len) }
        }
    };
}

pub mod __abi {
    use super::{GenesisPlugin, PluginError, PluginRequest, PluginResponse};
    use std::slice;

    pub fn alloc(len: u32) -> u32 {
        if len == 0 {
            return 0;
        }
        let boxed = vec![0_u8; len as usize].into_boxed_slice();
        let ptr = Box::into_raw(boxed) as *mut u8 as usize;
        u32::try_from(ptr).expect("genesis plugin ABI requires wasm32 pointers")
    }

    /// # Safety
    ///
    /// `ptr` and `len` must identify a buffer previously returned by
    /// `genesis_alloc` or by this SDK's response allocation path. After this
    /// call the pointer must not be used again.
    pub unsafe fn dealloc(ptr: u32, len: u32) {
        if ptr == 0 && len == 0 {
            return;
        }
        let slice = std::ptr::slice_from_raw_parts_mut(ptr as usize as *mut u8, len as usize);
        unsafe {
            drop(Box::from_raw(slice));
        }
    }

    /// # Safety
    ///
    /// `ptr` and `len` must identify a valid readable buffer in guest linear
    /// memory for the duration of the call.
    pub unsafe fn handle<P: GenesisPlugin>(ptr: u32, len: u32) -> u64 {
        let input = if ptr == 0 && len == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(ptr as usize as *const u8, len as usize) }
        };
        let output = handle_bytes::<P>(input);
        leak_response(output)
    }

    pub fn handle_bytes<P: GenesisPlugin>(input: &[u8]) -> Vec<u8> {
        let response = match serde_json::from_slice::<PluginRequest>(input) {
            Ok(req) => match P::handle(req) {
                Ok(response) => response,
                Err(error) => PluginResponse::error(error),
            },
            Err(error) => PluginResponse::error(PluginError::new(
                "invalid_request",
                format!("failed to deserialize PluginRequest: {error}"),
            )),
        };
        serialize_response(response)
    }

    fn serialize_response(response: PluginResponse) -> Vec<u8> {
        match serde_json::to_vec(&response) {
            Ok(bytes) => bytes,
            Err(error) => {
                let fallback = PluginResponse::error(PluginError::new(
                    "serialization_error",
                    format!("failed to serialize PluginResponse: {error}"),
                ));
                serde_json::to_vec(&fallback).unwrap_or_else(|_| {
                    br#"{"schema_version":1,"status":"error","error_code":"serialization_error","data":{"message":"failed to serialize PluginResponse"}}"#.to_vec()
                })
            }
        }
    }

    fn leak_response(bytes: Vec<u8>) -> u64 {
        let len = u32::try_from(bytes.len()).expect("PluginResponse exceeds u32 length");
        if len == 0 {
            return 0;
        }
        let boxed = bytes.into_boxed_slice();
        let ptr = Box::into_raw(boxed) as *mut u8 as usize;
        let ptr = u32::try_from(ptr).expect("genesis plugin ABI requires wasm32 pointers");
        ((ptr as u64) << 32) | len as u64
    }
}

fn stable_json_hash(value: &Value) -> Result<String, PluginError> {
    let bytes = serde_json::to_vec(value).map_err(|error| {
        PluginError::new(
            "payload_hash_error",
            format!("failed to serialize payload for hash: {error}"),
        )
    })?;
    Ok(hex_sha256(&bytes))
}

fn hex_sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    struct EchoPlugin;

    impl GenesisPlugin for EchoPlugin {
        fn handle(req: PluginRequest) -> Result<PluginResponse, PluginError> {
            Ok(PluginResponse::ok(serde_json::json!({
                "request_id": req.request_id,
                "payload_hash": req.payload_hash,
            })))
        }
    }

    export_plugin!(EchoPlugin);

    struct FailingPlugin;

    impl GenesisPlugin for FailingPlugin {
        fn handle(_req: PluginRequest) -> Result<PluginResponse, PluginError> {
            Err(PluginError::new("business_rejected", "fixture rejection"))
        }
    }

    #[test]
    fn handle_bytes_invokes_plugin_trait() {
        let req = PluginRequest::new("fixture", "req-1", serde_json::json!({"x": 1})).unwrap();
        let input = serde_json::to_vec(&req).unwrap();

        let output = __abi::handle_bytes::<EchoPlugin>(&input);
        let response: PluginResponse = serde_json::from_slice(&output).unwrap();

        assert_eq!(response.status, PluginStatus::Ok);
        assert_eq!(response.data["request_id"], "req-1");
        assert_eq!(response.data["payload_hash"], req.payload_hash);
    }

    #[test]
    fn business_errors_are_normal_plugin_responses() {
        let req = PluginRequest::new("fixture", "req-2", serde_json::json!({})).unwrap();
        let input = serde_json::to_vec(&req).unwrap();

        let output = __abi::handle_bytes::<FailingPlugin>(&input);
        let response: PluginResponse = serde_json::from_slice(&output).unwrap();

        assert_eq!(response.status, PluginStatus::Error);
        assert_eq!(response.error_code.as_deref(), Some("business_rejected"));
        assert_eq!(response.data["message"], "fixture rejection");
    }

    #[test]
    fn malformed_input_returns_error_response() {
        let output = __abi::handle_bytes::<EchoPlugin>(b"not-json");
        let response: PluginResponse = serde_json::from_slice(&output).unwrap();

        assert_eq!(response.status, PluginStatus::Error);
        assert_eq!(response.error_code.as_deref(), Some("invalid_request"));
    }

    #[test]
    fn export_macro_emits_api_version_function() {
        assert_eq!(
            genesis_plugin_api_version(),
            GENESIS_WASM_PLUGIN_API_VERSION
        );
    }
}
