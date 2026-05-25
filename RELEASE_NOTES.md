# Project Genesis v1 Release Notes

Release date: 2026-05-24

## Summary

Genesis v1 freezes the first reproducible baseline where the system can sense a real web page, route context through the microkernel, receive a model decision, purify it into a constrained action, execute that action through a browser airlock, and replay the resulting timeline from JSONL audit records.

This release is the baseline before v2 Outcome Verification. Do not mix v2 verify/retry logic into this release line.

## Milestones

- C ABI plugin contract stabilized around `ptr + len + free`.
- Worker Watchdog isolates slow or tainted plugins without killing native threads.
- Anchor mmap preserves cross-cycle state with ping-pong blocks and checksums.
- Brain daemon is isolated behind Unix Domain Socket IPC.
- Python LLM daemon includes JSON purifier, schema validation, target allowlist, and fallback.
- Act Dispatcher assigns stable `action_id` values and preserves `source_tick_id`.
- Audit Airlock records append-only JSONL events without blocking the core.
- `genesis-replay` provides strict timeline reading, plugin simulation, and brain mock replay.
- Web Arena provides real DOM Sense and Playwright-backed Act behind double allowlists.

## Support Boundary

v1 supports:

- Fantasy Dummy local closed-loop validation.
- Web Arena read-only HTTP probe.
- Playwright-backed DOM observation and basic `click` / `type` / `key` / `wait` / `assert_ui_state` actions.
- Static or lightly dynamic pages reachable through explicit origin allowlists.
- Deterministic replay for current ABI plugins using JSONL audit records and `ReplaySnapshot`.

v1 does not claim support for:

- Authenticated websites, CAPTCHA, anti-automation flows, or adversarial pages.
- Complex Shadow DOM, cross-origin iframes, file uploads, downloads, or multi-tab workflows.
- Planner-style multi-step goal decomposition.
- Outcome Verification, retry policy, or automatic self-correction. These are v2 scope.

## v1 Closed Loop

```text
Sense
  -> Shield
  -> Anchor
  -> Brain
  -> Purifier
  -> Act
  -> Web Arena
  -> Audit
  -> Replay
```

## Live Fire Result

Target:

```text
https://example.com
```

Action:

```json
{"act":"click","target":"a","reason":"web fallback clicked allowlisted target=a"}
```

Observed result:

```text
final url   = https://www.iana.org/help/example-domains
final title = Example Domains
```

## Release Invariants

```text
模型可以慢，核心不能慢。
模型可以乱，执行不能乱。
组件可以死，心跳不能死。
```

## Baseline Validation

Run:

```bash
scripts/validate_v1.sh
```

Optional Playwright live-fire smoke:

```bash
GENESIS_VALIDATE_LIVE_FIRE=1 scripts/validate_v1.sh
```

The validation script must pass before v2 changes are accepted.
