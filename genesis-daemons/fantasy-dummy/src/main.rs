use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const ACT_SOCKET_PATH: &str = "/tmp/genesis_act.sock";
const HTTP_ADDR: &str = "127.0.0.1:4767";

#[derive(Debug)]
struct DummyState {
    health: u8,
    button_left: u32,
    button_top: u32,
    log: VecDeque<String>,
    rng: u64,
}

#[derive(Serialize)]
struct StateView {
    health: u8,
    button_left: u32,
    button_top: u32,
    log: Vec<String>,
}

#[derive(Deserialize, Debug)]
#[serde(tag = "act")]
enum GenesisAction {
    #[serde(rename = "noop")]
    Noop { reason: Option<String> },
    #[serde(rename = "click")]
    Click { target: String, reason: String },
    #[serde(rename = "type")]
    Type {
        target: String,
        text: String,
        reason: String,
    },
    #[serde(rename = "key")]
    Key { code: String, reason: String },
    #[serde(rename = "wait")]
    Wait { ms: u64, reason: String },
    #[serde(rename = "assert_ui_state")]
    AssertUiState {
        target: String,
        expected: String,
        reason: String,
    },
}

fn main() -> std::io::Result<()> {
    let state = Arc::new(Mutex::new(DummyState {
        health: 100,
        button_left: 24,
        button_top: 150,
        log: VecDeque::new(),
        rng: 0xC0FFEE,
    }));

    spawn_entropy_loop(state.clone());
    spawn_act_socket(state.clone())?;
    serve_http(state)
}

fn spawn_entropy_loop(state: Arc<Mutex<DummyState>>) {
    thread::spawn(move || {
        loop {
            thread::sleep(Duration::from_secs(1));
            let mut state = state.lock().expect("dummy state poisoned");
            state.health = state.health.saturating_sub(5);

            if state.health < 50 && next_rand(&mut state.rng).is_multiple_of(2) {
                state.button_left = 20 + (next_rand(&mut state.rng) % 320) as u32;
                state.button_top = 120 + (next_rand(&mut state.rng) % 220) as u32;
            }
        }
    });
}

fn spawn_act_socket(state: Arc<Mutex<DummyState>>) -> std::io::Result<()> {
    let _ = fs::remove_file(ACT_SOCKET_PATH);
    let listener = UnixListener::bind(ACT_SOCKET_PATH)?;
    println!(
        "[fantasy-dummy] action socket listening on {}",
        ACT_SOCKET_PATH
    );

    thread::spawn(move || {
        for stream in listener.incoming() {
            match stream {
                Ok(stream) => handle_action_stream(stream, &state),
                Err(err) => eprintln!("[fantasy-dummy] action accept failed: {}", err),
            }
        }
    });

    Ok(())
}

fn handle_action_stream(stream: UnixStream, state: &Arc<Mutex<DummyState>>) {
    let mut line = String::new();
    if let Err(err) = BufReader::new(stream).read_line(&mut line) {
        eprintln!("[fantasy-dummy] action read failed: {}", err);
        return;
    }

    let action = match serde_json::from_str::<GenesisAction>(line.trim_end()) {
        Ok(action) => action,
        Err(err) => {
            eprintln!("[fantasy-dummy] invalid action: {}", err);
            return;
        }
    };

    apply_action(action, state);
}

fn apply_action(action: GenesisAction, state: &Arc<Mutex<DummyState>>) {
    let mut state = state.lock().expect("dummy state poisoned");
    match action {
        GenesisAction::Click { target, reason } if target == "#heal-btn" => {
            push_log(&mut state, format!("Genesis click {}: {}", target, reason));
            state.health = 100;
            push_log(&mut state, "System healed to 100%".to_string());
        }
        GenesisAction::Noop { reason } => {
            push_log(
                &mut state,
                format!("Genesis noop: {}", reason.unwrap_or_default()),
            );
        }
        GenesisAction::Type {
            target,
            text,
            reason,
        } => {
            push_log(
                &mut state,
                format!(
                    "Unsupported type target={} text={} reason={}",
                    target, text, reason
                ),
            );
        }
        GenesisAction::Key { code, reason } => {
            push_log(
                &mut state,
                format!("Unsupported key code={} reason={}", code, reason),
            );
        }
        GenesisAction::Wait { ms, reason } => {
            push_log(
                &mut state,
                format!("Unsupported wait ms={} reason={}", ms, reason),
            );
        }
        GenesisAction::AssertUiState {
            target,
            expected,
            reason,
        } => {
            push_log(
                &mut state,
                format!(
                    "Unsupported assert target={} expected={} reason={}",
                    target, expected, reason
                ),
            );
        }
        GenesisAction::Click { target, reason } => {
            push_log(
                &mut state,
                format!("Unsupported click target={} reason={}", target, reason),
            );
        }
    }
}

