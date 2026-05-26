use genesis_os_driver::{DriverReceipt, LogicalPoint, default_driver};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;

#[derive(Serialize)]
struct CliError {
    status: &'static str,
    error: String,
}

const DEFAULT_SOCKET_PATH: &str = "/tmp/genesis_os_driver.sock";
const ARMED_CONFIRMATION: &str = "GENESIS_OS_DRIVER_ARMED";

fn main() {
    if let Err(error) = run() {
        print_json(&CliError {
            status: "error",
            error: error.to_string(),
        });
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "probe".to_string());
    let rest: Vec<String> = args.collect();
    let driver = default_driver();

    match command.as_str() {
        "daemon" => {
            let options = DaemonOptions::parse(&rest)?;
            if options.armed {
                require_armed_confirmation(options.confirm.as_deref())?;
            }
            run_daemon(&options)?;
        }
        "probe" => print_json(&driver.probe()),
        "selftest" => {
            let probe = driver.probe();
            print_json(&probe);
            let point = center_point(&probe).unwrap_or(LogicalPoint { x: 100.0, y: 100.0 });
            let receipt = driver.move_mouse(point, false)?;
            print_json(&receipt);
        }
        "move" => {
            let options = Options::parse(&rest)?;
            if options.armed {
                require_armed_confirmation(options.confirm.as_deref())?;
            }
            let receipt = driver.move_mouse(options.point, options.armed)?;
            print_json(&receipt);
        }
        "click" => {
            let options = Options::parse(&rest)?;
            if options.armed {
                require_armed_confirmation(options.confirm.as_deref())?;
            }
            let receipt = driver.click_left(options.point, options.armed)?;
            print_json(&receipt);
        }
        _ => {
            return Err(format!(
                "unknown command '{command}'. Use probe, selftest, daemon, move, or click"
            )
            .into());
        }
    }

    Ok(())
}

#[derive(Debug)]
struct Options {
    point: LogicalPoint,
    armed: bool,
    confirm: Option<String>,
}

impl Options {
    fn parse(args: &[String]) -> Result<Self, Box<dyn std::error::Error>> {
        let mut x = None;
        let mut y = None;
        let mut armed = false;
        let mut confirm = None;
        let mut index = 0;
        while index < args.len() {
            match args[index].as_str() {
                "--x" => {
                    index += 1;
                    x = Some(parse_value(args, index, "--x")?);
                }
                "--y" => {
                    index += 1;
                    y = Some(parse_value(args, index, "--y")?);
                }
                "--confirm" => {
                    index += 1;
                    confirm = Some(parse_string(args, index, "--confirm")?);
                }
                "--armed" => armed = true,
                flag => return Err(format!("unknown option '{flag}'").into()),
            }
            index += 1;
        }

        Ok(Self {
            point: LogicalPoint {
                x: x.ok_or("missing --x")?,
                y: y.ok_or("missing --y")?,
            },
            armed,
            confirm,
        })
    }
}

#[derive(Debug)]
struct DaemonOptions {
    socket_path: String,
    armed: bool,
    confirm: Option<String>,
    viewport: ViewportOffset,
}

impl DaemonOptions {
    fn parse(args: &[String]) -> Result<Self, Box<dyn std::error::Error>> {
        let mut socket_path = DEFAULT_SOCKET_PATH.to_string();
        let mut armed = false;
        let mut confirm = None;
        let mut viewport = ViewportOffset::from_env()?;
        let mut index = 0;
        while index < args.len() {
            match args[index].as_str() {
                "--socket" => {
                    index += 1;
                    socket_path = parse_string(args, index, "--socket")?;
                }
                "--viewport-x" => {
                    index += 1;
                    viewport.x = parse_value(args, index, "--viewport-x")?;
                }
                "--viewport-y" => {
                    index += 1;
                    viewport.y = parse_value(args, index, "--viewport-y")?;
                }
                "--armed" => armed = true,
                "--confirm" => {
                    index += 1;
                    confirm = Some(parse_string(args, index, "--confirm")?);
                }
                flag => return Err(format!("unknown daemon option '{flag}'").into()),
            }
            index += 1;
        }

        Ok(Self {
            socket_path,
            armed,
            confirm,
            viewport,
        })
    }
}

#[derive(Debug, Clone, Copy)]
struct ViewportOffset {
    x: f64,
    y: f64,
}

impl ViewportOffset {
    fn from_env() -> Result<Self, Box<dyn std::error::Error>> {
        Ok(Self {
            x: parse_env_f64("GENESIS_OS_VIEWPORT_X")?.unwrap_or(0.0),
            y: parse_env_f64("GENESIS_OS_VIEWPORT_Y")?.unwrap_or(0.0),
        })
    }

    fn map(self, point: LogicalPoint) -> LogicalPoint {
        LogicalPoint {
            x: point.x + self.x,
            y: point.y + self.y,
        }
    }
}

#[derive(Debug, Deserialize)]
struct DriverRequest {
    request_id: Option<String>,
    action_id: Option<String>,
    act: String,
    x: Option<f64>,
    y: Option<f64>,
}

#[derive(Debug, Serialize)]
struct DriverResponse {
    status: &'static str,
    request_id: Option<String>,
    action_id: Option<String>,
    armed: bool,
    probe: Option<genesis_os_driver::DriverProbe>,
    receipt: Option<DriverReceipt>,
    viewport_offset: Option<LogicalPoint>,
    error: Option<String>,
}

