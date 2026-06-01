# Genesis Five-Platform Productization Blueprint

## 0. Verdict

System state: stable baseline, not finished product.

Current evidence proves the platform abstraction and release gate, not real
device parity. The next phase must shift from "can the architecture compile and
validate" to "can users operate Genesis through stable shells on macOS, Linux,
Windows, iOS, and Android."

Core verdict: keep the Rust core and platform adapters as the invariant center;
ship desktop nodes first, mobile control clients second, and full mobile local
runtime only after separate certification.

First principle: every platform addition must be a replaceable adapter or shell
around `GenesisSdk`; `genesis-core` must remain free of platform identity and UI
concerns.

Confidence: high for the baseline; medium for mobile delivery cost until real
iOS/Android devices are exercised.

## 1. Evidence Layer

Facts:

- Head `26648f4` has release evidence with `status=passed` and `git_dirty=false`.
- `scripts/validate_platform_contracts.sh` verifies macOS, Linux, Windows, iOS,
  Android, and WASI contract targets.
- `genesis-platform` owns platform identity, local IPC, remote HTTP, directory,
  worker, file-copy, and browser adapter details.
- `genesis-sdk` is the intended facade for UI shells and control clients.
- `MobileControlAdapter` rejects local workers, local IPC, local native plugins,
  and local Wasm, while allowing remote HTTP request/response.
- Local reasoning defaults are locked in `config/reasoning-engine.env`, and the
  release gate has passed local LM smoke with the locked model.

High-confidence inferences:

- Desktop productization should target `DesktopFull` or `DesktopSafe` nodes, not
  a separate per-OS core.
- Mobile productization should start as `MobileControl`, because mobile OS
  suspension, JIT policy, background limits, and app-store constraints make full
  local runtime parity the wrong first release target.
- The fastest reliable user-facing path is a thin shell over `GenesisSdk`, not a
  rewrite of core runtime behavior.

Low-confidence inferences:

- Windows named-pipe behavior is structurally checked but still needs real
  Windows host testing.
- iOS and Android cross-target checks prove contract shape, not app-store-ready
  runtime behavior.
- Large evidence streams through Flutter, Tauri, or another shell may need
  paging/streaming work after real UI load tests.

Unknowns:

- Final UI framework choice for five-platform shells.
- Real Windows/Linux/iOS/Android device behavior.
- Installer/signing/notarization/store constraints.
- Long-running evidence browsing performance on mobile.

## 2. Inversion And Death Paths

Success endgame:

- One Rust core and SDK contract serves all five platforms.
- Desktop nodes can run local Genesis services with bounded resources.
- Mobile apps control remote nodes and inspect evidence without pretending to be
  full local nodes.
- Every platform claim is backed by device or CI evidence.
- Release artifacts contain manifest evidence, not terminal-only logs.

Critical death path:

- Abstract leakage: UI or core code starts depending on socket paths, `/tmp`,
  named pipes, platform-specific handles, or local process assumptions. That
  turns the adapter model into a facade and makes five-platform support collapse
  into per-platform forks.

Secondary flaws:

1. Mobile scope creep: trying to run full local Genesis on iOS/Android before
   `MobileControl` is stable.
2. Evidence overload: sending huge logs/screenshots as single payloads through
   UI bridges instead of paged or streamed APIs.
3. False certification: treating cross-compilation as equivalent to real device
   behavior.

Zero-hypothesis test:

- If `GenesisSdk` is not sufficient for a UI shell to perform health, job
  control, evidence listing, and evidence retrieval without platform-specific
  imports, the next failure appears in shell code as direct transport/path
  dependencies.

## 3. Anti-Entropy System Loop

Input -> Process -> Output -> Feedback:

1. Shell calls `GenesisSdk`.
2. SDK calls `PlatformAdapter`.
3. Adapter maps capability intent to local desktop service or remote HTTP.
4. Genesis node returns status, job, action, or evidence payload.
5. Shell renders state and writes no core-owned behavior.
6. Release gate records manifest evidence.

Entropy sources:

- UI code duplicating service routing.
- Core code reintroducing `target_os` branches.
- Mobile clients gaining local-runtime responsibilities too early.
- Evidence payloads lacking paging boundaries.
- Release evidence spread across temp directories without manifests.

Anti-entropy actions:

- Freeze `GenesisSdk` shell-facing contract before building UI.
- Add contract tests for SDK health, jobs, evidence list, evidence page, and
  remote action request flows.
