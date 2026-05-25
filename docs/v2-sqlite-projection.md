# Genesis v2 SQLite Projection

Date: 2026-05-24

## Objective

Keep `.genesis-state/audit.jsonl` as the append-only source of truth, then build a disposable SQLite read model for analysis.

This follows the v1 CQRS rule:

```text
JSONL = immutable truth
SQLite = query projection
```

The projection must never sit in the 2 second Tick path.

## Command

```bash
python3 scripts/project_audit_sqlite.py \
  --rebuild \
  --audit .genesis-state/audit.jsonl \
  --db .genesis-state/audit.sqlite
```

Selftest:

```bash
python3 scripts/project_audit_sqlite.py --selftest
```

## Tables

- `audit_records`: raw event stream with `source_path`, `line_no`, `event_type`, and raw JSON.
- `ticks`: `TickStarted` records.
- `senses`: `SenseCaptured` payloads with extracted `health`, `web_title`, `web_mode`, and `last_outcome`.
- `plugin_responses`: plugin status, latency, error code, data hash, and preview.
- `actions`: decoded and dispatched action ledger keyed by `action_id`.
- `plans`: v3 read-only plan drafts keyed by `plan_id`.
- `plan_steps`: v3 plan steps keyed by `(plan_id, step_index)`.
- `plan_events`: v3 cursor lifecycle events such as `PlanActivated`, `StepActivated`, `PlanAdvanced`, and `PlanAborted`.
- `outcomes`: `OutcomeObserved` result, reason, `failure_kind`, policy, target, and evidence.
- `failures`: non-action component failures.
- `replay_snapshots`: replay anchor snapshots.

## Failure Queries

Failure distribution:

```sql
SELECT
  status,
  COALESCE(failure_kind, '<none>') AS failure_kind,
  COUNT(*) AS count
FROM outcomes
GROUP BY status, failure_kind
ORDER BY status, failure_kind;
```

Action to outcome trace:

```sql
SELECT
  actions.action_id,
  actions.source_tick_id,
  actions.dispatched_tick_id,
  actions.act,
  actions.target,
  outcomes.status,
  outcomes.failure_kind,
  outcomes.reason
FROM actions
LEFT JOIN outcomes USING(action_id)
ORDER BY actions.action_id;
```

Single-frame correction checks:

```sql
SELECT
  tick_id,
  last_outcome_action_id,
  last_outcome_status,
  web_title,
  web_mode
FROM senses
WHERE last_outcome_status IS NOT NULL;
```

## Smoke Evidence

Current fallback audit projection:

```text
[audit-sqlite] projected 52 records into /tmp/genesis_audit_projection.sqlite
outcomes:
  Verified / <none> = 3
```

Failure taxonomy audit projection:

```text
[audit-sqlite] projected 32 records into /tmp/genesis_taxonomy_projection.sqlite
('act-2-1', 'Failed', 'ReadOnlyMode', 'web_failure:ReadOnlyMode:read-only mode rejected click target=a')
('act-4-2', 'Verified', None, None)
```

## Non-goals

- No writes from `genesis-core` into SQLite.
- No replacement for JSONL.
- No online migration framework yet.
- No dashboard server yet.

The projection is deliberately rebuildable and disposable.
