use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use wasmtime::{Config, Engine, Instance, Module, Store, Val};

use crate::{WasmArtifact, WasmExecutionReport, payload_args, stable_hash};

#[derive(Clone)]
pub struct WasmArtifactExecutor {
    engine: Engine,
    precompiled_cache_dir: Option<PathBuf>,
    modules: Arc<Mutex<BTreeMap<PathBuf, Module>>>,
}

impl WasmArtifactExecutor {
    pub fn new() -> Result<Self, String> {
        Self::build(None)
    }

    pub fn new_with_precompiled_cache_dir(cache_dir: impl Into<PathBuf>) -> Result<Self, String> {
        Self::build(Some(cache_dir.into()))
    }

    fn build(precompiled_cache_dir: Option<PathBuf>) -> Result<Self, String> {
        let mut engine_config = Config::new();
        engine_config.consume_fuel(true);
        let engine = Engine::new(&engine_config).map_err(|error| error.to_string())?;
        Ok(Self {
            engine,
            precompiled_cache_dir,
            modules: Arc::new(Mutex::new(BTreeMap::new())),
        })
    }

    pub fn execute(
        &self,
        artifact: &WasmArtifact,
        payload: &Value,
        fuel: u64,
    ) -> Result<WasmExecutionReport, String> {
        if fuel == 0 {
            return Err("wasm fuel must be > 0".to_string());
        }
        let args = payload_args(payload, &artifact.input_order)?;
        let input_hash = stable_hash(payload)?;
        let module = self.module_for(artifact)?;
        execute_wasm_module(&self.engine, &module, artifact, args, input_hash, fuel)
    }

    pub fn execute_as_json(
        &self,
        artifact: &WasmArtifact,
        payload: &Value,
        fuel: u64,
    ) -> Result<Value, String> {
        let report = self.execute(artifact, payload, fuel)?;
        if report.trapped {
            return Err(format!(
                "wasm artifact trapped: {}",
                report.error.unwrap_or_else(|| "unknown trap".to_string())
            ));
        }
        let value = report
            .value
            .ok_or_else(|| "wasm artifact produced no i64 value".to_string())?;
        Ok(serde_json::json!({ "value": value }))
    }

    pub fn cached_module_count(&self) -> Result<usize, String> {
        self.modules
            .lock()
            .map(|modules| modules.len())
            .map_err(|_| "wasm module cache lock poisoned".to_string())
    }

    pub fn precompiled_module_path(&self, artifact: &WasmArtifact) -> Option<PathBuf> {
        self.precompiled_cache_dir
            .as_ref()
            .map(|dir| dir.join(format!("{}.cwasm", artifact.source_hash)))
    }

    fn module_for(&self, artifact: &WasmArtifact) -> Result<Module, String> {
        let cache_key = self
            .precompiled_module_path(artifact)
            .unwrap_or_else(|| artifact.wasm_path.clone());
        let mut modules = self
            .modules
            .lock()
            .map_err(|_| "wasm module cache lock poisoned".to_string())?;
        if let Some(module) = modules.get(&cache_key) {
            return Ok(module.clone());
        }
        let module = match self.precompiled_module_path(artifact) {
            Some(precompiled_path) if precompiled_path.is_file() => {
                // Wasmtime requires the same engine configuration for deserialize as serialize.
                unsafe { Module::deserialize_file(&self.engine, &precompiled_path) }
                    .map_err(|error| error.to_string())?
            }
            Some(precompiled_path) => {
                if let Some(parent) = precompiled_path.parent() {
                    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
                }
                let module = Module::from_file(&self.engine, &artifact.wasm_path)
                    .map_err(|error| error.to_string())?;
                let serialized = module.serialize().map_err(|error| error.to_string())?;
                fs::write(&precompiled_path, serialized).map_err(|error| error.to_string())?;
                module
            }
            None => Module::from_file(&self.engine, &artifact.wasm_path)
                .map_err(|error| error.to_string())?,
        };
        modules.insert(cache_key, module.clone());
        Ok(module)
    }
}

pub fn execute_wasm_artifact(
    artifact: &WasmArtifact,
    payload: &Value,
    fuel: u64,
) -> Result<WasmExecutionReport, String> {
    WasmArtifactExecutor::new()?.execute(artifact, payload, fuel)
}

pub fn execute_wasm_artifact_as_json(
    artifact: &WasmArtifact,
    payload: &Value,
    fuel: u64,
) -> Result<Value, String> {
    WasmArtifactExecutor::new()?.execute_as_json(artifact, payload, fuel)
}

fn execute_wasm_module(
    engine: &Engine,
    module: &Module,
    artifact: &WasmArtifact,
    args: Vec<i64>,
    input_hash: String,
    fuel: u64,
) -> Result<WasmExecutionReport, String> {
    let mut store = Store::new(engine, ());
    store.set_fuel(fuel).map_err(|error| error.to_string())?;
    let instance = Instance::new(&mut store, module, &[]).map_err(|error| error.to_string())?;
    let function = instance
        .get_func(&mut store, &artifact.function_name)
        .ok_or_else(|| format!("wasm export not found: {}", artifact.function_name))?;
    let params = args.into_iter().map(Val::I64).collect::<Vec<_>>();
    let mut results = [Val::I64(0)];
    match function.call(&mut store, &params, &mut results) {
        Ok(()) => match results[0] {
            Val::I64(value) => Ok(WasmExecutionReport {
                wasm_path: artifact.wasm_path.clone(),
                input_hash,
                trapped: false,
                value: Some(value),
                error: None,
            }),
            _ => Err("wasm result was not i64".to_string()),
        },
        Err(error) => Ok(WasmExecutionReport {
            wasm_path: artifact.wasm_path.clone(),
            input_hash,
            trapped: true,
            value: None,
            error: Some(error.to_string()),
        }),
    }
}
