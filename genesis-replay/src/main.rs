use genesis_contracts::wire::{
    GENESIS_ABI_VERSION, GenesisPayload, GenesisPluginApi, GenesisResponse, GenesisSlice,
};
use libloading::{Library, Symbol};
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const DEFAULT_AUDIT_PATH: &str = ".genesis-state/audit.jsonl";
const DEFAULT_PLUGINS_DIR: &str = "genesis-plugins";
const DEFAULT_SANDBOX_DIR: &str = ".genesis-state-replay";
const DEFAULT_ANCHOR_STATE: &str = ".genesis-state/anchor.mmap";
const ACTUATOR_SOCKET_PATH: &str = "/tmp/genesis_act.sock";

#[derive(Debug, Clone, Copy)]
enum ReplayMode {
    Strict,
    Simulate,
    BrainMock,
}

#[derive(Debug)]
struct Config {
    mode: ReplayMode,
    audit_path: PathBuf,
    plugins_dir: PathBuf,
    sandbox_dir: PathBuf,
    anchor_state: PathBuf,
    include_brain: bool,
    emit_actuator: bool,
}

#[derive(Deserialize, Debug)]
struct AuditRecord {
    timestamp_ms: u64,
    #[serde(rename = "type")]
    event_type: String,
    payload: Value,
}

#[derive(Debug, Clone)]
struct SenseFrame {
    tick_id: u64,
    timestamp_ms: u64,
    state_json: String,
}

#[derive(Debug, Clone)]
struct ExpectedPluginResponse {
    status: Option<u32>,
    error_code: Option<u32>,
    data_hash: Option<u64>,
}

struct LoadedReplayPlugin {
    _lib: Library,
    api: GenesisPluginApi,
    name: String,
}

