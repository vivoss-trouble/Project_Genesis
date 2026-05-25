# Project Genesis v3.2 Release Notes

Release date: 2026-05-24

## Summary

Genesis v3.2 freezes the first baseline where a macro goal can become a
multi-step plan, and each current step can be compiled just in time against
fresh Sense state without giving strategy ownership to the Rust microkernel.

v2 proved that Genesis can verify and reflect on actions. v3.2 proves that
Genesis can execute a single sequential plan while preserving that feedback
boundary.

## Milestones

### 1. Planner Read Model (v3.1)

The Brain can return a validated `PlanDraft` when Sense contains
`macro_goal`. The audit stream and SQLite projection record the goal and
steps:

```text
SenseCaptured(macro_goal)
  -> PlanDrafted
  -> plans / plan_steps projection
```

Planner output remains subject to schema validation, step limits, text
limits, and selector allowlists.

### 2. JIT Cursor Control (v3.2)

The core stores only an in-memory cursor:

```text
ActivePlan { plan_id, steps, current_index, awaiting_action_id }
```

For the active step, Sense receives an `active_step` context. The Brain then
switches from planner to tactical compiler mode and returns an ordinary
`GenesisAction` based on the newest observed state.

```text
PlanDrafted
  -> PlanActivated
  -> StepActivated
  -> SenseCaptured(active_step)
  -> BrainActionDecoded
  -> ActionDispatched
  -> OutcomeObserved
  -> PlanAdvanced | PlanAborted
```

### 3. Strict Causal Binding

An accepted tactical action is bound to the active cursor through
`awaiting_action_id`. Only the outcome for that exact action may advance or
abort the plan. Delayed or unrelated outcomes cannot corrupt a newer step.

### 4. Fail-Fast Abort

When the bound action produces `Failed` or `Timeout`, the active plan is
discarded immediately:

```text
OutcomeObserved(Failed | Timeout)
  -> PlanAborted
  -> last_outcome in next Sense
  -> new PlanDraft, if the Brain elects to replan
```

The core performs no automatic retry and no selector repair.

## Release Invariants

- **The core owns timing and causality only.** It does not interpret
  `intent`, compile actions, repair selectors, or choose retry strategy.
- **The Brain cannot bypass actuation gates.** JIT-produced actions continue
  through the v2 purifier, allowlists, actuator, verifier, and audit chain.
- **Only a bound outcome moves a cursor.** `awaiting_action_id` is the
  authorization token for `PlanAdvanced` and `PlanAborted`.
- **Failure destroys the current tactical context.** A new plan is preferable
  to silently continuing from a contaminated page state.
- **JSONL remains truth.** SQLite remains a disposable read projection.

## Live-Fire Evidence

Fantasy success timeline:

```text
PlanActivated plan-1
StepActivated 1
BrainActionDecoded act-6-2 click #heal-btn
OutcomeObserved act-6-2 Verified health=90
PlanAdvanced 1->2
```

Forced read-only Web Arena abort timeline:

```text
StepActivated 2 intent="Candidate future selector is allowlisted: a"
BrainActionDecoded act-8-3 click a
OutcomeObserved act-8-3 Failed failure_kind=ReadOnlyMode
PlanAborted plan-1 at_step=2
PlanDrafted plan-9
```

## Validation

Run the v3.2 baseline suite:

```bash
./scripts/validate_v3.sh
```

It executes the inherited v1 baseline, the Fantasy successful JIT path, the
deterministic Web Arena fail-fast path, strict replay, and SQLite projection
assertions.

## Support Boundary

v3.2 supports:

- one active sequential plan cursor;
- JIT compilation of the current step only;
- verified advance and fail-fast abort;
- replay and SQL projection of plan lifecycle events.

v3.2 does not support:

- branching or parallel plans;
- retry or exponential backoff;
- conditional execution inside the core;
- semantic long-term memory or RAG over audit history.

Those capabilities must be developed against this frozen causal baseline.
