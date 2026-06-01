# Lazarus Local LM Smoke

This smoke path connects Lazarus Synthesizer to a local OpenAI-compatible model server such as LM Studio.

## Default Endpoint

```text
http://127.0.0.1:1234/v1/chat/completions
```

The local path does not require an API key.

The repository default is locked in `config/reasoning-engine.env`:

```text
LAZARUS_LM_MODEL=huihui-ai/qwen/claude-4.7-opus-q8_0.gguf
```

## Required LM Studio State

Before running the smoke:

1. Start the LM Studio local server.
2. Load a chat/code-capable model that fits local memory.
3. Confirm models are visible:

```sh
curl http://127.0.0.1:1234/v1/models
```

If LM Studio refuses to load a model because of memory guardrails, choose a smaller quantized model or adjust LM Studio settings. Lazarus cannot bypass LM Studio resource protection.

## Run

```sh
scripts/run_lazarus_local_lm_synthesis_smoke.sh
```

Optional environment:

```text
LAZARUS_LM_ENDPOINT=http://127.0.0.1:1234/v1/chat/completions
LAZARUS_LM_MODEL=<model-id>
LAZARUS_ORACLE_MAX_RETRIES=1
LAZARUS_ORACLE_TIMEOUT_MS=120000
LAZARUS_ORACLE_MAX_OUTPUT_TOKENS=4096
LAZARUS_ORACLE_LOG_DIR=<dir>
LAZARUS_LM_SNAPSHOT_DIR=<snapshot-dir>
LAZARUS_LM_OUT_DIR=<out-dir>
LAZARUS_LM_BUSINESS_METHOD=<business-method>
```

## What The Script Does

1. Checks the local LM endpoint.
2. Finds a non-embedding local model if `LAZARUS_LM_MODEL` is not set.
3. Uses existing Java Probe snapshots, or generates dummy snapshots if missing.
4. Runs `genesis-cli corpus-report` to select the top business method.
5. Runs `genesis-cli synthesis-smoke` with:
   - `LAZARUS_ORACLE_PROTOCOL=openai_chat`
   - local LM endpoint
   - selected model
6. Writes `synthesis-smoke-report.json` and optional oracle request/response logs.

## Current Local Observation

The endpoint `127.0.0.1:1234` was reachable during local validation.

Observed model behavior:

- Some large local Qwen models were rejected by LM Studio memory guardrails.
- `huihui-ai/qwen/claude-4.7-opus-q8_0.gguf` is the locked local reasoning model for release smoke.
- The successful run reached `SmokeTestPassed` in one synthesis iteration and produced a Wasm artifact plus `synthesis-smoke-report.json`.

This observation is a local smoke result, not a release gate by itself. To make it a gate, run:

```sh
RUN_LOCAL_LM_SMOKE=1 \
bash scripts/validate_all.sh
```
