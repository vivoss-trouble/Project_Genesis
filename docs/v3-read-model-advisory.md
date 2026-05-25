# Genesis v3.4 Read Model Advisory

Date: 2026-05-24

## Boundary

v3.4 adds historical context to the Brain as advice, never as an action:

```text
SQLite projection -> bounded prompt advisory -> Brain -> existing Purifier -> Act -> Verify
```

There is no `QueryHistory` action. `genesis-core` does not open SQLite and does
not make a historical statistic executable.

## Read Contract

Set `GENESIS_ADVISORY_DB` to an existing SQLite audit projection. While an
allowlisted `active_step.target_selector` is present, the Python Brain daemon
may execute its fixed read-only query template and construct:

```json
{
  "scope": "active_step_target",
  "target_selector": "a",
  "sample_count": 3,
  "recent_failures": {
    "ReadOnlyMode": 1,
    "WaitConditionNotMet": 1
  },
  "last_verified_action": "wait"
}
```

The sample window is capped at 100 rows and the query budget is capped at
50ms. Missing databases, absent schema, timeout, and query failure produce no
advisory and leave the normal Brain path unchanged. Failure kinds are reduced
to a fixed taxonomy; unrecognized historical values collapse to `Other`
rather than entering the prompt as arbitrary text.

## Audit Contract

Advice enters only the daemon prompt. If it exists, the daemon may wrap its
normal result with bounded metadata:

```json
{
  "action": {
    "tick": 9,
    "act": "wait",
    "ms": 1000,
    "expected_state": {"type": "element_visible", "selector": "a"},
    "reason": "wait for allowlisted target"
  },
  "advisory_meta": {
    "scope": "active_step_target",
    "sample_count": 3,
    "hash": "0123456789abcdef"
  }
}
```

The core validates that metadata shape and records:

```text
MemoryAdvisoryAttached(scope=active_step_target, sample_count=3, hash=...)
```

It then discards the wrapper and processes only the inner decision through the
existing action and plan decoders. Consequently `BrainActionDecoded` remains a
clean physical decision ledger, not a copy of memory context.

## Invariants

- Current Sense outranks historical statistics in the model prompt.
- Purifier and Web Arena allowlists remain the only path to physical work.
- SQLite is a disposable read projection; JSONL remains the truth source.
- Historical advice silently disappears when unavailable or invalid.
- Advisory metadata is visible to Replay and the SQLite projection, but is
  bounded before entering the audit stream.

## Validation

```bash
./scripts/validate_v34.sh
```

The suite seeds a deterministic historical projection, runs a JIT wait against
a local DOM fixture, and asserts that a `MemoryAdvisoryAttached` stamp is
projected while the decoded action remains free of advisory metadata.
