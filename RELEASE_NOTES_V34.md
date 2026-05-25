# Project Genesis v3.4 Release Notes

Release date: 2026-05-24
Status: Frozen Baseline
Theme: Prompt-Only Read Model Advisory

## Summary

Genesis v3.4 freezes the first baseline where long-term operational memory can
inform Brain decisions without entering the physical action path.

v3.3 established a single-tick time barrier for verifiable waits. v3.4 adds a
bounded, read-only advisory channel from the SQLite audit projection into the
Brain prompt:

```text
SQLite projection -> bounded advisory -> Brain prompt -> Purifier -> Act -> Verify
```

History can now speak, but it still has no hands.

## Milestones

### 1. Prompt-Only Historical Advisory

The Python Brain daemon may read `GENESIS_ADVISORY_DB` only when an
`active_step.target_selector` is present and allowlisted. The query path is a
fixed template over the audit projection, not arbitrary SQL.

The advisory is deliberately low entropy:

```json
{
  "scope": "active_step_target",
  "target_selector": "a",
  "sample_count": 4,
  "recent_failures": {
    "ReadOnlyMode": 4
  },
  "last_verified_action": null
}
```

Unknown historical failure kinds collapse to `Other`. Query failure, missing
schema, missing database, or timeout silently removes the advisory and leaves
the v3.3 JIT cursor path unchanged.

### 2. Bounded Audit Stamp

When advisory context is attached, the daemon may wrap its normal decision:

```json
{
  "action": {"tick": 9, "act": "wait", "ms": 1000},
  "advisory_meta": {
    "scope": "active_step_target",
    "sample_count": 4,
    "hash": "0123456789abcdef"
  }
}
```

The core validates the metadata shape, records `MemoryAdvisoryAttached`, then
throws away the wrapper and decodes only the inner action or plan. The core
does not open SQLite and never copies historical records into Sense.

### 3. Memory-Guided Live-Fire A/B

v3.4 includes a deterministic causal experiment using
`GENESIS_TEST_MEMORY_GUIDED_MODEL=1`. This validation-only Brain consumes the
same prompt surface as a real model and still goes through Purifier, UDS,
Act/Verify, Replay, and SQLite projection.

Control universe:

```text
no advisory
  -> BrainActionDecoded(click a)
  -> OutcomeObserved(Failed, ReadOnlyMode)
  -> PlanAborted
```

Advisory universe:

```text
ReadOnlyMode history attached
  -> MemoryAdvisoryAttached(sample_count=4)
  -> BrainActionDecoded(wait element_visible=a)
  -> OutcomeObserved(Verified)
  -> PlanAdvanced
```

This proves the protocol-level causal effect of bounded memory advice without
claiming any particular GGUF model will always make the same choice.

## Release Invariants

- **History is not an action.** There is no `QueryHistory` `GenesisAction`.
- **Core remains database-blind.** SQLite exists only in the Brain daemon and
  offline projection tools.
- **JSONL remains truth.** SQLite is still a disposable read model.
- **Current Sense outranks memory.** Historical advisory is prompt context,
  not a world-state override.
- **Allowlists remain final.** Any memory-influenced decision must still pass
  Purifier and the actuator boundary.
- **Advisory metadata is bounded.** The core accepts only fixed scope,
  `sample_count <= 100`, and a 16-character hex digest.

## Validation

The v3.4 baseline suite is:

```bash
./scripts/validate_v34.sh
```

It performs:

- inherited v1, v3.2, and v3.3 redline verification;
- daemon and SQLite projection selftests;
- deterministic advisory attachment through a local DOM fixture;
- Replay and SQLite assertions that advisory metadata is visible while
  `BrainActionDecoded` remains free of wrapper data.

The memory-guided live-fire suite is:

```bash
./scripts/validate_v34_memory_live_fire.sh
```

It first runs the full v3.4 baseline, then executes the A/B causal experiment:

```text
control: click -> ReadOnlyMode -> PlanAborted
advised: MemoryAdvisoryAttached -> wait -> Verified -> PlanAdvanced
```

## Support Boundary

v3.4 supports:

- prompt-only historical advisory for the active step target;
- fixed-template SQLite reads with bounded samples and timeout;
- audit, replay, and SQLite projection of advisory attachment;
- deterministic A/B validation of memory-guided tactical change.

v3.4 does not support:

- arbitrary SQL or model-initiated history queries;
- semantic retrieval, embeddings, or long-context memory injection;
- history-driven bypass of Purifier, Web Arena, or Verify;
- production guarantees about a specific GGUF model's tactical choice;
- high-frequency dynamic UI stress testing.

The high-frequency dynamic UI arena belongs to the next release line and must
build on this frozen memory boundary.
