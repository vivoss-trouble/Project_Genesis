use crate::{PlatformError, WorkerExit, WorkerSpec};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

pub(super) fn run(spec: WorkerSpec) -> Result<WorkerExit, PlatformError> {
    let mut command = Command::new(&spec.program);
    command
        .args(&spec.args)
        .envs(&spec.env)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = &spec.cwd {
        command.current_dir(cwd);
    }

    let mut child = command.spawn().map_err(PlatformError::io)?;
    if let Some(timeout) = spec.timeout {
        let started = Instant::now();
        while started.elapsed() < timeout {
            if child.try_wait().map_err(PlatformError::io)?.is_some() {
                let output = child.wait_with_output().map_err(PlatformError::io)?;
                return Ok(worker_exit(output, false));
            }
            thread::sleep(Duration::from_millis(10));
        }
        let _ = child.kill();
        let output = child.wait_with_output().map_err(PlatformError::io)?;
        return Ok(worker_exit(output, true));
    }

    let output = child.wait_with_output().map_err(PlatformError::io)?;
    Ok(worker_exit(output, false))
}

fn worker_exit(output: std::process::Output, timed_out: bool) -> WorkerExit {
    WorkerExit {
        status_code: output.status.code(),
        stdout: output.stdout,
        stderr: output.stderr,
        timed_out,
    }
}
