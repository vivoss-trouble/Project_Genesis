# Desktop Shell Phase 2

Phase 2 adds the first product shell boundary around `GenesisSdk`.

This is intentionally a Rust shell crate, not a GUI framework commitment. Tauri,
Flutter, native menu bar, tray, or AppIndicator shells should call through the
same library surface instead of importing transport or platform details.

## Boundary

- Crate: `genesis-desktop-shell`
- Core dependency path: shell -> `GenesisSdk` -> `PlatformAdapter`
- Production shell code must not import socket, named pipe, TCP, or runtime temp
  path APIs directly.
- SDK ABI remains `genesis-sdk-shell-v1`; Phase 2 does not change the SDK
  contract.

## Commands

```bash
cargo run -p genesis-desktop-shell -- health
cargo run -p genesis-desktop-shell -- evidence-list 0 32
cargo run -p genesis-desktop-shell -- evidence-read run.log 0 4096
cargo run -p genesis-desktop-shell -- send-local-action genesis-web-act '{"act":"noop","reason":"manual smoke"}'
cargo run -p genesis-desktop-shell -- request-remote-action http://127.0.0.1:4777/rpc '{"act":"noop","reason":"manual smoke"}'
```

## Gate

The shell smoke is part of `cargo test --workspace --all-targets`.

It proves:

- SDK contract version is visible to the shell.
- Desktop health can be rendered without platform-specific imports.
- Evidence listing and paged reads work through the SDK.
- Local action sends and remote action requests use SDK transport methods.
- Invalid action JSON is rejected before transport.

`scripts/validate_platform_contracts.sh` includes `genesis-desktop-shell` in the
cross-target package matrix and containment scan.