fn serve_http(state: Arc<Mutex<DummyState>>) -> std::io::Result<()> {
    let listener = TcpListener::bind(HTTP_ADDR)?;
    println!("[fantasy-dummy] UI available at http://{}", HTTP_ADDR);

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => handle_http(stream, &state),
            Err(err) => eprintln!("[fantasy-dummy] http accept failed: {}", err),
        }
    }

    Ok(())
}

fn handle_http(mut stream: TcpStream, state: &Arc<Mutex<DummyState>>) {
    let mut buffer = [0u8; 2048];
    let read = match stream.read(&mut buffer) {
        Ok(read) => read,
        Err(_) => return,
    };
    let request = String::from_utf8_lossy(&buffer[..read]);
    let request_line = request.lines().next().unwrap_or_default();

    if request_line.starts_with("GET /state ") {
        let body = state_json(state);
        respond(&mut stream, "200 OK", "application/json", &body);
    } else if request_line.starts_with("POST /heal ") {
        let mut state = state.lock().expect("dummy state poisoned");
        push_log(&mut state, "Manual heal button clicked".to_string());
        state.health = 100;
        respond(&mut stream, "204 No Content", "text/plain", "");
    } else {
        respond(&mut stream, "200 OK", "text/html; charset=utf-8", HTML);
    }
}

fn state_json(state: &Arc<Mutex<DummyState>>) -> String {
    let state = state.lock().expect("dummy state poisoned");
    let view = StateView {
        health: state.health,
        button_left: state.button_left,
        button_top: state.button_top,
        log: state.log.iter().cloned().collect(),
    };
    serde_json::to_string(&view).unwrap_or_else(|_| "{}".to_string())
}

fn respond(stream: &mut TcpStream, status: &str, content_type: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        status,
        content_type,
        body.len(),
        body
    );
    let _ = stream.write_all(response.as_bytes());
}

fn push_log(state: &mut DummyState, message: String) {
    state
        .log
        .push_front(format!("[{}] {}", now_label(), message));
    while state.log.len() > 12 {
        state.log.pop_back();
    }
}

fn now_label() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

fn next_rand(seed: &mut u64) -> u64 {
    *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
    *seed
}

const HTML: &str = r#"<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Genesis Fantasy Dummy</title>
  <style>
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: #15171c;
      color: #f4f7fb;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      min-height: 100vh;
      padding: 24px;
    }
    main {
      max-width: 760px;
      margin: 0 auto;
    }
    h1 {
      font-size: 24px;
      margin: 0 0 18px;
      letter-spacing: 0;
    }
    .arena {
      position: relative;
      height: 420px;
      border: 1px solid #343b49;
      background: #20242c;
      overflow: hidden;
    }
    .meter {
      width: min(420px, 100%);
      height: 24px;
      border: 1px solid #4c5668;
      background: #0f1115;
      margin: 22px;
    }
    #health-bar {
      height: 100%;
      width: 100%;
      background: #38d66b;
      transition: width 0.2s, background 0.2s;
    }
    #status {
      margin: 0 22px;
      font-size: 15px;
    }
    #heal-btn {
      position: absolute;
      top: 150px;
      left: 24px;
      height: 38px;
      padding: 0 18px;
      border: 1px solid #0b7d35;
      background: #2ddc67;
      color: #07120a;
      cursor: pointer;
      font-weight: 700;
    }
    #log {
      min-height: 132px;
      margin-top: 18px;
      padding: 12px;
      background: #0f1115;
      border: 1px solid #343b49;
      color: #aeb8c8;
      white-space: pre-wrap;
      line-height: 1.45;
      font-size: 13px;
    }
  </style>
</head>
<body>
  <main>
    <h1>Genesis Fantasy Dummy</h1>
    <section class="arena">
      <div class="meter"><div id="health-bar"></div></div>
      <div id="status">Health: 100%</div>
      <button id="heal-btn">HEAL SYSTEM</button>
    </section>
    <div id="log"></div>
  </main>
  <script>
    const bar = document.getElementById('health-bar');
    const statusEl = document.getElementById('status');
    const btn = document.getElementById('heal-btn');
    const logEl = document.getElementById('log');

    btn.addEventListener('click', () => fetch('/heal', { method: 'POST' }));

    async function refresh() {
      const state = await fetch('/state').then(r => r.json());
      bar.style.width = state.health + '%';
      bar.style.background = state.health < 35 ? '#ff4f5e' : state.health < 60 ? '#f6c450' : '#38d66b';
      statusEl.textContent = `Health: ${state.health}%`;
      btn.style.left = state.button_left + 'px';
      btn.style.top = state.button_top + 'px';
      logEl.textContent = state.log.join('\n');
    }

    setInterval(refresh, 300);
    refresh();
  </script>
</body>
</html>
"#;