fn main() {
    if let Err(err) = run() {
        eprintln!("[genesis-replay] error: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let config = parse_args()?;
    let records = read_audit(&config.audit_path)?;

    match config.mode {
        ReplayMode::Strict => strict_audit(&records),
        ReplayMode::Simulate => simulate(&config, &records),
        ReplayMode::BrainMock => brain_mock(&config, &records),
    }
}

fn strict_audit(records: &[AuditRecord]) -> Result<(), String> {
    println!("[genesis-replay] strict audit: {} records", records.len());

    for record in records {
        match record.event_type.as_str() {
            "TickStarted" => {
                println!(
                    "[{}] tick {} started",
                    record.timestamp_ms,
                    value_u64(&record.payload, "tick_id").unwrap_or_default()
                );
            }
            "SenseCaptured" => {
                let tick_id = value_u64(&record.payload, "tick_id").unwrap_or_default();
                let state_json = value_str(&record.payload, "state_json").unwrap_or_default();
                println!(
                    "[{}] tick {} sense {}",
                    record.timestamp_ms,
                    tick_id,
                    sense_label(state_json)
                );
            }
            "PluginResponded" => {
                println!(
                    "[{}] tick {} plugin {} status={} error={} hash={}",
                    record.timestamp_ms,
                    value_u64(&record.payload, "tick_id").unwrap_or_default(),
                    value_str(&record.payload, "plugin_id").unwrap_or("<unknown>"),
                    value_u64(&record.payload, "status")
                        .map(|value| value.to_string())
                        .unwrap_or_else(|| "?".to_string()),
                    value_u64(&record.payload, "error_code")
                        .map(|value| value.to_string())
                        .unwrap_or_else(|| "?".to_string()),
                    value_u64(&record.payload, "data_hash")
                        .map(|value| value.to_string())
                        .unwrap_or_else(|| "unlogged".to_string())
                );
            }
            "BrainActionDecoded" => {
                println!(
                    "[{}] tick {} source_tick {} decoded {} {}",
                    record.timestamp_ms,
                    value_u64(&record.payload, "tick_id").unwrap_or_default(),
                    value_u64(&record.payload, "source_tick_id").unwrap_or_default(),
                    value_str(&record.payload, "action_id").unwrap_or("<no-action-id>"),
                    value_str(&record.payload, "action_json").unwrap_or("")
                );
            }
            "PlanDrafted" => {
                println!(
                    "[{}] tick {} source_tick {} plan {} goal={:?} steps={}",
                    record.timestamp_ms,
                    value_u64(&record.payload, "tick_id").unwrap_or_default(),
                    value_u64(&record.payload, "source_tick_id").unwrap_or_default(),
                    value_str(&record.payload, "plan_id").unwrap_or("<no-plan-id>"),
                    value_str(&record.payload, "goal").unwrap_or(""),
                    record
                        .payload
                        .get("steps")
                        .and_then(Value::as_array)
                        .map(|steps| steps.len())
                        .unwrap_or_default()
                );
                if let Some(steps) = record.payload.get("steps").and_then(Value::as_array) {
                    for step in steps {
                        println!(
                            "    step {} intent={:?} target={}",
                            step.get("step_index")
                                .and_then(Value::as_u64)
                                .unwrap_or_default(),
                            step.get("intent").and_then(Value::as_str).unwrap_or(""),
                            step.get("target_selector")
                                .map(Value::to_string)
                                .unwrap_or_else(|| "null".to_string())
                        );
                    }
                }
            }
            "MemoryAdvisoryAttached" => {
                println!(
                    "[{}] tick {} memory advisory scope={} samples={} hash={}",
                    record.timestamp_ms,
                    value_u64(&record.payload, "tick_id").unwrap_or_default(),
                    value_str(&record.payload, "scope").unwrap_or("<no-scope>"),
                    value_u64(&record.payload, "sample_count").unwrap_or_default(),
                    value_str(&record.payload, "hash").unwrap_or("<no-hash>")
                );
            }
            "PlanActivated" => {
                println!(
                    "[{}] tick {} plan {} activated",
                    record.timestamp_ms,
                    value_u64(&record.payload, "tick_id").unwrap_or_default(),
                    value_str(&record.payload, "plan_id").unwrap_or("<no-plan-id>")
                );
            }
            "StepActivated" => {
                println!(
                    "[{}] tick {} plan {} step {} activated intent={:?}",
                    record.timestamp_ms,
                    value_u64(&record.payload, "tick_id").unwrap_or_default(),
                    value_str(&record.payload, "plan_id").unwrap_or("<no-plan-id>"),
                    value_u64(&record.payload, "step_index").unwrap_or_default(),
                    value_str(&record.payload, "intent").unwrap_or("")
                );
            }
            "PlanAdvanced" => {
                println!(
                    "[{}] tick {} plan {} advanced {}->{}",
                    record.timestamp_ms,
                    value_u64(&record.payload, "tick_id").unwrap_or_default(),
                    value_str(&record.payload, "plan_id").unwrap_or("<no-plan-id>"),
                    value_u64(&record.payload, "from_step").unwrap_or_default(),
                    value_u64(&record.payload, "to_step").unwrap_or_default()
                );
            }
            "PlanAborted" => {
                println!(
                    "[{}] tick {} plan {} aborted at_step={} reason={:?}",
                    record.timestamp_ms,
                    value_u64(&record.payload, "tick_id").unwrap_or_default(),
                    value_str(&record.payload, "plan_id").unwrap_or("<no-plan-id>"),
                    value_u64(&record.payload, "at_step").unwrap_or_default(),
                    value_str(&record.payload, "reason").unwrap_or("")
                );
            }
            "ReplaySnapshot" => {
                println!(
                    "[{}] replay snapshot {} {}",
                    record.timestamp_ms,
                    value_str(&record.payload, "label").unwrap_or("<unknown>"),
                    value_str(&record.payload, "path").unwrap_or("<missing-path>")
                );
            }
            "OutcomeObserved" => {
                println!(
                    "[{}] tick {} outcome {} result={} evidence={}",
                    record.timestamp_ms,
                    value_u64(&record.payload, "tick_id").unwrap_or_default(),
                    value_str(&record.payload, "action_id").unwrap_or("<no-action-id>"),
                    record
                        .payload
                        .get("result")
                        .map(Value::to_string)
                        .unwrap_or_else(|| "null".to_string()),
                    record
                        .payload
                        .get("evidence")
                        .map(Value::to_string)
                        .unwrap_or_else(|| "null".to_string())
                );
            }
            "ActionDispatched" | "ActionDropped" | "FailureObserved" | "AuditDropped" => {
                println!(
                    "[{}] {} {}",
                    record.timestamp_ms, record.event_type, record.payload
                );
            }
            _ => {}
        }
    }

    Ok(())
}

fn simulate(config: &Config, records: &[AuditRecord]) -> Result<(), String> {
    let frames = collect_sense_frames(records);
    let expected = collect_expected_plugin_responses(records);
    if frames.is_empty() {
        return Err("audit log has no SenseCaptured events".to_string());
    }

    let project_root = std::env::current_dir().map_err(|err| err.to_string())?;
    let anchor_snapshot = find_replay_snapshot(records, "anchor-mmap");
    let sandbox_root = prepare_sandbox(config, &project_root, anchor_snapshot.as_deref())?;
    let plugin_paths = plugin_paths(&config.plugins_dir, &project_root)?;

    std::env::set_current_dir(&sandbox_root).map_err(|err| err.to_string())?;
    let plugins = load_plugins(&plugin_paths, config.include_brain)?;

    println!(
        "[genesis-replay] simulate {} frames in {}",
        frames.len(),
        sandbox_root.display()
    );

    let mut drift_count = 0usize;
    for frame in frames {
        println!(
            "[replay] tick {} payload {}",
            frame.tick_id, frame.state_json
        );
        for plugin in &plugins {
            let response = invoke_plugin(plugin, &frame);
            let status = response.status;
            let error_code = response.error_code;
            let data = response_to_string(&response);
            let data_hash = fnv1a64(data.as_bytes());
            (plugin.api.free_response)(response);

            let key = (frame.tick_id, plugin.name.clone());
            let verdict = match expected.get(&key) {
                Some(expected) => compare_plugin_response(expected, status, error_code, data_hash),
                None => ReplayVerdict::MissingHistory,
            };

            if matches!(verdict, ReplayVerdict::Drift(_)) {
                drift_count += 1;
            }

            println!(
                "[replay] tick {} plugin {} status={} error={} hash={} verdict={} preview={}",
                frame.tick_id,
                plugin.name,
                status,
                error_code,
                data_hash,
                verdict.label(),
                preview(&data, 120)
            );
        }
    }

    println!(
        "[genesis-replay] simulate complete: drift_count={}",
        drift_count
    );
    Ok(())
}

fn brain_mock(config: &Config, records: &[AuditRecord]) -> Result<(), String> {
    let decisions = records
        .iter()
        .filter(|record| record.event_type == "BrainActionDecoded")
        .collect::<Vec<_>>();

    println!(
        "[genesis-replay] brain-mock decisions={} emit_actuator={}",
        decisions.len(),
        config.emit_actuator
    );

    for record in decisions {
        let tick_id = value_u64(&record.payload, "tick_id").unwrap_or_default();
        let source_tick_id = value_u64(&record.payload, "source_tick_id").unwrap_or_default();
        let action_id = value_str(&record.payload, "action_id").unwrap_or("<no-action-id>");
        let action_json = value_str(&record.payload, "action_json").unwrap_or("{}");
        let action_value = action_only_json(action_json)?;

        println!(
            "[brain-mock] tick={} source_tick={} action_id={} action={}",
            tick_id, source_tick_id, action_id, action_value
        );

        if config.emit_actuator {
            emit_to_actuator(&action_value)?;
        }
    }

    Ok(())
}

#[derive(Debug)]
enum ReplayVerdict {
    Match,
    Drift(String),
    HashUnavailable,
    MissingHistory,
}

impl ReplayVerdict {
    fn label(&self) -> String {
        match self {
            Self::Match => "MATCH".to_string(),
            Self::Drift(reason) => format!("DRIFT({reason})"),
            Self::HashUnavailable => "MATCH_STATUS_HASH_UNAVAILABLE".to_string(),
            Self::MissingHistory => "NO_HISTORY".to_string(),
        }
    }
}

fn compare_plugin_response(
    expected: &ExpectedPluginResponse,
    status: u32,
    error_code: u32,
    data_hash: u64,
) -> ReplayVerdict {
    if expected.status.is_some_and(|value| value != status) {
        return ReplayVerdict::Drift(format!(
            "status expected={} actual={}",
            expected.status.unwrap_or_default(),
            status
        ));
    }
    if expected.error_code.is_some_and(|value| value != error_code) {
        return ReplayVerdict::Drift(format!(
            "error expected={} actual={}",
            expected.error_code.unwrap_or_default(),
            error_code
        ));
    }
    match expected.data_hash {
        Some(expected_hash) if expected_hash == data_hash => ReplayVerdict::Match,
        Some(expected_hash) => {
            ReplayVerdict::Drift(format!("hash expected={expected_hash} actual={data_hash}"))
        }
        None => ReplayVerdict::HashUnavailable,
    }
}

fn collect_sense_frames(records: &[AuditRecord]) -> Vec<SenseFrame> {
    records
        .iter()
        .filter(|record| record.event_type == "SenseCaptured")
        .filter_map(|record| {
            let tick_id = value_u64(&record.payload, "tick_id")?;
            let state_json = value_str(&record.payload, "state_json")?.to_string();
            Some(SenseFrame {
                tick_id,
                timestamp_ms: record.timestamp_ms,
                state_json,
            })
        })
        .collect()
}

fn collect_expected_plugin_responses(
    records: &[AuditRecord],
) -> HashMap<(u64, String), ExpectedPluginResponse> {
    let mut expected = HashMap::new();
    for record in records {
        if record.event_type != "PluginResponded" {
            continue;
        }
        let Some(tick_id) = value_u64(&record.payload, "tick_id") else {
            continue;
        };
        let Some(plugin_id) = value_str(&record.payload, "plugin_id") else {
            continue;
        };

        expected.insert(
            (tick_id, plugin_id.to_string()),
            ExpectedPluginResponse {
                status: value_u64(&record.payload, "status").map(|value| value as u32),
                error_code: value_u64(&record.payload, "error_code").map(|value| value as u32),
                data_hash: value_u64(&record.payload, "data_hash"),
            },
        );
    }
    expected
}

fn load_plugins(
    plugin_paths: &[PathBuf],
    include_brain: bool,
) -> Result<Vec<LoadedReplayPlugin>, String> {
    let mut plugins = Vec::new();
    for path in plugin_paths {
        unsafe {
            let lib = Library::new(path).map_err(|err| format!("{}: {err}", path.display()))?;
            let entry: Symbol<extern "C" fn() -> GenesisPluginApi> = lib
                .get(b"genesis_plugin_entry")
                .map_err(|err| format!("{}: {err}", path.display()))?;
            let api = entry();
            if api.abi_version != GENESIS_ABI_VERSION {
                return Err(format!(
                    "{} ABI mismatch: core={} plugin={}",
                    path.display(),
                    GENESIS_ABI_VERSION,
                    api.abi_version
                ));
            }
            let name = slice_to_string(api.plugin_id);
            if !include_brain && name == "brain-llm" {
                continue;
            }
            println!(
                "[genesis-replay] loaded plugin {} from {}",
                name,
                path.display()
            );
            plugins.push(LoadedReplayPlugin {
                _lib: lib,
                api,
                name,
            });
        }
    }
    Ok(plugins)
}

fn invoke_plugin(plugin: &LoadedReplayPlugin, frame: &SenseFrame) -> GenesisResponse {
    let bytes = frame.state_json.as_bytes();
    let payload = GenesisPayload {
        abi_version: GENESIS_ABI_VERSION,
        tick_id: frame.tick_id,
        timestamp_ms: frame.timestamp_ms,
        kind: 0,
        data: GenesisSlice::from_slice(bytes),
    };
    (plugin.api.on_event)(payload)
}

fn prepare_sandbox(
    config: &Config,
    project_root: &Path,
    anchor_snapshot: Option<&str>,
) -> Result<PathBuf, String> {
    let sandbox_base = absolutize(&config.sandbox_dir, project_root);
    let sandbox_root = sandbox_base.join(format!("session-{}", current_ts()));
    let sandbox_state = sandbox_root.join(".genesis-state");
    fs::create_dir_all(&sandbox_state).map_err(|err| err.to_string())?;

    let source_anchor = anchor_snapshot
        .map(PathBuf::from)
        .map(|path| absolutize(&path, project_root))
        .unwrap_or_else(|| absolutize(&config.anchor_state, project_root));
    if source_anchor.exists() {
        fs::copy(&source_anchor, sandbox_state.join("anchor.mmap")).map_err(|err| {
            format!(
                "failed to copy anchor state {} into sandbox: {err}",
                source_anchor.display()
            )
        })?;
    }

    Ok(sandbox_root)
}

fn find_replay_snapshot(records: &[AuditRecord], label: &str) -> Option<String> {
    records
        .iter()
        .filter(|record| record.event_type == "ReplaySnapshot")
        .find_map(|record| {
            if value_str(&record.payload, "label")? == label {
                value_str(&record.payload, "path").map(|path| path.to_string())
            } else {
                None
            }
        })
}

fn plugin_paths(plugins_dir: &Path, project_root: &Path) -> Result<Vec<PathBuf>, String> {
    let plugins_dir = absolutize(plugins_dir, project_root);
    let mut paths = fs::read_dir(&plugins_dir)
        .map_err(|err| format!("failed to read {}: {err}", plugins_dir.display()))?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .and_then(|ext| ext.to_str())
                .is_some_and(|ext| ext == "dylib" || ext == "so")
        })
        .collect::<Vec<_>>();
    paths.sort();
    Ok(paths)
}

