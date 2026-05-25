# Genesis v3 Planner Read Model

Date: 2026-05-24

## Objective

Introduce planning without letting planning control execution.

v3 first cut:

```text
Goal -> PlanDraft -> PlanDrafted -> SQLite plans/plan_steps
```

No `StepActivated`, no cursor, no automatic action dispatch.

## Trigger

Set a macro goal in the Sense payload:

```bash
GENESIS_MACRO_GOAL="restore system health while respecting allowlists"
```

`genesis-core` injects this as:

```json
{
  "macro_goal": "restore system health while respecting allowlists"
}
```

## Plan Schema

The LLM daemon purifier accepts:

```json
{
  "tick": 1,
  "plan_id": "plan-1",
  "goal": "restore system health",
  "steps": [
    {
      "step_index": 0,
      "intent": "observe health and decide whether a heal action is needed",
      "target_selector": null
    }
  ]
}
```

Plan constraints:

- `goal` must be non-empty and is clamped.
- `steps` must be non-empty.
- maximum steps: 8.
- `intent` must be non-empty and is clamped.
- `target_selector` must be null or match `GENESIS_ALLOWED_CLICK_TARGETS`.
- invalid model plan output falls back to a deterministic one-step plan.

## Audit Event

`PlanDrafted` is append-only:

```json
{
  "type": "PlanDrafted",
  "payload": {
    "tick_id": 2,
    "source_tick_id": 1,
    "plan_id": "plan-1",
    "goal": "restore system health",
    "steps": [
      {
        "step_index": 0,
        "intent": "observe health and available controls",
        "target_selector": null
      }
    ]
  }
}
```

## SQLite Projection

The projection creates:

```sql
CREATE TABLE plans (
    plan_id TEXT PRIMARY KEY,
    tick_id INTEGER NOT NULL,
    source_tick_id INTEGER,
    timestamp_ms INTEGER NOT NULL,
    goal TEXT NOT NULL
);

CREATE TABLE plan_steps (
    plan_id TEXT NOT NULL,
    step_index INTEGER NOT NULL,
    intent TEXT NOT NULL,
    target_selector TEXT,
    PRIMARY KEY (plan_id, step_index)
);
```

Query:

```sql
SELECT
  plans.plan_id,
  plans.goal,
  plan_steps.step_index,
  plan_steps.intent,
  plan_steps.target_selector
FROM plans
JOIN plan_steps USING(plan_id)
ORDER BY plans.plan_id, plan_steps.step_index;
```

## Replay

`genesis-replay strict` prints plans and steps. It does not execute them.

## Smoke Evidence

Macro goal run:

```bash
GENESIS_MACRO_GOAL="restore system health while respecting allowlists" \
  cargo run -p genesis-core
```

Observed JSONL:

```json
{
  "type": "PlanDrafted",
  "payload": {
    "tick_id": 2,
    "source_tick_id": 1,
    "plan_id": "plan-1",
    "goal": "restore system health while respecting allowlists",
    "steps": [
      {
        "step_index": 0,
        "intent": "restore system health while respecting allowlists",
        "target_selector": null
      }
    ]
  }
}
```

Replay strict:

```text
tick 2 source_tick 1 plan plan-1 goal="restore system health while respecting allowlists" steps=1
```

SQLite projection:

```text
('plan-1', 'restore system health while respecting allowlists', 0, 'restore system health while respecting allowlists', None)
```

Complex macro-goal run:

```bash
GENESIS_MACRO_GOAL="Handle a drifting healing target under falling health: observe health, identify an allowlisted heal control, avoid repeating failed actions, and verify recovery through the existing v2 loop" \
  cargo run -p genesis-core
```

Observed read-only plan:

```text
PlanDrafted plan_id=plan-1 steps=2
step 0: Observe the current state and preserve v2 Act/Verify boundaries
step 1: Health=90 is stable; prefer observation over action
```

This validates that the fallback planner can emit multi-step strategy while refusing to invent an action when current Sense does not justify one.

## v3.2 JIT Cursor

The second v3 cut activates a plan cursor without compiling actions in core:

```text
PlanDrafted
  -> PlanActivated
  -> StepActivated
  -> SenseCaptured(active_step)
  -> Brain compiles active_step + current state into GenesisAction
  -> Act
  -> Verify
  -> PlanAdvanced | PlanAborted
```

Core responsibilities:

- store `ActivePlan { plan_id, steps, current_index, awaiting_action_id }` in memory only.
- inject the current `active_step` into Sense.
- bind an accepted tactical dispatch to its `action_id`.
- advance on `OutcomeObserved(Verified)` only when it matches the bound action.
- abort and clear cursor on matching `Failed` or `Timeout`.

Core non-responsibilities:

- no intent parsing.
- no action compilation.
- no retry.
- no selector repair.

If an `active_step` is present, the LLM daemon must output a normal `GenesisAction`, not another plan. The core rejects PlanDraft output while a step is active.

## v3.2 Smoke Evidence

Setup:

```bash
GENESIS_MACRO_GOAL="Handle a drifting healing target under falling health: observe health, compile only allowlisted heal actions just in time, avoid repeating failed actions, and verify recovery through the v2 loop"
```

Observed replay:

```text
PlanDrafted plan_id=plan-1 steps=3
StepActivated step=0 intent="Observe the current state and preserve v2 Act/Verify boundaries"
BrainActionDecoded act-4-1 noop
PlanAdvanced 0->1
StepActivated step=1 intent="Candidate future action: health=50 is below threshold; consider heal control through existing Act pipeline"
BrainActionDecoded act-6-2 click #heal-btn
OutcomeObserved act-6-2 Verified health=90
PlanAdvanced 1->2
StepActivated step=2 intent="Verify that a future heal action restores health to at least 90"
```

SQLite projection:

```text
PLAN_EVENTS
('PlanActivated', None, None, None, None)
('StepActivated', 0, None, None, None)
('PlanAdvanced', None, 0, 1, None)
('StepActivated', 1, None, None, None)
('PlanAdvanced', None, 1, 2, None)
('StepActivated', 2, None, None, None)

ACTIONS
('act-4-1', 'noop', None, 'Verified')
('act-6-2', 'click', '#heal-btn', 'Verified')
```

## Non-goals

- No core-side intent parsing.
- No core-side action compilation.
- No automatic selector repair.
- No retry policy.
- No branching timeline.

The v3 invariant is: the Brain may draft a strategy and compile the current active step, but only the v2 action pipeline can do work.

## v3.2 Fail-Fast Evidence

The Web Arena read-only probe was used as a deliberate physical rejection point:

```text
StepActivated step=2 intent="Candidate future selector is allowlisted: a"
BrainActionDecoded act-8-3 click a
OutcomeObserved act-8-3 Failed failure_kind=ReadOnlyMode
PlanAborted plan_id=plan-1 at_step=2 reason="web_failure:ReadOnlyMode:read-only mode rejected click target=a"
PlanDrafted plan_id=plan-9
```

The aborted cursor is tied to `act-8-3`; a failure from any unrelated dispatched action cannot advance or abort that plan. After abort, the next planning pass is a new plan rather than a core-side retry.
