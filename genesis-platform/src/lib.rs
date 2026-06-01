use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub mod desktop;
pub mod ipc;
pub mod mobile;
mod remote_http;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    MacOs,
    Linux,
    Windows,
    Ios,
    Android,
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimeProfile {
    DesktopFull,
    DesktopSafe,
    MobileControl,
    MobileLocalLight,
    ServerNode,
    CiRelease,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlatformCapabilities {
    pub subprocess: bool,
    pub local_ipc: bool,
    pub remote_ipc: bool,
    pub local_wasm: bool,
    pub native_plugin: bool,
    pub browser_automation: bool,
    pub background_service: bool,
    pub java_probe: bool,
}

impl PlatformCapabilities {
    pub fn desktop_full() -> Self {
        Self {
            subprocess: true,
            local_ipc: true,
            remote_ipc: true,
            local_wasm: true,
            native_plugin: false,
            browser_automation: true,
            background_service: true,
            java_probe: true,
        }
    }

    pub fn mobile_control() -> Self {
        Self {
            subprocess: false,
            local_ipc: false,
            remote_ipc: true,
            local_wasm: false,
            native_plugin: false,
            browser_automation: false,
            background_service: false,
            java_probe: false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DirectoryKind {
    Data,
    Cache,
    Temp,
    Evidence,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkerSpec {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cwd: Option<PathBuf>,
    pub timeout: Option<Duration>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkerExit {
    pub status_code: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub timed_out: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IpcEndpoint {
    LocalService { name: String },
    LoopbackTcp { host: String, port: u16 },
    RemoteHttp { base_url: String },
}

impl IpcEndpoint {
    pub fn local_service(name: impl Into<String>) -> Result<Self, PlatformError> {
        let name = name.into();
        ipc::validate_service_name(&name)?;
        Ok(Self::LocalService { name })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BrowserRequest {
    pub url: String,
    pub allowed_origins: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PlatformErrorKind {
    UnsupportedCapability,
    InvalidInput,
    PermissionDenied,
    Timeout,
    WouldBlock,
    Io,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlatformError {
    pub kind: PlatformErrorKind,
    pub message: String,
}

impl PlatformError {
    pub fn unsupported(message: impl Into<String>) -> Self {
        Self {
            kind: PlatformErrorKind::UnsupportedCapability,
            message: message.into(),
        }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self {
            kind: PlatformErrorKind::InvalidInput,
            message: message.into(),
        }
    }

    pub fn unavailable(message: impl Into<String>) -> Self {
        Self {
            kind: PlatformErrorKind::Unavailable,
            message: message.into(),
        }
    }

    pub fn io(error: std::io::Error) -> Self {
        let kind = match error.kind() {
            std::io::ErrorKind::PermissionDenied => PlatformErrorKind::PermissionDenied,
            std::io::ErrorKind::TimedOut => PlatformErrorKind::Timeout,
            std::io::ErrorKind::WouldBlock => PlatformErrorKind::WouldBlock,
            _ => PlatformErrorKind::Io,
        };
        Self {
            kind,
            message: error.to_string(),
        }
    }
}

impl fmt::Display for PlatformError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:?}: {}", self.kind, self.message)
    }
}

impl std::error::Error for PlatformError {}

pub trait IpcClient: Send {
    fn send(&mut self, payload: &[u8], timeout: Duration) -> Result<(), PlatformError>;
    fn request(&mut self, payload: &[u8], timeout: Duration) -> Result<Vec<u8>, PlatformError>;
}

pub trait IpcStream: Send {
    fn send(&mut self, payload: &[u8], timeout: Duration) -> Result<(), PlatformError>;
    fn set_nonblocking(&mut self, nonblocking: bool) -> Result<(), PlatformError>;
    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, PlatformError>;
}

pub trait IpcListener: Send {
    fn accept(&self) -> Result<Box<dyn IpcStream>, PlatformError>;
}

pub trait PlatformAdapter: Send + Sync {
    fn platform(&self) -> Platform;
    fn profile(&self) -> RuntimeProfile;
    fn capabilities(&self) -> PlatformCapabilities;

    fn resolve_dir(&self, kind: DirectoryKind) -> Result<PathBuf, PlatformError>;
    fn ensure_private_dir(&self, path: &Path) -> Result<(), PlatformError>;
    fn current_dir(&self) -> Result<PathBuf, PlatformError> {
        Err(PlatformError::unsupported(
            "current directory is not supported by this adapter",
        ))
    }
    fn read_dir_paths(&self, _path: &Path) -> Result<Vec<PathBuf>, PlatformError> {
        Err(PlatformError::unsupported(
            "directory listing is not supported by this adapter",
        ))
    }
    fn read_file(&self, _path: &Path) -> Result<Vec<u8>, PlatformError> {
        Err(PlatformError::unsupported(
            "file reads are not supported by this adapter",
        ))
    }
    fn copy_file(&self, _source: &Path, _destination: &Path) -> Result<u64, PlatformError> {
        Err(PlatformError::unsupported(
            "file copy is not supported by this adapter",
        ))
    }
    fn path_exists(&self, _path: &Path) -> Result<bool, PlatformError> {
        Err(PlatformError::unsupported(
            "path existence checks are not supported by this adapter",
        ))
    }
    fn set_current_dir(&self, _path: &Path) -> Result<(), PlatformError> {
        Err(PlatformError::unsupported(
            "current directory mutation is not supported by this adapter",
        ))
    }

    fn now_unix_ms(&self) -> u64;
    fn monotonic_ms(&self) -> u64;

    fn run_worker(&self, spec: WorkerSpec) -> Result<WorkerExit, PlatformError>;
    fn local_service_address(
        &self,
        service_name: &str,
    ) -> Result<ipc::LocalServiceAddress, PlatformError> {
        let runtime_dir = self.resolve_dir(DirectoryKind::Temp)?;
        ipc::LocalServiceResolver::new(self.platform(), runtime_dir).resolve(service_name)
    }
    fn connect_ipc(&self, endpoint: IpcEndpoint) -> Result<Box<dyn IpcClient>, PlatformError>;
    fn connect_ipc_with_timeout(
        &self,
        endpoint: IpcEndpoint,
        _timeout: Duration,
    ) -> Result<Box<dyn IpcClient>, PlatformError> {
        self.connect_ipc(endpoint)
    }
    fn connect_streaming_ipc_with_timeout(
        &self,
        _endpoint: IpcEndpoint,
        _timeout: Duration,
    ) -> Result<Box<dyn IpcStream>, PlatformError> {
        Err(PlatformError::unsupported(
            "streaming IPC is not supported by this adapter",
        ))
    }
    fn bind_local_service(
        &self,
        _service_name: &str,
    ) -> Result<Box<dyn IpcListener>, PlatformError> {
        Err(PlatformError::unsupported(
            "local service listener is not supported by this adapter",
        ))
    }
    fn http_get(
        &self,
        _url: &str,
        _timeout: Duration,
        _max_response_body: usize,
    ) -> Result<Vec<u8>, PlatformError> {
        Err(PlatformError::unsupported(
            "HTTP GET is not supported by this adapter",
        ))
    }
    fn open_browser(&self, request: BrowserRequest) -> Result<(), PlatformError>;
}

pub fn current_platform() -> Platform {
    if cfg!(target_os = "macos") {
        Platform::MacOs
    } else if cfg!(target_os = "linux") {
        Platform::Linux
    } else if cfg!(target_os = "windows") {
        Platform::Windows
    } else if cfg!(target_os = "ios") {
        Platform::Ios
    } else if cfg!(target_os = "android") {
        Platform::Android
    } else {
        Platform::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mobile_control_is_remote_only_by_default() {
        let caps = PlatformCapabilities::mobile_control();

        assert!(!caps.subprocess);
        assert!(!caps.local_ipc);
        assert!(caps.remote_ipc);
        assert!(!caps.native_plugin);
        assert!(!caps.java_probe);
    }

    #[test]
    fn contract_uses_intent_level_ipc_names() {
        let endpoint = IpcEndpoint::local_service("genesis-brain").unwrap();

        assert_eq!(
            endpoint,
            IpcEndpoint::LocalService {
                name: "genesis-brain".to_string()
            }
        );
    }

    #[test]
    fn platform_error_is_a_standard_error() {
        let err = PlatformError::invalid("bad service");
        let as_error: &dyn std::error::Error = &err;

        assert_eq!(as_error.to_string(), "InvalidInput: bad service");
    }

    #[test]
    fn local_service_rejects_paths_and_platform_syntax() {
        assert!(IpcEndpoint::local_service("/tmp/genesis.sock").is_err());
        assert!(IpcEndpoint::local_service(r"\\.\pipe\genesis").is_err());
        assert!(IpcEndpoint::local_service("").is_err());
    }
}
