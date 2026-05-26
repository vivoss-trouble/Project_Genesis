use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const DEFAULT_SOCKET_PATH: &str = "/tmp/genesis_vision_daemon.sock";
const DEFAULT_HZ: f64 = 10.0;

fn main() {
    if let Err(error) = run() {
        let payload = ErrorPayload {
            status: "error",
            error: error.to_string(),
        };
        println!(
            "{}",
            serde_json::to_string_pretty(&payload)
                .expect("frame grabber error JSON serialization failed")
        );
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "probe".to_string());
    let rest: Vec<String> = args.collect();

    match command.as_str() {
        "probe" => {
            let sample = frame_probe();
            println!(
                "{}",
                serde_json::to_string_pretty(&sample)
                    .expect("frame probe JSON serialization failed")
            );
            if !sample.capture_supported || !sample.screen_capture_allowed {
                std::process::exit(1);
            }
        }
        "daemon" => {
            let options = DaemonOptions::parse(&rest)?;
            run_daemon(&options)?;
        }
        _ => {
            return Err(format!("unknown command '{command}'. Use probe or daemon").into());
        }
    }

    Ok(())
}

#[derive(Debug)]
struct DaemonOptions {
    socket_path: String,
    hz: f64,
}

impl DaemonOptions {
    fn parse(args: &[String]) -> Result<Self, Box<dyn std::error::Error>> {
        let mut socket_path = std::env::var("GENESIS_VISION_SOCKET")
            .unwrap_or_else(|_| DEFAULT_SOCKET_PATH.to_string());
        let mut hz = parse_env_f64("GENESIS_VISION_HZ")?.unwrap_or(DEFAULT_HZ);

        let mut index = 0;
        while index < args.len() {
            match args[index].as_str() {
                "--socket" => {
                    index += 1;
                    socket_path = parse_string(args, index, "--socket")?;
                }
                "--hz" => {
                    index += 1;
                    hz = parse_value(args, index, "--hz")?;
                }
                flag => return Err(format!("unknown daemon option '{flag}'").into()),
            }
            index += 1;
        }

        if !hz.is_finite() || hz <= 0.0 || hz > 120.0 {
            return Err("vision daemon --hz must be finite and within 0..120".into());
        }

        Ok(Self { socket_path, hz })
    }
}

#[derive(Debug, Serialize)]
struct ErrorPayload {
    status: &'static str,
    error: String,
}

#[derive(Debug, Clone, Serialize)]
struct PixelSize {
    width: usize,
    height: usize,
}

#[derive(Debug, Clone, Serialize)]
struct LogicalBounds {
    width: f64,
    height: f64,
}

#[derive(Debug, Clone, Serialize)]
struct FrameState {
    frame_id: u64,
    captured_at_ms: u64,
    served_at_ms: u64,
    backend: &'static str,
    platform: &'static str,
    capture_supported: bool,
    screen_capture_allowed: bool,
    display_id: Option<u32>,
    physical_pixels: Option<PixelSize>,
    logical_bounds: Option<LogicalBounds>,
    scale_factor: Option<f64>,
    scale_x: Option<f64>,
    scale_y: Option<f64>,
    bytes_per_row: Option<usize>,
    bits_per_pixel: Option<usize>,
    capture_latency_ms: f64,
    error: Option<String>,
}

#[derive(Debug, Serialize)]
struct FrameProbe {
    backend: &'static str,
    platform: &'static str,
    capture_supported: bool,
    screen_capture_allowed: bool,
    display_id: Option<u32>,
    pixel_width: Option<usize>,
    pixel_height: Option<usize>,
    logical_width: Option<f64>,
    logical_height: Option<f64>,
    scale_factor: Option<f64>,
    scale_x: Option<f64>,
    scale_y: Option<f64>,
    bytes_per_row: Option<usize>,
    bits_per_pixel: Option<usize>,
    capture_latency_ms: f64,
    error: Option<String>,
}

impl From<FrameState> for FrameProbe {
    fn from(state: FrameState) -> Self {
        Self {
            backend: state.backend,
            platform: state.platform,
            capture_supported: state.capture_supported,
            screen_capture_allowed: state.screen_capture_allowed,
            display_id: state.display_id,
            pixel_width: state.physical_pixels.as_ref().map(|pixels| pixels.width),
            pixel_height: state.physical_pixels.as_ref().map(|pixels| pixels.height),
            logical_width: state.logical_bounds.as_ref().map(|bounds| bounds.width),
            logical_height: state.logical_bounds.as_ref().map(|bounds| bounds.height),
            scale_factor: state.scale_factor,
            scale_x: state.scale_x,
            scale_y: state.scale_y,
            bytes_per_row: state.bytes_per_row,
            bits_per_pixel: state.bits_per_pixel,
            capture_latency_ms: state.capture_latency_ms,
            error: state.error,
        }
    }
}

#[derive(Debug, Deserialize)]
struct VisionRequest {
    request_id: Option<String>,
    act: Option<String>,
}

