#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import socket
import threading
import time
import urllib.request

from arena_engine import DynamicArenaEngine, render_loop
from uds_server import ACTION_SOCKET_PATH, STATE_HOST, STATE_PORT, serve_state, start_action_socket


def main() -> None:
    if os.environ.get("GENESIS_DYNAMIC_ARENA_SELFTEST") == "1":
        run_selftest()
        return

    engine = DynamicArenaEngine()
    engine.start()
    start_action_socket(engine)
    threading.Thread(target=render_loop, args=(engine,), daemon=True).start()
    serve_state(engine)


def run_selftest() -> None:
    engine = DynamicArenaEngine()
    engine.start()
    try:
        time.sleep(0.08)
        first = engine.read_snapshot()
        time.sleep(0.08)
        second = engine.read_snapshot()
        assert second["frame_id"] > first["frame_id"], (first, second)
        target = second["targets"][0]
        x = target["x"] + target["w"] / 2
        y = target["y"] + target["h"] / 2
        assert engine.enqueue_action(
            {
                "act": "click_point",
                "target_id": target["id"],
                "x": x,
                "y": y,
                "frame_id": second["frame_id"],
                "reason": "selftest click current committed frame",
            }
        )
        time.sleep(0.08)
        verdict = engine.read_snapshot()["last_verdict"]
        assert verdict and verdict["status"] == "Verified", verdict
        stale_frame = max(0, engine.frame_id - 99)
        assert engine.enqueue_action(
            {
                "act": "click_point",
                "target_id": target["id"],
                "x": -20,
                "y": -20,
                "frame_id": stale_frame,
                "reason": "selftest stale miss",
            }
        )
        time.sleep(0.08)
        verdict = engine.read_snapshot()["last_verdict"]
        assert verdict and verdict["failure_kind"] == "StaleFrame", verdict
    finally:
        engine.stop()

    print("[dynamic-arena] selftest passed")


def smoke_server() -> None:
    with urllib.request.urlopen(f"http://{STATE_HOST}:{STATE_PORT}/state", timeout=1) as response:
        state = json.loads(response.read())
    target = state["targets"][0]
    payload = {
        "act": "click_point",
        "target_id": target["id"],
        "x": target["x"] + target["w"] / 2,
        "y": target["y"] + target["h"] / 2,
        "frame_id": state["frame_id"],
        "reason": "manual smoke click",
    }
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(ACTION_SOCKET_PATH)
        client.sendall(json.dumps(payload).encode("utf-8") + b"\n")
        print(client.recv(4096).decode("utf-8", errors="replace").strip())


if __name__ == "__main__":
    main()
