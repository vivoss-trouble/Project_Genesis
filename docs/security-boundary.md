# Project Genesis Security Boundary

## Scope

This document describes the runtime isolation boundary that is implemented by the current repository. It does not claim properties for production deployment, host hardening, cloud policy, or external services that are not present in this source tree.

## Boundary Classes

### Trusted In-Process Genesis Plugins

`genesis-core` loads `.so` / `.dylib` plugins through `libloading` and a C ABI entrypoint. These plugins run inside the `genesis-core` process.

Runtime gate:

- Native `.so` / `.dylib` loading is disabled by default.
- Set `GENESIS_ALLOW_NATIVE_PLUGINS=1` only when loading trusted local plugins.
- When the gate is closed, `genesis-core` still starts and emits ticks, but it does not watch or load native plugins.

Provided controls:

- ABI version check before accepting a plugin.
- Watchdog timeout and tainting for plugin calls.
- Panic capture around plugin entry calls.
- FFI response buffer release on success and send-failure paths.
- Nonblocking retire/reap path for hot reload.

Not provided:

- Memory isolation from the host process.
- Protection from malicious native code.
- Protection from undefined behavior inside a plugin.
- Syscall, filesystem, or network sandboxing.

Policy: this path is for trusted plugins only.

### Untrusted Plugins

Untrusted generated or third-party code must not be loaded through the in-process FFI plugin path.

Allowed isolation targets:

- Wasm artifact execution with fuel limits.
- A future out-of-process worker boundary with explicit IPC and process lifecycle control.

Policy: reject untrusted code from the in-process FFI loader until an out-of-process or Wasm plugin runtime exists.

### Lazarus Wasm Artifacts

`lazarus-artifact-runner` supports Wasm execution through Wasmtime with fuel consumption enabled.

Provided controls:

- `fuel > 0` validation.
- Wasmtime fuel-limited execution.
- Bounded input extraction from JSON payloads.
- Structured execution reports.

Policy: this is the preferred execution path for generated code.

### Native Executable Artifacts

`lazarus-artifact-runner` also contains a native executable runner used by tests and development flows.

Current limitations:

- Timeout kills only the direct child process.
- No process-group or session-wide kill is guaranteed.
- No syscall, filesystem, network, or resource-limit sandbox is enforced.
- A generated binary can spawn children or create external side effects.

Policy: native executable artifacts are development-only until process-tree cleanup and resource isolation are implemented. Production synthesis/cutover flows should accept Wasm artifacts only.

## Operational Requirements

- Keep runtime state such as `.genesis-state/`, `target/`, smoke reports, and generated caches out of release commits.
- Run `scripts/validate_all.sh` before release candidate tagging.
- Use `scripts/validate_lazarus_pilot_gate.sh` before a controlled pilot.
- Use `scripts/validate_lazarus_release_candidate.sh` before a release-candidate handoff.
- Treat `cargo test` and `cargo clippy` as necessary but insufficient for sandbox claims.
- Record local or cloud oracle request/response logs for synthesis smoke runs when `LAZARUS_ORACLE_LOG_DIR` is configured.