#[derive(Debug, Serialize)]
struct VisionResponse {
    status: &'static str,
    request_id: Option<String>,
    frame_state: FrameState,
}

#[derive(Debug, Serialize)]
struct VisionErrorResponse {
    status: &'static str,
    request_id: Option<String>,
    error: String,
}

fn run_daemon(options: &DaemonOptions) -> Result<(), Box<dyn std::error::Error>> {
    if Path::new(&options.socket_path).exists() {
        std::fs::remove_file(&options.socket_path)?;
    }

    let listener = UnixListener::bind(&options.socket_path)?;
    let latest = Arc::new(Mutex::new(capture_frame_state(1)));
    let next_frame_id = Arc::new(AtomicU64::new(2));
    spawn_sampler(latest.clone(), next_frame_id, options.hz);

    println!(
        "{}",
        serde_json::to_string(&serde_json::json!({
            "status": "listening",
            "socket": options.socket_path,
            "hz": options.hz,
            "protocol": "genesis-vision-frame-state-v1"
        }))?
    );

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                if let Err(error) = handle_client(stream, latest.clone()) {
                    eprintln!("[genesis-frame-grabber] client error: {error}");
                }
            }
            Err(error) => eprintln!("[genesis-frame-grabber] accept error: {error}"),
        }
    }

    Ok(())
}

fn spawn_sampler(latest: Arc<Mutex<FrameState>>, next_frame_id: Arc<AtomicU64>, hz: f64) {
    let interval = Duration::from_secs_f64(1.0 / hz);
    thread::Builder::new()
        .name("Genesis-Vision-Sampler".to_string())
        .spawn(move || {
            loop {
                thread::sleep(interval);
                let frame_id = next_frame_id.fetch_add(1, Ordering::Relaxed);
                let state = capture_frame_state(frame_id);
                if let Ok(mut guard) = latest.lock() {
                    *guard = state;
                }
            }
        })
        .expect("failed to spawn vision sampler thread");
}

fn handle_client(
    stream: UnixStream,
    latest: Arc<Mutex<FrameState>>,
) -> Result<(), Box<dyn std::error::Error>> {
    let reader_stream = stream.try_clone()?;
    let mut reader = BufReader::new(reader_stream);
    let mut writer = stream;
    let mut line = String::new();

    while reader.read_line(&mut line)? > 0 {
        let raw = line.trim();
        if raw.is_empty() {
            line.clear();
            continue;
        }

        let request: Result<VisionRequest, _> = serde_json::from_str(raw);
        match request {
            Ok(request) if request.is_frame_state_request() => {
                let mut state = latest
                    .lock()
                    .map_err(|_| "vision sampler state lock poisoned")?
                    .clone();
                state.served_at_ms = current_ts();
                let response = VisionResponse {
                    status: "ok",
                    request_id: request.request_id,
                    frame_state: state,
                };
                writeln!(writer, "{}", serde_json::to_string(&response)?)?;
            }
            Ok(request) => {
                let response = VisionErrorResponse {
                    status: "error",
                    request_id: request.request_id,
                    error: "unsupported act; use frame_state, state, or probe".to_string(),
                };
                writeln!(writer, "{}", serde_json::to_string(&response)?)?;
            }
            Err(error) => {
                let response = VisionErrorResponse {
                    status: "error",
                    request_id: None,
                    error: format!("invalid JSON request: {error}"),
                };
                writeln!(writer, "{}", serde_json::to_string(&response)?)?;
            }
        }
        writer.flush()?;
        line.clear();
    }

    Ok(())
}

impl VisionRequest {
    fn is_frame_state_request(&self) -> bool {
        matches!(
            self.act.as_deref().unwrap_or("frame_state"),
            "frame_state" | "state" | "probe"
        )
    }
}

#[cfg(target_os = "macos")]
fn capture_frame_state(frame_id: u64) -> FrameState {
    macos::capture_frame_state(frame_id)
}

#[cfg(not(target_os = "macos"))]
fn capture_frame_state(frame_id: u64) -> FrameState {
    FrameState {
        frame_id,
        captured_at_ms: current_ts(),
        served_at_ms: 0,
        backend: "unsupported",
        platform: std::env::consts::OS,
        capture_supported: false,
        screen_capture_allowed: false,
        display_id: None,
        physical_pixels: None,
        logical_bounds: None,
        scale_factor: None,
        scale_x: None,
        scale_y: None,
        bytes_per_row: None,
        bits_per_pixel: None,
        capture_latency_ms: 0.0,
        error: Some("genesis-frame-grabber currently supports macOS only".to_string()),
    }
}

fn frame_probe() -> FrameProbe {
    capture_frame_state(1).into()
}

fn parse_value<T: std::str::FromStr>(
    args: &[String],
    index: usize,
    flag: &str,
) -> Result<T, Box<dyn std::error::Error>>
where
    T::Err: std::error::Error + 'static,
{
    args.get(index)
        .ok_or_else(|| format!("missing value for {flag}"))?
        .parse::<T>()
        .map_err(|error| Box::new(error) as Box<dyn std::error::Error>)
}

