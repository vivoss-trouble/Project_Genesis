use crate::{
    BrowserRequest, DirectoryKind, IpcClient, IpcEndpoint, Platform, PlatformAdapter,
    PlatformCapabilities, PlatformError, RuntimeProfile, WorkerExit, WorkerSpec,
};
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug)]
pub struct MobileControlAdapter {
    platform: Platform,
    data_root: PathBuf,
    cache_root: PathBuf,
}

impl MobileControlAdapter {
    pub fn new(platform: Platform, data_root: PathBuf, cache_root: PathBuf) -> Self {
        Self {
            platform,
            data_root,
            cache_root,
        }
    }
}

impl PlatformAdapter for MobileControlAdapter {
    fn platform(&self) -> Platform {
        self.platform
    }

    fn profile(&self) -> RuntimeProfile {
        RuntimeProfile::MobileControl
    }

    fn capabilities(&self) -> PlatformCapabilities {
        PlatformCapabilities::mobile_control()
    }

    fn resolve_dir(&self, kind: DirectoryKind) -> Result<PathBuf, PlatformError> {
        let path = match kind {
            DirectoryKind::Data => self.data_root.clone(),
            DirectoryKind::Cache => self.cache_root.clone(),
            DirectoryKind::Temp => self.cache_root.join("tmp"),
            DirectoryKind::Evidence => self.data_root.join("evidence"),
        };
        Ok(path)
    }

    fn ensure_private_dir(&self, path: &Path) -> Result<(), PlatformError> {
        std::fs::create_dir_all(path).map_err(PlatformError::io)
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

    fn run_worker(&self, _: WorkerSpec) -> Result<WorkerExit, PlatformError> {
        Err(PlatformError::unsupported(
            "MobileControl does not run local workers",
        ))
    }

    fn connect_ipc(&self, endpoint: IpcEndpoint) -> Result<Box<dyn IpcClient>, PlatformError> {
        match endpoint {
            IpcEndpoint::RemoteHttp { base_url } => crate::remote_http::connect(base_url, None),
            IpcEndpoint::LocalService { .. } | IpcEndpoint::LoopbackTcp { .. } => Err(
                PlatformError::unsupported("MobileControl only permits remote IPC endpoints"),
            ),
        }
    }

    fn http_get(
        &self,
        url: &str,
        timeout: std::time::Duration,
        max_response_body: usize,
    ) -> Result<Vec<u8>, PlatformError> {
        crate::remote_http::get(url, timeout, max_response_body)
    }

    fn open_browser(&self, _: BrowserRequest) -> Result<(), PlatformError> {
        Err(PlatformError::unsupported(
            "MobileControl browser launch must be handled by the app shell",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::time::Duration;

    #[test]
    fn mobile_control_refuses_local_execution() {
        let adapter = MobileControlAdapter::new(
            Platform::Ios,
            PathBuf::from("/app/data"),
            PathBuf::from("/app/cache"),
        );
        let spec = WorkerSpec {
            program: PathBuf::from("echo"),
            args: vec!["ok".to_string()],
            env: BTreeMap::new(),
            cwd: None,
            timeout: Some(Duration::from_millis(10)),
        };

        assert!(adapter.run_worker(spec).is_err());
        assert!(!adapter.capabilities().subprocess);
        assert!(!adapter.capabilities().local_wasm);
        assert!(!adapter.capabilities().native_plugin);
    }

    #[test]
    fn mobile_control_keeps_evidence_under_app_data() {
        let adapter = MobileControlAdapter::new(
            Platform::Android,
            PathBuf::from("/app/data"),
            PathBuf::from("/app/cache"),
        );

        assert_eq!(
            adapter.resolve_dir(DirectoryKind::Evidence).unwrap(),
            PathBuf::from("/app/data/evidence")
        );
    }
}
