use genesis_platform::desktop::DesktopPlatformAdapter;
use genesis_platform::mobile::MobileControlAdapter;
use genesis_platform::{
    BrowserRequest, DirectoryKind, IpcClient, IpcEndpoint, Platform, PlatformAdapter,
    PlatformCapabilities, PlatformError, PlatformErrorKind, RuntimeProfile, WorkerExit, WorkerSpec,
};
use genesis_sdk::{
    GENESIS_SDK_SHELL_ABI_VERSION, GENESIS_SDK_SHELL_CONTRACT_EPOCH, GenesisSdk, SdkErrorKind,
    ShellApiMethod, sdk_shell_contract,
};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[test]
fn shell_contract_declares_stable_v1_methods() {
    let contract = sdk_shell_contract();
    assert_eq!(contract.abi_version, GENESIS_SDK_SHELL_ABI_VERSION);
    assert_eq!(contract.abi_version, 1);
    assert_eq!(contract.epoch, GENESIS_SDK_SHELL_CONTRACT_EPOCH);
    assert_eq!(contract.epoch, "genesis-sdk-shell-v1");

    let method_names = contract
        .methods
        .iter()
        .map(|method| method.as_str())
        .collect::<Vec<_>>();
    assert_eq!(
        method_names,
        vec![
            "health",
            "evidence_root",
            "list_evidence",
            "read_evidence_page",
            "run_job",
            "job_status",
            "load_wasm_artifact",
            "request_local_service",
            "send_local_service",
            "request_remote_http",
            "send_remote_http",
        ]
    );
    assert_eq!(
        contract.methods,
        &[
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
        ]
    );
    assert_eq!(
        GenesisSdk::<MobileControlAdapter>::shell_contract(),
        contract
    );
}

#[test]
fn desktop_shell_reads_health_and_paged_evidence() {
    let data_root = unique_temp_dir("evidence-data");
    let cache_root = unique_temp_dir("evidence-cache");
    let temp_root = unique_temp_dir("evidence-temp");
    let evidence_root = data_root.join("evidence");
    fs::create_dir_all(&evidence_root).expect("evidence root");
    fs::write(evidence_root.join("a.log"), b"alpha-omega").expect("write evidence");
    fs::write(evidence_root.join("z.log"), b"zeta").expect("write evidence");

    let adapter = DesktopPlatformAdapter::with_roots(
        Platform::MacOs,
        RuntimeProfile::DesktopSafe,
        data_root.clone(),
        cache_root,
        temp_root,
    );
    let sdk = GenesisSdk::new(adapter);

    let health = sdk.health();
    assert_eq!(health.platform, Platform::MacOs);
    assert_eq!(health.profile, RuntimeProfile::DesktopSafe);
    assert!(health.capabilities.local_ipc);
    assert!(health.capabilities.local_wasm);
    assert!(!health.capabilities.native_plugin);

    assert_eq!(sdk.evidence_root().unwrap().root, evidence_root);
    let page = sdk.list_evidence(0, 1).expect("list evidence");
    assert_eq!(page.entries, vec![PathBuf::from("a.log")]);
    assert_eq!(page.next_offset, Some(1));

    let bytes = sdk
        .read_evidence_page("a.log", 0, 5)
        .expect("read evidence page");
    assert_eq!(bytes.relative_path, PathBuf::from("a.log"));
    assert_eq!(bytes.bytes, b"alpha");
    assert_eq!(bytes.total_bytes, 11);
    assert_eq!(bytes.next_offset, Some(5));

    let _ = fs::remove_dir_all(data_root);
}

