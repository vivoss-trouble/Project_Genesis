mod codegen;
mod native_runner;
mod wasm_runner;

use lazarus_contracts::DecisionIr;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest as _, Sha256};
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use codegen::{render_executable_source, render_wasm_source, sorted_inputs, validate_identifier};
pub use native_runner::{
    execute_artifact, execute_artifact_as_json, execute_artifact_as_json_dev_only,
    execute_artifact_with_timeout, execute_artifact_with_timeout_dev_only,
};
pub use wasm_runner::{WasmArtifactExecutor, execute_wasm_artifact, execute_wasm_artifact_as_json};

pub const DEFAULT_ARTIFACT_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone, Debug)]
pub struct ArtifactRunnerConfig {
    pub function_name: String,
    pub rustc_bin: PathBuf,
    pub out_dir: PathBuf,
}

#[derive(Clone, Debug)]
pub struct WasmRunnerConfig {
    pub function_name: String,
    pub rustc_bin: PathBuf,
    pub out_dir: PathBuf,
    pub fuel: u64,
}

impl WasmRunnerConfig {
    pub fn new(function_name: impl Into<String>, out_dir: impl Into<PathBuf>) -> Self {
        Self {
            function_name: function_name.into(),
            rustc_bin: PathBuf::from("rustc"),
            out_dir: out_dir.into(),
            fuel: 10_000,
        }
    }
}

