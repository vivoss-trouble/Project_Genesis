# Genesis Dynamic Arena

v4.1 dynamic UI sandbox.

The arena is a controlled 60fps physical field for the next Genesis release
line. It exposes committed frame snapshots over HTTP and accepts coordinate
actions over UDS.

## Contracts

Sense reads the latest committed frame:

```bash
curl http://127.0.0.1:4781/state
```

Actions are queued through:

```text
GENESIS_DYNAMIC_ACT_SOCKET when set, otherwise tempfile.gettempdir()/genesis_dynamic_act.sock
```

Supported action:

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

The arena computes OCC-style verdicts and exposes them in the next committed
snapshot as `last_verdict`.

## Failure Taxonomy

Initial v4 taxonomy:

- `FocusLost`
- `TargetMissing`
- `TargetHidden`
- `TargetOccluded`
- `StaleFrame`
- `CoordinateOutOfBounds`
- `TargetDrift`
- `UnsupportedAction`

Verified actions may still carry warning evidence such as `StaleButHit`.

## Run

Headless by default:

```bash
python3 genesis-daemons/dynamic-arena-python/dynamic_arena.py
```

Optional Pygame visualization:

```bash
GENESIS_DYNAMIC_HEADLESS=0 python3 genesis-daemons/dynamic-arena-python/dynamic_arena.py
```

Selftest:

```bash
GENESIS_DYNAMIC_ARENA_SELFTEST=1 python3 genesis-daemons/dynamic-arena-python/dynamic_arena.py
```
