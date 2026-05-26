# Genesis OS Driver

v5 physical abstraction spike.

This crate deliberately stays outside `genesis-core`. It probes the real OS
input layer and exposes a small `GenesisPhysicalDriver` trait without adding OS
policy to the microkernel.

## Commands

```bash
cargo run -p genesis-os-driver -- probe
cargo run -p genesis-os-driver -- selftest
cargo run -p genesis-os-driver -- move --x 100 --y 100
cargo run -p genesis-os-driver -- click --x 100 --y 100
```

`move` and `click` are dry-run by default. To post real macOS CoreGraphics input
events, pass `--armed`:

```bash
cargo run -p genesis-os-driver -- click --x 100 --y 100 --armed
```

Armed mode requires macOS Accessibility permission for the terminal or Codex
host process.

## Boundary

- The driver owns OS coordinates, display geometry, DPI scale, and native input
  injection.
- `genesis-core` remains unaware of Retina scaling, Accessibility prompts, and
  physical cursor APIs.
- The first backend is macOS CoreGraphics through minimal FFI. Cross-platform
  wrappers can be evaluated later after the physical facts are known.