impl ArtifactRunnerConfig {
    pub fn new(function_name: impl Into<String>, out_dir: impl Into<PathBuf>) -> Self {
        Self {
            function_name: function_name.into(),
            rustc_bin: PathBuf::from("rustc"),
            out_dir: out_dir.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutableArtifact {
    pub source_path: PathBuf,
    pub executable_path: PathBuf,
    pub source_hash: String,
    pub input_order: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WasmArtifact {
    pub source_path: PathBuf,
    pub wasm_path: PathBuf,
    pub source_hash: String,
    pub input_order: Vec<String>,
    pub function_name: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtifactExecutionReport {
    pub executable_path: PathBuf,
    pub input_hash: String,
    pub exit_code: Option<i32>,
    pub timed_out: bool,
    pub stdout: String,
    pub stderr: String,
    pub value: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WasmExecutionReport {
    pub wasm_path: PathBuf,
    pub input_hash: String,
    pub trapped: bool,
    pub value: Option<i64>,
    pub error: Option<String>,
}

pub fn compile_executable_artifact(
    ir: &DecisionIr,
    config: &ArtifactRunnerConfig,
) -> Result<ExecutableArtifact, String> {
    native_runner::ensure_native_artifacts_enabled()?;
    compile_executable_artifact_dev_only(ir, config)
}

pub fn compile_executable_artifact_dev_only(
    ir: &DecisionIr,
    config: &ArtifactRunnerConfig,
) -> Result<ExecutableArtifact, String> {
    ir.validate_bounded()?;
    validate_identifier(&config.function_name, "function_name")?;
    fs::create_dir_all(&config.out_dir).map_err(|error| error.to_string())?;
    let input_order = sorted_inputs(ir);
    let source = render_executable_source(ir, &input_order, &config.function_name)?;
    let source_hash = hex_sha256(source.as_bytes());
    let source_path = config
        .out_dir
        .join(format!("{}_artifact_main.rs", config.function_name));
    let executable_path = config
        .out_dir
        .join(format!("{}_artifact_exec", config.function_name));
    fs::write(&source_path, source).map_err(|error| error.to_string())?;

    let output = Command::new(&config.rustc_bin)
        .arg("--edition=2024")
        .arg(&source_path)
        .arg("-o")
        .arg(&executable_path)
        .output()
        .map_err(|error| format!("failed to spawn rustc: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "rustc executable build failed with status {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(ExecutableArtifact {
        source_path,
        executable_path,
        source_hash,
        input_order,
    })
}

pub fn compile_wasm_artifact(
    ir: &DecisionIr,
    config: &WasmRunnerConfig,
) -> Result<WasmArtifact, String> {
    ir.validate_bounded()?;
    validate_identifier(&config.function_name, "function_name")?;
    fs::create_dir_all(&config.out_dir).map_err(|error| error.to_string())?;
    let input_order = sorted_inputs(ir);
    let source = render_wasm_source(ir, &input_order, &config.function_name)?;
    let source_hash = hex_sha256(source.as_bytes());
    let source_path = config
        .out_dir
        .join(format!("{}_artifact_wasm.rs", config.function_name));
    let wasm_path = config
        .out_dir
        .join(format!("{}_artifact.wasm", config.function_name));
    fs::write(&source_path, source).map_err(|error| error.to_string())?;

    let output = Command::new(&config.rustc_bin)
        .arg("--target=wasm32-wasip1")
        .arg("--crate-type=cdylib")
        .arg("--edition=2024")
        .arg(&source_path)
        .arg("-o")
        .arg(&wasm_path)
        .output()
        .map_err(|error| format!("failed to spawn rustc for wasm: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "rustc wasm build failed with status {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(WasmArtifact {
        source_path,
        wasm_path,
        source_hash,
        input_order,
        function_name: config.function_name.clone(),
    })
}

fn payload_args(payload: &Value, input_order: &[String]) -> Result<Vec<i64>, String> {
    let object = payload
        .as_object()
        .ok_or_else(|| "artifact payload must be a JSON object".to_string())?;
    input_order
        .iter()
        .map(|name| {
            object
                .get(name)
                .and_then(Value::as_i64)
                .ok_or_else(|| format!("artifact payload missing i64 input: {name}"))
        })
        .collect()
}

fn stable_hash<T: Serialize>(value: &T) -> Result<String, String> {
    serde_json::to_vec(value)
        .map(|bytes| hex_sha256(&bytes))
        .map_err(|error| error.to_string())
}

fn hex_sha256(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::DecisionExpr;
    use std::collections::BTreeMap;

    #[test]
    fn compiles_and_executes_subprocess_artifact() {
        let root = test_dir("exec");
        let artifact = compile_executable_artifact_dev_only(
            &sample_ir(),
            &ArtifactRunnerConfig::new("compute", &root),
        )
        .unwrap();

        let report = execute_artifact_with_timeout_dev_only(
            &artifact,
            &serde_json::json!({"amount": 7}),
            DEFAULT_ARTIFACT_TIMEOUT,
        )
        .unwrap();

        assert_eq!(report.value, Some(14), "{report:?}");
        assert_eq!(
            execute_artifact_as_json_dev_only(&artifact, &serde_json::json!({"amount": 8}))
                .unwrap(),
            serde_json::json!({"value": 16})
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_missing_payload_input() {
        let root = test_dir("missing");
        let artifact = compile_executable_artifact_dev_only(
            &sample_ir(),
            &ArtifactRunnerConfig::new("compute", &root),
        )
        .unwrap();

        let error = execute_artifact_with_timeout_dev_only(
            &artifact,
            &serde_json::json!({}),
            DEFAULT_ARTIFACT_TIMEOUT,
        )
        .unwrap_err();

        assert!(error.contains("missing i64 input"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn kills_and_reaps_timed_out_artifact() {
        let root = test_dir("timeout");
        let executable_path = root.join("hang.sh");
        fs::write(
            &executable_path,
            "#!/usr/bin/env sh\nwhile true; do sleep 1; done\n",
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = fs::metadata(&executable_path).unwrap().permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&executable_path, permissions).unwrap();
        }
        let artifact = ExecutableArtifact {
            source_path: executable_path.clone(),
            executable_path,
            source_hash: "0".repeat(64),
            input_order: Vec::new(),
        };

        let report = execute_artifact_with_timeout_dev_only(
            &artifact,
            &serde_json::json!({}),
            Duration::from_millis(20),
        )
        .unwrap();

        assert!(report.timed_out);
        assert_eq!(report.value, None);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn native_artifact_public_api_requires_explicit_dev_mode() {
        let root = test_dir("native-disabled");
        let error =
            compile_executable_artifact(&sample_ir(), &ArtifactRunnerConfig::new("compute", &root))
                .unwrap_err();

        assert!(error.contains("disabled by default"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn compiles_and_executes_wasm_artifact_with_fuel() {
        let root = test_dir("wasm");
        let artifact =
            compile_wasm_artifact(&sample_ir(), &WasmRunnerConfig::new("compute", &root)).unwrap();
        let cache_dir = root.join("cwasm-cache");
        let executor = WasmArtifactExecutor::new_with_precompiled_cache_dir(&cache_dir).unwrap();

        let report = executor
            .execute(&artifact, &serde_json::json!({"amount": 9}), 10_000)
            .unwrap();

        assert!(!report.trapped, "{report:?}");
        assert_eq!(report.value, Some(18));
        assert_eq!(
            executor
                .execute_as_json(&artifact, &serde_json::json!({"amount": 10}), 10_000)
                .unwrap(),
            serde_json::json!({"value": 20})
        );
        assert_eq!(executor.cached_module_count().unwrap(), 1);
        let precompiled_path = executor.precompiled_module_path(&artifact).unwrap();
        assert!(precompiled_path.is_file());

        let cold_executor =
            WasmArtifactExecutor::new_with_precompiled_cache_dir(&cache_dir).unwrap();
        assert_eq!(cold_executor.cached_module_count().unwrap(), 0);
        assert_eq!(
            cold_executor
                .execute_as_json(&artifact, &serde_json::json!({"amount": 11}), 10_000)
                .unwrap(),
            serde_json::json!({"value": 22})
        );
        assert_eq!(cold_executor.cached_module_count().unwrap(), 1);
        let _ = fs::remove_dir_all(root);
    }

    fn sample_ir() -> DecisionIr {
        DecisionIr {
            ir_id: "fee-ir".to_string(),
            source_unit_id: "bank/src/lib.rs".to_string(),
            input_domains: BTreeMap::from([("amount".to_string(), vec![0, 1, 7, 8])]),
            expression: DecisionExpr::Mul {
                left: Box::new(DecisionExpr::Var {
                    name: "amount".to_string(),
                }),
                right: Box::new(DecisionExpr::Const { value: 2 }),
            },
            side_effects: Vec::new(),
            invariants: Vec::new(),
        }
    }

    fn test_dir(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "lazarus-artifact-runner-{label}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }
}
