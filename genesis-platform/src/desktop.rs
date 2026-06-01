use crate::{
    BrowserRequest, DirectoryKind, IpcClient, IpcEndpoint, IpcListener, IpcStream, Platform,
    PlatformAdapter, PlatformCapabilities, PlatformError, RuntimeProfile, WorkerExit, WorkerSpec,
    current_platform,
    ipc::{LocalServiceAddress, LocalServiceResolver},
    remote_http,
};
mod browser;
pub mod loopback_http;
mod loopback_tcp;
mod roots;
mod unix_socket;
mod windows_pipe;
mod worker;

use std::fs;
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug)]
pub struct DesktopPlatformAdapter {
    platform: Platform,
    profile: RuntimeProfile,
    data_root: PathBuf,
    cache_root: PathBuf,
    temp_root: PathBuf,
}

impl DesktopPlatformAdapter {
    pub fn legacy_runtime(profile: RuntimeProfile) -> Self {
        let runtime_dir = std::env::temp_dir();
        Self::with_roots(
            current_platform(),
            profile,
            runtime_dir.clone(),
            runtime_dir.clone(),
            runtime_dir,
        )
    }

    pub fn current(
        app_id: impl AsRef<str>,
        profile: RuntimeProfile,
    ) -> Result<Self, PlatformError> {
        let app_id = app_id.as_ref();
        if app_id.trim().is_empty() {
            return Err(PlatformError::invalid("app_id cannot be empty"));
        }

        let roots = roots::for_app(app_id)?;

        Ok(Self {
            platform: current_platform(),
            profile,
            data_root: roots.data_root,
            cache_root: roots.cache_root,
            temp_root: roots.temp_root,
        })
    }

    pub fn with_roots(
        platform: Platform,
        profile: RuntimeProfile,
        data_root: PathBuf,
        cache_root: PathBuf,
        temp_root: PathBuf,
    ) -> Self {
        Self {
            platform,
            profile,
            data_root,
            cache_root,
            temp_root,
        }
    }

    pub fn local_service_address(
        &self,
        service_name: &str,
    ) -> Result<LocalServiceAddress, PlatformError> {
        let runtime_dir = self.resolve_dir(DirectoryKind::Temp)?;
        LocalServiceResolver::new(self.platform, runtime_dir).resolve(service_name)
    }
}

impl PlatformAdapter for DesktopPlatformAdapter {
    fn platform(&self) -> Platform {
        self.platform
    }

    fn profile(&self) -> RuntimeProfile {
        self.profile
    }

    fn capabilities(&self) -> PlatformCapabilities {
        let mut caps = PlatformCapabilities::desktop_full();
        caps.native_plugin = matches!(
            self.profile,
            RuntimeProfile::DesktopFull | RuntimeProfile::ServerNode
        );
        caps
    }

    fn resolve_dir(&self, kind: DirectoryKind) -> Result<PathBuf, PlatformError> {
        let path = match kind {
            DirectoryKind::Data => self.data_root.clone(),
            DirectoryKind::Cache => self.cache_root.clone(),
            DirectoryKind::Temp => self.temp_root.clone(),
            DirectoryKind::Evidence => self.data_root.join("evidence"),
        };
        Ok(path)
    }

    fn ensure_private_dir(&self, path: &Path) -> Result<(), PlatformError> {
        fs::create_dir_all(path).map_err(PlatformError::io)
    }

    fn current_dir(&self) -> Result<PathBuf, PlatformError> {
        std::env::current_dir().map_err(PlatformError::io)
    }

    fn read_dir_paths(&self, path: &Path) -> Result<Vec<PathBuf>, PlatformError> {
        fs::read_dir(path)
            .map_err(PlatformError::io)?
            .map(|entry| entry.map(|entry| entry.path()).map_err(PlatformError::io))
            .collect()
    }

    fn read_file(&self, path: &Path) -> Result<Vec<u8>, PlatformError> {
        fs::read(path).map_err(PlatformError::io)
    }

    fn copy_file(&self, source: &Path, destination: &Path) -> Result<u64, PlatformError> {
        fs::copy(source, destination).map_err(PlatformError::io)
    }

    fn path_exists(&self, path: &Path) -> Result<bool, PlatformError> {
        Ok(path.exists())
    }

    fn set_current_dir(&self, path: &Path) -> Result<(), PlatformError> {
        std::env::set_current_dir(path).map_err(PlatformError::io)
    }

