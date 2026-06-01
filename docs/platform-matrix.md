# Genesis Platform Matrix

| Capability | macOS | Linux | Windows | iOS | Android |
| --- | --- | --- | --- | --- | --- |
| Rust core library | Supported | Supported | Planned | Planned | Planned |
| Wasm artifact runtime | Supported | Supported | Planned | Research | Research |
| Native plugin | Dev-only | Dev-only | Dev-only | No | No |
| Local subprocess workers | Supported | Supported | Planned | No | Restricted |
| Local IPC | UDS client/server | UDS client/server | Named Pipe client/server | No | Restricted |
| Browser automation | Supported | Supported | Planned | No | Restricted |
| Java probe | Supported | Supported | Planned | No | No |
| Mobile control UI | Remote | Remote | Remote | Planned | Planned |
| Platform SDK crate check | `aarch64-apple-darwin` verified on host | `x86_64-unknown-linux-gnu` verified | `x86_64-pc-windows-msvc` verified | `aarch64-apple-ios` verified | `aarch64-linux-android` verified |
| `brain-llm` plugin check | `aarch64-apple-darwin` verified on host | `x86_64-unknown-linux-gnu` verified | `x86_64-pc-windows-msvc` verified | `aarch64-apple-ios` verified | `aarch64-linux-android` verified |
| Wasm/WASI contract check | `wasm32-wasip1` verified for contract crates | Same Rust contract | Same Rust contract | SDK/control only | SDK/control only |

Verified means `scripts/validate_platform_contracts.sh` has passed. The gate checks
`genesis-platform`, `genesis-sdk`, `brain-llm`, `genesis-replay`, `genesis-os-driver`,
and `genesis-frame-grabber` against the desktop, mobile, and WASI target set; it also
checks the `genesis-core` shell with
`--no-default-features` so mobile/control and cross-compile builds are not forced to
link the desktop Wasmtime runtime. It also checks the `genesis-replay` shell with
`--no-default-features`; native dynamic plugin replay stays behind the `native-replay`
feature. These target checks run with Rust warnings promoted to errors. The same gate
scans that Unix socket and Windows pipe APIs remain contained inside
`genesis-platform/src/desktop/*`, and that production platform identity branches remain
inside `genesis-platform` or explicit native driver backend files. Legacy Unix socket
filenames are likewise limited to the local-service resolver tables.

## Rule

New platform support is added by implementing an adapter and capability tests. Core
runtime behavior must not branch on `target_os`; it should branch on capabilities.

## IPC Mapping

| Service input | macOS/Linux mapping | Windows mapping | Mobile mapping |
| --- | --- | --- | --- |
| `genesis-brain` | runtime dir + `genesis_brain.sock` | `\\.\pipe\genesis-brain` | unsupported |
| `genesis-web-act` | runtime dir + `genesis_act.sock` | `\\.\pipe\genesis-web-act` | unsupported |
| `genesis-dynamic-act` | runtime dir + `genesis_dynamic_act.sock` | `\\.\pipe\genesis-dynamic-act` | unsupported |
| `genesis-os-driver` | runtime dir + `genesis_os_driver.sock` | `\\.\pipe\genesis-os-driver` | unsupported |
| `genesis-vision` | runtime dir + `genesis_vision_daemon.sock` | `\\.\pipe\genesis-vision` | unsupported |
