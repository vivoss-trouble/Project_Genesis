# Project Genesis v3.3 Release Notes

Release date: 2026-05-24
Status: Frozen Baseline
Theme: Verifiable Single-Tick Backoff

## Summary

Genesis v3.3 freezes the first baseline where the Brain can express patience
without giving timing strategy to the microkernel.

v3.2 established JIT plan execution with strict action-to-cursor causality.
v3.3 upgrades `GenesisAction::Wait` from dispatch-only behavior into a typed,
next-tick observation contract:

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

## Milestones

### 1. Typed Wait Condition

Every wait must declare a physical condition. The initial supported condition
is deliberately narrow:

```text
element_visible { selector }
```

The Python purifier accepts only selectors explicitly listed in
`GENESIS_ALLOWED_WAIT_SELECTORS`, while Web Arena accepts only conditions for
selectors that are part of `GENESIS_WEB_OBSERVED_SELECTORS`.

### 2. Single-Tick Time Barrier

Wait duration is limited to `0..2000ms`, matching the current heartbeat and
next-Sense verification horizon.

The action does not create a multi-tick timer in the core. It does not block
the actuator worker. It only states: observe this condition at the next
physical snapshot.

### 3. Condition Verification And Fail-Fast Abort

The existing v3.2 cursor contract remains authoritative:

```text
BrainActionDecoded(wait + expected_state)
  -> ActionDispatched
  -> next Sense
  -> OutcomeObserved(Verified | Failed)
  -> PlanAdvanced | PlanAborted
```

If the expected element is absent, verification emits:

```text
failure_kind = WaitConditionNotMet
reason = wait_condition_not_met:element_visible:<selector>
```

The bound plan step is then aborted. The core does not retry, extend the
wait, or invent a replacement selector.

## Release Invariants

- **Wait is an action, not core strategy.** The microkernel contains no
  backoff loop, retry policy, or conditional planner behavior.
- **No unknown future is awaited.** A wait that exceeds the one-tick
  verification horizon is rejected before dispatch.
- **No hidden sleeping occurs.** Web Arena records a passive wait, and the
  heartbeat interval provides the observation window.
- **Causality remains locked.** Only the outcome for the action bound by
  `awaiting_action_id` may advance or abort the active plan.
- **Models remain untrusted.** Purifier validation and observed-selector
  allowlists remain mandatory before any wait condition is admitted.

## Validation

The v3.3 baseline suite is:

```bash
./scripts/validate_v33.sh
```

It performs:

- inherited v1 and v3.2 redline verification;
- Rust unit tests for wait budget and condition verdicts;
- Python purifier and Web Arena selftests;
- a deterministic local-DOM success path;
- a deterministic local-DOM missing-element abort path;
- replay and SQLite assertions for both timelines.

Observed success:

```text
wait(selector=a, ms=1000)
  -> OutcomeObserved(Verified, element_status=visible)
  -> PlanAdvanced
```

Observed failure:

```text
wait(selector=button, ms=1000)
  -> OutcomeObserved(Failed, failure_kind=WaitConditionNotMet)
  -> PlanAborted
```

## Support Boundary

v3.3 supports:

- a single active sequential plan cursor;
- JIT action compilation for the current step;
- passive single-tick waits for observed element visibility;
- fail-fast abort and replan after a failed wait;
- replay and SQLite projection of wait evidence.

v3.3 does not support:

- automatic retry or exponential backoff;
- waits spanning multiple heartbeat intervals;
- branching or parallel planning;
- historical SQLite read-model advice to the Brain;
- semantic retrieval or long-term memory injection.

Historical read-model advice belongs to a later release line and must build
on this frozen temporal baseline.
