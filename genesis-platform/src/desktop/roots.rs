use crate::{Platform, PlatformError, PlatformErrorKind, current_platform};
use std::path::PathBuf;

pub(super) struct DesktopRoots {
    pub data_root: PathBuf,
    pub cache_root: PathBuf,
    pub temp_root: PathBuf,
}

pub(super) fn for_app(app_id: &str) -> Result<DesktopRoots, PlatformError> {
    let home = home_dir()?;
    let temp_root = std::env::temp_dir().join(app_id);
    let (data_root, cache_root) = match current_platform() {
        Platform::MacOs => (
            home.join("Library")
                .join("Application Support")
                .join(app_id),
            home.join("Library").join("Caches").join(app_id),
        ),
        Platform::Windows => {
            let local = std::env::var_os("LOCALAPPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join("AppData").join("Local"));
            (
                local.join(app_id).join("Data"),
                local.join(app_id).join("Cache"),
            )
        }
        _ => (
            std::env::var_os("XDG_DATA_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".local").join("share"))
                .join(app_id),
            std::env::var_os("XDG_CACHE_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".cache"))
                .join(app_id),
        ),
    };

    Ok(DesktopRoots {
        data_root,
        cache_root,
        temp_root,
    })
}

fn home_dir() -> Result<PathBuf, PlatformError> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .ok_or_else(|| PlatformError {
            kind: PlatformErrorKind::Unavailable,
            message: "home directory is unavailable".to_string(),
        })
}
