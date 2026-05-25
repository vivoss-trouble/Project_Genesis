# Genesis v3.4 Memory-Guided Live-Fire

Date: 2026-05-24
Status: Deterministic causal experiment

## Question

Can bounded historical advice change the Brain's tactical output without
granting history any direct execution privilege?

## Experiment Design

The test uses a validation-only synthetic Brain exposed by
`GENESIS_TEST_MEMORY_GUIDED_MODEL=1`. This is not a production fallback and
does not claim to measure a particular GGUF model's behavior. It is a
deterministic instrument that consumes the same prompt assembled for a real
model and returns output through the same Purifier, UDS, Act, Verify, Audit,
Replay, and SQLite paths.

Both universes observe the same local Web Arena target:

```text
selector = a
arena mode = forced read-only HTTP probe
visible element = true
```

The advisory projection is seeded with four prior failed clicks:

```text
target=a, act=click, failure_kind=ReadOnlyMode, count=4
```

Only the experimental universe sets `GENESIS_ADVISORY_DB`.

## Control Universe: No Memory

Without a historical advisory, the controlled Brain compiles the active step
as an allowlisted click:

```text
PlanDrafted
  -> StepActivated(target=a)
  -> BrainActionDecoded(click a)
  -> OutcomeObserved(Failed, ReadOnlyMode)
  -> PlanAborted
```

## Advisory Universe: Memory Attached

With the bounded historical summary attached to the prompt, the same
controlled Brain avoids the historically rejected click and chooses passive
verification:

```text
PlanDrafted
  -> StepActivated(target=a)
  -> MemoryAdvisoryAttached(scope=active_step_target, sample_count=4)
  -> BrainActionDecoded(wait element_visible=a)
  -> OutcomeObserved(Verified)
  -> PlanAdvanced
```

## Safety Interpretation

This experiment proves causality at the protocol boundary:

- the prompt-only advisory can alter a tactical candidate;
- the altered candidate still must satisfy Purifier and Act/Verify;
- history never becomes an action or bypasses an allowlist;
- the evidence is visible through JSONL, Replay, and SQLite projection.

Real local-model evaluation remains an empirical follow-up, not a deterministic
release redline.

## Validation

Fast experiment only:

```bash
GENESIS_MEMORY_LIVE_FIRE_SKIP_BASELINE=1 ./scripts/validate_v34_memory_live_fire.sh
```

Experiment with the full inherited v3.4 redline first:

```bash
./scripts/validate_v34_memory_live_fire.sh
```
