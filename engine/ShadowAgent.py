#!/usr/bin/env python3
"""
Project Lazarus shadow agent.

The agent runs the legacy path and refactored path side by side, compares their
canonical outputs, and emits an audit record. The legacy result remains
authoritative. Shadow execution is refused unless the caller declares an
acceptable side-effect policy.
"""

from __future__ import annotations

import concurrent.futures
import dataclasses
import hashlib
import json
import time
from pathlib import Path
from typing import Any, Callable, Literal, Protocol


ShadowMode = Literal["read_only", "sandbox", "idempotent"]
Verdict = Literal[
    "MATCH",
    "MISMATCH",
    "PRIMARY_ERROR",
    "SHADOW_ERROR",
    "TIMEOUT",
    "POLICY_REJECTED",
]


class Endpoint(Protocol):
    def __call__(self, payload: dict[str, Any]) -> Any:
        ...


@dataclasses.dataclass(frozen=True)
class ShadowPolicy:
    mode: ShadowMode
    timeout_seconds: float = 2.0
    ignored_fields: tuple[str, ...] = ()
    numeric_tolerance: float = 0.0

    def validate(self) -> None:
        if self.mode not in {"read_only", "sandbox", "idempotent"}:
            raise ValueError(f"unsafe shadow mode: {self.mode!r}")
        if not (0.0 < self.timeout_seconds <= 30.0):
            raise ValueError("timeout_seconds must be within (0, 30]")
        if self.numeric_tolerance < 0.0:
            raise ValueError("numeric_tolerance must be non-negative")


@dataclasses.dataclass(frozen=True)
class ShadowRequest:
    request_id: str
    operation: str
    payload: dict[str, Any]
    idempotency_key: str | None = None

    def validate(self) -> None:
        if not self.request_id:
            raise ValueError("request_id is required")
        if not self.operation:
            raise ValueError("operation is required")
        if not isinstance(self.payload, dict):
            raise ValueError("payload must be a dict")


@dataclasses.dataclass(frozen=True)
class ShadowReport:
    request_id: str
    operation: str
    verdict: Verdict
    primary_hash: str | None
    shadow_hash: str | None
    diff: dict[str, Any]
    elapsed_ms: int
    error: str | None = None

    def to_json(self) -> str:
        return json.dumps(dataclasses.asdict(self), ensure_ascii=False, sort_keys=True)


def _strip_ignored(value: Any, ignored_fields: tuple[str, ...]) -> Any:
    if isinstance(value, dict):
        return {
            key: _strip_ignored(item, ignored_fields)
            for key, item in sorted(value.items())
            if key not in ignored_fields
        }
    if isinstance(value, list):
        return [_strip_ignored(item, ignored_fields) for item in value]
    return value


def _stable_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def stable_hash(value: Any) -> str:
    return hashlib.sha256(_stable_json(value).encode("utf-8")).hexdigest()


def _numbers_close(left: Any, right: Any, tolerance: float) -> bool:
    if isinstance(left, bool) or isinstance(right, bool):
        return left == right
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return abs(float(left) - float(right)) <= tolerance
    return left == right


def semantic_diff(left: Any, right: Any, tolerance: float, path: str = "$") -> dict[str, Any]:
    if isinstance(left, dict) and isinstance(right, dict):
        diffs: dict[str, Any] = {}
        for key in sorted(set(left) | set(right)):
            child_path = f"{path}.{key}"
            if key not in left:
                diffs[child_path] = {"left": "<missing>", "right": right[key]}
            elif key not in right:
                diffs[child_path] = {"left": left[key], "right": "<missing>"}
            else:
                child = semantic_diff(left[key], right[key], tolerance, child_path)
                diffs.update(child)
        return diffs
    if isinstance(left, list) and isinstance(right, list):
        diffs = {}
        if len(left) != len(right):
            diffs[f"{path}.length"] = {"left": len(left), "right": len(right)}
        for index, (left_item, right_item) in enumerate(zip(left, right)):
            diffs.update(semantic_diff(left_item, right_item, tolerance, f"{path}[{index}]"))
        return diffs
    if _numbers_close(left, right, tolerance):
        return {}
    return {path: {"left": left, "right": right}}


