# MobileControl Phase 3

Phase 3 adds the first mobile product boundary around `GenesisSdk`.
`genesis-mobile-control` is not a full mobile Genesis node. It is a remote
controller and evidence viewer for iOS and Android shells.

## Boundary

- Uses `MobileControlAdapter` with `RuntimeProfile::MobileControl`.
- Uses only SDK `request_remote_http` and `send_remote_http` for node access.
- Keeps local IPC, local Wasm, native plugins, subprocess workers, Java probe,
  browser automation, and release-gate execution out of the mobile client.
- Treats evidence as remote paged payloads. The client sends bounded evidence
  list/page requests instead of reading node files directly.
- Keeps the SDK shell ABI at `genesis-sdk-shell-v1`.

## Protocol

Every mobile request is JSON plus a trailing newline:

- `node_health`
- `action`
- `evidence_list`
- `evidence_page`

The protocol version is `1`. The remote endpoint remains a caller-provided
`http://` RemoteHttp URL owned by the platform adapter.

## Gate

- `cargo test -p genesis-mobile-control --all-targets`
- `cargo clippy -p genesis-mobile-control --all-targets -- -D warnings`
- `scripts/validate_platform_contracts.sh`

The platform contract gate cross-checks the mobile crate for macOS, Linux,
Windows, iOS, Android, and WASI targets and scans production code for adapter
boundary leaks.