fn read_audit(path: &Path) -> Result<Vec<AuditRecord>, String> {
    let file = File::open(path).map_err(|err| format!("{}: {err}", path.display()))?;
    let reader = BufReader::new(file);
    let mut records = Vec::new();

    for (idx, line) in reader.lines().enumerate() {
        let line = line.map_err(|err| err.to_string())?;
        if line.trim().is_empty() {
            continue;
        }
        let record = serde_json::from_str::<AuditRecord>(&line)
            .map_err(|err| format!("{}:{}: {err}", path.display(), idx + 1))?;
        records.push(record);
    }

    Ok(records)
}

fn parse_args() -> Result<Config, String> {
    let mut args = std::env::args().skip(1);
    let mode = match args.next().as_deref() {
        Some("strict") => ReplayMode::Strict,
        Some("simulate") => ReplayMode::Simulate,
        Some("brain-mock") => ReplayMode::BrainMock,
        Some("--help") | Some("-h") | None => {
            print_usage();
            std::process::exit(0);
        }
        Some(other) => return Err(format!("unknown mode: {other}")),
    };

    let mut config = Config {
        mode,
        audit_path: PathBuf::from(DEFAULT_AUDIT_PATH),
        plugins_dir: PathBuf::from(DEFAULT_PLUGINS_DIR),
        sandbox_dir: PathBuf::from(DEFAULT_SANDBOX_DIR),
        anchor_state: PathBuf::from(DEFAULT_ANCHOR_STATE),
        include_brain: false,
        emit_actuator: false,
    };

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--audit" => config.audit_path = next_path(&mut args, "--audit")?,
            "--plugins" => config.plugins_dir = next_path(&mut args, "--plugins")?,
            "--sandbox" => config.sandbox_dir = next_path(&mut args, "--sandbox")?,
            "--anchor-state" => config.anchor_state = next_path(&mut args, "--anchor-state")?,
            "--include-brain" => config.include_brain = true,
            "--emit-actuator" => config.emit_actuator = true,
            "--help" | "-h" => {
                print_usage();
                std::process::exit(0);
            }
            other => return Err(format!("unknown option: {other}")),
        }
    }

    Ok(config)
}

