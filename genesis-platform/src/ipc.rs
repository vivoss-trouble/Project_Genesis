use crate::{Platform, PlatformError};
use std::path::PathBuf;

pub const SERVICE_BRAIN: &str = "genesis-brain";
pub const SERVICE_WEB_ACT: &str = "genesis-web-act";
pub const SERVICE_DYNAMIC_ACT: &str = "genesis-dynamic-act";
pub const SERVICE_OS_DRIVER: &str = "genesis-os-driver";
pub const SERVICE_VISION: &str = "genesis-vision";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LocalServiceAddress {
    UnixSocket(PathBuf),
    WindowsNamedPipe(String),
    LoopbackTcp { host: String, port: u16 },
    Unsupported,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalServiceResolver {
    platform: Platform,
    runtime_dir: PathBuf,
}

impl LocalServiceResolver {
    pub fn new(platform: Platform, runtime_dir: PathBuf) -> Self {
        Self {
            platform,
            runtime_dir,
        }
    }

    pub fn resolve(&self, service_name: &str) -> Result<LocalServiceAddress, PlatformError> {
        validate_service_name(service_name)?;
        let address = match self.platform {
            Platform::MacOs | Platform::Linux => LocalServiceAddress::UnixSocket(
                self.runtime_dir
                    .join(legacy_unix_socket_file(service_name)?),
            ),
            Platform::Windows => {
                LocalServiceAddress::WindowsNamedPipe(format!(r"\\.\pipe\{service_name}"))
            }
            Platform::Ios | Platform::Android => LocalServiceAddress::Unsupported,
            Platform::Unknown => LocalServiceAddress::Unsupported,
        };
        Ok(address)
    }
}

pub fn legacy_unix_socket_file(service_name: &str) -> Result<&'static str, PlatformError> {
    validate_service_name(service_name)?;
    match service_name {
        SERVICE_BRAIN => Ok("genesis_brain.sock"),
        SERVICE_WEB_ACT => Ok("genesis_act.sock"),
        SERVICE_DYNAMIC_ACT => Ok("genesis_dynamic_act.sock"),
        SERVICE_OS_DRIVER => Ok("genesis_os_driver.sock"),
        SERVICE_VISION => Ok("genesis_vision_daemon.sock"),
        _ => Err(PlatformError::invalid(format!(
            "unknown Genesis local service: {service_name}"
        ))),
    }
}

pub fn validate_service_name(service_name: &str) -> Result<(), PlatformError> {
    let valid = !service_name.is_empty()
        && service_name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'));
    if valid {
        Ok(())
    } else {
        Err(PlatformError::invalid(
            "local service names must use ascii letters, digits, '-' or '_'",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unix_platforms_resolve_service_to_runtime_socket() {
        let resolver =
            LocalServiceResolver::new(Platform::MacOs, PathBuf::from("/run/user/genesis"));

        assert_eq!(
            resolver.resolve(SERVICE_BRAIN).unwrap(),
            LocalServiceAddress::UnixSocket(PathBuf::from("/run/user/genesis/genesis_brain.sock"))
        );
    }

    #[test]
    fn unix_socket_files_preserve_current_daemon_names() {
        assert_eq!(
            legacy_unix_socket_file(SERVICE_BRAIN).unwrap(),
            "genesis_brain.sock"
        );
        assert_eq!(
            legacy_unix_socket_file(SERVICE_WEB_ACT).unwrap(),
            "genesis_act.sock"
        );
        assert_eq!(
            legacy_unix_socket_file(SERVICE_DYNAMIC_ACT).unwrap(),
            "genesis_dynamic_act.sock"
        );
        assert_eq!(
            legacy_unix_socket_file(SERVICE_OS_DRIVER).unwrap(),
            "genesis_os_driver.sock"
        );
        assert_eq!(
            legacy_unix_socket_file(SERVICE_VISION).unwrap(),
            "genesis_vision_daemon.sock"
        );
    }

    #[test]
    fn windows_resolves_service_to_named_pipe_without_leaking_to_contract() {
        let resolver = LocalServiceResolver::new(Platform::Windows, PathBuf::from("ignored"));

        assert_eq!(
            resolver.resolve(SERVICE_WEB_ACT).unwrap(),
            LocalServiceAddress::WindowsNamedPipe(r"\\.\pipe\genesis-web-act".to_string())
        );
    }

    #[test]
    fn mobile_local_service_is_explicitly_unsupported() {
        let resolver = LocalServiceResolver::new(Platform::Ios, PathBuf::from("/app/tmp"));

        assert_eq!(
            resolver.resolve(SERVICE_DYNAMIC_ACT).unwrap(),
            LocalServiceAddress::Unsupported
        );
    }

    #[test]
    fn service_names_reject_paths_and_pipe_syntax() {
        assert!(validate_service_name(SERVICE_BRAIN).is_ok());
        assert!(validate_service_name("/tmp/genesis.sock").is_err());
        assert!(validate_service_name(r"\\.\pipe\genesis").is_err());
    }
}
