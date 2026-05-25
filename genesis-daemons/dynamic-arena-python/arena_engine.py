from __future__ import annotations

import math
import os
import queue
import random
import threading
import time
from dataclasses import dataclass
from typing import Any

from snapshot_committer import SnapshotCommitter


MAX_ACTION_QUEUE = int(os.environ.get("GENESIS_DYNAMIC_ACTION_QUEUE", "32"))
FRAME_RATE = int(os.environ.get("GENESIS_DYNAMIC_FPS", "60"))
WIDTH = int(os.environ.get("GENESIS_DYNAMIC_WIDTH", "640"))
HEIGHT = int(os.environ.get("GENESIS_DYNAMIC_HEIGHT", "360"))
FRESH_FRAME_TOLERANCE = int(os.environ.get("GENESIS_DYNAMIC_FRESH_FRAME_TOLERANCE", "2"))
MAX_SPATIAL_DRIFT_PX = float(os.environ.get("GENESIS_DYNAMIC_MAX_DRIFT_PX", "6"))
TARGET_ID = os.environ.get("GENESIS_DYNAMIC_TARGET_ID", "heal")
HEADLESS = os.environ.get("GENESIS_DYNAMIC_HEADLESS", "1") != "0"
SELFTEST_MODE = os.environ.get("GENESIS_DYNAMIC_SELFTEST_MODE", "0") == "1"


def now_ms() -> int:
    return int(time.time() * 1000)


@dataclass
class Target:
    id: str
    x: float
    y: float
    w: float = 64
    h: float = 32
    visible: bool = True
    hidden: bool = False
    occluded: bool = False
    confidence: float = 0.94
    render_x: float | None = None
    render_y: float | None = None

    def center(self) -> tuple[float, float]:
        return (self.x + self.w / 2, self.y + self.h / 2)

    def contains(self, x: float, y: float) -> bool:
        return self.x <= x <= self.x + self.w and self.y <= y <= self.y + self.h

    def snapshot(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "visible": self.visible,
            "hidden": self.hidden,
            "occluded": self.occluded,
            "x": round(self.x, 2),
            "y": round(self.y, 2),
            "w": round(self.w, 2),
            "h": round(self.h, 2),
            "render_x": round(self.render_x if self.render_x is not None else self.x, 2),
            "render_y": round(self.render_y if self.render_y is not None else self.y, 2),
            "confidence": self.confidence,
        }


