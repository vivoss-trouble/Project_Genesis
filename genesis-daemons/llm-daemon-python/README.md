# Genesis LLM Daemon Python

UDS-compatible daemon for replacing `llm-dummy` with a real local model.

Run deterministic fallback:

```bash
python3 genesis-daemons/llm-daemon-python/llm_daemon.py
```

Run with a GGUF model through `llama-cpp-python`:

```bash
GENESIS_MODEL_PATH=/absolute/path/model.gguf \
GENESIS_N_GPU_LAYERS=-1 \
python3 genesis-daemons/llm-daemon-python/llm_daemon.py
```

The daemon listens on `GENESIS_BRAIN_SOCKET` when set, otherwise
`tempfile.gettempdir()/genesis_brain.sock`, and returns newline-delimited JSON
compatible with `brain-llm`.

The daemon includes a JSON purifier before sending actions back to Genesis:

- extracts the first balanced JSON object from noisy model output
- validates the `act` schema
- clamps long text fields
- blocks unsafe click targets outside `GENESIS_ALLOWED_CLICK_TARGETS`
- falls back to deterministic health-based behavior when output is invalid

For Web Arena mode, keep the model purifier and browser daemon aligned:

```bash
export GENESIS_WEB_ALLOWED_SELECTORS="#submit,button.safe"
export GENESIS_ALLOWED_CLICK_TARGETS="$GENESIS_WEB_ALLOWED_SELECTORS"
```
