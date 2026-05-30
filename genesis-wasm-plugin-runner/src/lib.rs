use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest as _, Sha256};
use std::fmt;
use wasmtime::{Config, Engine, Instance, Module, Store, StoreLimits, StoreLimitsBuilder, Trap};

pub const GENESIS_WASM_PLUGIN_API_VERSION: u32 = 1;
const WASM_PAGE_BYTES: usize = 64 * 1024;

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
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WasmPluginLimits {
    pub max_input_bytes: usize,
    pub max_output_bytes: usize,
    pub max_fuel: u64,
    pub max_memory_bytes: usize,
}

impl Default for WasmPluginLimits {
    fn default() -> Self {
        Self {
            max_input_bytes: 1024 * 1024,
            max_output_bytes: 1024 * 1024,
            max_fuel: 10_000_000,
            max_memory_bytes: 16 * 1024 * 1024,
        }
    }
}

impl WasmPluginLimits {
    pub fn validate(&self) -> Result<(), PluginError> {
        if self.max_input_bytes == 0 {
            return Err(PluginError::InvalidLimits(
                "max_input_bytes must be > 0".to_string(),
            ));
        }
        if self.max_output_bytes == 0 {
            return Err(PluginError::InvalidLimits(
                "max_output_bytes must be > 0".to_string(),
            ));
        }
        if self.max_fuel == 0 {
            return Err(PluginError::InvalidLimits(
                "max_fuel must be > 0".to_string(),
            ));
        }
        if self.max_memory_bytes < WASM_PAGE_BYTES {
            return Err(PluginError::InvalidLimits(format!(
                "max_memory_bytes must be at least one wasm page ({WASM_PAGE_BYTES})"
            )));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FatalPluginCrashAudit {
    pub plugin_id: String,
    pub plugin_hash: String,
    pub request_id: String,
    pub trap_kind: String,
    pub trap_message: String,
    pub fuel_consumed: Option<u64>,
    pub fuel_remaining: Option<u64>,
    pub input_hash: String,
    pub wasm_memory_limit: usize,
    pub phase: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PluginError {
    InvalidLimits(String),
    InputTooLarge {
        len: usize,
        max: usize,
    },
    OutputTooLarge {
        len: usize,
        max: usize,
    },
    MissingExport(&'static str),
    UnsupportedApiVersion {
        expected: u32,
        actual: u32,
    },
    GuestMemoryOutOfBounds {
        ptr: u32,
        len: u32,
        memory_size: usize,
    },
    Serialization(String),
    ModuleLoad(String),
    Instantiation(String),
    FatalPluginCrash(Box<FatalPluginCrashAudit>),
}

impl fmt::Display for PluginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PluginError::InvalidLimits(message) => {
                write!(f, "invalid wasm plugin limits: {message}")
            }
            PluginError::InputTooLarge { len, max } => {
                write!(f, "plugin input too large: {len} > {max}")
            }
            PluginError::OutputTooLarge { len, max } => {
                write!(f, "plugin output too large: {len} > {max}")
            }
            PluginError::MissingExport(name) => write!(f, "missing wasm export: {name}"),
            PluginError::UnsupportedApiVersion { expected, actual } => {
                write!(
                    f,
                    "unsupported plugin api version: expected {expected}, got {actual}"
                )
            }
            PluginError::GuestMemoryOutOfBounds {
                ptr,
                len,
                memory_size,
            } => write!(
                f,
                "guest memory out of bounds: ptr={ptr} len={len} memory_size={memory_size}"
            ),
            PluginError::Serialization(message) => {
                write!(f, "plugin serialization error: {message}")
            }
            PluginError::ModuleLoad(message) => write!(f, "wasm module load failed: {message}"),
            PluginError::Instantiation(message) => {
                write!(f, "wasm plugin instantiation failed: {message}")
            }
            PluginError::FatalPluginCrash(audit) => write!(
                f,
                "fatal wasm plugin crash: plugin={} request={} phase={} kind={} message={}",
                audit.plugin_id, audit.request_id, audit.phase, audit.trap_kind, audit.trap_message
            ),
        }
    }
}

impl std::error::Error for PluginError {}

pub trait WasmPluginTransport {
    fn invoke(&self, request: PluginRequest) -> Result<PluginResponse, PluginError>;
}

#[derive(Clone)]
pub struct LinearMemoryTransport {
    engine: Engine,
    module: Module,
    plugin_id: String,
    plugin_hash: String,
    limits: WasmPluginLimits,
}

struct HostState {
    limits: StoreLimits,
}

impl LinearMemoryTransport {
    pub fn from_bytes(
        plugin_id: impl Into<String>,
        wasm_bytes: &[u8],
        limits: WasmPluginLimits,
    ) -> Result<Self, PluginError> {
        limits.validate()?;

        let mut config = Config::new();
        config.consume_fuel(true);
        let engine = Engine::new(&config).map_err(|error| {
            PluginError::ModuleLoad(format!("failed to create wasmtime engine: {error}"))
        })?;
        let module = Module::new(&engine, wasm_bytes)
            .map_err(|error| PluginError::ModuleLoad(error.to_string()))?;
        let plugin_hash = hex_sha256(wasm_bytes);

        Ok(Self {
            engine,
            module,
            plugin_id: plugin_id.into(),
            plugin_hash,
            limits,
        })
    }

    pub fn plugin_hash(&self) -> &str {
        &self.plugin_hash
    }

    fn new_store(&self) -> Result<Store<HostState>, PluginError> {
        let limits = StoreLimitsBuilder::new()
            .memory_size(self.limits.max_memory_bytes)
            .instances(1)
            .memories(1)
            .tables(1)
            .trap_on_grow_failure(true)
            .build();
        let mut store = Store::new(&self.engine, HostState { limits });
        store.limiter(|state| &mut state.limits);
        store
            .set_fuel(self.limits.max_fuel)
            .map_err(|error| PluginError::Instantiation(error.to_string()))?;
        Ok(store)
    }
}

impl WasmPluginTransport for LinearMemoryTransport {
    fn invoke(&self, request: PluginRequest) -> Result<PluginResponse, PluginError> {
        let request_id = request.request_id.clone();
        let input_hash = request.payload_hash.clone();
        let input = serde_json::to_vec(&request)
            .map_err(|error| PluginError::Serialization(error.to_string()))?;
        if input.len() > self.limits.max_input_bytes {
            return Err(PluginError::InputTooLarge {
                len: input.len(),
                max: self.limits.max_input_bytes,
            });
        }

        let mut store = self.new_store()?;
        let instance = Instance::new(&mut store, &self.module, &[])
            .map_err(|error| PluginError::Instantiation(error.to_string()))?;
        let memory = instance
            .get_memory(&mut store, "memory")
            .ok_or(PluginError::MissingExport("memory"))?;
        let api_version = instance
            .get_typed_func::<(), u32>(&mut store, "genesis_plugin_api_version")
            .map_err(|_| PluginError::MissingExport("genesis_plugin_api_version"))?;
        let alloc = instance
            .get_typed_func::<u32, u32>(&mut store, "genesis_alloc")
            .map_err(|_| PluginError::MissingExport("genesis_alloc"))?;
        let handle = instance
            .get_typed_func::<(u32, u32), u64>(&mut store, "genesis_handle")
            .map_err(|_| PluginError::MissingExport("genesis_handle"))?;
        let dealloc = instance
            .get_typed_func::<(u32, u32), ()>(&mut store, "genesis_dealloc")
            .map_err(|_| PluginError::MissingExport("genesis_dealloc"))?;

        let actual_version = api_version.call(&mut store, ()).map_err(|error| {
            self.fatal_audit("api_version", error, &request_id, &input_hash, &store)
        })?;
        if actual_version != GENESIS_WASM_PLUGIN_API_VERSION {
            return Err(PluginError::UnsupportedApiVersion {
                expected: GENESIS_WASM_PLUGIN_API_VERSION,
                actual: actual_version,
            });
        }

        let input_len = u32::try_from(input.len()).map_err(|_| PluginError::InputTooLarge {
            len: input.len(),
            max: self.limits.max_input_bytes,
        })?;
        let request_ptr = alloc
            .call(&mut store, input_len)
            .map_err(|error| self.fatal_audit("alloc", error, &request_id, &input_hash, &store))?;
        ensure_guest_range(&memory, &store, request_ptr, input_len)?;
        memory
            .write(&mut store, request_ptr as usize, &input)
            .map_err(|_| {
                let memory_size = memory.data_size(&store);
                PluginError::GuestMemoryOutOfBounds {
                    ptr: request_ptr,
                    len: input_len,
                    memory_size,
                }
            })?;

        let packed = match handle.call(&mut store, (request_ptr, input_len)) {
            Ok(value) => value,
            Err(error) => {
                return Err(self.fatal_audit("handle", error, &request_id, &input_hash, &store));
            }
        };

        let (response_ptr, response_len) = unpack_ptr_len(packed);
        let response_len_usize = response_len as usize;
        if response_len_usize > self.limits.max_output_bytes {
            return Err(PluginError::OutputTooLarge {
                len: response_len_usize,
                max: self.limits.max_output_bytes,
            });
        }
        ensure_guest_range(&memory, &store, response_ptr, response_len)?;

        let mut response_bytes = vec![0; response_len_usize];
        memory
            .read(&store, response_ptr as usize, &mut response_bytes)
            .map_err(|_| {
                let memory_size = memory.data_size(&store);
                PluginError::GuestMemoryOutOfBounds {
                    ptr: response_ptr,
                    len: response_len,
                    memory_size,
                }
            })?;

        dealloc
            .call(&mut store, (response_ptr, response_len))
            .map_err(|error| {
                self.fatal_audit("dealloc_response", error, &request_id, &input_hash, &store)
            })?;
        dealloc
            .call(&mut store, (request_ptr, input_len))
            .map_err(|error| {
                self.fatal_audit("dealloc_request", error, &request_id, &input_hash, &store)
            })?;

        let response: PluginResponse = serde_json::from_slice(&response_bytes)
            .map_err(|error| PluginError::Serialization(error.to_string()))?;
        Ok(response)
    }
}

impl LinearMemoryTransport {
    fn fatal_audit(
        &self,
        phase: impl Into<String>,
        error: wasmtime::Error,
        request_id: &str,
        input_hash: &str,
        store: &Store<HostState>,
    ) -> PluginError {
        let fuel_remaining = store.get_fuel().ok();
        let fuel_consumed =
            fuel_remaining.map(|remaining| self.limits.max_fuel.saturating_sub(remaining));
        let trap_kind = classify_trap(&error).to_string();
        let trap_message = error.to_string();
        PluginError::FatalPluginCrash(Box::new(FatalPluginCrashAudit {
            plugin_id: self.plugin_id.clone(),
            plugin_hash: self.plugin_hash.clone(),
            request_id: request_id.to_string(),
            trap_kind,
            trap_message,
            fuel_consumed,
            fuel_remaining,
            input_hash: input_hash.to_string(),
            wasm_memory_limit: self.limits.max_memory_bytes,
            phase: phase.into(),
        }))
    }
}

fn ensure_guest_range(
    memory: &wasmtime::Memory,
    store: &Store<HostState>,
    ptr: u32,
    len: u32,
) -> Result<(), PluginError> {
    let start = ptr as usize;
    let len = len as usize;
    let end = start.checked_add(len).ok_or_else(|| {
        let memory_size = memory.data_size(store);
        PluginError::GuestMemoryOutOfBounds {
            ptr,
            len: len as u32,
            memory_size,
        }
    })?;
    let memory_size = memory.data_size(store);
    if end > memory_size {
        return Err(PluginError::GuestMemoryOutOfBounds {
            ptr,
            len: len as u32,
            memory_size,
        });
    }
    Ok(())
}

fn unpack_ptr_len(value: u64) -> (u32, u32) {
    ((value >> 32) as u32, (value & 0xffff_ffff) as u32)
}

fn stable_json_hash(value: &Value) -> Result<String, PluginError> {
    let bytes =
        serde_json::to_vec(value).map_err(|error| PluginError::Serialization(error.to_string()))?;
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

fn classify_trap(error: &wasmtime::Error) -> &'static str {
    match error.downcast_ref::<Trap>() {
        Some(Trap::OutOfFuel) => "fuel_exhausted",
        Some(Trap::MemoryOutOfBounds) => "memory_out_of_bounds",
        Some(Trap::UnreachableCodeReached) => "trap_unreachable",
        Some(_) => "wasm_trap",
        None => "host_error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> PluginRequest {
        PluginRequest::new(
            "fixture-plugin",
            "request-1",
            serde_json::json!({"event": "ActionQueued"}),
        )
        .unwrap()
    }

    fn wat_string(bytes: &[u8]) -> String {
        let mut out = String::new();
        for byte in bytes {
            match *byte {
                b'"' => out.push_str("\\\""),
                b'\\' => out.push_str("\\\\"),
                0x20..=0x7e => out.push(*byte as char),
                _ => out.push_str(&format!("\\{:02x}", byte)),
            }
        }
        out
    }

    fn response_fixture_wasm(response: &PluginResponse) -> Vec<u8> {
        let response_bytes = serde_json::to_vec(response).unwrap();
        let response_len = response_bytes.len();
        let response_wat = wat_string(&response_bytes);
        wat::parse_str(format!(
            r#"
            (module
              (memory (export "memory") 1 2)
              (global $heap (mut i32) (i32.const 4096))
              (data (i32.const 2048) "{response_wat}")
              (func (export "genesis_plugin_api_version") (result i32)
                i32.const 1)
              (func (export "genesis_alloc") (param $len i32) (result i32)
                global.get $heap
                global.get $heap
                local.get $len
                i32.add
                global.set $heap)
              (func (export "genesis_dealloc") (param $ptr i32) (param $len i32))
              (func (export "genesis_handle") (param $ptr i32) (param $len i32) (result i64)
                i64.const {packed})
            )
            "#,
            packed = ((2048_u64) << 32) | response_len as u64
        ))
        .unwrap()
    }

    fn transport(wasm: Vec<u8>) -> LinearMemoryTransport {
        LinearMemoryTransport::from_bytes(
            "fixture-plugin",
            &wasm,
            WasmPluginLimits {
                max_input_bytes: 4096,
                max_output_bytes: 4096,
                max_fuel: 100_000,
                max_memory_bytes: 128 * 1024,
            },
        )
        .unwrap()
    }

    #[test]
    fn invokes_plugin_through_linear_memory_abi() {
        let expected = PluginResponse::ok(serde_json::json!({"accepted": true}));
        let runner = transport(response_fixture_wasm(&expected));

        let response = runner.invoke(request()).unwrap();

        assert_eq!(response, expected);
        assert_eq!(runner.plugin_hash().len(), 64);
    }

    #[test]
    fn rejects_missing_handle_export() {
        let wasm = wat::parse_str(
            r#"
            (module
              (memory (export "memory") 1)
              (func (export "genesis_plugin_api_version") (result i32) i32.const 1)
              (func (export "genesis_alloc") (param i32) (result i32) i32.const 0)
              (func (export "genesis_dealloc") (param i32) (param i32)))
            "#,
        )
        .unwrap();
        let runner = transport(wasm);

        let error = runner.invoke(request()).unwrap_err();

        assert_eq!(error, PluginError::MissingExport("genesis_handle"));
    }

    #[test]
    fn traps_are_reported_as_fatal_plugin_crashes() {
        let wasm = wat::parse_str(
            r#"
            (module
              (memory (export "memory") 1)
              (func (export "genesis_plugin_api_version") (result i32) i32.const 1)
              (func (export "genesis_alloc") (param i32) (result i32) i32.const 1024)
              (func (export "genesis_dealloc") (param i32) (param i32))
              (func (export "genesis_handle") (param i32) (param i32) (result i64)
                unreachable))
            "#,
        )
        .unwrap();
        let runner = transport(wasm);

        let error = runner.invoke(request()).unwrap_err();

        match error {
            PluginError::FatalPluginCrash(audit) => {
                assert_eq!(audit.plugin_id, "fixture-plugin");
                assert_eq!(audit.request_id, "request-1");
                assert_eq!(audit.phase, "handle");
                assert_eq!(audit.trap_kind, "trap_unreachable");
                assert_eq!(audit.plugin_hash.len(), 64);
            }
            other => panic!("expected fatal crash, got {other:?}"),
        }
    }

    #[test]
    fn fuel_exhaustion_is_fatal_plugin_crash() {
        let wasm = wat::parse_str(
            r#"
            (module
              (memory (export "memory") 1)
              (func (export "genesis_plugin_api_version") (result i32) i32.const 1)
              (func (export "genesis_alloc") (param i32) (result i32) i32.const 1024)
              (func (export "genesis_dealloc") (param i32) (param i32))
              (func (export "genesis_handle") (param i32) (param i32) (result i64)
                (loop br 0)
                i64.const 0))
            "#,
        )
        .unwrap();
        let runner = LinearMemoryTransport::from_bytes(
            "fixture-plugin",
            &wasm,
            WasmPluginLimits {
                max_input_bytes: 4096,
                max_output_bytes: 4096,
                max_fuel: 10,
                max_memory_bytes: 128 * 1024,
            },
        )
        .unwrap();

        let error = runner.invoke(request()).unwrap_err();

        match error {
            PluginError::FatalPluginCrash(audit) => {
                assert_eq!(audit.trap_kind, "fuel_exhausted");
                assert_eq!(audit.fuel_remaining, Some(0));
                assert_eq!(audit.fuel_consumed, Some(10));
            }
            other => panic!("expected fatal crash, got {other:?}"),
        }
    }

    #[test]
    fn oversized_response_is_rejected_before_read() {
        let wasm = wat::parse_str(
            r#"
            (module
              (memory (export "memory") 1)
              (func (export "genesis_plugin_api_version") (result i32) i32.const 1)
              (func (export "genesis_alloc") (param i32) (result i32) i32.const 1024)
              (func (export "genesis_dealloc") (param i32) (param i32))
              (func (export "genesis_handle") (param i32) (param i32) (result i64)
                i64.const 8796093087744))
            "#,
        )
        .unwrap();
        let runner = LinearMemoryTransport::from_bytes(
            "fixture-plugin",
            &wasm,
            WasmPluginLimits {
                max_input_bytes: 4096,
                max_output_bytes: 32,
                max_fuel: 100_000,
                max_memory_bytes: 128 * 1024,
            },
        )
        .unwrap();

        let error = runner.invoke(request()).unwrap_err();

        assert_eq!(
            error,
            PluginError::OutputTooLarge {
                len: 65_536,
                max: 32
            }
        );
    }

    #[test]
    fn guest_memory_bounds_are_checked() {
        let wasm = wat::parse_str(
            r#"
            (module
              (memory (export "memory") 1)
              (func (export "genesis_plugin_api_version") (result i32) i32.const 1)
              (func (export "genesis_alloc") (param i32) (result i32) i32.const 1024)
              (func (export "genesis_dealloc") (param i32) (param i32))
              (func (export "genesis_handle") (param i32) (param i32) (result i64)
                i64.const 281474976710657))
            "#,
        )
        .unwrap();
        let runner = transport(wasm);

        let error = runner.invoke(request()).unwrap_err();

        match error {
            PluginError::GuestMemoryOutOfBounds {
                ptr,
                len,
                memory_size,
            } => {
                assert_eq!(ptr, 65_536);
                assert_eq!(len, 1);
                assert_eq!(memory_size, 65_536);
            }
            other => panic!("expected bounds error, got {other:?}"),
        }
    }
}
