# Genesis Frame Grabber

v5 optic nerve spike.

This crate probes native frame capture before any YOLO/OCR/Vision daemon work.
It deliberately stays outside `genesis-core` and reports physical sampling facts:

- capture backend
- screen-capture permission status
- main-display pixel size
- bytes per row
- bits per pixel
- capture latency in milliseconds

Run:

```bash
cargo run -p genesis-frame-grabber
```

On macOS, a null `CGDisplayCreateImage` result is reported as
`screen_capture_allowed=false`. Grant Screen Recording permission to the terminal
or Codex host process before expecting real pixel access.

This probe does not perform object detection, OCR, target extraction, or action
planning. Those belong in a future Vision daemon after the frame sampling
boundary is measured and stable.
