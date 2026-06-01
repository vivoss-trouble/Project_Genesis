# Lazarus Validation Gates

This document defines the validation profiles used before pilot or release-candidate handoff.

## Profiles

### default

Command:

```sh
bash scripts/validate_all.sh
```

Scope:

- Rust workspace tests.
- Rust clippy with `-D warnings`.
- Python bytecode compile for `engine/` and Python daemons.
- Python daemon transport selftest for the shared `/state` HTTP handler,
  transport health envelope, response-size rejection, and invalid numeric
  daemon environment fallback.
- Python daemon numeric environment parsing uses shared safe parsers; invalid
  numeric values warn and fall back to bounded defaults instead of crashing
  during module import.
- Java Probe Docker build, test, package, shade relocation, corpus ingest/report.

Default does not run external-dependency gates:

- Java CVE scan.
- Local LM synthesis smoke.
- Lazarus lifecycle stress.

### pilot

Command:

```sh
bash scripts/validate_lazarus_pilot_gate.sh
```

Scope:

- Everything in `default`.
- Lazarus lifecycle stress with `LAZARUS_STRESS_ITERATIONS=20` unless overridden.

Use this before a controlled customer-environment pilot. It does not require an NVD key or a local LM server.

### release

Command:

```sh
bash scripts/validate_lazarus_release_candidate.sh
```

Scope:

- Everything in `default`.
- Java dependency CVE scan.
- Local LM synthesis smoke.
- Lazarus lifecycle stress with `LAZARUS_STRESS_ITERATIONS=100` unless overridden.
- Clean git worktree check.

Required external state:

- `NVD_API_KEY` for the Java dependency scan, unless `ALLOW_UNKEYED_NVD=1` is explicitly set for exploratory local scans.
- A reachable local OpenAI-compatible LM endpoint, normally `http://127.0.0.1:1234/v1/chat/completions`.
- `LAZARUS_LM_MODEL` set to a loaded local model, or a non-embedding model visible from `/v1/models`.

Release validation is expected to fail if the repository contains unstaged source changes, untracked release files, missing NVD credentials, or no reachable local model.

The release wrapper deliberately checks git cleanliness before expensive external gates. This prevents a dirty local run from being mistaken for release evidence.

## Autonomous Blueprint Runner

For platform-adapter migration work, prefer the autonomous wrapper:

```sh
GENESIS_AUTONOMOUS_MODE=auto scripts/run_autonomous_blueprint.sh
```

`auto` first writes `.genesis-state/autonomous-blueprint/release-precheck.json`.
If the worktree is clean, it runs the `release` profile. If the worktree is dirty, it
automatically falls back to the `fast` profile and records
`reason=release_dirty_fast_fallback` in
`.genesis-state/autonomous-blueprint/autonomous-summary.json`. This keeps iteration
moving while preserving the rule that dirty runs cannot be release evidence.

Use explicit modes when needed:

```sh
GENESIS_AUTONOMOUS_MODE=fast scripts/run_autonomous_blueprint.sh
GENESIS_AUTONOMOUS_MODE=pilot scripts/run_autonomous_blueprint.sh
GENESIS_AUTONOMOUS_MODE=release scripts/run_autonomous_blueprint.sh
```

Every autonomous run writes `autonomous-summary.json`; read that file first when deciding
whether the latest run is release evidence, a fast fallback, a blocked clean-baseline
precheck, or a failed gate. Failed runs record `status=failed`, `current_step`, and
`exit_code`, so stale success evidence is not reused accidentally.

The platform contract gate is part of the autonomous wrapper. It cross-checks the five
OS targets plus WASI, then scans for platform API leakage, platform identity leakage,
hard-coded local service paths, direct runtime temp-dir access outside
`genesis-platform`, direct subprocess spawning outside the platform adapter, and Python
daemon transport APIs outside `daemon_transport.py`. Python daemons provide state
snapshot callbacks; the shared transport owns `/state` HTTP request handling, bounded
threading, socket timeouts, response-size limits, structured transport errors, and
transport health fields. Numeric daemon configuration is parsed through shared
bounded helpers, so invalid ports, timeouts, queue sizes, dimensions, and model
thread counts cannot abort daemon import before structured startup handling runs.

`scripts/validate_all.sh` also writes its configured `GENESIS_VALIDATE_EVIDENCE` manifest
on failed gates, not just on success. Failure manifests include `status=failed`,
`failed_gate`, `current_step`, `exit_code`, and the best-known status of each gate
(`passed`, `skipped`, `failed`, `not_run`, or `unknown`). Success, failure, invalid
profile, and dirty-worktree blocked manifests all include the same `gate_report` shape:
each gate has `status`, `required`, and `skip_reason`. Success manifests are written
from the recorded gate results, not inferred after the fact from environment variables;
if a gate was not recorded as the expected `passed` or `skipped` value, manifest writing
fails. When `validate_all.sh` runs platform contract checks directly, it also writes a
sibling `*-platform-contracts.json` evidence file unless
`GENESIS_PLATFORM_CONTRACT_EVIDENCE` is already set.

