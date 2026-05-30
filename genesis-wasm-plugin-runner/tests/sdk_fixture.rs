use genesis_plugin_sdk::{PluginRequest, PluginStatus};
use genesis_wasm_plugin_runner::{
    LinearMemoryTransport, PluginError as HostPluginError, WasmPluginLimits, WasmPluginTransport,
};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

static FIXTURE_WASM: OnceLock<PathBuf> = OnceLock::new();

#[test]
fn real_sdk_guest_echoes_through_host_runner() {
    let wasm = fixture_wasm();
    let runner = fixture_runner(wasm, 100_000, 2 * 1024 * 1024, 64 * 1024);
    let request = fixture_request("echo");

    let response = runner.invoke(request).unwrap();

    assert_eq!(response.status, PluginStatus::Ok);
    assert_eq!(response.data["echo"], "fixture:hello");
}

#[test]
fn real_sdk_guest_business_error_is_not_a_host_crash() {
    let wasm = fixture_wasm();
    let runner = fixture_runner(wasm, 100_000, 2 * 1024 * 1024, 64 * 1024);
    let request = fixture_request("business_error");

    let response = runner.invoke(request).unwrap();

    assert_eq!(response.status, PluginStatus::Error);
    assert_eq!(
        response.error_code.as_deref(),
        Some("unsupported_operation")
    );
    assert_eq!(response.data["message"], "fixture business rejection");
}

#[test]
fn real_sdk_guest_panic_is_host_fatal_crash() {
    let wasm = fixture_wasm();
    let runner = fixture_runner(wasm, 100_000, 2 * 1024 * 1024, 64 * 1024);
    let request = fixture_request("panic");

    let error = runner.invoke(request).unwrap_err();

    match error {
        HostPluginError::FatalPluginCrash(audit) => {
            assert_eq!(audit.plugin_id, "fixture-plugin");
            assert_eq!(audit.request_id, "fixture-panic");
            assert_eq!(audit.phase, "handle");
            assert_eq!(audit.plugin_hash.len(), 64);
        }
        other => panic!("expected FatalPluginCrash, got {other:?}"),
    }
}

#[test]
fn real_sdk_guest_memory_hog_is_host_fatal_crash() {
    let wasm = fixture_wasm();
    let runner = fixture_runner(wasm, 10_000_000, 2 * 1024 * 1024, 64 * 1024);
    let request = fixture_request("memory_hog");

    let error = runner.invoke(request).unwrap_err();

    match error {
        HostPluginError::FatalPluginCrash(audit) => {
            assert_eq!(audit.plugin_id, "fixture-plugin");
            assert_eq!(audit.request_id, "fixture-memory_hog");
            assert_eq!(audit.phase, "handle");
            assert!(
                matches!(
                    audit.trap_kind.as_str(),
                    "memory_out_of_bounds" | "wasm_trap" | "host_error"
                ),
                "unexpected trap kind: {} ({})",
                audit.trap_kind,
                audit.trap_message
            );
        }
        other => panic!("expected FatalPluginCrash, got {other:?}"),
    }
}

fn fixture_request(op: &str) -> PluginRequest {
    PluginRequest::new(
        "fixture-plugin",
        format!("fixture-{op}"),
        serde_json::json!({
            "op": op,
            "message": "hello"
        }),
    )
    .unwrap()
}

fn fixture_runner(
    wasm_path: &Path,
    max_fuel: u64,
    max_memory_bytes: usize,
    max_output_bytes: usize,
) -> LinearMemoryTransport {
    let wasm = fs::read(wasm_path).unwrap();
    LinearMemoryTransport::from_bytes(
        "fixture-plugin",
        &wasm,
        WasmPluginLimits {
            max_input_bytes: 64 * 1024,
            max_output_bytes,
            max_fuel,
            max_memory_bytes,
        },
    )
    .unwrap()
}

fn fixture_wasm() -> &'static Path {
    FIXTURE_WASM.get_or_init(build_fixture_wasm).as_path()
}

fn build_fixture_wasm() -> PathBuf {
    let root = unique_temp_dir();
    fs::create_dir_all(root.join("src")).unwrap();
    write_fixture_manifest(&root);
    write_fixture_source(&root);

    let target_dir = root.join("target");
    let output = Command::new("cargo")
        .arg("build")
        .arg("--target=wasm32-wasip1")
        .arg("--release")
        .arg("--target-dir")
        .arg(&target_dir)
        .current_dir(&root)
        .output()
        .unwrap_or_else(|error| panic!("failed to invoke cargo for fixture: {error}"));

    if !output.status.success() {
        panic!(
            "fixture wasm build failed with status {}\nstdout:\n{}\nstderr:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let wasm_path = target_dir
        .join("wasm32-wasip1")
        .join("release")
        .join("plugin_dummy_echo.wasm");
    assert!(wasm_path.is_file(), "missing fixture wasm: {wasm_path:?}");
    wasm_path
}

fn write_fixture_manifest(root: &Path) {
    let sdk_path = workspace_root().join("genesis-plugin-sdk");
    let manifest = format!(
        r#"
[package]
name = "plugin-dummy-echo"
version = "0.1.0"
edition = "2024"

[workspace]

[lib]
crate-type = ["cdylib"]

[profile.release]
panic = "abort"

[dependencies]
genesis-plugin-sdk = {{ path = "{}", default-features = false }}
serde_json = {{ version = "1.0", default-features = false, features = ["alloc"] }}
wee_alloc = "0.4"
"#,
        sdk_path.display()
    );
    fs::write(root.join("Cargo.toml"), manifest).unwrap();
}

fn write_fixture_source(root: &Path) {
    fs::write(
        root.join("src").join("lib.rs"),
        r#"
#![no_std]

extern crate alloc;

use alloc::format;
use alloc::vec;
use alloc::vec::Vec;
use genesis_plugin_sdk::{
    export_plugin, GenesisPlugin, PluginError, PluginRequest, PluginResponse,
};

#[global_allocator]
static ALLOC: wee_alloc::WeeAlloc = wee_alloc::WeeAlloc::INIT;

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}

struct FixturePlugin;

impl GenesisPlugin for FixturePlugin {
    fn handle(req: PluginRequest) -> Result<PluginResponse, PluginError> {
        let op = req
            .payload
            .get("op")
            .and_then(|value| value.as_str())
            .unwrap_or("business_error");

        match op {
            "echo" => {
                let message = req
                    .payload
                    .get("message")
                    .and_then(|value| value.as_str())
                    .unwrap_or("");
                Ok(PluginResponse::ok(serde_json::json!({
                    "echo": format!("fixture:{message}")
                })))
            }
            "business_error" => Err(PluginError::new(
                "unsupported_operation",
                "fixture business rejection",
            )),
            "panic" => panic!("fixture panic"),
            "memory_hog" => {
                let mut blocks = Vec::new();
                loop {
                    blocks.push(vec![42_u8; 64 * 1024]);
                }
            }
            _ => Err(PluginError::new("unknown_operation", op)),
        }
    }
}

export_plugin!(FixturePlugin);
"#,
    )
    .unwrap();
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
    let path = std::env::temp_dir().join(format!(
        "genesis-sdk-fixture-{}-{nanos}",
        std::process::id()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}
