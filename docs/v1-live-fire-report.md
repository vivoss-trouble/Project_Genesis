# Genesis v1 Live Fire Report

This report is the narrative scenario record for the v1 real DOM live fire.

For the technical validation matrix, see [validation-log.md](validation-log.md).

Date: 2026-05-24

## Objective

Validate that Genesis can operate beyond the local Fantasy Dummy sandbox and perform a constrained action against a real DOM through Web Arena, while preserving auditability and replay safety.

## System Under Test

- `genesis-core`: Rust microkernel with 2 second Tick loop.
- `genesis-contracts`: C ABI plugin boundary.
- `brain-llm`: UDS airlock plugin.
- `llm-daemon-python`: purifier and fallback decision daemon.
- `web-arena-python`: Playwright browser airlock.
- `genesis-replay`: audit timeline and deterministic replay runner.

## Safety Gates

The real DOM action crossed two independent allowlists:

```text
LLM daemon target allowlist: GENESIS_ALLOWED_CLICK_TARGETS=a
Web Arena selector allowlist: GENESIS_WEB_ALLOWED_SELECTORS=a
```

The model layer remained a suggestion source. Web Arena retained final execution authority.

## Live Fire Setup

```bash
GENESIS_WEB_URL=https://example.com
GENESIS_WEB_ALLOWED_ORIGINS=https://example.com,https://www.iana.org,https://iana.org
GENESIS_WEB_ALLOWED_SELECTORS=a
GENESIS_ALLOWED_CLICK_TARGETS=a
GENESIS_WEB_FALLBACK_CLICK=1
```

## Engagement Log

1. `web_state.mode = "playwright"` and `web_state.title = "Example Domain"` were captured by Sense.
2. Brain fallback emitted:

   ```json
   {"tick":1,"act":"click","target":"a","reason":"web fallback clicked allowlisted target=a"}
   ```

3. Core decoded the decision:

   ```text
   BrainActionDecoded action_id=act-2-1 source_tick_id=1
   ```

4. Act Dispatcher sent the action:

   ```text
   ActionDispatched action_id=act-2-1
   ```

5. Web Arena accepted and executed:

   ```text
   queued click a
   clicked a
   ```

6. Browser state changed:

   ```text
   final url   = https://www.iana.org/help/example-domains
   final title = Example Domains
   ```

## Replay Evidence

`genesis-replay strict` observed:

```text
tick 1 sense web_title="Example Domain" mode=playwright
tick 2 source_tick 1 decoded act-2-1 {"tick":1,"act":"click","target":"a",...}
ActionDispatched {"action_id":"act-2-1","source_tick_id":1,"tick_id":2}
```

## Conclusion

**PASS.**

Genesis v1 proves the real DOM loop:

```text
Sense -> Brain -> Purifier -> Act -> Web Arena -> DOM navigation -> Audit -> Replay
```

The system can now touch a real webpage, but the execution path remains constrained by deterministic contracts and double allowlists.
