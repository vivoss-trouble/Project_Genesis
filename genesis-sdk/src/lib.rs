use genesis_platform::{
    DirectoryKind, IpcEndpoint, Platform, PlatformAdapter, PlatformCapabilities, PlatformError,
    RuntimeProfile, ipc::LocalServiceAddress,
};
use std::path::PathBuf;
use std::time::Duration;

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

impl<A: PlatformAdapter> GenesisSdk<A> {
    pub fn new(adapter: A) -> Self {
        Self { adapter }
    }

    pub fn health(&self) -> SdkHealth {
        SdkHealth {
            platform: self.adapter.platform(),
            profile: self.adapter.profile(),
            capabilities: self.adapter.capabilities(),
        }
    }

    pub fn run_job(&self, _request: JobRequest) -> Result<JobId, PlatformError> {
        Err(PlatformError::unsupported(
            "GenesisSdk::run_job is not wired to genesis-core yet",
        ))
    }

    pub fn job_status(&self, _job_id: &JobId) -> Result<JobStatus, PlatformError> {
        Err(PlatformError::unsupported(
            "GenesisSdk::job_status is not wired to genesis-core yet",
        ))
    }

    pub fn load_wasm_artifact(&self, bytes: &[u8]) -> Result<ArtifactId, PlatformError> {
        if !self.adapter.capabilities().local_wasm {
            return Err(PlatformError::unsupported(
                "local Wasm artifact execution is not available on this platform",
            ));
        }
        if bytes.is_empty() {
            return Err(PlatformError::invalid("artifact bytes cannot be empty"));
        }
        Err(PlatformError::unsupported(
            "GenesisSdk::load_wasm_artifact is not wired to genesis-core yet",
        ))
    }

    pub fn evidence_root(&self) -> Result<EvidencePack, PlatformError> {
        Ok(EvidencePack {
            root: self.adapter.resolve_dir(DirectoryKind::Evidence)?,
        })
    }

    pub fn local_service_address(
        &self,
        service_name: &str,
    ) -> Result<LocalServiceAddress, PlatformError> {
        self.adapter.local_service_address(service_name)
    }

    pub fn request_local_service(
        &self,
        service_name: &str,
        payload: &[u8],
        timeout: Duration,
    ) -> Result<Vec<u8>, PlatformError> {
        let endpoint = IpcEndpoint::local_service(service_name)?;
        let mut client = self.adapter.connect_ipc_with_timeout(endpoint, timeout)?;
        client.request(payload, timeout)
    }

    pub fn request_remote_http(
        &self,
        base_url: &str,
        payload: &[u8],
        timeout: Duration,
    ) -> Result<Vec<u8>, PlatformError> {
        let endpoint = IpcEndpoint::RemoteHttp {
            base_url: base_url.to_string(),
        };
        let mut client = self.adapter.connect_ipc_with_timeout(endpoint, timeout)?;
        client.request(payload, timeout)
    }

    pub fn send_local_service(
        &self,
        service_name: &str,
        payload: &[u8],
        timeout: Duration,
    ) -> Result<(), PlatformError> {
        let endpoint = IpcEndpoint::local_service(service_name)?;
        let mut client = self.adapter.connect_ipc_with_timeout(endpoint, timeout)?;
        client.send(payload, timeout)
    }

    pub fn send_remote_http(
        &self,
        base_url: &str,
        payload: &[u8],
        timeout: Duration,
    ) -> Result<(), PlatformError> {
        let endpoint = IpcEndpoint::RemoteHttp {
            base_url: base_url.to_string(),
        };
        let mut client = self.adapter.connect_ipc_with_timeout(endpoint, timeout)?;
        client.send(payload, timeout)
    }
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