fn next_path(args: &mut impl Iterator<Item = String>, label: &str) -> Result<PathBuf, String> {
    args.next()
        .map(PathBuf::from)
        .ok_or_else(|| format!("{label} requires a path"))
}

fn print_usage() {
    println!(
        "Usage:
  cargo run -p genesis-replay -- strict [--audit PATH]
  cargo run -p genesis-replay -- simulate [--audit PATH] [--plugins DIR] [--sandbox DIR]
  cargo run -p genesis-replay -- brain-mock [--audit PATH] [--emit-actuator]

Modes:
  strict      Print a human-readable timeline from audit.jsonl.
  simulate    Re-feed SenseCaptured payloads into current plugins inside a replay sandbox.
  brain-mock  Re-emit historical BrainActionDecoded decisions without starting an LLM daemon."
    );
}

fn value_u64(payload: &Value, key: &str) -> Option<u64> {
    payload.get(key)?.as_u64()
}

fn value_str<'a>(payload: &'a Value, key: &str) -> Option<&'a str> {
    payload.get(key)?.as_str()
}

fn sense_label(state_json: &str) -> String {
    let Ok(value) = serde_json::from_str::<Value>(state_json) else {
        return "state=invalid-json".to_string();
    };

    let outcome_label = value
        .get("last_outcome")
        .map(last_outcome_label)
        .map(|label| format!(" last_outcome={label}"))
        .unwrap_or_default();

    if let Some(health) = value
        .get("fantasy_state")
        .and_then(|state| state.get("health"))
        .and_then(Value::as_u64)
    {
        return format!("health={health}{outcome_label}");
    }

    if let Some(web_state) = value.get("web_state") {
        let title = web_state
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("<untitled>");
        let mode = web_state
            .get("mode")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        return format!("web_title={title:?} mode={mode}{outcome_label}");
    }

    format!("state=unknown{outcome_label}")
}

