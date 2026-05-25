from __future__ import annotations

import json
import os
import socket
import socketserver
import threading
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any

from arena_engine import DynamicArenaEngine


STATE_HOST = os.environ.get("GENESIS_DYNAMIC_ARENA_HOST", "127.0.0.1")
STATE_PORT = int(os.environ.get("GENESIS_DYNAMIC_ARENA_PORT", "4781"))
ACTION_SOCKET_PATH = os.environ.get(
    "GENESIS_DYNAMIC_ACT_SOCKET", "/tmp/genesis_dynamic_act.sock"
)


def serve_state(engine: DynamicArenaEngine) -> None:
    class ReusableThreadingTCPServer(socketserver.ThreadingTCPServer):
        allow_reuse_address = True

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            if self.path != "/state":
                self.send_response(404)
                self.end_headers()
                return

            body = json.dumps(engine.read_snapshot(), ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: Any) -> None:
            return

    with ReusableThreadingTCPServer((STATE_HOST, STATE_PORT), Handler) as httpd:
        print(f"[dynamic-arena] state at http://{STATE_HOST}:{STATE_PORT}/state")
        httpd.serve_forever()


def start_action_socket(engine: DynamicArenaEngine) -> None:
    try:
        Path(ACTION_SOCKET_PATH).unlink()
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(ACTION_SOCKET_PATH)
    server.listen()
    print(f"[dynamic-arena] action socket at {ACTION_SOCKET_PATH}")

    def accept_loop() -> None:
        while True:
            conn, _ = server.accept()
            threading.Thread(target=handle_action, args=(engine, conn), daemon=True).start()

    threading.Thread(target=accept_loop, daemon=True).start()


def handle_action(engine: DynamicArenaEngine, conn: socket.socket) -> None:
    with conn:
        try:
            raw = read_line(conn)
            action = json.loads(raw)
        except Exception as exc:
            write_line(conn, {"status": "error", "reason": f"invalid action: {exc}"})
            return

        accepted = engine.enqueue_action(action)
        if accepted:
            write_line(conn, {"status": "queued"})
        else:
            write_line(conn, {"status": "rejected", "reason": "ActionQueueFull"})


def read_line(conn: socket.socket) -> str:
    chunks: list[bytes] = []
    while True:
        chunk = conn.recv(4096)
        if not chunk:
            break
        if b"\n" in chunk:
            before, _, _ = chunk.partition(b"\n")
            chunks.append(before)
            break
        chunks.append(chunk)
    return b"".join(chunks).decode("utf-8", errors="replace")


def write_line(conn: socket.socket, payload: dict[str, Any]) -> None:
    conn.sendall(json.dumps(payload, ensure_ascii=False).encode("utf-8") + b"\n")