    fn now_unix_ms(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis() as u64)
            .unwrap_or_default()
    }

    fn monotonic_ms(&self) -> u64 {
        static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
        START.get_or_init(Instant::now).elapsed().as_millis() as u64
    }

    fn run_worker(&self, spec: WorkerSpec) -> Result<WorkerExit, PlatformError> {
        if !self.capabilities().subprocess {
            return Err(PlatformError::unsupported("subprocess is not available"));
        }
        worker::run(spec)
    }

    fn connect_ipc(&self, endpoint: IpcEndpoint) -> Result<Box<dyn IpcClient>, PlatformError> {
        self.connect_ipc_endpoint(endpoint, None)
    }

    fn connect_ipc_with_timeout(
        &self,
        endpoint: IpcEndpoint,
        timeout: Duration,
    ) -> Result<Box<dyn IpcClient>, PlatformError> {
        self.connect_ipc_endpoint(endpoint, Some(timeout))
    }

    fn connect_streaming_ipc_with_timeout(
        &self,
        endpoint: IpcEndpoint,
        timeout: Duration,
    ) -> Result<Box<dyn IpcStream>, PlatformError> {
        self.connect_streaming_ipc_endpoint(endpoint, Some(timeout))
    }

    fn bind_local_service(
        &self,
        service_name: &str,
    ) -> Result<Box<dyn IpcListener>, PlatformError> {
        let address = self.local_service_address(service_name)?;
        bind_local_service_address(address)
    }

    fn http_get(
        &self,
        url: &str,
        timeout: Duration,
        max_response_body: usize,
    ) -> Result<Vec<u8>, PlatformError> {
        remote_http::get(url, timeout, max_response_body)
    }

    fn open_browser(&self, request: BrowserRequest) -> Result<(), PlatformError> {
        if !request.url.starts_with("http://") && !request.url.starts_with("https://") {
            return Err(PlatformError::invalid("browser URL must be http(s)"));
        }
        browser::open_url(&request.url)
    }
}

impl DesktopPlatformAdapter {
    fn connect_ipc_endpoint(
        &self,
        endpoint: IpcEndpoint,
        timeout: Option<Duration>,
    ) -> Result<Box<dyn IpcClient>, PlatformError> {
        match endpoint {
            IpcEndpoint::LocalService { name } => {
                let address = self.local_service_address(&name)?;
                connect_local_service(address, timeout)
            }
            IpcEndpoint::LoopbackTcp { host, port } => loopback_tcp::connect(&host, port, timeout),
            IpcEndpoint::RemoteHttp { base_url } => remote_http::connect(base_url, timeout),
        }
    }

    fn connect_streaming_ipc_endpoint(
        &self,
        endpoint: IpcEndpoint,
        timeout: Option<Duration>,
    ) -> Result<Box<dyn IpcStream>, PlatformError> {
        match endpoint {
            IpcEndpoint::LocalService { name } => {
                let address = self.local_service_address(&name)?;
                connect_streaming_local_service(address, timeout)
            }
            IpcEndpoint::LoopbackTcp { host, port } => {
                loopback_tcp::connect_streaming(&host, port, timeout)
            }
            IpcEndpoint::RemoteHttp { .. } => Err(PlatformError::unsupported(
                "Remote HTTP IPC is request/response only",
            )),
        }
    }
}

fn connect_local_service(
    address: LocalServiceAddress,
    timeout: Option<Duration>,
) -> Result<Box<dyn IpcClient>, PlatformError> {
    match address {
        LocalServiceAddress::UnixSocket(path) => unix_socket::connect(path, timeout),
        LocalServiceAddress::LoopbackTcp { host, port } => {
            loopback_tcp::connect(&host, port, timeout)
        }
        LocalServiceAddress::WindowsNamedPipe(pipe_name) => {
            windows_pipe::connect(pipe_name, timeout)
        }
        LocalServiceAddress::Unsupported => Err(PlatformError::unsupported(
            "local service IPC is not supported on this platform",
        )),
    }
}

fn connect_streaming_local_service(
    address: LocalServiceAddress,
    timeout: Option<Duration>,
) -> Result<Box<dyn IpcStream>, PlatformError> {
    match address {
        LocalServiceAddress::UnixSocket(path) => unix_socket::connect_streaming(path, timeout),
        LocalServiceAddress::LoopbackTcp { host, port } => {
            loopback_tcp::connect_streaming(&host, port, timeout)
        }
        LocalServiceAddress::WindowsNamedPipe(pipe_name) => {
            windows_pipe::connect_streaming(pipe_name, timeout)
        }
        LocalServiceAddress::Unsupported => Err(PlatformError::unsupported(
            "local streaming IPC is not supported on this platform",
        )),
    }
}

