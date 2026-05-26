#!/usr/bin/env python3
"""Low-entropy v5.1 vision-to-action spatiotemporal alignment helpers.

This module deliberately does not perform object detection, OCR, or action
planning. It only converts physical pixel coordinates into the local logical
coordinate domain consumed by genesis-os-driver, and classifies stale vision
snapshots before they can become physical actions.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import asdict, dataclass
from typing import Any


DEFAULT_MAX_VISION_LAG_MS = 150.0
COORDINATE_ABS_LIMIT = 1_000_000.0


@dataclass(frozen=True)
class ViewportOffset:
    x: float
    y: float


@dataclass(frozen=True)
class LogicalPoint:
    x: float
    y: float


@dataclass(frozen=True)
class TransformEvidence:
    physical_x: float
    physical_y: float
    logical_x: float
    logical_y: float
    scale_factor: float
    viewport_x: float
    viewport_y: float
    captured_at_ms: int
    served_at_ms: int
    vision_lag_ms: int
    max_vision_lag_ms: float


class AlignmentError(ValueError):
    def __init__(self, failure_kind: str, evidence: dict[str, Any]) -> None:
        super().__init__(failure_kind)
        self.failure_kind = failure_kind
        self.evidence = evidence


def pixel_to_local_logical(
    physical_x: float,
    physical_y: float,
    *,
    scale_factor: float,
    viewport: ViewportOffset,
) -> LogicalPoint:
    require_finite("physical_x", physical_x)
    require_finite("physical_y", physical_y)
    require_finite("scale_factor", scale_factor)
    require_finite("viewport.x", viewport.x)
    require_finite("viewport.y", viewport.y)

    if scale_factor <= 0.0:
        raise AlignmentError(
            "InvalidScaleFactor",
            {"scale_factor": scale_factor},
        )
    if abs(physical_x) > COORDINATE_ABS_LIMIT or abs(physical_y) > COORDINATE_ABS_LIMIT:
        raise AlignmentError(
            "PhysicalCoordinateOutOfBounds",
            {"physical_x": physical_x, "physical_y": physical_y},
        )

    return LogicalPoint(
        x=(physical_x / scale_factor) - viewport.x,
        y=(physical_y / scale_factor) - viewport.y,
    )


def align_detection(
    *,
    physical_x: float,
    physical_y: float,
    scale_factor: float,
    viewport: ViewportOffset,
    captured_at_ms: int,
    served_at_ms: int,
    max_vision_lag_ms: float = DEFAULT_MAX_VISION_LAG_MS,
) -> tuple[LogicalPoint, TransformEvidence]:
    if served_at_ms < captured_at_ms:
        raise AlignmentError(
            "InvalidVisionTimestamp",
            {"captured_at_ms": captured_at_ms, "served_at_ms": served_at_ms},
        )

    vision_lag_ms = served_at_ms - captured_at_ms
    if vision_lag_ms > max_vision_lag_ms:
        raise AlignmentError(
            "StaleVision",
            {
                "captured_at_ms": captured_at_ms,
                "served_at_ms": served_at_ms,
                "vision_lag_ms": vision_lag_ms,
                "max_vision_lag_ms": max_vision_lag_ms,
            },
        )

    point = pixel_to_local_logical(
        physical_x,
        physical_y,
        scale_factor=scale_factor,
        viewport=viewport,
    )
    evidence = TransformEvidence(
        physical_x=physical_x,
        physical_y=physical_y,
        logical_x=point.x,
        logical_y=point.y,
        scale_factor=scale_factor,
        viewport_x=viewport.x,
        viewport_y=viewport.y,
        captured_at_ms=captured_at_ms,
        served_at_ms=served_at_ms,
        vision_lag_ms=vision_lag_ms,
        max_vision_lag_ms=max_vision_lag_ms,
    )
    return point, evidence


def build_click_point_action(
    *,
    action_id: str,
    target_id: str,
    frame_id: int,
    physical_x: float,
    physical_y: float,
    scale_factor: float,
    viewport: ViewportOffset,
    captured_at_ms: int,
    served_at_ms: int,
    max_vision_lag_ms: float = DEFAULT_MAX_VISION_LAG_MS,
) -> dict[str, Any]:
    point, evidence = align_detection(
        physical_x=physical_x,
        physical_y=physical_y,
        scale_factor=scale_factor,
        viewport=viewport,
        captured_at_ms=captured_at_ms,
        served_at_ms=served_at_ms,
        max_vision_lag_ms=max_vision_lag_ms,
    )
    return {
        "action_id": action_id,
        "act": "click_point",
        "target_id": target_id,
        "x": point.x,
        "y": point.y,
        "frame_id": frame_id,
        "reason": "vision-action transformer aligned physical pixel detection",
        "alignment_evidence": asdict(evidence),
    }


def require_finite(name: str, value: float) -> None:
    if not isinstance(value, (int, float)) or not math.isfinite(value):
        raise AlignmentError("NonFiniteVisionCoordinate", {name: value})


def selftest() -> None:
    viewport = ViewportOffset(x=10.0, y=20.0)
    action = build_click_point_action(
        action_id="act-v51-1",
        target_id="heal",
        frame_id=42,
        physical_x=1000.0,
        physical_y=500.0,
        scale_factor=2.0,
        viewport=viewport,
        captured_at_ms=1_000,
        served_at_ms=1_085,
        max_vision_lag_ms=150.0,
    )
    assert action["x"] == 490.0, action
    assert action["y"] == 230.0, action
    assert action["alignment_evidence"]["vision_lag_ms"] == 85, action

    try:
        build_click_point_action(
            action_id="act-v51-stale",
            target_id="heal",
            frame_id=43,
            physical_x=1000.0,
            physical_y=500.0,
            scale_factor=2.0,
            viewport=viewport,
            captured_at_ms=1_000,
            served_at_ms=1_151,
            max_vision_lag_ms=150.0,
        )
    except AlignmentError as error:
        assert error.failure_kind == "StaleVision", error.failure_kind
        assert error.evidence["vision_lag_ms"] == 151, error.evidence
    else:
        raise AssertionError("expected StaleVision")

    print("[v5.1-spatiotemporal] transformer selftest passed")


def cli() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--physical-x", type=float)
    parser.add_argument("--physical-y", type=float)
    parser.add_argument("--scale-factor", type=float)
    parser.add_argument("--viewport-x", type=float, default=0.0)
    parser.add_argument("--viewport-y", type=float, default=0.0)
    parser.add_argument("--captured-at-ms", type=int)
    parser.add_argument("--served-at-ms", type=int)
    parser.add_argument("--max-vision-lag-ms", type=float, default=DEFAULT_MAX_VISION_LAG_MS)
    parser.add_argument("--frame-id", type=int, default=0)
    parser.add_argument("--target-id", default="target")
    parser.add_argument("--action-id", default="act-v51")
    args = parser.parse_args()

    if args.selftest:
        selftest()
        return 0

    required = [
        args.physical_x,
        args.physical_y,
        args.scale_factor,
        args.captured_at_ms,
        args.served_at_ms,
    ]
    if any(value is None for value in required):
        parser.error("coordinate conversion requires physical, scale, and timestamp arguments")

    try:
        action = build_click_point_action(
            action_id=args.action_id,
            target_id=args.target_id,
            frame_id=args.frame_id,
            physical_x=args.physical_x,
            physical_y=args.physical_y,
            scale_factor=args.scale_factor,
            viewport=ViewportOffset(args.viewport_x, args.viewport_y),
            captured_at_ms=args.captured_at_ms,
            served_at_ms=args.served_at_ms,
            max_vision_lag_ms=args.max_vision_lag_ms,
        )
    except AlignmentError as error:
        print(
            json.dumps(
                {
                    "status": "failed",
                    "failure_kind": error.failure_kind,
                    "evidence": error.evidence,
                },
                sort_keys=True,
            )
        )
        return 2

    print(json.dumps({"status": "ok", "action": action}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(cli())