class ShadowAgent:
    def __init__(
        self,
        primary: Endpoint,
        shadow: Endpoint,
        policy: ShadowPolicy,
        audit_path: str | Path | None = None,
        shadow_payload_transform: Callable[[dict[str, Any]], dict[str, Any]] | None = None,
    ) -> None:
        policy.validate()
        self._primary = primary
        self._shadow = shadow
        self._policy = policy
        self._audit_path = Path(audit_path) if audit_path else None
        self._shadow_payload_transform = shadow_payload_transform or self._default_shadow_payload

    def execute(self, request: ShadowRequest) -> tuple[Any | None, ShadowReport]:
        request.validate()
        start = time.monotonic()

        try:
            primary_payload = dict(request.payload)
            shadow_payload = self._shadow_payload_transform(dict(request.payload))
        except Exception as exc:
            report = self._report(request, "POLICY_REJECTED", None, None, {}, start, str(exc))
            self._audit(report)
            return None, report

        pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)
        try:
            primary_future = pool.submit(self._primary, primary_payload)
            shadow_future = pool.submit(self._shadow, shadow_payload)

            primary_result, primary_error = self._collect(primary_future)
            shadow_result, shadow_error = self._collect(shadow_future)
        finally:
            pool.shutdown(wait=False, cancel_futures=True)

        if primary_error:
            report = self._report(
                request, "PRIMARY_ERROR", primary_result, shadow_result, {}, start, primary_error
            )
            self._audit(report)
            return None, report

        if shadow_error:
            verdict: Verdict = "TIMEOUT" if shadow_error == "timeout" else "SHADOW_ERROR"
            report = self._report(
                request, verdict, primary_result, shadow_result, {}, start, shadow_error
            )
            self._audit(report)
            return primary_result, report

        left = _strip_ignored(primary_result, self._policy.ignored_fields)
        right = _strip_ignored(shadow_result, self._policy.ignored_fields)
        diff = semantic_diff(left, right, self._policy.numeric_tolerance)
        report = self._report(
            request,
            "MATCH" if not diff else "MISMATCH",
            left,
            right,
            diff,
            start,
            None,
        )
        self._audit(report)
        return primary_result, report

    def _default_shadow_payload(self, payload: dict[str, Any]) -> dict[str, Any]:
        payload["_lazarus_shadow_mode"] = self._policy.mode
        return payload

    def _collect(self, future: concurrent.futures.Future[Any]) -> tuple[Any | None, str | None]:
        try:
            return future.result(timeout=self._policy.timeout_seconds), None
        except concurrent.futures.TimeoutError:
            future.cancel()
            return None, "timeout"
        except Exception as exc:
            return None, f"{type(exc).__name__}: {exc}"

    def _report(
        self,
        request: ShadowRequest,
        verdict: Verdict,
        primary_result: Any,
        shadow_result: Any,
        diff: dict[str, Any],
        start: float,
        error: str | None,
    ) -> ShadowReport:
        return ShadowReport(
            request_id=request.request_id,
            operation=request.operation,
            verdict=verdict,
            primary_hash=stable_hash(primary_result) if primary_result is not None else None,
            shadow_hash=stable_hash(shadow_result) if shadow_result is not None else None,
            diff=diff,
            elapsed_ms=int((time.monotonic() - start) * 1000),
            error=error,
        )

    def _audit(self, report: ShadowReport) -> None:
        if not self._audit_path:
            return
        self._audit_path.parent.mkdir(parents=True, exist_ok=True)
        with self._audit_path.open("a", encoding="utf-8") as handle:
            handle.write(report.to_json() + "\n")


def _selftest() -> None:
    def legacy(payload: dict[str, Any]) -> dict[str, Any]:
        return {"balance": payload["balance"] + 10, "trace": "legacy"}

    def refactored(payload: dict[str, Any]) -> dict[str, Any]:
        assert payload["_lazarus_shadow_mode"] == "sandbox"
        return {"balance": payload["balance"] + 10, "trace": "new"}

    agent = ShadowAgent(
        legacy,
        refactored,
        ShadowPolicy(mode="sandbox", ignored_fields=("trace",)),
    )
    _, report = agent.execute(
        ShadowRequest(request_id="selftest-1", operation="credit", payload={"balance": 90})
    )
    assert report.verdict == "MATCH", report

    bad_agent = ShadowAgent(legacy, lambda _: {"balance": 101}, ShadowPolicy(mode="sandbox"))
    _, bad_report = bad_agent.execute(
        ShadowRequest(request_id="selftest-2", operation="credit", payload={"balance": 90})
    )
    assert bad_report.verdict == "MISMATCH", bad_report
    print("ShadowAgent selftest passed")


if __name__ == "__main__":
    _selftest()
