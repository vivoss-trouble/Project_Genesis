# Genesis Wasm Plugin Sandbox Presearch

## Verdict

Native Genesis plugins are a trusted extension mechanism, not a sandbox. The next safe boundary for third-party or generated plugins is a Wasm runtime with explicit host capabilities, fuel limits, memory limits, and a stable message ABI.

## Current Boundary

`genesis-core` currently supports trusted native plugins through:

- `libloading`
- `genesis_plugin_entry`
- `GenesisPluginApi`
- watchdog timeout and tainting

This catches plugin panics and timeouts, but it cannot stop undefined behavior, arbitrary syscalls, filesystem writes, network access, or mmap side effects inside the host process.

Native plugin loading is therefore opt-in through:

```bash
GENESIS_ALLOW_NATIVE_PLUGINS=1
```

## Target Boundary

The Wasm plugin runtime should be a separate execution path from the native ABI.

Minimum target properties:

- Wasmtime execution with fuel enabled.
- Fixed maximum linear memory.
- No default filesystem, network, clock, or environment access.
- JSON or bincode message payloads over guest memory.
- Host-owned timeout and fuel exhaustion classification.
- Plugin identity loaded from a signed manifest, not from guest-provided strings alone.

## Minimal ABI

The first Wasm ABI should avoid borrowed host pointers and host-allocated response buffers. Use a copy-in/copy-out memory protocol:

1. Host writes a bounded `GenesisWasmPayload` into guest memory.
2. Host calls `genesis_wasm_on_event(ptr, len) -> u64`.
3. Return value encodes `(response_ptr, response_len)`.
4. Host copies the response out before dropping the instance or store.

Required response fields:

- `status`
- `error_code`
- `data`

Required host controls:

- `max_payload_bytes`
- `max_response_bytes`
- `fuel`
- `max_memory_bytes`

## Migration Order

1. Keep existing native plugins under the opt-in trusted gate.
2. Add a `genesis-wasm-plugin-runner` crate that can execute one wasm file against one payload.
3. Add a dummy Wasm plugin fixture with no WASI imports.
4. Add unit tests for fuel exhaustion, oversized response rejection, and missing export rejection.
5. Add `GenesisKernel::load_wasm_plugin` behind a separate explicit path.
6. Move untrusted/generated plugins to Wasm only.

## Cut 21 Status

Implemented in `genesis-wasm-plugin-runner`:

- Path A linear-memory transport with `genesis_alloc`, `genesis_handle`, and `genesis_dealloc`.
- `genesis_handle(ptr, len) -> u64`, where high 32 bits are response pointer and low 32 bits are response length.
- Host-side envelope types: `PluginRequest`, `PluginResponse`, and `WasmPluginTransport`.
- Host-side bounds checks for input size, output size, and guest memory ranges.
- Wasmtime fuel accounting and store memory limits through `StoreLimits`.
- Fatal trap handling that discards the instance and returns a `FatalPluginCrash` audit payload.

The first implementation deliberately does not use Component Model / WIT. That path remains a future `ComponentModelTransport` candidate behind the same `WasmPluginTransport` trait.

## Non-Goals

- Do not compile `anchor-mmap` to Wasm as-is. Its value is host mmap persistence, which is intentionally outside a pure sandbox.
- Do not expose filesystem or network WASI capabilities in the first runtime.
- Do not replace trusted native plugins until the Wasm runner has equal observability and audit events.

## Release Gate

Before accepting untrusted Wasm plugins:

- `cargo test -p genesis-wasm-plugin-runner --all-targets`
- workspace `cargo clippy --workspace --all-targets -- -D warnings`
- a security boundary test proving native plugin loading is disabled without `GENESIS_ALLOW_NATIVE_PLUGINS=1`
- a fixture test proving a looping Wasm plugin is stopped by fuel exhaustion
