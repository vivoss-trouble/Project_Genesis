# Release Notes: Genesis v4.6

## Cerebellum Architecture Core

Genesis v4.6 freezes the control-law split that makes high-frequency dynamic UI interaction viable:

> Strategy is selected by Brain, coordinates are computed by Cerebellum, physics are judged by Arena, and Core remains blank.

## Core Invariant

- **Brain / LLM:** emits only tactical intent for dynamic active steps: `aim_dynamic + target_id`.
- **Cerebellum / brain-llm plugin:** resolves `aim_dynamic` at the last polling moment using the freshest `dynamic_state`, then emits a standard `click_point(x, y, frame_id)`.
- **Core:** remains unaware of the shooter. It only sees ordinary `GenesisAction` data and keeps the existing Act/Verify loop.
- **Arena:** remains the sole physical judge for hit, occlusion, stale frame, drift, focus loss, and other world facts.

## v4.5 vs v4.6 Live-Fire Telemetry

Both runs used the same Dynamic Arena and the same `FRESH_FRAME_TOLERANCE=2` physical constant.

| Metric | v4.5: 7B direct `click_point` | v4.6: 7B `aim_dynamic` + Cerebellum |
| --- | --- | --- |
| Live-fire duration | 180s | 180s |
| Decoded intents | 14 | 23 |
| JSON legal rate | 100% | 100% |
| Fallback actions | 0 | 0 |
| Dynamic shots | 13 | 11 |
| Normal frame delta | 170-200 frames | 1-2 frames |
| Dominant failure | `StaleFrame` | none |
| Physical outcomes | `StaleFrame=10`, `TargetHidden=2`, `TargetOccluded=1` | `Verified=10`, `TargetOccluded=1` |

## Boundary

The Cerebellum Shooter is deterministic geometry, not a hidden policy layer.

- It does not predict motion.
- It does not compensate for occlusion.
- It does not widen frame tolerance.
- It does not bypass Purifier, Core, Act/Verify, or Arena.

The single `TargetOccluded` failure in the v4.6 live-fire run is a boundary proof: the shooter resolved the latest target center in time, but Arena still rejected the action because the world state physically blocked it.

## Release Verdict

v4.6 turns the previous second-scale LLM reflex loop into a last-frame deterministic reflex without changing the microkernel control flow. This version is the frozen baseline for any future OS-level driver work.