Validation, autonomous, release-precheck, and platform-contract manifests include
`schema_version`, `generated_at_utc`, `git_head`, and `git_dirty`, so evidence can be tied
back to the source baseline that produced it.

Invalid `GENESIS_AUTONOMOUS_MODE` and invalid `GENESIS_VALIDATE_PROFILE` values are also
evidence-producing failures with exit code `2`, so configuration mistakes do not leave a
stale successful manifest behind.

After writing `autonomous-summary.json`, the autonomous wrapper self-checks that the
summary JSON is parseable, that the primary evidence file exists, and that the primary
manifest status matches the wrapper result (`passed`, `blocked`, or `failed`). Passed
runs also parse and verify `platform-contracts.json` and `validation-*.json` as
`status=passed`; `auto` runs also verify `release-precheck.json` as either `passed` or
`blocked`. These referenced manifests must use the same `schema_version`, `git_head`,
and `git_dirty` value as the summary. A broken, stale, or cross-baseline summary
therefore fails the run instead of being reported as a valid pass.

For passed runs, the wrapper also treats platform-contract evidence as a structured
contract, not just a green status string. It requires the five OS targets plus WASI,
the contract package set, a `target_matrix` showing each target passed workspace,
`genesis-core --no-default-features`, and `genesis-replay --no-default-features`
checks, `warnings_as_errors=true`, and every containment subcheck to be present and
passed. The containment subchecks must also appear in `containment_report.checks` with
`status=passed`, `violation_count=0`, and explicit `allowed_paths`, so a stale top-level
`passed` string is not enough to satisfy the release evidence chain.

The wrapper also treats `validation-*.json` as structured evidence. It checks that the
validation profile matches the selected mode, that Rust tests, clippy, Python bytecode,
the Python daemon transport selftest, and platform contracts passed, and that fast-mode
external gate skips have explicit skip reasons. These checks must also be reflected in
`gate_report`, so top-level gate fields and structured gate entries cannot drift.
Required gates must be marked `required=true`, fast-mode skipped external gates must be
`required=false`, pilot mode must prove Lazarus stress passed and required, and release
mode must prove Java probe, Java dependency scan, local LM smoke, and Lazarus stress all
passed and required.

In `auto` mode, the wrapper also validates the cause of the selected effective mode.
`effective_mode=fast` must have `reason=release_dirty_fast_fallback`, a blocked
`release-precheck.json`, `git_clean=false`, and non-empty `dirty_paths`. If `auto`
selects `effective_mode=release`, the same precheck must be `status=passed` with
`git_clean=true`.

For failed runs, the wrapper selects the most specific primary evidence available:
platform contract failures point to `platform-contracts.json`, validation failures point
to `validation-*.json`, and wrapper-local failures point to `autonomous-summary.json`
itself. This prevents a stale validation success from masking a later wrapper failure.
The wrapper also parses failed primary evidence: platform-contract failures must include
`current_step`, `exit_code`, and `target_matrix`; validation failures must include
`gate_report`, consistent `failed_gate` / `current_step`, and an `exit_code`. Blocked
release-precheck summaries must point to a blocked `release-precheck.json` with
`git_clean=false` and non-empty `dirty_paths`.

## NVD Connectivity Probe

Use this before coupling NVD-backed dependency scanning to long-running stress:

```sh
NVD_API_KEY=... bash scripts/validate_nvd_connectivity.sh
```

The probe sends one CVE API request and classifies the result:

- exit `0`: connectivity and response shape are valid.
- exit `2`: missing API key unless `ALLOW_UNKEYED_NVD=1`.
- exit `3`: NVD returned HTTP 429 rate limiting after retry exhaustion.
- exit `4`: unexpected non-200 response.

The probe uses bounded exponential backoff with jitter:

```text
NVD_PROBE_MAX_RETRIES=5
NVD_PROBE_BASE_BACKOFF_SECONDS=6
NVD_PROBE_MAX_BACKOFF_SECONDS=60
```

It also prints `Retry-After` / rate-limit response headers when present. This script is intentionally separate from lifecycle stress so network rate limits cannot be misdiagnosed as local deadlock or memory pressure.

## Non-Negotiables

- `default` proves local engineering health, not production readiness.
- `pilot` proves the stress harness can run repeatedly, not long-term 7x24 stability.
- `release` is the first gate that attempts to close dependency security, local model synthesis, lifecycle stress, and baseline reproducibility together.
