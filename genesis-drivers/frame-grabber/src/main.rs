use serde::Serialize;
use std::time::Instant;

fn main() {
    let sample = frame_probe();
    println!(
        "{}",
        serde_json::to_string_pretty(&sample).expect("frame probe JSON serialization failed")
    );
    if !sample.capture_supported {
        std::process::exit(1);
    }
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
    bytes_per_row: Option<usize>,
    bits_per_pixel: Option<usize>,
    capture_latency_ms: f64,
    error: Option<String>,
}

#[cfg(target_os = "macos")]
fn frame_probe() -> FrameProbe {
    macos::frame_probe()
}

#[cfg(not(target_os = "macos"))]
fn frame_probe() -> FrameProbe {
    FrameProbe {
        backend: "unsupported",
        platform: std::env::consts::OS,
        capture_supported: false,
        screen_capture_allowed: false,
        display_id: None,
        pixel_width: None,
        pixel_height: None,
        bytes_per_row: None,
        bits_per_pixel: None,
        capture_latency_ms: 0.0,
        error: Some("genesis-frame-grabber currently supports macOS only".to_string()),
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{FrameProbe, Instant};
    use std::ffi::c_void;

    type CGImageRef = *mut c_void;

    #[link(name = "ApplicationServices", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(cf: *const c_void);
        fn CGDisplayCreateImage(display: u32) -> CGImageRef;
        fn CGImageGetBitsPerPixel(image: CGImageRef) -> usize;
        fn CGImageGetBytesPerRow(image: CGImageRef) -> usize;
        fn CGImageGetHeight(image: CGImageRef) -> usize;
        fn CGImageGetWidth(image: CGImageRef) -> usize;
        fn CGMainDisplayID() -> u32;
    }

    pub fn frame_probe() -> FrameProbe {
        let display_id = unsafe { CGMainDisplayID() };
        let start = Instant::now();
        let image = unsafe { CGDisplayCreateImage(display_id) };
        let capture_latency_ms = start.elapsed().as_secs_f64() * 1000.0;

        if image.is_null() {
            return FrameProbe {
                backend: "macos-coregraphics",
                platform: "macos",
                capture_supported: true,
                screen_capture_allowed: false,
                display_id: Some(display_id),
                pixel_width: None,
                pixel_height: None,
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

        FrameProbe {
            backend: "macos-coregraphics",
            platform: "macos",
            capture_supported: true,
            screen_capture_allowed: true,
            display_id: Some(display_id),
            pixel_width: Some(width),
            pixel_height: Some(height),
            bytes_per_row: Some(bytes_per_row),
            bits_per_pixel: Some(bits_per_pixel),
            capture_latency_ms,
            error: None,
        }
    }
}
