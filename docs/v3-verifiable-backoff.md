# Genesis v3.3 Verifiable Backoff

Date: 2026-05-24

## Boundary

v3.3 introduces one conditional action:

```json
{
  "act": "wait",
  "ms": 1000,
  "expected_state": {
    "type": "element_visible",
    "selector": "a"
  },
  "reason": "wait for observed control"
}
```

`Wait` is not a core retry strategy. It is a passive, one-tick observation
bet: do no physical work during this step, then verify the declared condition
against the next Sense snapshot.

## Invariants

- `ms` is restricted to `0..2000`, matching the current next-tick
  verification horizon.
- The initial supported expectation is only
  `element_visible { selector }`.
- Python Purifier permits only selectors in
  `GENESIS_ALLOWED_WAIT_SELECTORS`.
- Web Arena accepts a wait only when the selector is included in
  `GENESIS_WEB_OBSERVED_SELECTORS`.
- The Actuator does not sleep or block a command worker for a wait; the
  heartbeat interval provides the observation window.
- A missing condition emits `WaitConditionNotMet`, and the existing bound
  action rule converts it into `PlanAborted`.

## Evidence

Visible local-fixture selector:

```text
BrainActionDecoded {"act":"wait","ms":1000,"expected_state":{"type":"element_visible","selector":"a"}}
OutcomeObserved Verified
evidence.actual.element_status = "visible"
PlanAdvanced
```

Missing local-fixture selector:

```text
BrainActionDecoded {"act":"wait","ms":1000,"expected_state":{"type":"element_visible","selector":"button"}}
OutcomeObserved Failed failure_kind=WaitConditionNotMet
evidence.actual.element_status = "not_found"
PlanAborted reason="wait_condition_not_met:element_visible:button"
```

## Validation

```bash
./scripts/validate_v33.sh
```

The script inherits `validate_v3.sh`, hosts a deterministic local HTML
fixture, and executes both the verified and failed wait timelines through the
full UDS, replay, and SQLite projection path.
