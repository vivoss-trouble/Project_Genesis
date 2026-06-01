use genesis_platform::mobile::MobileControlAdapter;
use genesis_platform::{Platform, PlatformAdapter, RuntimeProfile};
use genesis_sdk::{
    GENESIS_SDK_SHELL_ABI_VERSION, GENESIS_SDK_SHELL_CONTRACT_EPOCH, GenesisSdk,
    SDK_MAX_EVIDENCE_LIST_LIMIT, SDK_MAX_EVIDENCE_PAGE_BYTES, SdkError, SdkHealth,
};
use serde::{Deserialize, Serialize};
use std::fmt;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

pub const MOBILE_CONTROL_PROTOCOL_VERSION: u32 = 1;
pub const DEFAULT_MOBILE_TIMEOUT: Duration = Duration::from_secs(5);

pub struct GenesisMobileControl<A: PlatformAdapter> {
    sdk: GenesisSdk<A>,
    remote_base_url: String,
    timeout: Duration,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MobileControlConfig {
    pub platform: Platform,
    pub data_root: PathBuf,
    pub cache_root: PathBuf,
    pub remote_base_url: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct MobileControlHealth {
    pub sdk_contract_epoch: &'static str,
    pub sdk_abi_version: u32,
    pub protocol_version: u32,
    pub platform: String,
    pub profile: String,
    pub remote_base_url: String,
    pub local_ipc: bool,
    pub remote_ipc: bool,
    pub local_wasm: bool,
    pub native_plugin: bool,
    pub subprocess: bool,
    pub browser_automation: bool,
    pub java_probe: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct MobileRemoteReport {
    pub route: MobileRoute,
    pub remote_base_url: String,
    pub request_kind: MobileRequestKind,
    pub response_bytes: Option<usize>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub enum MobileRoute {
    RemoteHttp,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum MobileRequestKind {
    NodeHealth,
    Action,
    EvidenceList,
    EvidencePage,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MobileControlError {
    pub message: String,
}

impl MobileControlError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl From<SdkError> for MobileControlError {
    fn from(error: SdkError) -> Self {
        Self::new(error.to_string())
    }
}

impl fmt::Display for MobileControlError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for MobileControlError {}

impl GenesisMobileControl<MobileControlAdapter> {
    pub fn from_config(config: MobileControlConfig) -> Result<Self, MobileControlError> {
        validate_remote_base_url(&config.remote_base_url)?;
        Ok(Self::new(
            MobileControlAdapter::new(config.platform, config.data_root, config.cache_root),
            config.remote_base_url,
        ))
    }
}

impl<A: PlatformAdapter> GenesisMobileControl<A> {
    pub fn new(adapter: A, remote_base_url: impl Into<String>) -> Self {
        Self {
            sdk: GenesisSdk::new(adapter),
            remote_base_url: remote_base_url.into(),
            timeout: DEFAULT_MOBILE_TIMEOUT,
        }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn health(&self) -> MobileControlHealth {
        MobileControlHealth::from_sdk(self.sdk.health(), self.remote_base_url.clone())
    }

    pub fn request_node_health(&self) -> Result<MobileRemoteReport, MobileControlError> {
        self.request_mobile_payload(MobileRequestKind::NodeHealth, node_health_payload()?)
    }

    pub fn request_action(
        &self,
        action_json: &str,
    ) -> Result<MobileRemoteReport, MobileControlError> {
        let action = parse_json_value(action_json)?;
        self.request_mobile_payload(
            MobileRequestKind::Action,
            serde_json::json!({
                "protocol_version": MOBILE_CONTROL_PROTOCOL_VERSION,
                "kind": "action",
                "action": action,
            }),
        )
    }

    pub fn send_action(&self, action_json: &str) -> Result<MobileRemoteReport, MobileControlError> {
        let action = parse_json_value(action_json)?;
        self.send_mobile_payload(
            MobileRequestKind::Action,
            serde_json::json!({
                "protocol_version": MOBILE_CONTROL_PROTOCOL_VERSION,
                "kind": "action",
                "action": action,
            }),
        )
    }

    pub fn request_evidence_list(
        &self,
        offset: usize,
        limit: usize,
    ) -> Result<MobileRemoteReport, MobileControlError> {
        if limit == 0 {
            return Err(MobileControlError::new(
                "remote evidence list limit cannot be zero",
            ));
        }
        if limit > SDK_MAX_EVIDENCE_LIST_LIMIT {
            return Err(MobileControlError::new(format!(
                "remote evidence list limit cannot exceed {SDK_MAX_EVIDENCE_LIST_LIMIT}"
            )));
        }
        self.request_mobile_payload(
            MobileRequestKind::EvidenceList,
            serde_json::json!({
                "protocol_version": MOBILE_CONTROL_PROTOCOL_VERSION,
                "kind": "evidence_list",
                "offset": offset,
                "limit": limit,
            }),
        )
    }

    pub fn request_evidence_page(
        &self,
        relative_path: &str,
        offset: usize,
        limit: usize,
    ) -> Result<MobileRemoteReport, MobileControlError> {
        if limit == 0 {
            return Err(MobileControlError::new(
                "remote evidence page limit cannot be zero",
            ));
        }
        if limit > SDK_MAX_EVIDENCE_PAGE_BYTES {
            return Err(MobileControlError::new(format!(
                "remote evidence page limit cannot exceed {SDK_MAX_EVIDENCE_PAGE_BYTES}"
            )));
        }
        let relative_path = validate_relative_evidence_path(relative_path)?;
        self.request_mobile_payload(
            MobileRequestKind::EvidencePage,
            serde_json::json!({
                "protocol_version": MOBILE_CONTROL_PROTOCOL_VERSION,
                "kind": "evidence_page",
                "path": relative_path.to_string_lossy(),
                "offset": offset,
                "limit": limit,
            }),
        )
    }

    fn request_mobile_payload(
        &self,
        request_kind: MobileRequestKind,
        payload: serde_json::Value,
    ) -> Result<MobileRemoteReport, MobileControlError> {
        validate_remote_base_url(&self.remote_base_url)?;
        let payload = line_payload(payload)?;
        let response = self
            .sdk
            .request_remote_http(&self.remote_base_url, &payload, self.timeout)
            .map_err(MobileControlError::from)?;
        Ok(MobileRemoteReport {
            route: MobileRoute::RemoteHttp,
            remote_base_url: self.remote_base_url.clone(),
            request_kind,
            response_bytes: Some(response.len()),
        })
    }

    fn send_mobile_payload(
        &self,
        request_kind: MobileRequestKind,
        payload: serde_json::Value,
    ) -> Result<MobileRemoteReport, MobileControlError> {
        validate_remote_base_url(&self.remote_base_url)?;
        let payload = line_payload(payload)?;
        self.sdk
            .send_remote_http(&self.remote_base_url, &payload, self.timeout)
            .map_err(MobileControlError::from)?;
        Ok(MobileRemoteReport {
            route: MobileRoute::RemoteHttp,
            remote_base_url: self.remote_base_url.clone(),
            request_kind,
            response_bytes: None,
        })
    }
}

impl MobileControlHealth {
    fn from_sdk(health: SdkHealth, remote_base_url: String) -> Self {
        Self {
            sdk_contract_epoch: GENESIS_SDK_SHELL_CONTRACT_EPOCH,
            sdk_abi_version: GENESIS_SDK_SHELL_ABI_VERSION,
            protocol_version: MOBILE_CONTROL_PROTOCOL_VERSION,
            platform: format!("{:?}", health.platform),
            profile: profile_name(health.profile).to_string(),
            remote_base_url,
            local_ipc: health.capabilities.local_ipc,
            remote_ipc: health.capabilities.remote_ipc,
            local_wasm: health.capabilities.local_wasm,
            native_plugin: health.capabilities.native_plugin,
            subprocess: health.capabilities.subprocess,
            browser_automation: health.capabilities.browser_automation,
            java_probe: health.capabilities.java_probe,
        }
    }
}

fn node_health_payload() -> Result<serde_json::Value, MobileControlError> {
    Ok(serde_json::json!({
        "protocol_version": MOBILE_CONTROL_PROTOCOL_VERSION,
        "kind": "node_health",
    }))
}

fn parse_json_value(raw: &str) -> Result<serde_json::Value, MobileControlError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(MobileControlError::new("mobile payload cannot be empty"));
    }
    serde_json::from_str::<serde_json::Value>(trimmed)
        .map_err(|error| MobileControlError::new(format!("mobile payload must be JSON: {error}")))
}

fn line_payload(value: serde_json::Value) -> Result<Vec<u8>, MobileControlError> {
    let mut payload = serde_json::to_vec(&value).map_err(|error| {
        MobileControlError::new(format!("mobile payload encode failed: {error}"))
    })?;
    payload.push(b'\n');
    Ok(payload)
}

fn validate_remote_base_url(url: &str) -> Result<(), MobileControlError> {
    if !url.starts_with("http://") {
        return Err(MobileControlError::new(
            "MobileControl remote endpoint must use http:// RemoteHttp",
        ));
    }
    if url.trim().len() != url.len() || url.trim() == "http://" {
        return Err(MobileControlError::new(
            "MobileControl remote endpoint is invalid",
        ));
    }
    Ok(())
}

fn validate_relative_evidence_path(raw: &str) -> Result<PathBuf, MobileControlError> {
    if raw.trim().is_empty() {
        return Err(MobileControlError::new(
            "remote evidence path cannot be empty",
        ));
    }

    let path = Path::new(raw);
    if path.is_absolute() {
        return Err(MobileControlError::new(
            "remote evidence path must be relative",
        ));
    }

    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => normalized.push(part),
            Component::CurDir
            | Component::ParentDir
            | Component::RootDir
            | Component::Prefix(_) => {
                return Err(MobileControlError::new(
                    "remote evidence path cannot contain traversal components",
                ));
            }
        }
    }

    if normalized.as_os_str().is_empty() {
        return Err(MobileControlError::new(
            "remote evidence path cannot be empty",
        ));
    }
    Ok(normalized)
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
        BrowserRequest, DirectoryKind, IpcClient, IpcEndpoint, PlatformCapabilities, PlatformError,
        WorkerExit, WorkerSpec,
    };
    use std::path::Path;
    use std::sync::{Arc, Mutex};

    #[test]
    fn mobile_control_smoke_proves_remote_only_health_action_and_evidence() {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let client = GenesisMobileControl::new(
            MockMobileAdapter::new(Arc::clone(&calls)),
            "http://node.example/mobile-rpc",
        );

        let health = client.health();
        assert_eq!(health.sdk_abi_version, 1);
        assert_eq!(health.sdk_contract_epoch, "genesis-sdk-shell-v1");
        assert_eq!(health.protocol_version, 1);
        assert_eq!(health.profile, "MobileControl");
        assert!(!health.local_ipc);
        assert!(health.remote_ipc);
        assert!(!health.local_wasm);
        assert!(!health.native_plugin);
        assert!(!health.subprocess);
        assert!(!health.browser_automation);
        assert!(!health.java_probe);

        let node_health = client.request_node_health().expect("node health");
        assert_eq!(node_health.request_kind, MobileRequestKind::NodeHealth);
        assert_eq!(
            node_health.response_bytes,
            Some(b"{\"ok\":true,\"n\":1}\n".len())
        );

        let action = client
            .request_action(r#"{"act":"noop","source":"mobile"}"#)
            .expect("action");
        assert_eq!(action.route, MobileRoute::RemoteHttp);
        assert_eq!(action.request_kind, MobileRequestKind::Action);

        let evidence_list = client.request_evidence_list(0, 16).expect("evidence list");
        assert_eq!(evidence_list.request_kind, MobileRequestKind::EvidenceList);

        let evidence_page = client
            .request_evidence_page("runs/latest.log", 0, 128)
            .expect("evidence page");
        assert_eq!(evidence_page.request_kind, MobileRequestKind::EvidencePage);

        let calls = calls.lock().expect("calls");
        assert_eq!(calls.len(), 4);
        assert!(
            calls
                .iter()
                .all(|call| call.starts_with("http://node.example/mobile-rpc|"))
        );
        assert!(calls[0].contains("\"kind\":\"node_health\""));
        assert!(calls[1].contains("\"kind\":\"action\""));
        assert!(calls[2].contains("\"kind\":\"evidence_list\""));
        assert!(calls[3].contains("\"kind\":\"evidence_page\""));
    }

    #[test]
    fn mobile_control_rejects_invalid_payloads_before_transport() {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let client = GenesisMobileControl::new(
            MockMobileAdapter::new(Arc::clone(&calls)),
            "http://node.example/mobile-rpc",
        );

        let invalid_json = client.request_action("not json").unwrap_err();
        assert!(invalid_json.message.contains("mobile payload must be JSON"));

        let traversal = client
            .request_evidence_page("../secret.log", 0, 1)
            .unwrap_err();
        assert!(
            traversal
                .message
                .contains("remote evidence path cannot contain traversal")
        );

        let oversized = client
            .request_evidence_list(0, SDK_MAX_EVIDENCE_LIST_LIMIT + 1)
            .unwrap_err();
        assert!(
            oversized
                .message
                .contains("remote evidence list limit cannot exceed")
        );
        assert!(calls.lock().expect("calls").is_empty());
    }

    #[test]
    fn mobile_control_rejects_non_remote_http_endpoint() {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let client = GenesisMobileControl::new(
            MockMobileAdapter::new(Arc::clone(&calls)),
            "file:///tmp/genesis.sock",
        );

        let error = client.request_node_health().unwrap_err();

        assert!(
            error
                .message
                .contains("MobileControl remote endpoint must use http://")
        );
        assert!(calls.lock().expect("calls").is_empty());
    }

    #[derive(Clone, Debug)]
    struct MockMobileAdapter {
        calls: Arc<Mutex<Vec<String>>>,
    }

    impl MockMobileAdapter {
        fn new(calls: Arc<Mutex<Vec<String>>>) -> Self {
            Self { calls }
        }
    }

    impl PlatformAdapter for MockMobileAdapter {
        fn platform(&self) -> Platform {
            Platform::Android
        }

        fn profile(&self) -> RuntimeProfile {
            RuntimeProfile::MobileControl
        }

        fn capabilities(&self) -> PlatformCapabilities {
            PlatformCapabilities::mobile_control()
        }

        fn resolve_dir(&self, kind: DirectoryKind) -> Result<PathBuf, PlatformError> {
            let suffix = match kind {
                DirectoryKind::Data => "data",
                DirectoryKind::Cache => "cache",
                DirectoryKind::Temp => "tmp",
                DirectoryKind::Evidence => "evidence",
            };
            Ok(PathBuf::from("/mobile").join(suffix))
        }

        fn ensure_private_dir(&self, _path: &Path) -> Result<(), PlatformError> {
            Ok(())
        }

        fn now_unix_ms(&self) -> u64 {
            1_700_000_000_000
        }

        fn monotonic_ms(&self) -> u64 {
            42
        }

        fn run_worker(&self, _: WorkerSpec) -> Result<WorkerExit, PlatformError> {
            Err(PlatformError::unsupported(
                "MobileControl test adapter does not run workers",
            ))
        }

        fn connect_ipc(&self, endpoint: IpcEndpoint) -> Result<Box<dyn IpcClient>, PlatformError> {
            match endpoint {
                IpcEndpoint::RemoteHttp { base_url } => Ok(Box::new(MockRemoteClient {
                    base_url,
                    calls: Arc::clone(&self.calls),
                })),
                IpcEndpoint::LocalService { .. } | IpcEndpoint::LoopbackTcp { .. } => Err(
                    PlatformError::unsupported("MobileControl test only permits RemoteHttp"),
                ),
            }
        }

        fn open_browser(&self, _: BrowserRequest) -> Result<(), PlatformError> {
            Err(PlatformError::unsupported(
                "MobileControl browser launch is shell-owned",
            ))
        }
    }

    struct MockRemoteClient {
        base_url: String,
        calls: Arc<Mutex<Vec<String>>>,
    }

    impl IpcClient for MockRemoteClient {
        fn send(&mut self, payload: &[u8], _timeout: Duration) -> Result<(), PlatformError> {
            self.calls.lock().expect("calls").push(format!(
                "{}|{}",
                self.base_url,
                String::from_utf8_lossy(payload)
            ));
            Ok(())
        }

        fn request(
            &mut self,
            payload: &[u8],
            _timeout: Duration,
        ) -> Result<Vec<u8>, PlatformError> {
            self.send(payload, _timeout)?;
            Ok(b"{\"ok\":true,\"n\":1}\n".to_vec())
        }
    }
}
