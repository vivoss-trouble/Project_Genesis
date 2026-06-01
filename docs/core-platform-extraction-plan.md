# Genesis Core Platform Extraction Plan

## Goal

Move platform-specific runtime assumptions behind `genesis-platform` without changing
current macOS behavior.

## Current Bridge

The first bridge is actuator IPC naming:

| Legacy hard-coded path | Canonical service | Current resolver output on macOS/Linux |
| --- | --- | --- |
| `/tmp/genesis_act.sock` | `genesis-web-act` | temp dir + `genesis_act.sock` |
| `/tmp/genesis_dynamic_act.sock` | `genesis-dynamic-act` | temp dir + `genesis_dynamic_act.sock` |
| `/tmp/genesis_brain.sock` | `genesis-brain` | temp dir + `genesis_brain.sock` |

`genesis-core/src/act.rs` now asks `genesis-platform` for the default actuator
service path. Environment overrides still win:

- `GENESIS_OS_ACT_SOCKET`
- `GENESIS_DYNAMIC_ACT_SOCKET`

The core actuator path resolver now has an injected-runtime-dir test seam
(`actuator_socket_path_with_runtime_dir`). The production call still uses the
current temp directory until the larger `PlatformAdapter` injection reaches the
kernel runtime, but path construction is no longer embedded in the action
delivery branch.

## Next Extraction Steps

1. Move Brain daemon IPC service lookup from raw `/tmp/genesis_brain.sock` to
   `SERVICE_BRAIN`. Done for `brain-llm`; Python daemon now exposes
   `GENESIS_BRAIN_SOCKET` while keeping the same default filename.
2. Update remaining Python daemons to accept canonical service names and resolve platform paths in
   one place. Done for the LLM, Web Arena, and Dynamic Arena daemon defaults through
   `daemon_transport.local_service_socket_path`.
3. Move Rust dummy daemons off literal `/tmp/genesis_*.sock` constants. Done for
   `llm-dummy` and `fantasy-dummy`; both preserve legacy filenames and support
   the existing environment overrides. Their server-side bind/accept loops now use
   `PlatformAdapter::bind_local_service` / `IpcListener`, so Unix listener and stream
   concrete types remain inside `genesis-platform`.
4. Replace the remaining production `std::env::temp_dir()` in core runtime code
   with adapter-provided `DirectoryKind::Temp`. Done for actuator delivery,
   `brain-llm`, Rust dummy daemons, and `genesis-replay`; the remaining `temp_dir`
   references in core are test fixtures.
5. Introduce Windows IPC transport behind `LocalServiceAddress::WindowsNamedPipe` or a
   loopback fallback. Named-pipe client send/request/stream read is now wired behind
   the desktop adapter; Windows service binding is also wired through `IpcListener`.
6. Move core/plugin daemon calls from direct Unix socket types to
   `PlatformAdapter::connect_ipc`; desktop adapter now has a tested UDS client, so the
   remaining work is dependency injection and preserving the current async/poll behavior.
   `GenesisSdk::send_local_service` and `GenesisSdk::request_local_service` are already
   wired through the adapter facade.
   `genesis-core/src/act.rs` now uses the adapter-backed local service path for default
   actuator delivery and legacy socket-path environment overrides; core no longer imports
   Unix socket or `socket2` types for actuator delivery.
   `brain-llm` now stores `Box<dyn IpcStream>` instead of `UnixStream`; its submit/poll
   behavior is preserved, and legacy `GENESIS_BRAIN_SOCKET` is handled through
   `genesis-platform::desktop`. The legacy helper name is transport-neutral at the public
   API boundary; Unix socket details remain inside the desktop adapter implementation.
   `genesis-replay` now emits actuator actions through the same local-service adapter
   path instead of connecting to a hard-coded Unix socket.
   The OS driver and frame grabber daemon entrypoints now bind and accept through
   `IpcListener`; their legacy socket-path CLI/env options are preserved while Unix
   listener details stay inside the desktop adapter implementation.
7. Keep platform dependencies target-scoped. `genesis-platform` now checks on
   `aarch64-apple-darwin`, `wasm32-wasip1`, `x86_64-unknown-linux-gnu`,
   `x86_64-pc-windows-msvc`, `aarch64-apple-ios`, and `aarch64-linux-android`;
   Unix-only `socket2` is limited to macOS/Linux builds.
8. Keep desktop adapter internals modular. `genesis-platform/src/desktop.rs` now delegates
   concrete browser launching, loopback TCP, Unix sockets, Windows named pipes, worker
   execution, and platform root resolution to dedicated `desktop/*` modules.
9. Move user-facing startup defaults away from fixed `/tmp` paths. `start_genesis.sh`
   now derives a runtime dir through Python `tempfile`, exports `GENESIS_BRAIN_SOCKET`
   and `GENESIS_ACT_SOCKET`, and writes daemon logs under the same runtime root unless
   explicitly overridden.
10. Make platform containment a release gate. `scripts/validate_platform_contracts.sh`
    checks the five OS targets plus WASI for the contract crates and fails if Unix
    socket or Windows pipe APIs leak outside the desktop adapter modules. It also fails
    if production Rust code outside `genesis-platform` directly reaches for
    `std::env::temp_dir()` or spawns subprocesses with `Command::new`, keeping runtime
    directory resolution and worker execution behind adapter capabilities. `release`
    validation runs this gate by default through `RUN_PLATFORM_CONTRACTS=1`.
11. Keep the desktop Wasmtime runtime out of mobile/control builds. `genesis-core`
    now gates `genesis-wasm-plugin-runner` behind the default `wasm-runtime` feature;
    `--no-default-features` keeps the core shell, native gate, action dispatcher, and
    verification path compilable without Wasmtime C helper dependencies.
12. Keep replay dynamic loading desktop-scoped. `genesis-replay` now gates `libloading`
    and native plugin replay behind the default `native-replay` feature, while
    `--no-default-features` keeps strict audit, brain mock, and actuator client paths
    available for five-end contract checks without native dynamic library loading.
13. Move active driver daemon defaults to canonical local services. `genesis-os-driver`
    and `genesis-frame-grabber` now bind `SERVICE_OS_DRIVER` and `SERVICE_VISION` by
    default through `PlatformAdapter::bind_local_service`; explicit `--socket` and
    `GENESIS_VISION_SOCKET` remain legacy overrides.

## Non-Goals

- Do not change the current wire protocol.
- Do not remove Unix sockets before Windows transport exists.
- Do not add mobile local execution in the same pass.
