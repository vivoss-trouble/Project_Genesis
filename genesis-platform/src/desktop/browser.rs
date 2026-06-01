use crate::PlatformError;

#[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
use std::process::Command;

#[cfg(target_os = "macos")]
pub(super) fn open_url(url: &str) -> Result<(), PlatformError> {
    Command::new("open")
        .arg(url)
        .status()
        .map_err(PlatformError::io)
        .and_then(|status| {
            if status.success() {
                Ok(())
            } else {
                Err(PlatformError::unavailable("open command failed"))
            }
        })
}

#[cfg(target_os = "linux")]
pub(super) fn open_url(url: &str) -> Result<(), PlatformError> {
    Command::new("xdg-open")
        .arg(url)
        .status()
        .map_err(PlatformError::io)
        .and_then(|status| {
            if status.success() {
                Ok(())
            } else {
                Err(PlatformError::unavailable("xdg-open command failed"))
            }
        })
}

#[cfg(target_os = "windows")]
pub(super) fn open_url(url: &str) -> Result<(), PlatformError> {
    Command::new("cmd")
        .args(["/C", "start", "", url])
        .status()
        .map_err(PlatformError::io)
        .and_then(|status| {
            if status.success() {
                Ok(())
            } else {
                Err(PlatformError::unavailable("start command failed"))
            }
        })
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
pub(super) fn open_url(_: &str) -> Result<(), PlatformError> {
    Err(PlatformError::unsupported(
        "open_browser is not supported on this target",
    ))
}
