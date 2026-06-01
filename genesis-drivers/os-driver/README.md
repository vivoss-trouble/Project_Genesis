# Genesis OS Driver

v5 physical abstraction spike.

This crate deliberately stays outside `genesis-core`. It probes the real OS
input layer and exposes a small `GenesisPhysicalDriver` trait without adding OS
policy to the microkernel.

## Commands

```bash
cargo run -p genesis-os-driver -- probe
cargo run -p genesis-os-driver -- selftest
cargo run -p genesis-os-driver -- daemon
cargo run -p genesis-os-driver -- move --x 100 --y 100
cargo run -p genesis-os-driver -- click --x 100 --y 100
```

`move` and `click` are dry-run by default. To post real macOS CoreGraphics input
events, pass `--armed`:

```bash
cargo run -p genesis-os-driver -- click --x 100 --y 100 --armed --confirm GENESIS_OS_DRIVER_ARMED
```

Armed mode requires macOS Accessibility permission for the terminal or Codex
host process.

The daemon binds the canonical `genesis-os-driver` local service by default and
speaks one JSON request per line. On macOS/Linux this currently maps to
`<system temp dir>/genesis_os_driver.sock`. Pass `--socket` to pin a specific
legacy path:

```json
{"request_id":"probe-1","act":"probe"}
{"request_id":"click-1","action_id":"act-v5-1","act":"click_point","x":100,"y":100}
```

Local physical-field coordinates can be mapped into global macOS coordinates at
the final driver boundary with viewport offsets:

```bash
GENESIS_OS_VIEWPORT_X=320 GENESIS_OS_VIEWPORT_Y=180 \
  cargo run -p genesis-os-driver -- daemon
```

For the example above, a request with `x=100,y=100` is posted as global
`x=420,y=280`. The response includes both the `viewport_offset` and the mapped
receipt point. Receipts also include `cursor_position`, sampled from
CoreGraphics after the driver action, so armed calibration can distinguish a
failed OS cursor move from a higher-level AppKit coordinate mismatch.

The daemon is dry-run unless started with both `--armed` and the confirmation
token:

```bash
cargo run -p genesis-os-driver -- daemon --armed --confirm GENESIS_OS_DRIVER_ARMED
```

You can also provide the token through:

```bash
GENESIS_OS_DRIVER_CONFIRM=GENESIS_OS_DRIVER_ARMED
```

## macOS Accessibility

Armed CoreGraphics events require Accessibility permission.

1. Open **System Settings**.
2. Go to **Privacy & Security** -> **Accessibility**.
3. Enable the terminal or Codex host application that launches
   `genesis-os-driver`.
4. Re-run `cargo run -p genesis-os-driver -- probe` and confirm
   `accessibility_trusted` is `true`.

If `accessibility_trusted` is `false`, dry-run mode still works, but armed
`move` and `click` commands are rejected before posting events.

## Boundary

- The driver owns OS coordinates, display geometry, DPI scale, and native input
  injection.
- Viewport offsets are owned by the driver, so `genesis-core` can keep emitting
  local `click_point` coordinates.
- `genesis-core` remains unaware of Retina scaling, Accessibility prompts, and
  physical cursor APIs.
- The first backend is macOS CoreGraphics through minimal FFI. Cross-platform
  wrappers can be evaluated later after the physical facts are known.