fn run_daemon(options: &DaemonOptions) -> Result<(), Box<dyn std::error::Error>> {
    let socket_path = Path::new(&options.socket_path);
    if socket_path.exists() {
        std::fs::remove_file(socket_path)?;
    }
    let listener = UnixListener::bind(socket_path)?;
    eprintln!(
        "[genesis-os-driver] listening on {} armed={} viewport=({}, {})",
        options.socket_path, options.armed, options.viewport.x, options.viewport.y
    );

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => handle_stream(stream, options.armed, options.viewport),
            Err(error) => eprintln!("[genesis-os-driver] accept failed: {error}"),
        }
    }

    Ok(())
}

fn handle_stream(stream: UnixStream, armed: bool, viewport: ViewportOffset) {
    let Ok(writer) = stream.try_clone() else {
        return;
    };
    let mut writer = writer;
    let reader = BufReader::new(stream);
    let driver = default_driver();

    for line in reader.lines() {
        let response = match line {
            Ok(line) => handle_line(&*driver, &line, armed, viewport),
            Err(error) => DriverResponse {
                status: "error",
                request_id: None,
                action_id: None,
                armed,
                probe: None,
                receipt: None,
                viewport_offset: Some(viewport.point()),
                error: Some(error.to_string()),
            },
        };
        if write_json_line(&mut writer, &response).is_err() {
            break;
        }
    }
}

fn handle_line(
    driver: &dyn genesis_os_driver::GenesisPhysicalDriver,
    line: &str,
    armed: bool,
    viewport: ViewportOffset,
) -> DriverResponse {
    let parsed = serde_json::from_str::<DriverRequest>(line);
    let request = match parsed {
        Ok(request) => request,
        Err(error) => {
            return DriverResponse {
                status: "error",
                request_id: None,
                action_id: None,
                armed,
                probe: None,
                receipt: None,
                viewport_offset: Some(viewport.point()),
                error: Some(format!("invalid request JSON: {error}")),
            };
        }
    };

    let result = match request.act.as_str() {
        "probe" => {
            return DriverResponse {
                status: "ok",
                request_id: request.request_id,
                action_id: request.action_id,
                armed,
                probe: Some(driver.probe()),
                receipt: None,
                viewport_offset: Some(viewport.point()),
                error: None,
            };
        }
        "move_mouse" | "move" => request.point().and_then(|point| {
            driver
                .move_mouse(viewport.map(point), armed)
                .map_err(|error| error.to_string())
        }),
        "click_left" | "click" | "click_point" => request.point().and_then(|point| {
            driver
                .click_left(viewport.map(point), armed)
                .map_err(|error| error.to_string())
        }),
        other => Err(format!("unsupported os-driver act: {other}")),
    };

    match result {
        Ok(receipt) => DriverResponse {
            status: "ok",
            request_id: request.request_id,
            action_id: request.action_id,
            armed,
            probe: None,
            receipt: Some(receipt),
            viewport_offset: Some(viewport.point()),
            error: None,
        },
        Err(error) => DriverResponse {
            status: "error",
            request_id: request.request_id,
            action_id: request.action_id,
            armed,
            probe: None,
            receipt: None,
            viewport_offset: Some(viewport.point()),
            error: Some(error),
        },
    }
}

impl ViewportOffset {
    fn point(self) -> LogicalPoint {
        LogicalPoint {
            x: self.x,
            y: self.y,
        }
    }
}

impl DriverRequest {
    fn point(&self) -> Result<LogicalPoint, String> {
        Ok(LogicalPoint {
            x: self.x.ok_or("missing x")?,
            y: self.y.ok_or("missing y")?,
        })
    }
}

fn write_json_line<T: Serialize>(writer: &mut UnixStream, value: &T) -> Result<(), String> {
    serde_json::to_writer(&mut *writer, value).map_err(|error| error.to_string())?;
    writer.write_all(b"\n").map_err(|error| error.to_string())
}

fn require_armed_confirmation(confirm: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let env_confirm = std::env::var("GENESIS_OS_DRIVER_CONFIRM").ok();
    if confirm == Some(ARMED_CONFIRMATION) || env_confirm.as_deref() == Some(ARMED_CONFIRMATION) {
        Ok(())
    } else {
        Err(format!(
            "armed mode requires --confirm {ARMED_CONFIRMATION} or GENESIS_OS_DRIVER_CONFIRM={ARMED_CONFIRMATION}"
        )
        .into())
    }
}

fn parse_value(
    args: &[String],
    index: usize,
    name: &str,
) -> Result<f64, Box<dyn std::error::Error>> {
    let value = args
        .get(index)
        .ok_or_else(|| format!("{name} requires a value"))?;
    Ok(value.parse::<f64>()?)
}

fn parse_string(
    args: &[String],
    index: usize,
    name: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    args.get(index)
        .cloned()
        .ok_or_else(|| format!("{name} requires a value").into())
}

fn parse_env_f64(name: &str) -> Result<Option<f64>, Box<dyn std::error::Error>> {
    match std::env::var(name) {
        Ok(value) if !value.trim().is_empty() => Ok(Some(value.parse::<f64>()?)),
        Ok(_) | Err(std::env::VarError::NotPresent) => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn center_point(probe: &genesis_os_driver::DriverProbe) -> Option<LogicalPoint> {
    let display = probe.main_display.as_ref()?;
    Some(LogicalPoint {
        x: display.logical_origin_x + display.logical_width / 2.0,
        y: display.logical_origin_y + display.logical_height / 2.0,
    })
}

fn print_json<T: Serialize>(value: &T) {
    println!(
        "{}",
        serde_json::to_string_pretty(value).expect("JSON serialization failed")
    );
}