class DynamicArenaEngine:
    def __init__(self) -> None:
        self.action_queue: queue.Queue[dict[str, Any]] = queue.Queue(
            maxsize=MAX_ACTION_QUEUE
        )
        self.frame_id = 0
        self.focused = True
        self.jank = False
        self.last_action: dict[str, Any] | None = None
        self.last_error_kind: str | None = None
        self.last_error: str | None = None
        self.last_verdict: dict[str, Any] | None = None
        self.log: list[str] = []
        self.target = Target(TARGET_ID, x=240, y=150)
        self.committer = SnapshotCommitter(self._snapshot())
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._loop, name="DynamicArena", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=1.0)

    def read_snapshot(self) -> dict[str, Any]:
        snapshot = self.committer.read()
        snapshot["served_at_ms"] = now_ms()
        snapshot["sense_latency_ms"] = max(
            0, snapshot["served_at_ms"] - int(snapshot.get("captured_at_ms") or 0)
        )
        return snapshot

    def enqueue_action(self, action: dict[str, Any]) -> bool:
        try:
            self.action_queue.put_nowait(action)
            return True
        except queue.Full:
            self.last_error_kind = "ActionQueueFull"
            self.last_error = "dynamic action queue full"
            return False

    def _loop(self) -> None:
        frame_budget = 1.0 / max(FRAME_RATE, 1)
        while not self._stop.is_set():
            start = time.perf_counter()
            self._advance_world()
            self._drain_actions()
            self.committer.commit(self._snapshot())
            elapsed = time.perf_counter() - start
            time.sleep(max(0.0, frame_budget - elapsed))

    def _advance_world(self) -> None:
        self.frame_id += 1
        if SELFTEST_MODE:
            self.target.x = 240
            self.target.y = 150
            self.target.hidden = False
            self.target.visible = True
            self.target.occluded = False
            self.focused = True
            self.jank = False
            return

        t = self.frame_id / max(FRAME_RATE, 1)
        self.target.x = 240 + math.sin(t * 1.7) * 96 + math.sin(t * 7.0) * 4
        self.target.y = 150 + math.cos(t * 1.3) * 48
        self.target.hidden = self.frame_id % 241 in range(0, 18)
        self.target.visible = not self.target.hidden
        self.target.occluded = self.frame_id % 317 in range(0, 24)
        self.focused = self.frame_id % 421 not in range(0, 20)
        self.jank = self.frame_id % 503 in range(0, 6)
        self.target.render_x = self.target.x
        self.target.render_y = self.target.y
        if self.frame_id % 389 in range(0, 14):
            self.target.render_x = self.target.x + 12
            self.target.render_y = self.target.y

    def _drain_actions(self) -> None:
        while True:
            try:
                action = self.action_queue.get_nowait()
            except queue.Empty:
                return
            self.last_action = action
            self.last_verdict = self._judge_action(action)
            self.last_action_id = self.last_verdict.get("action_id")
            self.last_error_kind = self.last_verdict.get("failure_kind")
            self.last_error = self.last_verdict.get("reason")
            self._log(
                f"{action.get('act')} id={action.get('action_id')} target={action.get('target_id')} "
                f"verdict={self.last_verdict.get('status')} "
                f"failure={self.last_error_kind} warning={self.last_verdict.get('warning_kind')}"
            )

    def _judge_action(self, action: dict[str, Any]) -> dict[str, Any]:
        action_id = str(action.get("action_id") or "")
        if action.get("act") != "click_point":
            return self._failed(
                "UnsupportedAction",
                "dynamic arena accepts click_point only",
                action_id=action_id,
            )

        target_id = str(action.get("target_id") or "")
        action_frame = int(action.get("frame_id") or -1)
        x = float(action.get("x") or 0)
        y = float(action.get("y") or 0)
        frame_delta = max(0, self.frame_id - action_frame)
        target = self.target if target_id == self.target.id else None

        if not self.focused:
            return self._failed(
                "FocusLost", "arena focus is false", frame_delta=frame_delta, action_id=action_id
            )
        if target is None:
            return self._failed(
                "TargetMissing", f"target_id not found: {target_id}", frame_delta, action_id=action_id
            )
        if target.hidden or not target.visible:
            return self._failed(
                "TargetHidden", f"target hidden: {target_id}", frame_delta, action_id=action_id
            )
        if target.occluded:
            return self._failed(
                "TargetOccluded", f"target occluded: {target_id}", frame_delta, action_id=action_id
            )
        is_hit = target.contains(x, y)
        drift = self._drift_px(x, y, target)
        if frame_delta > FRESH_FRAME_TOLERANCE and not is_hit:
            return self._failed(
                "StaleFrame",
                "frame stale and point missed target",
                frame_delta,
                drift,
                action_id=action_id,
            )
        if x < 0 or y < 0 or x > WIDTH or y > HEIGHT:
            return self._failed(
                "CoordinateOutOfBounds",
                "click point outside arena",
                frame_delta,
                action_id=action_id,
            )
        if frame_delta <= FRESH_FRAME_TOLERANCE and not is_hit:
            return self._failed(
                "TargetDrift",
                "fresh frame but target moved away",
                frame_delta,
                drift,
                action_id=action_id,
            )

        warning = None
        policy = "within_tolerance"
        if frame_delta > FRESH_FRAME_TOLERANCE:
            warning = "StaleButHit"
            policy = "stale_but_hit"
        elif drift > MAX_SPATIAL_DRIFT_PX:
            warning = "HighSpatialDrift"

        return {
            "action_id": action_id,
            "status": "Verified",
            "failure_kind": None,
            "warning_kind": warning,
            "reason": None,
            "target_id": target.id,
            "frame_delta": frame_delta,
            "spatial_drift_px": round(drift, 3),
            "staleness_policy": policy,
            "action_frame_id": action_frame,
            "observed_frame_id": self.frame_id,
        }

    def _failed(
        self,
        kind: str,
        reason: str,
        frame_delta: int | None = None,
        drift: float | None = None,
        action_id: str = "",
    ) -> dict[str, Any]:
        return {
            "action_id": action_id,
            "status": "Failed",
            "failure_kind": kind,
            "warning_kind": None,
            "reason": reason,
            "target_id": self.target.id,
            "frame_delta": frame_delta,
            "spatial_drift_px": None if drift is None else round(drift, 3),
            "staleness_policy": "failed",
            "observed_frame_id": self.frame_id,
        }

    @staticmethod
    def _drift_px(x: float, y: float, target: Target) -> float:
        cx, cy = target.center()
        dx = max(abs(x - cx) - target.w / 2, 0)
        dy = max(abs(y - cy) - target.h / 2, 0)
        return math.sqrt(dx * dx + dy * dy)

    def _snapshot(self) -> dict[str, Any]:
        return {
            "frame_id": self.frame_id,
            "captured_at_ms": now_ms(),
            "fps": FRAME_RATE,
            "width": WIDTH,
            "height": HEIGHT,
            "focused": self.focused,
            "jank": self.jank,
            "fresh_frame_tolerance": FRESH_FRAME_TOLERANCE,
            "max_spatial_drift_px": MAX_SPATIAL_DRIFT_PX,
            "targets": [self.target.snapshot()],
            "last_action": self.last_action,
            "last_action_id": self.last_verdict.get("action_id") if self.last_verdict else None,
            "last_error_kind": self.last_error_kind,
            "last_error": self.last_error,
            "last_verdict": self.last_verdict,
            "log": self.log[-12:],
        }

    def _log(self, message: str) -> None:
        self.log.append(f"[{now_ms()}] {message}")
        self.log = self.log[-40:]


def render_loop(engine: DynamicArenaEngine) -> None:
    if HEADLESS:
        return
    try:
        import pygame  # type: ignore
    except Exception as exc:
        engine._log(f"pygame unavailable; continuing headless: {exc}")
        return

    pygame.init()
    screen = pygame.display.set_mode((WIDTH, HEIGHT))
    pygame.display.set_caption("Genesis Dynamic Arena")
    clock = pygame.time.Clock()
    while True:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                return
        snapshot = engine.read_snapshot()
        screen.fill((18, 20, 28))
        for target in snapshot["targets"]:
            if target["visible"] and not target["hidden"]:
                color = (80, 220, 140) if not target["occluded"] else (120, 120, 120)
                rect = pygame.Rect(
                    target["render_x"], target["render_y"], target["w"], target["h"]
                )
                pygame.draw.rect(screen, color, rect)
        pygame.display.flip()
        clock.tick(FRAME_RATE)