#[test]
fn mobile_control_uses_remote_http_without_local_runtime() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let text = read_http_request(&mut stream);
        assert!(text.starts_with("POST /rpc HTTP/1.1\r\n"));
        assert!(text.ends_with("mobile\n"));
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nremote\n")
            .expect("write response");
    });

    let sdk = GenesisSdk::new(MobileControlAdapter::new(
        Platform::Android,
        PathBuf::from("/app/data"),
        PathBuf::from("/app/cache"),
    ));

    let health = sdk.health();
    assert_eq!(health.profile, RuntimeProfile::MobileControl);
    assert!(!health.capabilities.local_ipc);
    assert!(!health.capabilities.local_wasm);
    assert_eq!(
        sdk.load_wasm_artifact(b"\0asm").unwrap_err().kind,
        SdkErrorKind::Unsupported
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

#[test]
fn shell_contract_returns_typed_error_codes() {
    let data_root = unique_temp_dir("typed-errors");
    fs::create_dir_all(data_root.join("evidence")).expect("evidence root");
    let sdk = GenesisSdk::new(DesktopPlatformAdapter::with_roots(
        Platform::Linux,
        RuntimeProfile::DesktopSafe,
        data_root.clone(),
        unique_temp_dir("typed-cache"),
        unique_temp_dir("typed-temp"),
    ));

    assert_eq!(
        sdk.load_wasm_artifact(&[]).unwrap_err().kind,
        SdkErrorKind::InvalidInput
    );
    assert_eq!(
        sdk.list_evidence(0, 0).unwrap_err().kind,
        SdkErrorKind::InvalidInput
    );
    assert_eq!(
        sdk.read_evidence_page("../secret", 0, 1).unwrap_err().kind,
        SdkErrorKind::InvalidInput
    );
    assert_eq!(
        sdk.run_job(genesis_sdk::JobRequest {
            goal: "compile".to_string()
        })
        .unwrap_err()
        .kind,
        SdkErrorKind::Unsupported
    );

    let _ = fs::remove_dir_all(data_root);
}

#[test]
fn shell_contract_preserves_timeout_behavior() {
    let sdk = GenesisSdk::new(TimeoutAdapter);
    let error = sdk
        .request_remote_http("http://example.test/rpc", b"ping", Duration::from_millis(1))
        .unwrap_err();

    assert_eq!(error.kind, SdkErrorKind::Timeout);
    assert!(error.message.contains("simulated timeout"));
}

#[test]
fn shell_contract_tolerates_concurrent_calls() {
    let data_root = unique_temp_dir("concurrent-data");
    let evidence_root = data_root.join("evidence");
    fs::create_dir_all(&evidence_root).expect("evidence root");
    fs::write(evidence_root.join("status.json"), b"{\"ok\":true}").expect("write evidence");

    let sdk = Arc::new(GenesisSdk::new(DesktopPlatformAdapter::with_roots(
        Platform::Linux,
        RuntimeProfile::DesktopSafe,
        data_root.clone(),
        unique_temp_dir("concurrent-cache"),
        unique_temp_dir("concurrent-temp"),
    )));
    let handles = (0..8)
        .map(|_| {
            let sdk = Arc::clone(&sdk);
            std::thread::spawn(move || {
                assert_eq!(sdk.health().profile, RuntimeProfile::DesktopSafe);
                let page = sdk.list_evidence(0, 1).expect("list evidence");
                assert_eq!(page.entries, vec![PathBuf::from("status.json")]);
            })
        })
        .collect::<Vec<_>>();

    for handle in handles {
        handle.join().expect("conformance worker");
    }

    let _ = fs::remove_dir_all(data_root);
}

#[derive(Clone, Debug)]
struct TimeoutAdapter;

impl PlatformAdapter for TimeoutAdapter {
    fn platform(&self) -> Platform {
        Platform::Linux
    }

    fn profile(&self) -> RuntimeProfile {
        RuntimeProfile::DesktopSafe
    }

    fn capabilities(&self) -> PlatformCapabilities {
        PlatformCapabilities::desktop_full()
    }

    fn resolve_dir(&self, kind: DirectoryKind) -> Result<PathBuf, PlatformError> {
        let suffix = match kind {
            DirectoryKind::Data => "data",
            DirectoryKind::Cache => "cache",
            DirectoryKind::Temp => "tmp",
            DirectoryKind::Evidence => "evidence",
        };
        Ok(std::env::temp_dir()
            .join("genesis-sdk-timeout")
            .join(suffix))
    }

    fn ensure_private_dir(&self, path: &Path) -> Result<(), PlatformError> {
        fs::create_dir_all(path).map_err(PlatformError::io)
    }

    fn now_unix_ms(&self) -> u64 {
        0
    }

    fn monotonic_ms(&self) -> u64 {
        0
    }

    fn run_worker(&self, _spec: WorkerSpec) -> Result<WorkerExit, PlatformError> {
        Err(PlatformError::unsupported("worker unavailable"))
    }

    fn connect_ipc(&self, _endpoint: IpcEndpoint) -> Result<Box<dyn IpcClient>, PlatformError> {
        Err(timeout_error())
    }

    fn connect_ipc_with_timeout(
        &self,
        _endpoint: IpcEndpoint,
        _timeout: Duration,
    ) -> Result<Box<dyn IpcClient>, PlatformError> {
        Err(timeout_error())
    }

    fn open_browser(&self, _request: BrowserRequest) -> Result<(), PlatformError> {
        Err(PlatformError::unsupported("browser unavailable"))
    }
}

fn timeout_error() -> PlatformError {
    PlatformError {
        kind: PlatformErrorKind::Timeout,
        message: "simulated timeout".to_string(),
    }
}

fn unique_temp_dir(label: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "genesis-sdk-conformance-{label}-{}-{nanos}",
        std::process::id()
    ))
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
