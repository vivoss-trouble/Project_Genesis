# Genesis v3.2 JIT Cursor Live-Fire Report

Date: 2026-05-24

## Objective

Validate the v3.2 boundary:

```text
PlanDraft -> active_step -> JIT GenesisAction -> v2 Verify -> Advance | Abort
```

The test specifically asserts that the microkernel maintains only a cursor
and action causality, while the Brain compiles tactics from current Sense.

## Success Path: Fantasy Dummy

Setup:

```bash
GENESIS_MACRO_GOAL="Handle a drifting healing target under falling health: observe health, compile only allowlisted heal actions just in time, avoid repeating failed actions, and verify recovery through the v2 loop"
```

The arena health was allowed to decay before the plan began. Observed
timeline:

```text
PlanDrafted plan_id=plan-1 steps=3
PlanActivated plan_id=plan-1
StepActivated step=0
BrainActionDecoded act-4-1 noop
OutcomeObserved act-4-1 Verified
PlanAdvanced 0->1
StepActivated step=1
BrainActionDecoded act-6-2 click #heal-btn
OutcomeObserved act-6-2 Verified health=90
PlanAdvanced 1->2
StepActivated step=2
```

Finding: the heal action was compiled only when its step became active and
was evaluated against the latest health state. Its verified outcome moved
the cursor.

## Abort Path: Forced Read-Only Web Arena

Setup:

```bash
GENESIS_WEB_FORCE_READ_ONLY=1
GENESIS_WEB_ALLOWED_SELECTORS=a
GENESIS_ALLOWED_CLICK_TARGETS=a
GENESIS_WEB_FALLBACK_CLICK=1
GENESIS_MACRO_GOAL="Navigate only if the link selector is safe, observe errors, and abort plan if the read-only arena rejects the click"
```

`a` is allowlisted for planning and purification, but the Arena is placed in
an explicit no-actuation mode. Observed timeline:

```text
PlanActivated plan_id=plan-1
StepActivated step=2 intent="Candidate future selector is allowlisted: a"
BrainActionDecoded act-8-3 click a
OutcomeObserved act-8-3 Failed failure_kind=ReadOnlyMode
PlanAborted plan_id=plan-1 at_step=2 reason="web_failure:ReadOnlyMode:read-only mode rejected click target=a"
PlanDrafted plan_id=plan-9
```

Finding: the physical execution refusal aborted the exact plan step bound to
`act-8-3`. The core did not retry the click; it cleared the cursor and
permitted a subsequent replan.

## Projection Evidence

Successful execution includes:

```text
('PlanAdvanced', 0, 1)
('PlanAdvanced', 1, 2)
('act-6-2', 'click', '#heal-btn', 'Verified')
```

Failure execution includes:

```text
('PlanAborted', 'web_failure:ReadOnlyMode:read-only mode rejected click target=a')
('act-8-3', 'click', 'a', 'Failed', 'ReadOnlyMode')
```

## Verdict

**PASS.**

v3.2 preserves the central invariant: the core can move a single cursor only
when the outcome is causally tied to its accepted action; tactical meaning
and recovery strategy remain outside the kernel.
