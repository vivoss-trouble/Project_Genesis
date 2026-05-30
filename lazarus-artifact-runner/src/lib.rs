use lazarus_contracts::{DecisionExpr, DecisionIr};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest as _, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use wasmtime::{Config, Engine, Instance, Module, Store, Val};

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

pub fn compile_executable_artifact(
    ir: &DecisionIr,
    config: &ArtifactRunnerConfig,
) -> Result<ExecutableArtifact, String> {
    ensure_native_artifacts_enabled()?;
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

pub fn execute_artifact(
    artifact: &ExecutableArtifact,
    payload: &Value,
) -> Result<ArtifactExecutionReport, String> {
    ensure_native_artifacts_enabled()?;
    execute_artifact_with_timeout_dev_only(artifact, payload, DEFAULT_ARTIFACT_TIMEOUT)
}

pub fn execute_artifact_with_timeout(
    artifact: &ExecutableArtifact,
    payload: &Value,
    timeout: Duration,
) -> Result<ArtifactExecutionReport, String> {
    ensure_native_artifacts_enabled()?;
    execute_artifact_with_timeout_dev_only(artifact, payload, timeout)
}

pub fn execute_artifact_with_timeout_dev_only(
    artifact: &ExecutableArtifact,
    payload: &Value,
    timeout: Duration,
) -> Result<ArtifactExecutionReport, String> {
    if timeout.is_zero() {
        return Err("artifact timeout must be non-zero".to_string());
    }
    let args = payload_args(payload, &artifact.input_order)?;
    let input_hash = stable_hash(payload)?;
    let mut child = spawn_artifact_child(artifact, &args)?;
    let deadline = Instant::now() + timeout;
    loop {
        if child
            .try_wait()
            .map_err(|error| format!("failed to poll artifact child: {error}"))?
            .is_some()
        {
            let output = child
                .wait_with_output()
                .map_err(|error| format!("failed to collect artifact output: {error}"))?;
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            let value =
                if output.status.success() {
                    Some(stdout.parse::<i64>().map_err(|error| {
                        format!("artifact stdout was not i64: {error}: {stdout}")
                    })?)
                } else {
                    None
                };

            return Ok(ArtifactExecutionReport {
                executable_path: artifact.executable_path.clone(),
                input_hash,
                exit_code: output.status.code(),
                timed_out: false,
                stdout,
                stderr,
                value,
            });
        }
        if Instant::now() >= deadline {
            terminate_artifact_child(&mut child);
            let output = child
                .wait_with_output()
                .map_err(|error| format!("failed to reap timed-out artifact: {error}"))?;
            return Ok(ArtifactExecutionReport {
                executable_path: artifact.executable_path.clone(),
                input_hash,
                exit_code: output.status.code(),
                timed_out: true,
                stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
                stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
                value: None,
            });
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn spawn_artifact_child(
    artifact: &ExecutableArtifact,
    args: &[i64],
) -> Result<Child, String> {
    let mut command = Command::new(&artifact.executable_path);
    command
        .args(args.iter().map(i64::to_string))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;

        unsafe {
            command.pre_exec(|| {
                if libc::setpgid(0, 0) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }

    command
        .spawn()
        .map_err(|error| format!("failed to execute artifact: {error}"))
}

fn terminate_artifact_child(child: &mut Child) {
    #[cfg(unix)]
    {
        let pgid = child.id() as libc::pid_t;
        unsafe {
            if libc::killpg(pgid, libc::SIGKILL) == -1 {
                let _ = child.kill();
            }
        }
    }

    #[cfg(not(unix))]
    {
        let _ = child.kill();
    }
}

pub fn execute_artifact_as_json(
    artifact: &ExecutableArtifact,
    payload: &Value,
) -> Result<Value, String> {
    ensure_native_artifacts_enabled()?;
    execute_artifact_as_json_dev_only(artifact, payload)
}

pub fn execute_artifact_as_json_dev_only(
    artifact: &ExecutableArtifact,
    payload: &Value,
) -> Result<Value, String> {
    let report = execute_artifact_with_timeout_dev_only(
        artifact,
        payload,
        DEFAULT_ARTIFACT_TIMEOUT,
    )?;
    let Some(value) = report.value else {
        if report.timed_out {
            return Err(format!(
                "artifact timed out after {:?}: {}",
                DEFAULT_ARTIFACT_TIMEOUT, report.stderr
            ));
        }
        return Err(format!(
            "artifact failed with code {:?}: {}",
            report.exit_code, report.stderr
        ));
    };
    Ok(serde_json::json!({ "value": value }))
}

fn ensure_native_artifacts_enabled() -> Result<(), String> {
    if std::env::var("LAZARUS_NATIVE_ARTIFACT_DEV_MODE").as_deref() == Ok("1") {
        return Ok(());
    }
    Err(
        "native executable artifacts are disabled by default; use Wasm artifacts for production or call the *_dev_only API in development tooling"
            .to_string(),
    )
}

fn render_executable_source(
    ir: &DecisionIr,
    input_order: &[String],
    function_name: &str,
) -> Result<String, String> {
    for input in input_order {
        validate_identifier(input, "input")?;
    }
    let signature = input_order
        .iter()
        .map(|name| format!("{name}: i64"))
        .collect::<Vec<_>>()
        .join(", ");
    let parse_args = input_order
        .iter()
        .enumerate()
        .map(|(index, name)| {
            format!(
                "    let {name}: i64 = args[{arg_index}].parse().unwrap_or_else(|_| {{ eprintln!(\"invalid i64 arg {name}\"); std::process::exit(65); }});\n",
                arg_index = index + 1
            )
        })
        .collect::<String>();
    let call_args = input_order.join(", ");
    let expected_arg_count = input_order.len() + 1;
    let expr = compile_expr(&ir.expression)?;

    Ok(format!(
        "// Generated executable artifact by Project Lazarus.\n\
fn {function_name}({signature}) -> i64 {{\n\
    {expr}\n\
}}\n\
\n\
fn main() {{\n\
    let args: Vec<String> = std::env::args().collect();\n\
    if args.len() != {expected_arg_count} {{\n\
        eprintln!(\"expected {} i64 args, got {{}}\", args.len().saturating_sub(1));\n\
        std::process::exit(64);\n\
    }}\n\
{parse_args}\
    println!(\"{{}}\", {function_name}({call_args}));\n\
}}\n",
        input_order.len()
    ))
}

fn render_wasm_source(
    ir: &DecisionIr,
    input_order: &[String],
    function_name: &str,
) -> Result<String, String> {
    for input in input_order {
        validate_identifier(input, "input")?;
    }
    let signature = input_order
        .iter()
        .map(|name| format!("{name}: i64"))
        .collect::<Vec<_>>()
        .join(", ");
    let expr = compile_wasm_expr(&ir.expression)?;

    Ok(format!(
        "#![no_std]\n\
#[panic_handler]\n\
fn panic(_: &core::panic::PanicInfo) -> ! {{ loop {{}} }}\n\
\n\
#[unsafe(no_mangle)]\n\
pub extern \"C\" fn {function_name}({signature}) -> i64 {{\n\
    {expr}\n\
}}\n"
    ))
}

fn sorted_inputs(ir: &DecisionIr) -> Vec<String> {
    let mut inputs = ir
        .input_domains
        .keys()
        .filter(|name| name.as_str() != "__unit")
        .cloned()
        .collect::<Vec<_>>();
    inputs.sort();
    inputs
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

fn compile_expr(expr: &DecisionExpr) -> Result<String, String> {
    match expr {
        DecisionExpr::Const { value } => Ok(value.to_string()),
        DecisionExpr::Var { name } => {
            validate_identifier(name, "var")?;
            Ok(name.clone())
        }
        DecisionExpr::Add { left, right } => Ok(format!(
            "({}).saturating_add({})",
            compile_expr(left)?,
            compile_expr(right)?
        )),
        DecisionExpr::Sub { left, right } => Ok(format!(
            "({}).saturating_sub({})",
            compile_expr(left)?,
            compile_expr(right)?
        )),
        DecisionExpr::Mul { left, right } => Ok(format!(
            "({}).saturating_mul({})",
            compile_expr(left)?,
            compile_expr(right)?
        )),
        DecisionExpr::Min { left, right } => Ok(format!(
            "std::cmp::min({}, {})",
            compile_expr(left)?,
            compile_expr(right)?
        )),
        DecisionExpr::Max { left, right } => Ok(format!(
            "std::cmp::max({}, {})",
            compile_expr(left)?,
            compile_expr(right)?
        )),
        DecisionExpr::Abs { value } => Ok(format!("({}).saturating_abs()", compile_expr(value)?)),
    }
}

fn compile_wasm_expr(expr: &DecisionExpr) -> Result<String, String> {
    match expr {
        DecisionExpr::Const { value } => Ok(value.to_string()),
        DecisionExpr::Var { name } => {
            validate_identifier(name, "var")?;
            Ok(name.clone())
        }
        DecisionExpr::Add { left, right } => Ok(format!(
            "({}).saturating_add({})",
            compile_wasm_expr(left)?,
            compile_wasm_expr(right)?
        )),
        DecisionExpr::Sub { left, right } => Ok(format!(
            "({}).saturating_sub({})",
            compile_wasm_expr(left)?,
            compile_wasm_expr(right)?
        )),
        DecisionExpr::Mul { left, right } => Ok(format!(
            "({}).saturating_mul({})",
            compile_wasm_expr(left)?,
            compile_wasm_expr(right)?
        )),
        DecisionExpr::Min { left, right } => Ok(format!(
            "core::cmp::min({}, {})",
            compile_wasm_expr(left)?,
            compile_wasm_expr(right)?
        )),
        DecisionExpr::Max { left, right } => Ok(format!(
            "core::cmp::max({}, {})",
            compile_wasm_expr(left)?,
            compile_wasm_expr(right)?
        )),
        DecisionExpr::Abs { value } => {
            Ok(format!("({}).saturating_abs()", compile_wasm_expr(value)?))
        }
    }
}

fn validate_identifier(value: &str, field: &str) -> Result<(), String> {
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return Err(format!("{field} is required"));
    };
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return Err(format!("{field} must start with '_' or ASCII letter"));
    }
    if !chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric()) {
        return Err(format!(
            "{field} must contain only ASCII letters, digits, and '_'"
        ));
    }
    Ok(())
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

        let report =
            execute_artifact_with_timeout_dev_only(
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
        let error = compile_executable_artifact(
            &sample_ir(),
            &ArtifactRunnerConfig::new("compute", &root),
        )
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
