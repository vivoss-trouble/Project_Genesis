use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::thread;
use std::time::Duration;

const SOCKET_PATH: &str = "/tmp/genesis_brain.sock";

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
    let _ = fs::remove_file(SOCKET_PATH);
    let listener = UnixListener::bind(SOCKET_PATH)?;
    println!("[llm-dummy] listening on {}", SOCKET_PATH);

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                thread::spawn(move || handle_client(stream));
            }
            Err(err) => eprintln!("[llm-dummy] accept failed: {}", err),
        }
    }

    Ok(())
}

fn handle_client(mut stream: UnixStream) {
    let cloned = match stream.try_clone() {
        Ok(stream) => stream,
        Err(err) => {
            eprintln!("[llm-dummy] clone failed: {}", err);
            return;
        }
    };

    let mut line = String::new();
    if let Err(err) = BufReader::new(cloned).read_line(&mut line) {
        eprintln!("[llm-dummy] read failed: {}", err);
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

    if let Err(err) = stream.write_all(&frame) {
        eprintln!("[llm-dummy] write failed: {}", err);
    }
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
