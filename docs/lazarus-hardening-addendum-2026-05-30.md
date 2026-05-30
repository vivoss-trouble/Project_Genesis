# Lazarus Hardening Addendum

## Scope

This addendum updates the architecture/source refactor report after the latest automatic hardening pass.

## Newly Closed Items

1. Validation gate profiles are now explicit.
   - `scripts/validate_all.sh` supports `GENESIS_VALIDATE_PROFILE=default|pilot|release`.
   - `scripts/validate_lazarus_pilot_gate.sh` wraps the pilot profile.
   - `scripts/validate_lazarus_release_candidate.sh` wraps the release profile.

2. Native executable artifacts are no longer production-default.
   - The public native artifact API rejects execution by default.
   - Native execution now requires the explicit `*_dev_only` path.
   - The stress gate includes `native_artifact_public_api_requires_explicit_dev_mode`.

3. Security boundary documentation is now explicit.
   - `docs/security-boundary.md` distinguishes trusted in-process FFI plugins, untrusted plugins, Wasm artifacts, and native executable artifacts.
   - README no longer presents Genesis in-process plugins as a strong memory sandbox.

4. Java dependency scanning is wired as a gate.
   - `scripts/validate_lazarus_java_dependency_scan.sh` runs OWASP Dependency Check in Docker.
   - `NVD_API_KEY` is required unless `ALLOW_UNKEYED_NVD=1` is explicitly set for exploratory local scans.
   - `scripts/validate_nvd_connectivity.sh` isolates NVD API connectivity and HTTP 429 diagnosis from lifecycle stress.

5. Lifecycle stress is wired as a gate.
   - `scripts/validate_lazarus_stress.sh` covers action delivery, audit rotation, native timeout, native dev-only rejection, shadow queue drop, worker retire, supervisor respawn, single ledger writer, and Tokio spawn-blocking topology.

6. Local LM synthesis smoke has been revalidated against a local OpenAI-compatible endpoint.
   - Endpoint: `http://127.0.0.1:1234/v1/chat/completions`
   - Model: `huihui-ai/qwen/claude-4.7-opus--q8_0.gguf`
   - Result: `SmokeTestPassed`, `verdict=Accepted`, `production_ready=false`

## Verified Commands

```sh
bash scripts/validate_all.sh
LAZARUS_STRESS_ITERATIONS=1 bash scripts/validate_lazarus_pilot_gate.sh
RUN_LOCAL_LM_SMOKE=1 LAZARUS_LM_MODEL='huihui-ai/qwen/claude-4.7-opus--q8_0.gguf' bash scripts/validate_all.sh
```

The release candidate wrapper was also executed and correctly failed fast because the git worktree is not clean:

```sh
bash scripts/validate_lazarus_release_candidate.sh
```

## Current Boundary

The system is stronger than the original report baseline, but still not a release-candidate completion state.

Remaining blockers:

1. The worktree is still not a frozen clean baseline.
2. Java CVE scanning is wired but has not completed with a real `NVD_API_KEY` in this run.
3. Long stress has not been run at the release default of `LAZARUS_STRESS_ITERATIONS=100`.
4. CLI and Synthesizer module split remains a maintainability task.

## Updated Rating

- Architecture design: `9.0/10`
- Local engineering implementation: `8.9/10`
- Production pilot readiness: `8.4/10`
- Release-candidate readiness: blocked by clean baseline and external security gate completion

## Final Calibrated Verdict

Default engineering gates are closed, pilot gates are executable, local LM synthesis has a live successful sample, and native production misuse is blocked by default.

The next non-negotiable release step is not more architecture expansion. It is freezing the source baseline, running the Java CVE gate with `NVD_API_KEY`, running the release stress profile, and preserving the local LM smoke artifacts as release evidence.
