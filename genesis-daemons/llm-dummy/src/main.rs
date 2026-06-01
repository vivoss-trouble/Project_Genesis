use genesis_platform::desktop::{DesktopPlatformAdapter, bind_legacy_socket_path};
use genesis_platform::ipc::{LocalServiceAddress, SERVICE_BRAIN};
use genesis_platform::{IpcListener, IpcStream, PlatformAdapter};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

const BRAIN_SOCKET_ENV: &str = "GENESIS_BRAIN_SOCKET";

#[derive(Deserialize)]
struct BrainRequest {
    task_id: String,
    tick_id: u64,
    timestamp_ms: u64,
    payload: String,
}

#[derive(Deserialize)]
struct TickContext {
    signal: Option<String>,
    fantasy_state: Option<FantasyState>,
}

#[derive(Deserialize)]
struct FantasyState {
    health: u8,
    button_left: u32,
    button_top: u32,
}

#[derive(Serialize)]
struct BrainResponse {
    task_id: String,
    status: &'static str,
    action: String,
}

fn main() -> std::io::Result<()> {
    let listener = brain_listener()?;
    println!(
        "[llm-dummy] listening on {}",
        brain_socket_path()?.display()
    );

    loop {
        match listener.accept() {
            Ok(stream) => {
                thread::spawn(move || handle_client(stream));
            }
            Err(err) => eprintln!("[llm-dummy] accept failed: {}", err),
        }
    }
}

fn brain_listener() -> std::io::Result<Box<dyn IpcListener>> {
    if let Ok(path) = std::env::var(BRAIN_SOCKET_ENV) {
        return bind_legacy_socket_path(&path).map_err(std::io::Error::other);
    }
    default_platform_adapter()
        .bind_local_service(SERVICE_BRAIN)
        .map_err(std::io::Error::other)
}

fn default_platform_adapter() -> DesktopPlatformAdapter {
    DesktopPlatformAdapter::legacy_runtime(genesis_platform::RuntimeProfile::DesktopSafe)
}

fn brain_socket_path() -> std::io::Result<PathBuf> {
    if let Ok(path) = std::env::var(BRAIN_SOCKET_ENV) {
        return Ok(PathBuf::from(path));
    }
    brain_socket_path_from_adapter(&default_platform_adapter())
}

#[cfg(test)]
fn brain_socket_path_with_runtime_dir(runtime_dir: PathBuf) -> std::io::Result<PathBuf> {
    let adapter = DesktopPlatformAdapter::with_roots(
        genesis_platform::current_platform(),
        genesis_platform::RuntimeProfile::DesktopSafe,
        runtime_dir.clone(),
        runtime_dir.clone(),
        runtime_dir,
    );
    brain_socket_path_from_adapter(&adapter)
}

fn brain_socket_path_from_adapter(adapter: &DesktopPlatformAdapter) -> std::io::Result<PathBuf> {
    match adapter
        .local_service_address(SERVICE_BRAIN)
        .map_err(std::io::Error::other)?
    {
        LocalServiceAddress::UnixSocket(path) => Ok(path),
        other => Err(std::io::Error::other(format!(
            "llm-dummy requires a Unix socket address, got {other:?}"
        ))),
    }
}

fn handle_client(mut stream: Box<dyn IpcStream>) {
    let line = match read_line_from_stream(stream.as_mut()) {
        Ok(line) => line,
        Err(err) => {
            eprintln!("[llm-dummy] read failed: {}", err);
            return;
        }
    };

    if line.is_empty() {
        eprintln!("[llm-dummy] read failed: empty request");
        return;
    }

    let request = match serde_json::from_str::<BrainRequest>(line.trim_end()) {
        Ok(request) => request,
        Err(err) => {
            eprintln!("[llm-dummy] invalid request: {}", err);
            return;
        }
    };

    println!(
        "[llm-dummy] accepted task={} tick={} payload={}",
        request.task_id, request.tick_id, request.payload
    );

    thread::sleep(Duration::from_millis(4500));

    let action = decide_action(&request);
    let response = BrainResponse {
        task_id: request.task_id,
        status: "ok",
        action,
    };

    let mut frame = match serde_json::to_vec(&response) {
        Ok(frame) => frame,
        Err(err) => {
            eprintln!("[llm-dummy] encode failed: {}", err);
            return;
        }
    };
    frame.push(b'\n');

    if let Err(err) = stream.send(&frame, Duration::from_secs(1)) {
        eprintln!("[llm-dummy] write failed: {}", err);
    }
}

fn read_line_from_stream(stream: &mut dyn IpcStream) -> Result<String, String> {
    let mut line = Vec::new();
    let mut buffer = [0_u8; 256];
    loop {
        let read = stream.read(&mut buffer).map_err(|err| err.to_string())?;
        if read == 0 {
            break;
        }
        line.extend_from_slice(&buffer[..read]);
        if line.contains(&b'\n') {
            break;
        }
        if line.len() > 64 * 1024 {
            return Err("line exceeds 64 KiB".to_string());
        }
    }
    String::from_utf8(line).map_err(|err| err.to_string())
}

fn decide_action(request: &BrainRequest) -> String {
    let context = serde_json::from_str::<TickContext>(&request.payload).ok();
    if let Some(state) = context
        .as_ref()
        .and_then(|context| context.fantasy_state.as_ref())
    {
        if state.health <= 65 {
            return format!(
                "{{\"tick\":{},\"act\":\"click\",\"target\":\"#heal-btn\",\"reason\":\"health={} below threshold; button=({},{}); observed_at={}\"}}",
                request.tick_id,
                state.health,
                state.button_left,
                state.button_top,
                request.timestamp_ms
            );
        }

        return format!(
            "{{\"tick\":{},\"act\":\"noop\",\"reason\":\"health={} stable; signal={}\"}}",
            request.tick_id,
            state.health,
            context
                .as_ref()
                .and_then(|context| context.signal.as_ref())
                .cloned()
                .unwrap_or_else(|| "unknown".to_string())
        );
    }

    format!(
        "{{\"tick\":{},\"act\":\"noop\",\"reason\":\"fantasy state unavailable; observed_at={}\"}}",
        request.tick_id, request.timestamp_ms
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn default_socket_preserves_legacy_filename() {
        let path = brain_socket_path_with_runtime_dir(PathBuf::from("/custom-runtime"))
            .expect("socket path");
        assert_eq!(path, PathBuf::from("/custom-runtime/genesis_brain.sock"));
    }
}
