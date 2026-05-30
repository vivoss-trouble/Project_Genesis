use serde_json::Value;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use crate::{
    ArtifactExecutionReport, DEFAULT_ARTIFACT_TIMEOUT, ExecutableArtifact, payload_args,
    stable_hash,
};

pub fn execute_artifact(
    artifact: &ExecutableArtifact,
    payload: &Value,
) -> Result<ArtifactExecutionReport, String> {
    ensure_native_artifacts_enabled()?;
    execute_artifact_with_timeout_dev_only(artifact, payload, DEFAULT_ARTIFACT_TIMEOUT)
}

pub fn execute_artifact_with_timeout(
    artifact: &ExecutableArtifact,
    payload: &Value,
    timeout: Duration,
) -> Result<ArtifactExecutionReport, String> {
    ensure_native_artifacts_enabled()?;
    execute_artifact_with_timeout_dev_only(artifact, payload, timeout)
}

pub fn execute_artifact_with_timeout_dev_only(
    artifact: &ExecutableArtifact,
    payload: &Value,
    timeout: Duration,
) -> Result<ArtifactExecutionReport, String> {
    if timeout.is_zero() {
        return Err("artifact timeout must be non-zero".to_string());
    }
    let args = payload_args(payload, &artifact.input_order)?;
    let input_hash = stable_hash(payload)?;
    let mut child = spawn_artifact_child(artifact, &args)?;
    let deadline = Instant::now() + timeout;
    loop {
        if child
            .try_wait()
            .map_err(|error| format!("failed to poll artifact child: {error}"))?
            .is_some()
        {
            let output = child
                .wait_with_output()
                .map_err(|error| format!("failed to collect artifact output: {error}"))?;
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            let value =
                if output.status.success() {
                    Some(stdout.parse::<i64>().map_err(|error| {
                        format!("artifact stdout was not i64: {error}: {stdout}")
                    })?)
                } else {
                    None
                };

            return Ok(ArtifactExecutionReport {
                executable_path: artifact.executable_path.clone(),
                input_hash,
                exit_code: output.status.code(),
                timed_out: false,
                stdout,
                stderr,
                value,
            });
        }
        if Instant::now() >= deadline {
            terminate_artifact_child(&mut child);
            let output = child
                .wait_with_output()
                .map_err(|error| format!("failed to reap timed-out artifact: {error}"))?;
            return Ok(ArtifactExecutionReport {
                executable_path: artifact.executable_path.clone(),
                input_hash,
                exit_code: output.status.code(),
                timed_out: true,
                stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
                stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
                value: None,
            });
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

pub fn execute_artifact_as_json(
    artifact: &ExecutableArtifact,
    payload: &Value,
) -> Result<Value, String> {
    ensure_native_artifacts_enabled()?;
    execute_artifact_as_json_dev_only(artifact, payload)
}

pub fn execute_artifact_as_json_dev_only(
    artifact: &ExecutableArtifact,
    payload: &Value,
) -> Result<Value, String> {
    let report =
        execute_artifact_with_timeout_dev_only(artifact, payload, DEFAULT_ARTIFACT_TIMEOUT)?;
    let Some(value) = report.value else {
        if report.timed_out {
            return Err(format!(
                "artifact timed out after {:?}: {}",
                DEFAULT_ARTIFACT_TIMEOUT, report.stderr
            ));
        }
        return Err(format!(
            "artifact failed with code {:?}: {}",
            report.exit_code, report.stderr
        ));
    };
    Ok(serde_json::json!({ "value": value }))
}

pub fn ensure_native_artifacts_enabled() -> Result<(), String> {
    if std::env::var("LAZARUS_NATIVE_ARTIFACT_DEV_MODE").as_deref() == Ok("1") {
        return Ok(());
    }
    Err(
        "native executable artifacts are disabled by default; use Wasm artifacts for production or call the *_dev_only API in development tooling"
            .to_string(),
    )
}

fn spawn_artifact_child(artifact: &ExecutableArtifact, args: &[i64]) -> Result<Child, String> {
    let mut command = Command::new(&artifact.executable_path);
    command
        .args(args.iter().map(i64::to_string))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;

        unsafe {
            command.pre_exec(|| {
                if libc::setpgid(0, 0) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }

    command
        .spawn()
        .map_err(|error| format!("failed to execute artifact: {error}"))
}

fn terminate_artifact_child(child: &mut Child) {
    #[cfg(unix)]
    {
        let pgid = child.id() as libc::pid_t;
        unsafe {
            if libc::killpg(pgid, libc::SIGKILL) == -1 {
                let _ = child.kill();
            }
        }
    }

    #[cfg(not(unix))]
    {
        let _ = child.kill();
    }
}
