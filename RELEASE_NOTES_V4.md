# Genesis v4 Release Notes: Dynamic Taxonomy & Cognitive Backflow

**Version status:** Frozen baseline at v4.3  
**Direction:** Move from static DOM control into high-frequency dynamic UI, with explainable failure taxonomy and bounded cognitive backflow.

## Core Milestones

1. **v4.1 Dynamic Arena Scaffold:** `085c78e`
   - Added an independent 60fps physical sandbox for dynamic UI behavior.
   - Simulates `TargetDrift`, `TargetOccluded`, `FocusLost`, render jank, and committed-frame snapshots.
   - Uses a pull-based immutable snapshot model so Sense always reads a committed world slice.

2. **v4.2 Action Causal Lock & Dynamic Taxonomy:** `d11c79c`
   - Added `GenesisAction::ClickPoint` with `frame_id` for optimistic concurrency control.
   - Added end-to-end `action_id` echo from Core to Dynamic Arena and back into `last_verdict`.
   - Rejects ghost verdicts through `DynamicVerdictActionMismatch`.
   - Established dynamic failure taxonomy: `StaleFrame`, `CoordinateOutOfBounds`, `TargetDrift`, and related arena verdict evidence.

3. **v4.3 Dynamic Advisory:** `687d2b5`
   - Extends read model advisory with dynamic failures, warnings, and recent action counts.
   - Adds bounded advice for `TargetDrift`, `StaleFrame`, `CoordinateOutOfBounds`, `StaleButHit`, and `HighSpatialDrift`.
   - Validates the cognitive effect through deterministic A/B testing:
     - No advisory: risky `click_point` -> `TargetDrift` -> `PlanAborted`
     - With advisory: dynamic history -> `noop` -> `Verified` -> `PlanAdvanced`

## Architectural Invariants

- **Protocol facts belong to the Purifier; world facts belong to the Arena.**
  The Purifier rejects non-computable data such as NaN, Inf, or unbounded coordinates. Hit testing, stale-frame judgement, drift, occlusion, and bounds checks remain Arena verdicts.

- **Forgive hits, but record the evidence.**
  Tolerated stale hits are allowed to verify, but the system records `StaleButHit` and related drift evidence as warning telemetry.

- **History can advise, but it has no hands.**
  Dynamic advisory is prompt-only and read-only. It can influence Brain candidates but cannot bypass Purifier, Act dispatch, Arena judgement, Verify, or Audit.

- **The Core remains strategy-free.**
  v4 adds dynamic physical evidence and bounded historical advice without adding retry, compensation, hit testing, or planner semantics to the Rust microkernel.

## Validation

The v4.3 baseline is validated by:

```bash
./scripts/validate_v43_dynamic_advisory.sh
```

This inherits the prior redlines and verifies:

- v1 baseline replay and deterministic audit integrity
- v3 JIT cursor, fail-fast abort, verifiable backoff, and read-model advisory
- v4.2 dynamic `click_point` taxonomy and `action_id` causal lock
- v4.3 dynamic advisory A/B behavior

## Out of Scope

- Real GGUF free-fire behavior in the dynamic arena
- Rust/WinAPI or OS-level dynamic target control
- Multimodal screen perception
- Parallel active plans
- Core-managed retry or backoff strategy

Those belong to future v4.4/v4.5 work after this deterministic reference point is frozen.
