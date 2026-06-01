# Genesis Platform Adapter Contract

## Decision

`genesis-core` must depend on platform intent, not platform identity. Platform-specific
details such as Unix Domain Socket paths, Windows Named Pipe handles, file permission
bits, process signals, app container paths, or mobile background policies belong behind
`genesis-platform`.

## Contract Boundary

Allowed in `PlatformAdapter`:

- capability discovery
- private data/cache/temp/evidence directory resolution
- bounded worker execution by intent
- IPC endpoint by service identity or remote URL
- browser open requests by URL intent
- monotonic and wall-clock time

Forbidden in `PlatformAdapter`:

- Unix-only permission modes such as `chmod`
- raw OS signals
- raw file descriptors or OS handles
- hard-coded `/tmp` socket paths
- platform-specific dependency types in public signatures

## First Profiles

| Profile | Meaning |
| --- | --- |
| `DesktopFull` | Desktop node with local workers and browser automation. |
| `DesktopSafe` | Desktop node without native plugin trust. |
| `MobileControl` | Remote-control client only. |
| `MobileLocalLight` | Future mobile local-light runtime. |
| `ServerNode` | Headless server node. |
| `CiRelease` | Strict release validation profile. |

## Current Status

The first implementation is a desktop adapter baseline. It resolves platform directories,
executes bounded workers, exposes capability metadata, and can connect local service IPC
on macOS/Linux through Unix sockets. Desktop adapters can also bind and accept local
service listeners through `IpcListener`, so daemon entrypoints do not need to import
Unix listener or stream types. Loopback TCP has a basic request client. Windows Named
Pipe client and server transports are implemented behind the adapter for local desktop
services.

`genesis-sdk` now exposes both local service send and request flows through the adapter,
so UI shells can use the SDK facade without depending on socket paths or
transport-specific types. The adapter also exposes connect-timeout aware IPC connection,
which preserves the existing actuator dispatch resource boundary during core migration.
Local service address resolution is part of the `PlatformAdapter` trait, so SDK callers
do not duplicate platform routing rules.
For protocols that submit work and poll later, `IpcStream` exposes send, nonblocking, and
read intent without exposing Unix socket or named-pipe concrete types. For service
processes, `IpcListener` exposes bind/accept intent without exposing Unix listener or
named-pipe server types.
Legacy socket-path environment overrides are routed through the desktop adapter helper,
so core/plugins keep compatibility without importing Unix socket or `socket2` APIs.
`scripts/validate_platform_contracts.sh` enforces this boundary in CI/release validation:
the contract crates plus active driver entrypoints must compile for macOS, Linux,
Windows, iOS, Android, and WASI, and transport-specific socket/pipe APIs may only appear
in the desktop adapter modules. The same cross-target checks run with Rust warnings
promoted to errors, so inactive-target dead code cannot silently accumulate. Production
`target_os` platform identity checks are also contained to `genesis-platform` and the
native driver backend files; test modules are ignored by that containment scan.
Legacy Unix socket filenames are contained to the Rust and Python local-service resolver
tables, so business code can depend on service identity rather than path strings.
When `GENESIS_PLATFORM_CONTRACT_EVIDENCE` is set, the gate writes a JSON manifest on both
success and failure. Failed manifests include `status=failed`, `current_step`,
`exit_code`, and the target/package set, so platform contract regressions are auditable
without relying on terminal scrollback.
The autonomous release wrapper also writes `release-precheck.json` before expensive
release gates, making a dirty baseline an explicit evidence item instead of a log-only
failure.
Direct `GENESIS_VALIDATE_PROFILE=release scripts/validate_all.sh` runs use the same
principle: a failed clean precheck writes a blocked validation manifest before exiting.
Each autonomous wrapper run writes `autonomous-summary.json`, which points to the primary
manifest for the run and records whether referenced evidence files exist.
The gate also compiles the `genesis-core` shell with `--no-default-features`; the default
desktop build still includes the Wasmtime-backed `wasm-runtime`, while mobile/control and
cross-target checks can prove the core is not structurally coupled to that runtime.
The gate also compiles the `genesis-replay` shell with `--no-default-features`, so native
dynamic replay remains a desktop feature instead of a mobile/control requirement.

## Canonical Local Services

Local IPC is addressed by service identity, not path syntax:

| Service | Meaning |
| --- | --- |
| `genesis-brain` | Brain / LLM daemon endpoint. |
| `genesis-web-act` | Web arena action endpoint. |
| `genesis-dynamic-act` | Dynamic arena action endpoint. |
| `genesis-os-driver` | Physical OS input driver endpoint. |
| `genesis-vision` | Low-entropy frame-state daemon endpoint. |

The SDK and platform layer reject path-shaped local service names such as
`/tmp/genesis.sock` or `\\.\pipe\genesis`. Platform adapters may map the same service name
to UDS, Named Pipe, loopback TCP, or `Unsupported`, but upstream callers must never encode
those details.

## Remote Control IPC

`MobileControl` uses `IpcEndpoint::RemoteHttp` for the first mobile RPC path. The SDK
exposes `request_remote_http` and `send_remote_http`, while the concrete HTTP/1.1 client
lives in `genesis-platform`. Mobile adapters still refuse local subprocess, local Wasm,
and local IPC service execution, but they can send request/response payloads to a remote
Genesis node through the platform adapter.

The platform contract gate treats TCP and HTTP client primitives as adapter-owned
transport details. Rust `std::net`, `TcpStream`, `TcpListener`, and `ToSocketAddrs` usage
is allowed only in the platform transport modules, so core, SDK callers, plugins, and
drivers cannot bypass the adapter boundary for network IPC.

## Plugin File Access

Core plugin discovery now asks the platform adapter for the current directory,
directory entries, and plugin bytes. `GenesisKernel` loads Wasm plugins from bytes
instead of reading files itself. This keeps path discovery and file reads as injected
platform capabilities, which matters for app containers and mobile control shells.

The platform contract gate enforces `plugin_fs_containment`: production Rust outside
`genesis-platform` cannot call `std::env::current_dir`, `fs::read_dir`, `fs::read`, or
direct `File::open` reads for adapter-owned discovery/input paths. Replay snapshot copy
for audit evidence also goes through `PlatformAdapter::copy_file` rather than direct
`fs::copy`.

Replay sandbox setup also goes through the adapter for private-directory creation, anchor
file copy, and current-directory mutation. The contract gate enforces
`process_cwd_containment`, so production code outside `genesis-platform` cannot call
`std::env::set_current_dir` directly.