fn parse_string(
    args: &[String],
    index: usize,
    flag: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    Ok(args
        .get(index)
        .ok_or_else(|| format!("missing value for {flag}"))?
        .to_string())
}

fn parse_env_f64(key: &str) -> Result<Option<f64>, Box<dyn std::error::Error>> {
    match std::env::var(key) {
        Ok(value) if !value.trim().is_empty() => Ok(Some(value.parse::<f64>()?)),
        _ => Ok(None),
    }
}

fn current_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{FrameState, Instant, LogicalBounds, PixelSize, current_ts};
    use std::ffi::c_void;

    type CGImageRef = *mut c_void;

    #[repr(C)]
    #[derive(Debug, Clone, Copy)]
    struct CGPoint {
        x: f64,
        y: f64,
    }

    #[repr(C)]
    #[derive(Debug, Clone, Copy)]
    struct CGSize {
        width: f64,
        height: f64,
    }

    #[repr(C)]
    #[derive(Debug, Clone, Copy)]
    struct CGRect {
        origin: CGPoint,
        size: CGSize,
    }

    #[link(name = "ApplicationServices", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(cf: *const c_void);
        fn CGDisplayBounds(display: u32) -> CGRect;
        fn CGDisplayCreateImage(display: u32) -> CGImageRef;
        fn CGDisplayPixelsHigh(display: u32) -> usize;
        fn CGDisplayPixelsWide(display: u32) -> usize;
        fn CGImageGetBitsPerPixel(image: CGImageRef) -> usize;
        fn CGImageGetBytesPerRow(image: CGImageRef) -> usize;
        fn CGImageGetHeight(image: CGImageRef) -> usize;
        fn CGImageGetWidth(image: CGImageRef) -> usize;
        fn CGMainDisplayID() -> u32;
    }

    pub fn capture_frame_state(frame_id: u64) -> FrameState {
        let display_id = unsafe { CGMainDisplayID() };
        let bounds = unsafe { CGDisplayBounds(display_id) };
        let display_pixel_width = unsafe { CGDisplayPixelsWide(display_id) };
        let display_pixel_height = unsafe { CGDisplayPixelsHigh(display_id) };
        let logical_width = bounds.size.width.max(0.0);
        let logical_height = bounds.size.height.max(0.0);
        let scale_x = scale(display_pixel_width, logical_width);
        let scale_y = scale(display_pixel_height, logical_height);
        let scale_factor = match (scale_x, scale_y) {
            (Some(x), Some(y)) => Some((x + y) / 2.0),
            (Some(x), None) => Some(x),
            (None, Some(y)) => Some(y),
            (None, None) => None,
        };

        let start = Instant::now();
        let image = unsafe { CGDisplayCreateImage(display_id) };
        let capture_latency_ms = start.elapsed().as_secs_f64() * 1000.0;
        let captured_at_ms = current_ts();

        if image.is_null() {
            return FrameState {
                frame_id,
                captured_at_ms,
                served_at_ms: 0,
                backend: "macos-coregraphics",
                platform: "macos",
                capture_supported: true,
                screen_capture_allowed: false,
                display_id: Some(display_id),
                physical_pixels: Some(PixelSize {
                    width: display_pixel_width,
                    height: display_pixel_height,
                }),
                logical_bounds: Some(LogicalBounds {
                    width: logical_width,
                    height: logical_height,
                }),
                scale_factor,
                scale_x,
                scale_y,
                bytes_per_row: None,
                bits_per_pixel: None,
                capture_latency_ms,
                error: Some(
                    "CGDisplayCreateImage returned null; Screen Recording permission may be required"
                        .to_string(),
                ),
            };
        }

        let width = unsafe { CGImageGetWidth(image) };
        let height = unsafe { CGImageGetHeight(image) };
        let bytes_per_row = unsafe { CGImageGetBytesPerRow(image) };
        let bits_per_pixel = unsafe { CGImageGetBitsPerPixel(image) };
        unsafe {
            CFRelease(image.cast_const());
        }

        FrameState {
            frame_id,
            captured_at_ms,
            served_at_ms: 0,
            backend: "macos-coregraphics",
            platform: "macos",
            capture_supported: true,
            screen_capture_allowed: true,
            display_id: Some(display_id),
            physical_pixels: Some(PixelSize { width, height }),
            logical_bounds: Some(LogicalBounds {
                width: logical_width,
                height: logical_height,
            }),
            scale_factor,
            scale_x,
            scale_y,
            bytes_per_row: Some(bytes_per_row),
            bits_per_pixel: Some(bits_per_pixel),
            capture_latency_ms,
            error: None,
        }
    }

    fn scale(pixel_size: usize, logical_size: f64) -> Option<f64> {
        if logical_size > 0.0 {
            Some(pixel_size as f64 / logical_size)
        } else {
            None
        }
    }
}
