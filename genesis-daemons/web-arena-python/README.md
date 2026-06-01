# Genesis Web Arena Python

Browser airlock for real web targets.

Run safe read-only mode against `example.com`:

```bash
GENESIS_WEB_URL=https://example.com \
python3 genesis-daemons/web-arena-python/web_arena.py
```

Point `genesis-core` Sense at the arena:

```bash
GENESIS_SENSE_URL=http://127.0.0.1:4777/state \
GENESIS_SENSE_KEY=web_state \
cargo run -p genesis-core
```

By default the daemon observes only. Click execution is rejected unless a selector is explicitly allowlisted:

```bash
GENESIS_WEB_ALLOWED_SELECTORS="#submit,button.safe" \
GENESIS_ALLOWED_CLICK_TARGETS="#submit,button.safe" \
python3 genesis-daemons/web-arena-python/web_arena.py
```

Install Playwright for real browser-backed DOM actions:

```bash
.venv-llm/bin/python -m pip install playwright
.venv-llm/bin/python -m playwright install chromium
```

Without Playwright, the daemon falls back to read-only HTTP probe mode. This keeps Sense and Audit testable while preventing physical clicks.

Force the same no-actuation mode deterministically, even on machines with Playwright installed:

```bash
GENESIS_WEB_FORCE_READ_ONLY=1 \
GENESIS_WEB_URL=https://example.com \
GENESIS_WEB_ALLOWED_SELECTORS=a \
python3 genesis-daemons/web-arena-python/web_arena.py
```

Minimal live-fire DOM click:

```bash
GENESIS_WEB_URL=https://example.com \
GENESIS_WEB_ALLOWED_ORIGINS=https://example.com,https://www.iana.org,https://iana.org \
GENESIS_WEB_ALLOWED_SELECTORS=a \
GENESIS_WEB_OBSERVED_SELECTORS=a,body \
.venv-llm/bin/python genesis-daemons/web-arena-python/web_arena.py
```

Then send a Genesis action frame:

```bash
GENESIS_ACT_SOCKET="${GENESIS_ACT_SOCKET:-$(python3 - <<'PY'
import tempfile
print(f"{tempfile.gettempdir()}/genesis_act.sock")
PY
)}"
python3 - <<'PY'
import json, os, socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(os.environ["GENESIS_ACT_SOCKET"])
s.sendall((json.dumps({
    "act": "click",
    "target": "a",
    "reason": "live fire click allowlisted example link",
}) + "\n").encode())
PY
```

v3.3 supports a passive, next-tick verifiable wait. It does not block the
microkernel or sleep inside Web Arena; it declares a condition that must be
visible in the next Sense snapshot:

```json
{
  "act": "wait",
  "ms": 1000,
  "expected_state": {
    "type": "element_visible",
    "selector": "a"
  },
  "reason": "wait for an observed link"
}
```

`ms` is bounded to `0..2000`, and the selector must be listed in
`GENESIS_WEB_OBSERVED_SELECTORS`.
