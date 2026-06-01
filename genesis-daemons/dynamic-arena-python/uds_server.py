from __future__ import annotations

import json
import os
import socket
import sys
import threading
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from daemon_transport import (
    ClientThreadLimiter,
    SERVICE_DYNAMIC_ACT,
    bind_unix_stream_socket,
    local_service_socket_path,
    parse_int_env,
    read_line,
    serve_json_state,
)
from arena_engine import DynamicArenaEngine


STATE_HOST = os.environ.get("GENESIS_DYNAMIC_ARENA_HOST", "127.0.0.1")
STATE_PORT = parse_int_env("GENESIS_DYNAMIC_ARENA_PORT", 4781, 1)
ACTION_SOCKET_PATH = os.environ.get(
    "GENESIS_DYNAMIC_ACT_SOCKET", local_service_socket_path(SERVICE_DYNAMIC_ACT)
)
CLIENT_THREADS = ClientThreadLimiter("dynamic-arena", connection_arg_index=1)


def serve_state(engine: DynamicArenaEngine) -> None:
    serve_json_state(
        STATE_HOST,
        STATE_PORT,
        label="dynamic-arena-state",
        log_prefix="dynamic-arena",
        snapshot_provider=engine.read_snapshot,
    )


def start_action_socket(engine: DynamicArenaEngine) -> None:
    server = bind_unix_stream_socket(ACTION_SOCKET_PATH)
    print(f"[dynamic-arena] action socket at {ACTION_SOCKET_PATH}")

    def accept_loop() -> None:
        while True:
            conn, _ = server.accept()
            CLIENT_THREADS.spawn(handle_action, engine, conn)

    threading.Thread(target=accept_loop, daemon=True).start()


def handle_action(engine: DynamicArenaEngine, conn: socket.socket) -> None:
    with conn:
        try:
            raw = read_line(conn)
            action = json.loads(raw)
            if not isinstance(action, dict):
                raise ValueError("action must be a JSON object")
        except Exception as exc:
            write_line(conn, {"status": "error", "reason": f"invalid action: {exc}"})
            return

        accepted = engine.enqueue_action(action)
        if accepted:
            write_line(conn, {"status": "queued"})
        else:
            write_line(conn, {"status": "rejected", "reason": "ActionQueueFull"})


def write_line(conn: socket.socket, payload: dict[str, Any]) -> None:
    conn.sendall(json.dumps(payload, ensure_ascii=False).encode("utf-8") + b"\n")
