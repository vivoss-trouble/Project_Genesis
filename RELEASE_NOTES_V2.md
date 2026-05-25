# Project Genesis v2 Release Notes

Release date: 2026-05-24

## Summary

Genesis v2 freezes the first baseline where the system can execute an action, observe the physical result, feed failure evidence back to the Brain, and project the append-only audit stream into a queryable SQLite read model.

v1 proved that Genesis can do work. v2 proves that Genesis can observe the cost and outcome of that work without turning the microkernel into a planner.

## Milestones

### 1. Outcome Verification

Genesis now records whether dispatched actions produced an observable result.

```text
BrainActionDecoded
  -> ActionDispatched
  -> SenseCaptured
  -> OutcomeObserved(Verified | Failed | Timeout)
```

The verifier is a pure policy layer. It reads the next Sense payload and emits evidence into `OutcomeObserved`; it does not retry, repair, or choose a replacement action.

Current policies:

- `noop`: verified by definition.
- Fantasy `click #heal-btn`: verified when `fantasy_state.health >= 90`.
- Web DOM actions: verified when `web_state.last_action.target` matches and `web_state.last_error` is null.
- `wait` and `key`: dispatch-level verification only.

### 2. Cognitive Correction

Verification failure is treated as environment fact, not core strategy.

When an action fails, `genesis-core` creates a one-frame `last_outcome` payload and stitches it into the next Brain context:

```text
OutcomeObserved(Failed)
  -> SenseCaptured(last_outcome)
  -> Brain re-evaluates
```

The core still does not contain retry logic. It only moves the failure evidence across the timeline. The Python LLM daemon prompt and fallback path reject repeating the exact same failed `act/target` pair.

### 3. Failure Taxonomy

Web Arena failures are now split into a machine-readable kind and a human-readable message:

```json
{
  "last_error_kind": "ReadOnlyMode",
  "last_error": "read-only mode rejected click target=a"
}
```

The verifier copies this into `OutcomeObserved.evidence.failure_kind` and folds it into the failure reason:

```text
web_failure:ReadOnlyMode:read-only mode rejected click target=a
```

Initial failure kinds include:

- `ReadOnlyMode`
- `SelectorNotAllowed`
- `ActionQueueFull`
- `UnsupportedAction`
- `InvalidActionJson`
- `PlaywrightUnavailable`
- Playwright/Python exception class names such as `TimeoutError` and `AssertionError`

### 4. SQLite Projection

Genesis now has a disposable SQL read model for audit analysis:

```bash
python3 scripts/project_audit_sqlite.py \
  --rebuild \
  --audit .genesis-state/audit.jsonl \
  --db .genesis-state/audit.sqlite
```

The source of truth remains `.genesis-state/audit.jsonl`. SQLite is only a projection and can be deleted and rebuilt at any time.

Projected tables include:

- `audit_records`
- `ticks`
- `senses`
- `plugin_responses`
- `actions`
- `outcomes`
- `failures`
- `replay_snapshots`

## v2 Closed Loop

```text
Sense
  -> Shield
  -> Anchor
  -> Brain
  -> Purifier
  -> Act
  -> Verify
  -> last_outcome
  -> Brain correction
  -> Audit JSONL
  -> SQLite Projection
```

## Release Invariants

- **The core stays simple.** Rust microkernel code does not contain Planner, retry, backoff, or automatic repair logic.
- **JSONL is truth.** SQLite is a query projection, never the canonical timeline.
- **Models remain untrusted.** LLM output must pass purifier schema checks and target allowlists.
- **Actuation remains sandboxed.** Web Arena selector allowlists remain the final DOM execution gate.
- **v1 remains green.** `scripts/validate_v1.sh` must pass after v2 changes.

## Validation

Static and baseline checks:

```bash
cargo check --all-targets
scripts/validate_v1.sh
```

Daemon selftests:

```bash
GENESIS_WEB_ARENA_SELFTEST=1 python3 genesis-daemons/web-arena-python/web_arena.py
GENESIS_DAEMON_SELFTEST=1 python3 genesis-daemons/llm-daemon-python/llm_daemon.py
```

Replay checks:

```bash
cargo run -p genesis-replay -- strict --audit .genesis-state/audit.jsonl
cargo run -p genesis-replay -- simulate --audit .genesis-state/audit.jsonl
cargo run -p genesis-replay -- brain-mock --audit .genesis-state/audit.jsonl
```

SQLite projection checks:

```bash
python3 scripts/project_audit_sqlite.py --selftest
python3 scripts/project_audit_sqlite.py --rebuild \
  --audit .genesis-state/audit.jsonl \
  --db /tmp/genesis_audit_projection.sqlite
```

Example SQL:

```sql
SELECT status, COALESCE(failure_kind, '<none>'), COUNT(*)
FROM outcomes
GROUP BY status, failure_kind
ORDER BY status, failure_kind;
```

Observed projection smoke:

```text
[audit-sqlite] projected 52 records into /tmp/genesis_audit_projection.sqlite
('Verified', '<none>', 3)
```

Failure taxonomy smoke:

```text
('act-2-1', 'Failed', 'ReadOnlyMode',
 'web_failure:ReadOnlyMode:read-only mode rejected click target=a')
```

## Support Boundary

v2 supports:

- Outcome verification for Fantasy Dummy and basic Web Arena actions.
- One-frame `last_outcome` feedback for cognitive correction.
- Machine-readable Web Arena failure taxonomy.
- Offline SQLite projection of JSONL audit records.
- SQL queries over actions, outcomes, failures, senses, and plugin responses.

v2 does not claim support for:

- Multi-step planning.
- Automatic retry or exponential backoff.
- Branching timelines.
- Long-term semantic retrieval over the audit log.
- Planner-driven browser workflows.
- Online dashboard service or live SQLite sync daemon.

These are v3 scope.

## v3 Horizon

v3 may introduce Planner, Retry, and multi-step goals, but it must build on top of the v2 feedback substrate:

```text
Planner decisions must be explainable through action_id, source_tick_id,
OutcomeObserved, failure_kind, and replayable audit evidence.
```

If a future Planner cannot survive replay and SQL audit, it does not belong in the core.
