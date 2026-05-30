use genesis_plugin_sdk::{PluginRequest, PluginStatus};
use genesis_wasm_plugin_runner::{
    LinearMemoryTransport, PluginError as HostPluginError, WasmPluginLimits, WasmPluginTransport,
};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

static DUMMY_WASM: OnceLock<PathBuf> = OnceLock::new();

#[test]
fn dummy_wasm_plugin_runs_through_sandbox() {
    let runner = dummy_runner();
    let request = dummy_request(
        "payload-ok",
        serde_json::json!({
            "tick_id": 7,
            "payload": "clean-me"
        }),
    );

    let response = runner.invoke(request).unwrap();

    assert_eq!(response.status, PluginStatus::Ok);
    assert_eq!(response.data["plugin_id"], "shield-gateway");
    assert_eq!(
        response.data["data"],
        "Shield cleaned [clean-me] at Tick: 7"
    );
}

#[test]
fn dummy_wasm_plugin_business_error_stays_in_response_protocol() {
    let runner = dummy_runner();
    let request = dummy_request(
        "empty-payload",
        serde_json::json!({
            "tick_id": 8,
            "payload": ""
        }),
    );

    let response = runner.invoke(request).unwrap();

    assert_eq!(response.status, PluginStatus::Error);
    assert_eq!(response.error_code.as_deref(), Some("invalid_input"));
    assert_eq!(response.data["message"], "Empty payload");
}

#[test]
fn dummy_wasm_plugin_panic_is_fatal_crash() {
    let runner = dummy_runner();
    let request = dummy_request(
        "kill-payload",
        serde_json::json!({
            "tick_id": 9,
            "payload": "KILL"
        }),
    );

    let error = runner.invoke(request).unwrap_err();

    match error {
        HostPluginError::FatalPluginCrash(audit) => {
            assert_eq!(audit.plugin_id, "plugin-dummy-wasm");
            assert_eq!(audit.request_id, "kill-payload");
            assert_eq!(audit.phase, "handle");
        }
        other => panic!("expected FatalPluginCrash, got {other:?}"),
    }
}

fn dummy_request(request_id: &str, payload: serde_json::Value) -> PluginRequest {
    PluginRequest::new("plugin-dummy-wasm", request_id, payload).unwrap()
}

fn dummy_runner() -> LinearMemoryTransport {
    let wasm = fs::read(dummy_wasm()).unwrap();
    LinearMemoryTransport::from_bytes(
        "plugin-dummy-wasm",
        &wasm,
        WasmPluginLimits {
            max_input_bytes: 64 * 1024,
            max_output_bytes: 64 * 1024,
            max_fuel: 100_000,
            max_memory_bytes: 2 * 1024 * 1024,
        },
    )
    .unwrap()
}

fn dummy_wasm() -> &'static Path {
    DUMMY_WASM.get_or_init(build_dummy_wasm).as_path()
}

fn build_dummy_wasm() -> PathBuf {
    let workspace = workspace_root();
    let manifest_path = workspace
        .join("genesis-plugins")
        .join("plugin-dummy-wasm")
        .join("Cargo.toml");
    let target_dir = unique_temp_dir().join("target");
    let output = Command::new("cargo")
        .arg("build")
        .arg("--manifest-path")
        .arg(&manifest_path)
        .arg("--target=wasm32-wasip1")
        .arg("--release")
        .arg("--target-dir")
        .arg(&target_dir)
        .output()
        .unwrap_or_else(|error| panic!("failed to invoke cargo for dummy wasm plugin: {error}"));

    if !output.status.success() {
        panic!(
            "dummy wasm plugin build failed with status {}\nstdout:\n{}\nstderr:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let wasm_path = target_dir
        .join("wasm32-wasip1")
        .join("release")
        .join("plugin_dummy_wasm.wasm");
    assert!(wasm_path.is_file(), "missing dummy wasm: {wasm_path:?}");
    wasm_path
}

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("runner crate must live under workspace root")
        .to_path_buf()
}

fn unique_temp_dir() -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path =
        std::env::temp_dir().join(format!("genesis-dummy-wasm-{}-{nanos}", std::process::id()));
    fs::create_dir_all(&path).unwrap();
    path
}
