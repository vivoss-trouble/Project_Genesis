use genesis_platform::{
    DirectoryKind, IpcEndpoint, Platform, PlatformAdapter, PlatformCapabilities, PlatformError,
    PlatformErrorKind, RuntimeProfile, ipc::LocalServiceAddress,
};
use std::fmt;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

pub const GENESIS_SDK_SHELL_ABI_VERSION: u32 = 1;
pub const GENESIS_SDK_SHELL_CONTRACT_EPOCH: &str = "genesis-sdk-shell-v1";
pub const SDK_MAX_EVIDENCE_LIST_LIMIT: usize = 256;
pub const SDK_MAX_EVIDENCE_PAGE_BYTES: usize = 64 * 1024;

pub const SHELL_API_METHODS: &[ShellApiMethod] = &[
    ShellApiMethod::Health,
    ShellApiMethod::EvidenceRoot,
    ShellApiMethod::ListEvidence,
    ShellApiMethod::ReadEvidencePage,
    ShellApiMethod::RunJob,
    ShellApiMethod::JobStatus,
    ShellApiMethod::LoadWasmArtifact,
    ShellApiMethod::RequestLocalService,
    ShellApiMethod::SendLocalService,
    ShellApiMethod::RequestRemoteHttp,
    ShellApiMethod::SendRemoteHttp,
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShellApiMethod {
    Health,
    EvidenceRoot,
    ListEvidence,
    ReadEvidencePage,
    RunJob,
    JobStatus,
    LoadWasmArtifact,
    RequestLocalService,
    SendLocalService,
    RequestRemoteHttp,
    SendRemoteHttp,
}

impl ShellApiMethod {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Health => "health",
            Self::EvidenceRoot => "evidence_root",
            Self::ListEvidence => "list_evidence",
            Self::ReadEvidencePage => "read_evidence_page",
            Self::RunJob => "run_job",
            Self::JobStatus => "job_status",
            Self::LoadWasmArtifact => "load_wasm_artifact",
            Self::RequestLocalService => "request_local_service",
            Self::SendLocalService => "send_local_service",
            Self::RequestRemoteHttp => "request_remote_http",
            Self::SendRemoteHttp => "send_remote_http",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SdkShellContract {
    pub abi_version: u32,
    pub epoch: &'static str,
    pub methods: &'static [ShellApiMethod],
}

pub fn sdk_shell_contract() -> SdkShellContract {
    SdkShellContract {
        abi_version: GENESIS_SDK_SHELL_ABI_VERSION,
        epoch: GENESIS_SDK_SHELL_CONTRACT_EPOCH,
        methods: SHELL_API_METHODS,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SdkErrorKind {
    Unsupported,
    InvalidInput,
    PermissionDenied,
    Timeout,
    WouldBlock,
    Io,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SdkError {
    pub kind: SdkErrorKind,
    pub message: String,
}

impl SdkError {
    pub fn unsupported(message: impl Into<String>) -> Self {
        Self {
            kind: SdkErrorKind::Unsupported,
            message: message.into(),
        }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self {
            kind: SdkErrorKind::InvalidInput,
            message: message.into(),
        }
    }
}

impl From<PlatformError> for SdkError {
    fn from(error: PlatformError) -> Self {
        let kind = match error.kind {
            PlatformErrorKind::UnsupportedCapability => SdkErrorKind::Unsupported,
            PlatformErrorKind::InvalidInput => SdkErrorKind::InvalidInput,
            PlatformErrorKind::PermissionDenied => SdkErrorKind::PermissionDenied,
            PlatformErrorKind::Timeout => SdkErrorKind::Timeout,
            PlatformErrorKind::WouldBlock => SdkErrorKind::WouldBlock,
            PlatformErrorKind::Io => SdkErrorKind::Io,
            PlatformErrorKind::Unavailable => SdkErrorKind::Unavailable,
        };
        Self {
            kind,
            message: error.message,
        }
    }
}

impl fmt::Display for SdkError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:?}: {}", self.kind, self.message)
    }
}

impl std::error::Error for SdkError {}

pub struct GenesisSdk<A: PlatformAdapter> {
    adapter: A,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SdkHealth {
    pub platform: Platform,
    pub profile: RuntimeProfile,
    pub capabilities: PlatformCapabilities,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JobRequest {
    pub goal: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JobId(pub String);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum JobStatus {
    Queued,
    Running,
    Completed,
    Failed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArtifactId(pub String);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EvidencePack {
    pub root: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EvidenceListPage {
    pub root: PathBuf,
    pub offset: usize,
    pub limit: usize,
    pub entries: Vec<PathBuf>,
    pub next_offset: Option<usize>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EvidenceBytesPage {
    pub relative_path: PathBuf,
    pub offset: usize,
    pub total_bytes: usize,
    pub bytes: Vec<u8>,
    pub next_offset: Option<usize>,
}

impl<A: PlatformAdapter> GenesisSdk<A> {
    pub fn new(adapter: A) -> Self {
        Self { adapter }
    }

    pub fn shell_contract() -> SdkShellContract {
        sdk_shell_contract()
    }

    pub fn contract(&self) -> SdkShellContract {
        sdk_shell_contract()
    }

    /// Shell-facing API.
    pub fn health(&self) -> SdkHealth {
        SdkHealth {
            platform: self.adapter.platform(),
            profile: self.adapter.profile(),
            capabilities: self.adapter.capabilities(),
        }
    }

    /// Shell-facing API.
    pub fn run_job(&self, _request: JobRequest) -> Result<JobId, SdkError> {
        Err(SdkError::from(PlatformError::unsupported(
            "GenesisSdk::run_job is not wired to genesis-core yet",
        )))
    }

    /// Shell-facing API.
    pub fn job_status(&self, _job_id: &JobId) -> Result<JobStatus, SdkError> {
        Err(SdkError::from(PlatformError::unsupported(
            "GenesisSdk::job_status is not wired to genesis-core yet",
        )))
    }

    /// Shell-facing API.
    pub fn load_wasm_artifact(&self, bytes: &[u8]) -> Result<ArtifactId, SdkError> {
        if !self.adapter.capabilities().local_wasm {
            return Err(SdkError::from(PlatformError::unsupported(
                "local Wasm artifact execution is not available on this platform",
            )));
        }
        if bytes.is_empty() {
            return Err(SdkError::from(PlatformError::invalid(
                "artifact bytes cannot be empty",
            )));
        }
        Err(SdkError::from(PlatformError::unsupported(
            "GenesisSdk::load_wasm_artifact is not wired to genesis-core yet",
        )))
    }

    /// Shell-facing API.
    pub fn evidence_root(&self) -> Result<EvidencePack, SdkError> {
        Ok(EvidencePack {
            root: self
                .adapter
                .resolve_dir(DirectoryKind::Evidence)
                .map_err(SdkError::from)?,
        })
    }

    /// Shell-facing API.
    pub fn list_evidence(&self, offset: usize, limit: usize) -> Result<EvidenceListPage, SdkError> {
        if limit == 0 {
            return Err(SdkError::invalid("evidence list limit cannot be zero"));
        }
        if limit > SDK_MAX_EVIDENCE_LIST_LIMIT {
            return Err(SdkError::invalid(format!(
                "evidence list limit cannot exceed {SDK_MAX_EVIDENCE_LIST_LIMIT}"
            )));
        }

        let root = self
            .adapter
            .resolve_dir(DirectoryKind::Evidence)
            .map_err(SdkError::from)?;
        let mut entries = self
            .adapter
            .read_dir_paths(&root)
            .map_err(SdkError::from)?
            .into_iter()
            .map(|path| relative_evidence_path(&root, &path))
            .collect::<Result<Vec<_>, _>>()?;
        entries.sort();

        let total = entries.len();
        let page = entries
            .into_iter()
            .skip(offset)
            .take(limit)
            .collect::<Vec<_>>();
        let next_offset = offset
            .checked_add(page.len())
            .filter(|next_offset| *next_offset < total);

        Ok(EvidenceListPage {
            root,
            offset,
            limit,
            entries: page,
            next_offset,
        })
    }

    /// Shell-facing API.
    pub fn read_evidence_page(
        &self,
        relative_path: &str,
        offset: usize,
        limit: usize,
    ) -> Result<EvidenceBytesPage, SdkError> {
        if limit == 0 {
            return Err(SdkError::invalid("evidence page limit cannot be zero"));
        }
        if limit > SDK_MAX_EVIDENCE_PAGE_BYTES {
            return Err(SdkError::invalid(format!(
                "evidence page limit cannot exceed {SDK_MAX_EVIDENCE_PAGE_BYTES}"
            )));
        }

        let root = self
            .adapter
            .resolve_dir(DirectoryKind::Evidence)
            .map_err(SdkError::from)?;
        let relative_path = validate_relative_evidence_path(relative_path)?;
        let absolute_path = root.join(&relative_path);
        let data = self
            .adapter
            .read_file(&absolute_path)
            .map_err(SdkError::from)?;
        let total_bytes = data.len();
        let bytes = data
            .into_iter()
            .skip(offset)
            .take(limit)
            .collect::<Vec<_>>();
        let next_offset = offset
            .checked_add(bytes.len())
            .filter(|next_offset| *next_offset < total_bytes);

        Ok(EvidenceBytesPage {
            relative_path,
            offset,
            total_bytes,
            bytes,
            next_offset,
        })
    }

    /// Internal adapter diagnostic; this is intentionally not part of the shell contract.
    pub fn local_service_address(
        &self,
        service_name: &str,
    ) -> Result<LocalServiceAddress, PlatformError> {
        self.adapter.local_service_address(service_name)
    }

    /// Shell-facing API.
    pub fn request_local_service(
        &self,
        service_name: &str,
        payload: &[u8],
        timeout: Duration,
    ) -> Result<Vec<u8>, SdkError> {
        let endpoint = IpcEndpoint::local_service(service_name).map_err(SdkError::from)?;
        let mut client = self
            .adapter
            .connect_ipc_with_timeout(endpoint, timeout)
            .map_err(SdkError::from)?;
        client.request(payload, timeout).map_err(SdkError::from)
    }

    /// Shell-facing API.
    pub fn request_remote_http(
        &self,
        base_url: &str,
        payload: &[u8],
        timeout: Duration,
    ) -> Result<Vec<u8>, SdkError> {
        let endpoint = IpcEndpoint::RemoteHttp {
            base_url: base_url.to_string(),
        };
        let mut client = self
            .adapter
            .connect_ipc_with_timeout(endpoint, timeout)
            .map_err(SdkError::from)?;
        client.request(payload, timeout).map_err(SdkError::from)
    }

    /// Shell-facing API.
    pub fn send_local_service(
        &self,
        service_name: &str,
        payload: &[u8],
        timeout: Duration,
    ) -> Result<(), SdkError> {
        let endpoint = IpcEndpoint::local_service(service_name).map_err(SdkError::from)?;
        let mut client = self
            .adapter
            .connect_ipc_with_timeout(endpoint, timeout)
            .map_err(SdkError::from)?;
        client.send(payload, timeout).map_err(SdkError::from)
    }

    /// Shell-facing API.
    pub fn send_remote_http(
        &self,
        base_url: &str,
        payload: &[u8],
        timeout: Duration,
    ) -> Result<(), SdkError> {
        let endpoint = IpcEndpoint::RemoteHttp {
            base_url: base_url.to_string(),
        };
        let mut client = self
            .adapter
            .connect_ipc_with_timeout(endpoint, timeout)
            .map_err(SdkError::from)?;
        client.send(payload, timeout).map_err(SdkError::from)
    }
}

fn relative_evidence_path(root: &Path, path: &Path) -> Result<PathBuf, SdkError> {
    path.strip_prefix(root)
        .map(|path| path.to_path_buf())
        .map_err(|_| SdkError::invalid("evidence entry escaped evidence root"))
}

fn validate_relative_evidence_path(raw: &str) -> Result<PathBuf, SdkError> {
    if raw.trim().is_empty() {
        return Err(SdkError::invalid("evidence path cannot be empty"));
    }

    let path = Path::new(raw);
    if path.is_absolute() {
        return Err(SdkError::invalid("evidence path must be relative"));
    }

    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => normalized.push(part),
            Component::CurDir
            | Component::ParentDir
            | Component::RootDir
            | Component::Prefix(_) => {
                return Err(SdkError::invalid(
                    "evidence path cannot contain traversal components",
                ));
            }
        }
    }

    if normalized.as_os_str().is_empty() {
        return Err(SdkError::invalid("evidence path cannot be empty"));
    }
    Ok(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;
    use genesis_platform::desktop::DesktopPlatformAdapter;
    use genesis_platform::ipc::SERVICE_BRAIN;
    use genesis_platform::mobile::MobileControlAdapter;
    use std::io::Read;
    use std::path::PathBuf;

    #[test]
    fn sdk_health_reflects_adapter_capabilities() {
        let adapter = DesktopPlatformAdapter::with_roots(
            Platform::MacOs,
            RuntimeProfile::DesktopSafe,
            PathBuf::from("/data"),
            PathBuf::from("/cache"),
            PathBuf::from("/tmp"),
        );
        let sdk = GenesisSdk::new(adapter);
        let health = sdk.health();

        assert_eq!(health.platform, Platform::MacOs);
        assert_eq!(health.profile, RuntimeProfile::DesktopSafe);
        assert!(health.capabilities.local_wasm);
        assert!(!health.capabilities.native_plugin);
    }

    #[test]
    fn sdk_exposes_evidence_root_through_adapter() {
        let adapter = DesktopPlatformAdapter::with_roots(
            Platform::MacOs,
            RuntimeProfile::DesktopSafe,
            PathBuf::from("/data"),
            PathBuf::from("/cache"),
            PathBuf::from("/tmp"),
        );
        let sdk = GenesisSdk::new(adapter);

        assert_eq!(
            sdk.evidence_root().unwrap().root,
            PathBuf::from("/data/evidence")
        );
    }

    #[test]
    fn sdk_resolves_local_services_without_exposing_paths_in_input() {
        let adapter = DesktopPlatformAdapter::with_roots(
            Platform::MacOs,
            RuntimeProfile::DesktopSafe,
            PathBuf::from("/data"),
            PathBuf::from("/cache"),
            PathBuf::from("/runtime"),
        );
        let sdk = GenesisSdk::new(adapter);

        assert_eq!(
            sdk.local_service_address("genesis-brain").unwrap(),
            LocalServiceAddress::UnixSocket(PathBuf::from("/runtime/genesis_brain.sock"))
        );
        assert!(sdk.local_service_address("/tmp/genesis.sock").is_err());
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn sdk_requests_local_service_through_adapter() {
        use std::fs;
        use std::thread;

        let runtime_dir = std::env::temp_dir().join(format!("gs-ipc-{}", std::process::id()));
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
            assert_eq!(&request, b"hello\n");
            stream
                .send(b"world\n", Duration::from_secs(1))
                .expect("write response");
        });

        let sdk = GenesisSdk::new(adapter);

        let response = sdk
            .request_local_service(SERVICE_BRAIN, b"hello\n", Duration::from_secs(1))
            .expect("service response");

        assert_eq!(response, b"world\n");
        server.join().expect("server thread");
        let _ = fs::remove_dir_all(runtime_dir);
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn sdk_sends_local_service_without_transport_details() {
        use std::fs;
        use std::thread;

        let runtime_dir = std::env::temp_dir().join(format!("gs-send-{}", std::process::id()));
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
            assert_eq!(&request, b"event\n");
        });

        let sdk = GenesisSdk::new(adapter);

        sdk.send_local_service(SERVICE_BRAIN, b"event\n", Duration::from_secs(1))
            .expect("service send");

        server.join().expect("server thread");
        let _ = fs::remove_dir_all(runtime_dir);
    }

    #[test]
    fn mobile_sdk_requests_remote_http_without_local_ipc() {
        use std::io::Write;
        use std::net::TcpListener;
        use std::thread;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let text = read_http_request(&mut stream);
            assert!(text.starts_with("POST /rpc HTTP/1.1\r\n"));
            assert!(text.ends_with("mobile\n"));
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nremote\n")
                .expect("write response");
        });

        let adapter = MobileControlAdapter::new(
            Platform::Ios,
            PathBuf::from("/app/data"),
            PathBuf::from("/app/cache"),
        );
        let sdk = GenesisSdk::new(adapter);

        assert!(!sdk.health().capabilities.local_ipc);
        assert_eq!(
            sdk.local_service_address(SERVICE_BRAIN).unwrap(),
            LocalServiceAddress::Unsupported
        );
        let response = sdk
            .request_remote_http(
                &format!("http://127.0.0.1:{port}/rpc"),
                b"mobile\n",
                Duration::from_secs(1),
            )
            .expect("remote response");

        assert_eq!(response, b"remote\n");
        server.join().expect("server thread");
    }

    fn read_http_request(stream: &mut std::net::TcpStream) -> String {
        let mut request = Vec::new();
        let mut buffer = [0_u8; 128];
        loop {
            let size = stream.read(&mut buffer).expect("read request");
            assert!(size > 0, "request ended before headers");
            request.extend_from_slice(&buffer[..size]);
            if let Some(header_end) = request.windows(4).position(|window| window == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&request[..header_end]).into_owned();
                let content_length = headers
                    .lines()
                    .find_map(|line| line.strip_prefix("Content-Length: "))
                    .expect("content length")
                    .parse::<usize>()
                    .expect("content length number");
                let expected = header_end + 4 + content_length;
                while request.len() < expected {
                    let size = stream.read(&mut buffer).expect("read request body");
                    assert!(size > 0, "request ended before body");
                    request.extend_from_slice(&buffer[..size]);
                }
                return String::from_utf8_lossy(&request).into_owned();
            }
        }
    }
}
