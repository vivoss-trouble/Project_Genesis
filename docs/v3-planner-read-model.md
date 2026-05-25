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

## Non-goals

- No execution cursor in `genesis-core`.
- No `StepActivated`.
- No automatic conversion from plan step to action.
- No retry policy.
- No branching timeline.

The first v3 invariant is: the Brain may draft a strategy, but only the v2 action pipeline can do work.
