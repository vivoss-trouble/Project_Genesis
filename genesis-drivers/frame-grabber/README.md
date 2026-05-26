# Genesis Frame Grabber

v5 optic nerve spike.

This crate probes native frame capture before any YOLO/OCR work. It deliberately
stays outside `genesis-core` and reports physical sampling facts:

- capture backend
- screen-capture permission status
- main-display pixel size
- main-display logical bounds
- Retina scale factor
- bytes per row
- bits per pixel
- capture latency in milliseconds

Run:

```bash
cargo run -p genesis-frame-grabber
```

Run the low-entropy Vision daemon:

```bash
cargo run -p genesis-frame-grabber -- daemon --socket /tmp/genesis_vision_daemon.sock --hz 10
```

Request the latest committed frame state over JSONL:

```bash
printf '{"request_id":"state-1","act":"frame_state"}\n' | nc -U /tmp/genesis_vision_daemon.sock
```

The daemon emits only physical constants and timestamps:

- `frame_id`
- `captured_at_ms`
- `served_at_ms`
- `physical_pixels`
- `logical_bounds`
- `scale_factor`
- `capture_latency_ms`

On macOS, a null `CGDisplayCreateImage` result is reported as
`screen_capture_allowed=false`. Grant Screen Recording permission to the terminal
or Codex host process before expecting real pixel access.

This probe and daemon do not perform object detection, OCR, target extraction, or
action planning. Those belong after the frame sampling boundary is measured and
stable.

## v5.4 Native Marker Baseline

The frame state may include a `marker_detection` object when the controlled
Native Dummy marker is visible and Screen Recording permission is granted. This
is a deterministic color-threshold detector for the `native-heal-marker` only:

- threshold: `R >= 220`, `G <= 45`, `B >= 220`
- output pixel center in physical capture coordinates
- output CoreGraphics logical center for `genesis-os-driver`
- output AppKit logical center for audit comparison

If Screen Recording permission is missing or the marker is not visible,
`marker_detection` is `null`. This is an observation fact, not an error.
