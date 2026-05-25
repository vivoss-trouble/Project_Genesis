# Genesis v4 Dynamic Taxonomy Blueprint

Date: 2026-05-24
Branch: `codex/v4-dynamic-taxonomy`

## Principle

Do not try to win the dynamic UI field first. Learn to lose with evidence.

v4 begins with a controlled dynamic arena, not a Rust/WinAPI target. The goal
is to freeze a clean taxonomy for frame drift, target motion, focus loss, and
render instability before introducing operating-system noise.

## v4.1 Dynamic Arena

The first arena is a Python daemon under
`genesis-daemons/dynamic-arena-python/`.

It has three responsibilities:

```text
60fps world loop
  -> atomic committed snapshot
  -> HTTP Pull /state

UDS /act
  -> enqueue click_point
  -> OCC verdict in next committed snapshots
```

The Sense contract deliberately reads a committed frame, not live memory:

```json
{
  "frame_id": 1842,
  "captured_at_ms": 123456789,
  "served_at_ms": 123456800,
  "sense_latency_ms": 11,
  "fps": 60,
  "focused": true,
  "jank": false,
  "targets": [
    {
      "id": "heal",
      "visible": true,
      "hidden": false,
      "occluded": false,
      "x": 312,
      "y": 188,
      "w": 64,
      "h": 32,
      "confidence": 0.94
    }
  ],
  "last_verdict": null
}
```

## v4.2 Coordinate Action

The next protocol expansion is a coordinate action:

```json
{
  "act": "click_point",
  "target_id": "heal",
  "x": 312,
  "y": 188,
  "frame_id": 1842,
  "reason": "target visible in latest frame"
}
```

`frame_id` is the optimistic-concurrency version number. A hit is evaluated
against the arena's current committed physics, not against the action's
historical frame.

## OCC Verdict Rules

Initial thresholds:

```text
FRESH_FRAME_TOLERANCE = 2 frames
MAX_SPATIAL_DRIFT_PX = 6 px
```

Strict short-circuit order:

```text
1. FocusLost
2. TargetMissing
3. TargetHidden
4. TargetOccluded
5. StaleFrame
6. CoordinateOutOfBounds
7. TargetDrift
8. Verified
```

Success must still be honest:

```text
frame_delta <= 2 and point inside current hitbox
  -> Verified

frame_delta > 2 and point inside current hitbox
  -> Verified warning_kind=StaleButHit

frame_delta <= 2 and point outside current hitbox
  -> Failed failure_kind=TargetDrift

frame_delta > 2 and point outside current hitbox
  -> Failed failure_kind=StaleFrame
```

`StaleButHit` is not a failure. It is an early-warning signal that should be
visible in SQLite trends before the system starts missing.

## Current Implementation Boundary

Implemented now:

- headless Python 60fps arena loop;
- optional Pygame visualization when installed and enabled;
- committed-frame HTTP `/state` endpoint;
- UDS action endpoint at `/tmp/genesis_dynamic_act.sock`;
- `click_point` verdict calculation inside the arena;
- `scripts/validate_v4_dynamic_arena.sh` for committed-frame and OCC smoke validation.

Not implemented yet:

- `GenesisAction::ClickPoint` in Rust;
- dynamic-state verifier in `genesis-core`;
- dynamic failure projection columns in SQLite;
- Brain purifier support for coordinate actions;
- v4 memory advisory over `StaleButHit` and `TargetDrift` trends;
- Rust/WinAPI or mmap zero-copy arena.

## Validation

```bash
./scripts/validate_v4_dynamic_arena.sh
```

This validates that committed frames advance, action UDS accepts a
`click_point`, and the arena emits both verified and failed OCC verdicts.
