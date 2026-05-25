# Genesis v2 Outcome Verification

Date: 2026-05-24

## Objective

Add the first feedback loop without introducing Planner or Retry complexity.

v1:

```text
BrainActionDecoded -> ActionDispatched
```

v2 first cut:

```text
BrainActionDecoded -> ActionDispatched -> next SenseCaptured -> OutcomeObserved
```

v2 cognitive correction:

```text
ActionDispatched -> OutcomeObserved(Failed) -> SenseCaptured(last_outcome) -> Brain re-evaluates
```

## Event Model

`OutcomeObserved` is appended to `audit.jsonl`:

```json
{
  "type": "OutcomeObserved",
  "payload": {
    "tick_id": 7,
    "action_id": "act-6-3",
    "source_tick_id": 5,
    "dispatched_tick_id": 6,
    "result": { "status": "Verified" },
    "evidence": {
      "policy": "fantasy_heal_health_threshold",
      "target": "#heal-btn",
      "expected": { "health_gte": 90 },
      "actual": { "health": 90 }
    }
  }
}
```

`VerificationResult` supports:

```text
Verified
Failed { reason }
Timeout
```

## Minimal Policies

- `noop`: verified by policy because no world change is requested.
- `click #heal-btn`: verified if `fantasy_state.health >= 90` on the next Sense.
- Web actions: verified if `web_state.last_action.target` matches and `web_state.last_error` is null.
- `wait` and `key`: dispatch-level verification only in this first cut.

## Smoke Test Evidence

Fantasy Dummy fallback run:

```text
BrainActionDecoded action_id=act-6-3 action={"act":"click","target":"#heal-btn"}
ActionDispatched action_id=act-6-3
OutcomeObserved action_id=act-6-3 result=Verified
evidence.expected.health_gte = 90
evidence.actual.health = 90
```

Read-only Web Arena failure run:

```text
ActionDispatched action_id=act-2-1 source_tick_id=1
OutcomeObserved action_id=act-2-1 result=Failed
evidence.failure_kind = "ReadOnlyMode"
evidence.last_error = "read-only mode rejected click target=a"
SenseCaptured tick=3 last_outcome.status = "Failed"
BrainActionDecoded action_id=act-4-2 action=noop
```

`last_outcome` is single-frame feedback. It is stitched into the next payload sent to plugins and then discarded. The core does not retry, repair, or choose a replacement action.

Example `last_outcome` payload:

```json
{
  "status": "Failed",
  "reason": "web_failure:ReadOnlyMode:read-only mode rejected click target=a",
  "action_id": "act-2-1",
  "source_tick_id": 1,
  "dispatched_tick_id": 2,
  "observed_tick_id": 3,
  "action": {
    "act": "click",
    "target": "a",
    "reason": "web fallback clicked allowlisted target=a"
  },
  "evidence": {
    "policy": "web_last_action_matches",
    "target": "a",
    "failure_kind": "ReadOnlyMode",
    "last_error": "read-only mode rejected click target=a"
  }
}
```

## Failure Taxonomy

Web Arena reports failures as two fields:

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

Initial taxonomy:

- `ReadOnlyMode`: action reached a probe-only arena.
- `SelectorNotAllowed`: selector failed the Web Arena allowlist.
- `ActionQueueFull`: actuator queue was saturated.
- `UnsupportedAction`: action type is not supported by Web Arena.
- `InvalidActionJson`: actuator received invalid JSON.
- `PlaywrightUnavailable`: browser automation dependency is missing.
- `PlaywrightLaunchFailed`: Playwright could not launch or open the page.
- Python/Playwright exception class names such as `TimeoutError` or `AssertionError` for execution and refresh failures.

## Non-goals

- No retry policy.
- No automatic repair.
- No multi-step Planner.
- No model-driven verification.

This is only the black-box event model, the first deterministic pure verifier, and a one-frame failure feedback channel for the Brain.

## Query Projection

For analysis, project the JSONL truth stream into SQLite:

```bash
python3 scripts/project_audit_sqlite.py --rebuild
```

Details and query examples live in [v2-sqlite-projection.md](v2-sqlite-projection.md).
