use genesis_platform::{PlatformAdapter, RuntimeProfile};
use genesis_sdk::{
    EvidenceBytesPage, EvidenceListPage, GenesisSdk, SdkError, SdkHealth, SdkShellContract,
    sdk_shell_contract,
};
use serde::Serialize;
use std::fmt;
use std::time::Duration;

pub const DEFAULT_SHELL_TIMEOUT: Duration = Duration::from_secs(3);

pub struct GenesisDesktopShell<A: PlatformAdapter> {
    sdk: GenesisSdk<A>,
    timeout: Duration,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ShellHealth {
    pub sdk_contract_epoch: &'static str,
    pub sdk_abi_version: u32,
    pub platform: String,
    pub profile: String,
    pub local_ipc: bool,
    pub remote_ipc: bool,
    pub local_wasm: bool,
    pub native_plugin: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ShellActionReport {
    pub route: ShellActionRoute,
    pub service_or_url: String,
    pub response_bytes: Option<usize>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub enum ShellActionRoute {
    LocalService,
    RemoteHttp,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShellError {
    pub message: String,
}

impl ShellError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl From<SdkError> for ShellError {
    fn from(error: SdkError) -> Self {
        Self::new(error.to_string())
    }
}

impl fmt::Display for ShellError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ShellError {}

impl<A: PlatformAdapter> GenesisDesktopShell<A> {
    pub fn new(adapter: A) -> Self {
        Self {
            sdk: GenesisSdk::new(adapter),
            timeout: DEFAULT_SHELL_TIMEOUT,
        }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn sdk_contract(&self) -> SdkShellContract {
        sdk_shell_contract()
    }

    pub fn health(&self) -> ShellHealth {
        ShellHealth::from_sdk(self.sdk.health(), self.sdk_contract())
    }

    pub fn list_evidence(
        &self,
        offset: usize,
        limit: usize,
    ) -> Result<EvidenceListPage, ShellError> {
        self.sdk
            .list_evidence(offset, limit)
            .map_err(ShellError::from)
    }

    pub fn read_evidence_page(
        &self,
        relative_path: &str,
        offset: usize,
        limit: usize,
    ) -> Result<EvidenceBytesPage, ShellError> {
        self.sdk
            .read_evidence_page(relative_path, offset, limit)
            .map_err(ShellError::from)
    }

    pub fn send_local_action(
        &self,
        service_name: &str,
        action_json: &str,
    ) -> Result<ShellActionReport, ShellError> {
        let payload = line_payload(action_json)?;
        self.sdk
            .send_local_service(service_name, &payload, self.timeout)
            .map_err(ShellError::from)?;
        Ok(ShellActionReport {
            route: ShellActionRoute::LocalService,
            service_or_url: service_name.to_string(),
            response_bytes: None,
        })
    }

    pub fn request_local_action(
        &self,
        service_name: &str,
        action_json: &str,
    ) -> Result<Vec<u8>, ShellError> {
        let payload = line_payload(action_json)?;
        self.sdk
            .request_local_service(service_name, &payload, self.timeout)
            .map_err(ShellError::from)
    }

    pub fn request_remote_action(
        &self,
        base_url: &str,
        action_json: &str,
    ) -> Result<ShellActionReport, ShellError> {
        let payload = line_payload(action_json)?;
        let response = self
            .sdk
            .request_remote_http(base_url, &payload, self.timeout)
            .map_err(ShellError::from)?;
        Ok(ShellActionReport {
            route: ShellActionRoute::RemoteHttp,
            service_or_url: base_url.to_string(),
            response_bytes: Some(response.len()),
        })
    }
}

impl ShellHealth {
    fn from_sdk(health: SdkHealth, contract: SdkShellContract) -> Self {
        Self {
            sdk_contract_epoch: contract.epoch,
            sdk_abi_version: contract.abi_version,
            platform: format!("{:?}", health.platform),
            profile: profile_name(health.profile).to_string(),
            local_ipc: health.capabilities.local_ipc,
            remote_ipc: health.capabilities.remote_ipc,
            local_wasm: health.capabilities.local_wasm,
            native_plugin: health.capabilities.native_plugin,
        }
    }
}

fn line_payload(json: &str) -> Result<Vec<u8>, ShellError> {
    let trimmed = json.trim();
    if trimmed.is_empty() {
        return Err(ShellError::new("action payload cannot be empty"));
    }
    serde_json::from_str::<serde_json::Value>(trimmed)
        .map_err(|error| ShellError::new(format!("action payload must be JSON: {error}")))?;
    let mut payload = trimmed.as_bytes().to_vec();
    payload.push(b'\n');
    Ok(payload)
}

fn profile_name(profile: RuntimeProfile) -> &'static str {
    match profile {
        RuntimeProfile::DesktopFull => "DesktopFull",
        RuntimeProfile::DesktopSafe => "DesktopSafe",
        RuntimeProfile::MobileControl => "MobileControl",
        RuntimeProfile::MobileLocalLight => "MobileLocalLight",
        RuntimeProfile::ServerNode => "ServerNode",
        RuntimeProfile::CiRelease => "CiRelease",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use genesis_platform::{
        BrowserRequest, DirectoryKind, IpcClient, IpcEndpoint, Platform, PlatformCapabilities,
        PlatformError, WorkerExit, WorkerSpec,
    };
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex};

    #[test]
    fn desktop_shell_smoke_proves_health_action_and_evidence_browsing() {
        let sent = Arc::new(Mutex::new(Vec::new()));
        let shell = GenesisDesktopShell::new(MockAdapter::new(Arc::clone(&sent)));

        let health = shell.health();
        assert_eq!(health.sdk_abi_version, 1);
        assert_eq!(health.sdk_contract_epoch, "genesis-sdk-shell-v1");
        assert_eq!(health.profile, "DesktopSafe");
        assert!(health.local_ipc);
        assert!(health.remote_ipc);

        let evidence = shell.list_evidence(0, 2).expect("evidence list");
        assert_eq!(evidence.entries, vec![PathBuf::from("run.log")]);

        let page = shell
            .read_evidence_page("run.log", 0, 5)
            .expect("evidence page");
        assert_eq!(page.bytes, b"shell");
        assert_eq!(page.next_offset, Some(5));

        let local = shell
            .send_local_action(
                "genesis-web-act",
                r#"{"act":"noop","reason":"desktop shell smoke"}"#,
            )
            .expect("local action");
        assert_eq!(local.route, ShellActionRoute::LocalService);
        assert_eq!(
            sent.lock().expect("sent").as_slice(),
            &[b"{\"act\":\"noop\",\"reason\":\"desktop shell smoke\"}\n".to_vec()]
        );

        let remote = shell
            .request_remote_action(
                "http://node.example/rpc",
                r#"{"act":"noop","reason":"remote shell smoke"}"#,
            )
            .expect("remote action");
        assert_eq!(remote.route, ShellActionRoute::RemoteHttp);
        assert_eq!(remote.response_bytes, Some(16));
    }

    #[test]
    fn desktop_shell_rejects_non_json_actions_before_transport() {
        let sent = Arc::new(Mutex::new(Vec::new()));
        let shell = GenesisDesktopShell::new(MockAdapter::new(Arc::clone(&sent)));

        let error = shell
            .send_local_action("genesis-web-act", "not json")
            .unwrap_err();

        assert!(error.message.contains("action payload must be JSON"));
        assert!(sent.lock().expect("sent").is_empty());
    }

    #[derive(Clone, Debug)]
    struct MockAdapter {
        sent: Arc<Mutex<Vec<Vec<u8>>>>,
    }

    impl MockAdapter {
        fn new(sent: Arc<Mutex<Vec<Vec<u8>>>>) -> Self {
            Self { sent }
        }
    }

    impl PlatformAdapter for MockAdapter {
        fn platform(&self) -> Platform {
            Platform::MacOs
        }

        fn profile(&self) -> RuntimeProfile {
            RuntimeProfile::DesktopSafe
        }

        fn capabilities(&self) -> PlatformCapabilities {
            PlatformCapabilities::desktop_full()
        }

        fn resolve_dir(&self, kind: DirectoryKind) -> Result<PathBuf, PlatformError> {
            let path = match kind {
                DirectoryKind::Evidence => PathBuf::from("/genesis/evidence"),
                DirectoryKind::Data => PathBuf::from("/genesis/data"),
                DirectoryKind::Cache => PathBuf::from("/genesis/cache"),
                DirectoryKind::Temp => PathBuf::from("/genesis/tmp"),
            };
            Ok(path)
        }

        fn ensure_private_dir(&self, _path: &Path) -> Result<(), PlatformError> {
            Ok(())
        }

        fn read_dir_paths(&self, path: &Path) -> Result<Vec<PathBuf>, PlatformError> {
            Ok(vec![path.join("run.log")])
        }

        fn read_file(&self, path: &Path) -> Result<Vec<u8>, PlatformError> {
            if path.ends_with("run.log") {
                Ok(b"shell-evidence".to_vec())
            } else {
                Err(PlatformError::unavailable("missing evidence"))
            }
        }

        fn now_unix_ms(&self) -> u64 {
            0
        }

        fn monotonic_ms(&self) -> u64 {
            0
        }

        fn run_worker(&self, _spec: WorkerSpec) -> Result<WorkerExit, PlatformError> {
            Err(PlatformError::unsupported(
                "worker unavailable in shell smoke",
            ))
        }

        fn connect_ipc(&self, endpoint: IpcEndpoint) -> Result<Box<dyn IpcClient>, PlatformError> {
            Ok(Box::new(MockClient {
                endpoint,
                sent: Arc::clone(&self.sent),
            }))
        }

        fn connect_ipc_with_timeout(
            &self,
            endpoint: IpcEndpoint,
            _timeout: Duration,
        ) -> Result<Box<dyn IpcClient>, PlatformError> {
            self.connect_ipc(endpoint)
        }

        fn open_browser(&self, _request: BrowserRequest) -> Result<(), PlatformError> {
            Err(PlatformError::unsupported(
                "browser unavailable in shell smoke",
            ))
        }
    }

    struct MockClient {
        endpoint: IpcEndpoint,
        sent: Arc<Mutex<Vec<Vec<u8>>>>,
    }

    impl IpcClient for MockClient {
        fn send(&mut self, payload: &[u8], _timeout: Duration) -> Result<(), PlatformError> {
            self.sent.lock().expect("sent").push(payload.to_vec());
            Ok(())
        }

        fn request(&mut self, payload: &[u8], timeout: Duration) -> Result<Vec<u8>, PlatformError> {
            self.send(payload, timeout)?;
            match &self.endpoint {
                IpcEndpoint::RemoteHttp { .. } => Ok(b"{\"status\":\"ok\"}\n".to_vec()),
                IpcEndpoint::LocalService { .. } => Ok(b"{\"local\":\"ok\"}\n".to_vec()),
                IpcEndpoint::LoopbackTcp { .. } => Err(PlatformError::unsupported(
                    "loopback is not used by shell smoke",
                )),
            }
        }
    }
}