fn last_outcome_label(value: &Value) -> String {
    let status = value
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let action_id = value
        .get("action_id")
        .and_then(Value::as_str)
        .unwrap_or("<no-action-id>");
    format!("{status}:{action_id}")
}

fn action_only_json(action_json: &str) -> Result<Value, String> {
    let mut value = serde_json::from_str::<Value>(action_json).map_err(|err| err.to_string())?;
    if let Value::Object(map) = &mut value {
        map.remove("tick");
    }
    Ok(value)
}

fn emit_to_actuator(action: &Value) -> Result<(), String> {
    let mut stream = UnixStream::connect(ACTUATOR_SOCKET_PATH).map_err(|err| err.to_string())?;
    let mut frame = serde_json::to_vec(action).map_err(|err| err.to_string())?;
    frame.push(b'\n');
    stream.write_all(&frame).map_err(|err| err.to_string())
}

fn response_to_string(response: &GenesisResponse) -> String {
    if response.data.ptr.is_null() || response.data.len == 0 {
        return String::new();
    }
    let bytes = unsafe { std::slice::from_raw_parts(response.data.ptr, response.data.len) };
    String::from_utf8_lossy(bytes).into_owned()
}

fn slice_to_string(slice: GenesisSlice) -> String {
    if slice.ptr.is_null() || slice.len == 0 {
        return "<unnamed-plugin>".to_string();
    }
    let bytes = unsafe { std::slice::from_raw_parts(slice.ptr, slice.len) };
    String::from_utf8_lossy(bytes).into_owned()
}

fn absolutize(path: &Path, root: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        root.join(path)
    }
}

fn preview(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in bytes {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn current_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}