- Add a shell conformance test harness that every UI implementation must pass.
- Require every new platform claim to add manifest evidence.
- Keep mobile first release as `MobileControl` only.

## 4. Six-Dimension Audit

Time:

- Desktop shell first gives the quickest real product proof. Mobile full-local
  runtime should be deferred until mobile control is proven.

Resource:

- Reusing `GenesisSdk` and `genesis-platform` avoids duplicate client logic.
  Real device testing is the main resource cost.

Momentum:

- Current release gate is strong. The next leverage point is turning the release
  evidence into product shell evidence.

Boundary:

- `genesis-core`: no UI, no platform identity, no direct transport.
- `genesis-platform`: all OS capability details.
- `genesis-sdk`: only shell/client facade.
- desktop shell: local node control.
- mobile shell: remote node control.

Complexity:

- The dangerous complexity is not adding UI. It is allowing UI needs to mutate
  core abstractions. All shell needs must first become SDK methods or adapter
  capabilities.

Cognitive load:

- Keep profiles explicit: `DesktopFull`, `DesktopSafe`, `MobileControl`,
  `ServerNode`, `CiRelease`. Do not describe mobile as "same as desktop" until
  real mobile runtime evidence exists.

## 5. Decision Tradeoff

Short-term gain:

- Build a thin desktop shell and mobile control client around existing SDK.

Long-term cost:

- SDK contract discipline becomes mandatory. Changing SDK shape later will be
  expensive once multiple shells exist.

Pro:

- Preserves the release-proven core boundary.
- Enables five-platform product progress without per-platform core forks.
- Lets mobile ship useful functionality without fighting OS runtime policy.

Con:

- Mobile is not a full local Genesis node in the first product phase.
- Real Windows/Linux/iOS/Android validation still requires host/device
  infrastructure outside the current macOS release run.

Decision rationale:

- The project already proved adapter contracts and release gates. The next
  globally optimal move is to freeze the shell-facing SDK and validate real
  platform shells. Adding more core capability before this would increase
  abstraction risk without proving product usability.

## 6. Resilience Strategy

Validation:

- `GENESIS_AUTONOMOUS_MODE=auto scripts/run_autonomous_blueprint.sh`
- `scripts/validate_platform_contracts.sh`
- SDK shell conformance tests for health, jobs, evidence list, evidence page,
  and remote request/response.
- Real host smoke:
  - macOS desktop node.
  - Linux desktop/server node.
  - Windows desktop node.
  - iOS MobileControl client.
  - Android MobileControl client.

Rollback:

- If a shell needs platform-specific behavior, add or adjust an adapter
  capability instead of importing platform APIs into shell/core.
- If mobile control cannot handle evidence size, add paged evidence APIs before
  changing transport.
- If Windows/Linux real hosts fail despite contract checks, keep the contract
  gate and fix only `genesis-platform` adapter implementation.

## 7. Construction Plan

Phase 1: SDK contract freeze.

- Add shell-facing SDK methods for node health, job submit, job status, evidence
  list, evidence page, and remote request/response.
- Add conformance tests that run against desktop adapter and mobile control
  adapter.
- Gate: SDK tests pass without UI code importing platform transport details.

Phase 2: Desktop node shell.

- Build the first shell around `GenesisSdk`.
- Keep it able to control local desktop services and remote nodes.
- Gate: shell smoke proves health, action request, and evidence browsing.

Phase 3: MobileControl client.

- Build iOS/Android as remote controller and evidence viewer.
- No local native plugins, local Java probe, browser automation, or subprocess
  workers.
- Gate: mobile client uses only SDK remote HTTP APIs.

Phase 4: Real platform matrix.

- Run host/device smoke on macOS, Linux, Windows, iOS, Android.
- Store manifests for every platform run.
- Gate: platform matrix cannot say "verified" unless a manifest exists.

Phase 5: Packaging and release evidence.

- Desktop: installer/signing/notarization/package smoke.
- Mobile: store/development signing, network permission, background behavior
  documentation.
- Gate: release evidence links build artifact hashes, SDK version, platform
  manifest, and validation profile.

## 8. Immediate Next Step

Implement Phase 1 first: create SDK shell conformance tests and fill only the
minimal missing `GenesisSdk` methods required by shells. Do not start UI until
the SDK facade can prove the product loop without platform-specific imports.
