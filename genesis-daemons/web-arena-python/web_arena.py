#!/usr/bin/env python3
"""
Genesis Real Web Arena.

This daemon is a browser airlock:
  - exposes GET /state for genesis-core Sense
  - listens on /tmp/genesis_act.sock for GenesisAction JSON
  - opens only an allowlisted URL
  - executes only allowlisted selectors

If Playwright is unavailable, it falls back to a read-only HTTP probe so the
state contract and safety checks remain testable without a browser install.
"""

from __future__ import annotations

import html
import json
import os
import queue
import re
import socket
import socketserver
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from daemon_transport import BoundedThreadingMixIn, ClientThreadLimiter, read_line


def origin_of(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError(f"unsupported URL: {url}")
    return f"{parsed.scheme}://{parsed.netloc}"


def csv_env(key: str, default: str) -> list[str]:
    value = os.environ.get(key, default)
    return [item.strip() for item in value.split(",") if item.strip()]


ACT_SOCKET_PATH = os.environ.get("GENESIS_ACT_SOCKET", "/tmp/genesis_act.sock")
STATE_HOST = os.environ.get("GENESIS_WEB_ARENA_HOST", "127.0.0.1")
STATE_PORT = int(os.environ.get("GENESIS_WEB_ARENA_PORT", "4777"))
TARGET_URL = os.environ.get("GENESIS_WEB_URL", "https://example.com")
ALLOWED_ORIGINS = set(csv_env("GENESIS_WEB_ALLOWED_ORIGINS", origin_of(TARGET_URL)))
OBSERVED_SELECTORS = set(
    csv_env("GENESIS_WEB_OBSERVED_SELECTORS", "a,button,input,textarea,select")
)
ALLOWED_CLICK_SELECTORS = set(csv_env("GENESIS_WEB_ALLOWED_SELECTORS", ""))
HEADLESS = os.environ.get("GENESIS_WEB_HEADLESS", "1") != "0"
FORCE_READ_ONLY = os.environ.get("GENESIS_WEB_FORCE_READ_ONLY", "0") == "1"
STATE_TIMEOUT_MS = int(os.environ.get("GENESIS_WEB_STATE_TIMEOUT_MS", "300"))
ACTION_TIMEOUT_MS = int(os.environ.get("GENESIS_WEB_ACTION_TIMEOUT_MS", "3000"))
MAX_WAIT_MS = 2_000
REFRESH_INTERVAL_SEC = float(os.environ.get("GENESIS_WEB_REFRESH_SEC", "1.0"))
ACTION_QUEUE_SIZE = int(os.environ.get("GENESIS_WEB_ACTION_QUEUE", "32"))
CLIENT_THREADS = ClientThreadLimiter("web-arena", connection_arg_index=1)


class ArenaState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.mode = "starting"
        self.url = TARGET_URL
        self.title = ""
        self.ready_state = "unknown"
        self.text_preview = ""
        self.elements: list[dict[str, Any]] = []
        self.last_error_kind: str | None = None
        self.last_error: str | None = None
        self.last_action: dict[str, Any] | None = None
        self.action_log: list[str] = []
        self.action_queue: queue.Queue[dict[str, Any]] = queue.Queue(
            maxsize=ACTION_QUEUE_SIZE
        )

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            return {
                "mode": self.mode,
                "url": self.url,
                "title": self.title,
                "ready_state": self.ready_state,
                "text_preview": self.text_preview,
                "elements": self.elements,
                "observed_selectors": sorted(OBSERVED_SELECTORS),
                "allowed_click_selectors": sorted(ALLOWED_CLICK_SELECTORS),
                "last_error_kind": self.last_error_kind,
                "last_error": self.last_error,
                "last_action": self.last_action,
                "log": self.action_log[-12:],
            }

    def log(self, message: str) -> None:
        with self.lock:
            self.action_log.append(f"[{int(time.time())}] {message}")
            self.action_log = self.action_log[-40:]


def main() -> None:
    if os.environ.get("GENESIS_WEB_ARENA_SELFTEST") == "1":
        run_selftest()
        return

    assert_allowed_url(TARGET_URL)
    state = ArenaState()
    start_browser_or_probe(state)
    start_refresh_loop(state)
    start_act_socket(state)
    serve_state(state)


def start_browser_or_probe(state: ArenaState) -> None:
    if FORCE_READ_ONLY:
        with state.lock:
            state.mode = "http_probe"
        state.log("forced read-only HTTP probe mode")
        refresh_http_probe(state)
        return

    try:
        from playwright.sync_api import sync_playwright  # type: ignore
    except Exception as exc:
        with state.lock:
            state.mode = "http_probe"
        set_failure(state, "PlaywrightUnavailable", f"playwright unavailable: {exc}")
        refresh_http_probe(state)
        return

    threading.Thread(
        target=playwright_worker, args=(state, sync_playwright), daemon=True
    ).start()


def start_act_socket(state: ArenaState) -> None:
    try:
        Path(ACT_SOCKET_PATH).unlink()
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(ACT_SOCKET_PATH)
    server.listen()
    print(f"[web-arena] action socket listening on {ACT_SOCKET_PATH}")

    def accept_loop() -> None:
        while True:
            conn, _ = server.accept()
            CLIENT_THREADS.spawn(handle_action, state, conn)

    threading.Thread(target=accept_loop, daemon=True).start()


def serve_state(state: ArenaState) -> None:
    class ReusableThreadingTCPServer(BoundedThreadingMixIn, socketserver.TCPServer):
        allow_reuse_address = True
        transport_name = "web-arena-state"

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            if self.path != "/state":
                self.send_response(404)
                self.end_headers()
                return

            snapshot = state.snapshot()
            snapshot["transport"] = self.server.transport_health()
            body = json.dumps(snapshot, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: Any) -> None:
            return

    with ReusableThreadingTCPServer((STATE_HOST, STATE_PORT), Handler) as httpd:
        print(f"[web-arena] state available at http://{STATE_HOST}:{STATE_PORT}/state")
        httpd.serve_forever()


def start_refresh_loop(state: ArenaState) -> None:
    def refresh_loop() -> None:
        while True:
            time.sleep(REFRESH_INTERVAL_SEC)
            if state.mode != "playwright":
                refresh_http_probe(state)

    threading.Thread(target=refresh_loop, daemon=True).start()


def playwright_worker(state: ArenaState, sync_playwright: Any) -> None:
    try:
        playwright = sync_playwright().start()
        browser = playwright.chromium.launch(headless=HEADLESS)
        page = browser.new_page()
        page.goto(TARGET_URL, wait_until="domcontentloaded", timeout=10_000)
        with state.lock:
            state.mode = "playwright"
        safe_refresh_playwright_state(state, page)
        state.log(f"opened {TARGET_URL}")
    except Exception as exc:
        with state.lock:
            state.mode = "http_probe"
        set_failure(state, type(exc).__name__, f"playwright launch failed: {exc}")
        refresh_http_probe(state)
        return

    while True:
        try:
            action = state.action_queue.get(timeout=REFRESH_INTERVAL_SEC)
        except queue.Empty:
            safe_refresh_playwright_state(state, page)
            continue

        execute_playwright_action(state, page, action)
        safe_refresh_playwright_state(state, page)


def handle_action(state: ArenaState, conn: socket.socket) -> None:
    with conn:
        try:
            line = read_line(conn)
            if not line:
                return
            action = json.loads(line)
            if not isinstance(action, dict):
                raise ValueError("action must be a JSON object")
        except Exception as exc:
            reject_action(state, "InvalidActionJson", f"invalid action JSON: {exc}")
            return

        with state.lock:
            state.last_action = action
            state.last_error_kind = None
            state.last_error = None

        act = action.get("act")
        if act == "noop":
            state.log(f"noop: {action.get('reason') or ''}")
            return

        if act == "wait":
            expected = action.get("expected_state")
            ms = action.get("ms")
            selector = expected.get("selector") if isinstance(expected, dict) else None
            if (
                not isinstance(ms, int)
                or ms < 0
                or ms > MAX_WAIT_MS
                or not isinstance(expected, dict)
                or expected.get("type") != "element_visible"
                or not isinstance(selector, str)
                or selector not in OBSERVED_SELECTORS
            ):
                reject_action(state, "InvalidWaitCondition", "rejected unobservable wait condition")
                return
            state.log(f"passive wait accepted ms={ms} expected_visible={selector}")
            return

        if act not in {"click", "type", "key", "assert_ui_state"}:
            reject_action(state, "UnsupportedAction", f"rejected unsupported act={act}")
            return

        target = action.get("target")
        if act in {"click", "type", "assert_ui_state"}:
            if not isinstance(target, str) or target not in ALLOWED_CLICK_SELECTORS:
                reject_action(state, "SelectorNotAllowed", f"rejected {act} target={target!r}")
                return

        if state.mode != "playwright":
            reject_action(state, "ReadOnlyMode", f"read-only mode rejected {act} target={target}")
            return

        try:
            state.action_queue.put_nowait(action)
            state.log(f"queued {act} {target}: {action.get('reason') or ''}")
        except queue.Full:
            reject_action(state, "ActionQueueFull", f"rejected {act} {target}: action queue full")


def reject_action(state: ArenaState, kind: str, message: str) -> None:
    set_failure(state, kind, message)


def set_failure(state: ArenaState, kind: str, message: str) -> None:
    with state.lock:
        state.last_error_kind = kind
        state.last_error = message
    state.log(message)


def refresh_state(state: ArenaState) -> None:
    if state.mode != "playwright":
        refresh_http_probe(state)


def safe_refresh_playwright_state(state: ArenaState, page: Any) -> None:
    try:
        refresh_playwright_state(state, page)
    except Exception as exc:
        set_failure(state, type(exc).__name__, f"state refresh failed: {exc}")


def refresh_playwright_state(state: ArenaState, page: Any) -> None:
    url = page.url
    assert_allowed_url(url)
    title = page.title()
    ready_state = page.evaluate("document.readyState")
    try:
        text = page.locator("body").inner_text(timeout=STATE_TIMEOUT_MS)
    except Exception as exc:
        text = ""
        set_failure(state, type(exc).__name__, f"body text unavailable: {exc}")
    elements = []
    for selector in sorted(OBSERVED_SELECTORS):
        try:
            locator = page.locator(selector).first
            count = page.locator(selector).count()
            if count == 0:
                continue
            box = locator.bounding_box(timeout=STATE_TIMEOUT_MS)
            label = locator.inner_text(timeout=STATE_TIMEOUT_MS)[:120]
            elements.append({"selector": selector, "count": count, "label": label, "box": box})
        except Exception as exc:
            elements.append({"selector": selector, "error": str(exc)[:180]})

    with state.lock:
        state.url = url
        state.title = title
        state.ready_state = str(ready_state)
        state.text_preview = text[:1000]
        state.elements = elements
        if text:
            state.last_error_kind = None
            state.last_error = None


def execute_playwright_action(state: ArenaState, page: Any, action: dict[str, Any]) -> None:
    act = action.get("act")
    target = action.get("target")
    try:
        if act == "click":
            page.click(target, timeout=ACTION_TIMEOUT_MS)
            try:
                page.wait_for_load_state("domcontentloaded", timeout=ACTION_TIMEOUT_MS)
            except Exception:
                pass
            state.log(f"clicked {target}: {action.get('reason') or ''}")
        elif act == "type":
            page.fill(target, str(action.get("text") or ""), timeout=ACTION_TIMEOUT_MS)
            state.log(f"typed {target}: {action.get('reason') or ''}")
        elif act == "key":
            page.keyboard.press(str(action.get("code") or ""), timeout=ACTION_TIMEOUT_MS)
            state.log(f"key: {action.get('code') or ''}")
        elif act == "assert_ui_state":
            expected = str(action.get("expected") or "")
            text = page.locator(target).inner_text(timeout=STATE_TIMEOUT_MS)
            if expected not in text:
                raise AssertionError(f"expected {expected!r} not found in {target!r}")
            state.log(f"asserted {target}: {expected}")
        else:
            state.log(f"ignored unsupported worker act={act}")
    except Exception as exc:
        set_failure(state, type(exc).__name__, str(exc))


def refresh_http_probe(state: ArenaState) -> None:
    try:
        assert_allowed_url(TARGET_URL)
        request = urllib.request.Request(
            TARGET_URL, headers={"User-Agent": "GenesisWebArena/1.0"}
        )
        with urllib.request.urlopen(request, timeout=2) as response:
            raw = response.read(200_000).decode("utf-8", errors="replace")
        title, text, links = parse_html(raw)
        with state.lock:
            state.url = TARGET_URL
            state.title = title
            state.ready_state = "probe"
            state.text_preview = text[:1000]
            state.elements = links
    except Exception as exc:
        set_failure(state, type(exc).__name__, str(exc))


def parse_html(raw: str) -> tuple[str, str, list[dict[str, Any]]]:
    title_match = re.search(r"<title[^>]*>(.*?)</title>", raw, flags=re.I | re.S)
    title = clean_text(title_match.group(1)) if title_match else ""
    body = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", raw, flags=re.I | re.S)
    text = clean_text(re.sub(r"<[^>]+>", " ", body))
    links: list[dict[str, Any]] = []
    for index, match in enumerate(re.finditer(r"<a\b[^>]*>(.*?)</a>", raw, flags=re.I | re.S)):
        if index >= 20:
            break
        links.append({"selector": "a", "label": clean_text(match.group(1))[:120]})
    return title, text, links


def assert_allowed_url(url: str) -> None:
    origin = origin_of(url)
    if origin not in ALLOWED_ORIGINS:
        raise ValueError(f"origin not allowlisted: {origin}")


def clean_text(text: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


def run_selftest() -> None:
    title, text, links = parse_html(
        "<html><head><title>Alpha</title></head>"
        "<body><a href='/x'>First link</a><p>Hello   world</p></body></html>"
    )
    assert title == "Alpha"
    assert "Hello world" in text
    assert links and links[0]["selector"] == "a"
    assert origin_of("https://example.com/path") == "https://example.com"
    assert MAX_WAIT_MS == 2_000
    print("[web-arena] selftest passed")


if __name__ == "__main__":
    main()