fn bind_local_service_address(
    address: LocalServiceAddress,
) -> Result<Box<dyn IpcListener>, PlatformError> {
    match address {
        LocalServiceAddress::UnixSocket(path) => unix_socket::bind(path),
        LocalServiceAddress::LoopbackTcp { .. } => Err(PlatformError::unsupported(
            "loopback TCP service listener is not implemented yet",
        )),
        LocalServiceAddress::WindowsNamedPipe(pipe_name) => windows_pipe::bind(pipe_name),
        LocalServiceAddress::Unsupported => Err(PlatformError::unsupported(
            "local service listener is not supported on this platform",
        )),
    }
}

pub fn connect_legacy_socket_path_with_timeout(
    path: &str,
    timeout: Duration,
) -> Result<Box<dyn IpcStream>, PlatformError> {
    unix_socket::connect_streaming_path(path, timeout)
}

pub fn bind_legacy_socket_path(path: &str) -> Result<Box<dyn IpcListener>, PlatformError> {
    unix_socket::bind_path(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::SERVICE_BRAIN;
    use std::collections::BTreeMap;

    #[test]
    fn desktop_adapter_resolves_evidence_under_data_root() {
        let adapter = DesktopPlatformAdapter::with_roots(
            Platform::MacOs,
            RuntimeProfile::DesktopSafe,
            PathBuf::from("/data/genesis"),
            PathBuf::from("/cache/genesis"),
            PathBuf::from("/tmp/genesis"),
        );

        assert_eq!(
            adapter.resolve_dir(DirectoryKind::Evidence).unwrap(),
            PathBuf::from("/data/genesis/evidence")
        );
        assert!(!adapter.capabilities().native_plugin);
    }

    #[test]
    fn desktop_worker_timeout_is_observable() {
        let adapter = DesktopPlatformAdapter::with_roots(
            current_platform(),
            RuntimeProfile::DesktopSafe,
            PathBuf::from("/data"),
            PathBuf::from("/cache"),
            PathBuf::from("/tmp"),
        );
        let spec = WorkerSpec {
            program: script_program(),
            args: script_args("sleep 1"),
            env: BTreeMap::new(),
            cwd: None,
            timeout: Some(Duration::from_millis(10)),
        };

        let exit = adapter.run_worker(spec).unwrap();
        assert!(exit.timed_out);
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn desktop_adapter_binds_local_service_without_exposing_unix_type() {
        let runtime_dir = test_runtime_dir("gp-bind");
        let _ = fs::remove_dir_all(&runtime_dir);
        fs::create_dir_all(&runtime_dir).expect("runtime dir");

        let adapter = DesktopPlatformAdapter::with_roots(
            Platform::MacOs,
            RuntimeProfile::DesktopSafe,
            PathBuf::from("/data"),
            PathBuf::from("/cache"),
            runtime_dir.clone(),
        );
        let listener = adapter
            .bind_local_service(SERVICE_BRAIN)
            .expect("bind local service");

        let server = thread::spawn(move || {
            let mut stream = listener.accept().expect("accept");
            let mut request = [0_u8; 6];
            stream.read(&mut request).expect("read request");
            assert_eq!(&request, b"bind?\n");
            stream
                .send(b"bound\n", Duration::from_secs(1))
                .expect("send response");
        });

        let mut client = adapter
            .connect_streaming_ipc_with_timeout(
                IpcEndpoint::local_service(SERVICE_BRAIN).unwrap(),
                Duration::from_secs(1),
            )
            .expect("connect streaming local service");
        client
            .send(b"bind?\n", Duration::from_secs(1))
            .expect("client send");

        let mut response = [0_u8; 6];
        client.read(&mut response).expect("read response");
        assert_eq!(&response, b"bound\n");

        server.join().expect("server thread");
        let _ = fs::remove_dir_all(runtime_dir);
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    fn test_runtime_dir(prefix: &str) -> PathBuf {
        let temp_root = if PathBuf::from("/private/tmp").is_dir() {
            PathBuf::from("/private/tmp")
        } else {
            std::env::temp_dir()
        };
        temp_root.join(format!("{prefix}-{}", std::process::id()))
    }

    #[cfg(windows)]
    fn script_program() -> PathBuf {
        PathBuf::from("cmd")
    }

    #[cfg(windows)]
    fn script_args(script: &str) -> Vec<String> {
        vec!["/C".to_string(), script.to_string()]
    }

    #[cfg(not(windows))]
    fn script_program() -> PathBuf {
        PathBuf::from("sh")
    }

    #[cfg(not(windows))]
    fn script_args(script: &str) -> Vec<String> {
        vec!["-c".to_string(), script.to_string()]
    }
}
