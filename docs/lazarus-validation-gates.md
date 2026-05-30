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

## Non-Negotiables

- `default` proves local engineering health, not production readiness.
- `pilot` proves the stress harness can run repeatedly, not long-term 7x24 stability.
- `release` is the first gate that attempts to close dependency security, local model synthesis, lifecycle stress, and baseline reproducibility together.
