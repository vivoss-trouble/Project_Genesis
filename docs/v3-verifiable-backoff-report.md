# Genesis v3.3 Verifiable Backoff Report

Date: 2026-05-24
Verdict: PASS

## Objective

Prove that Genesis can express a bounded wait as a physical condition, verify
it on the next Sense frame, and preserve the v3.2 cursor invariants without
introducing a timer or retry state machine into the core.

## Test Harness

The validation suite uses a deterministic local HTML fixture at
`http://127.0.0.1:4788/`:

```html
<html>
  <head><title>Wait Fixture</title></head>
  <body><a>Ready</a></body>
</html>
```

Web Arena is deliberately forced into passive HTTP probe mode. This prevents
actuation and makes the test independent of browser installation:

```text
GENESIS_WEB_FORCE_READ_ONLY=1
```

Both timelines pass through Brain UDS, Purifier, the core Act/Verify loop,
strict replay, and SQLite projection.

## Happy Path: Condition Appears

Configuration:

```text
GENESIS_ALLOWED_WAIT_SELECTORS=a
GENESIS_WEB_FALLBACK_WAIT_SELECTOR=a
GENESIS_WEB_FALLBACK_WAIT_MS=1000
```

Observed decision and result:

```json
{
  "act": "wait",
  "ms": 1000,
  "expected_state": {
    "type": "element_visible",
    "selector": "a"
  }
}
```

```text
OutcomeObserved result=Verified
evidence.policy=one_tick_wait_condition
evidence.expected.selector=a
evidence.actual.element_status=visible
PlanAdvanced
```

Conclusion: a passive wait can safely advance its bound cursor step when the
declared condition is visible on the next Sense snapshot.

## Abort Path: Condition Does Not Appear

Configuration:

```text
GENESIS_ALLOWED_WAIT_SELECTORS=button
GENESIS_WEB_FALLBACK_WAIT_SELECTOR=button
GENESIS_WEB_FALLBACK_WAIT_MS=1000
```

The fixture contains no `button`. Observed result:

```json
{
  "act": "wait",
  "ms": 1000,
  "expected_state": {
    "type": "element_visible",
    "selector": "button"
  }
}
```

```text
OutcomeObserved result=Failed
evidence.failure_kind=WaitConditionNotMet
evidence.expected.selector=button
evidence.actual.element_status=not_found
PlanAborted reason="wait_condition_not_met:element_visible:button"
```

Conclusion: the failed wait destroys the bound cursor context. No click, no
retry, and no cross-tick timer policy is introduced.

## Regression Chain

`./scripts/validate_v33.sh` also executes the inherited baselines:

```text
validate_v1.sh  -> PASS
validate_v3.sh  -> PASS
validate_v33.sh -> PASS
```

This proves that typed wait behavior does not change the previously frozen
JIT click/abort paths.

## Final Finding

v3.3 satisfies its controlling rule:

```text
Wait is a verifiable action, not a timing strategy in the core.
```

The system has gained bounded patience while keeping the microkernel ignorant
of tactics, retries, and historical advice.
