#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import threading
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from daemon_transport import connect_unix_stream_socket
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
        first = wait_ready_snapshot(engine)
        time.sleep(0.08)
        second = engine.read_snapshot()
        assert second["frame_id"] > first["frame_id"], (first, second)
        target = second["targets"][0]
        x = target["x"] + target["w"] / 2
        y = target["y"] + target["h"] / 2
        assert engine.enqueue_action(
            {
                "action_id": "selftest-hit",
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
        assert verdict["action_id"] == "selftest-hit", verdict
        stale_frame = max(0, engine.frame_id - 99)
        assert engine.enqueue_action(
            {
                "action_id": "selftest-stale",
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
        assert verdict["action_id"] == "selftest-stale", verdict
    finally:
        engine.stop()

    print("[dynamic-arena] selftest passed")


def wait_ready_snapshot(engine: DynamicArenaEngine) -> dict:
    deadline = time.time() + 2.0
    while time.time() < deadline:
        snapshot = engine.read_snapshot()
        target = snapshot["targets"][0]
        if (
            snapshot["focused"]
            and target["visible"]
            and not target["hidden"]
            and not target["occluded"]
        ):
            return snapshot
        time.sleep(0.02)
    raise AssertionError(f"arena did not reach a ready selftest frame: {snapshot}")


def smoke_server() -> None:
    with urllib.request.urlopen(f"http://{STATE_HOST}:{STATE_PORT}/state", timeout=1) as response:
        state = json.loads(response.read())
    target = state["targets"][0]
    payload = {
        "action_id": "manual-smoke",
        "act": "click_point",
        "target_id": target["id"],
        "x": target["x"] + target["w"] / 2,
        "y": target["y"] + target["h"] / 2,
        "frame_id": state["frame_id"],
        "reason": "manual smoke click",
    }
    with connect_unix_stream_socket(ACTION_SOCKET_PATH) as client:
        client.sendall(json.dumps(payload).encode("utf-8") + b"\n")
        print(client.recv(4096).decode("utf-8", errors="replace").strip())


if __name__ == "__main__":
    main()
