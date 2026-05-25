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
python3 - <<'PY'
import json, socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('/tmp/genesis_act.sock')
s.sendall((json.dumps({
    "act": "click",
    "target": "a",
    "reason": "live fire click allowlisted example link",
}) + "\n").encode())
PY
```
