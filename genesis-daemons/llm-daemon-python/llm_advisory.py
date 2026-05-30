from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
from pathlib import Path
from typing import Any


ALLOWED_ADVISORY_FAILURE_KINDS = {
    "ActionQueueFull",
    "AssertionError",
    "PlaywrightLaunchFailed",
    "PlaywrightUnavailable",
    "ReadOnlyMode",
    "SelectorNotAllowed",
    "TimeoutError",
    "WaitConditionNotMet",
    "CoordinateOutOfBounds",
    "DynamicVerdictMissing",
    "FocusLost",
    "HitboxMismatch",
    "StaleFrame",
    "TargetDrift",
    "TargetHidden",
    "TargetMissing",
    "TargetOccluded",
    "UnsupportedAction",
    "Unknown",
}
ALLOWED_ADVISORY_WARNING_KINDS = {
    "HighSpatialDrift",
    "StaleButHit",
    "Unknown",
}
MAX_ADVISORY_SAMPLES = 100
MAX_ADVISORY_QUERY_MS = 50


def read_memory_advisory(
    payload: dict[str, Any],
    allowed_click_targets: set[str],
    allowed_wait_selectors: set[str],
    allowed_acts: set[str],
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    db_path = os.environ.get("GENESIS_ADVISORY_DB")
    active_step = payload.get("active_step")
    if not db_path or not isinstance(active_step, dict):
        return None, None

    target = active_step.get("target_selector")
    if not isinstance(target, str) or target not in allowed_click_targets | allowed_wait_selectors:
        return None, None

    path = Path(db_path)
    if not path.exists():
        return None, None

    sample_limit = max(
        1,
        min(
            _safe_int(os.environ.get("GENESIS_ADVISORY_SAMPLE_LIMIT"), 25),
            MAX_ADVISORY_SAMPLES,
        ),
    )
    query_ms = max(
        1,
        min(
            _safe_int(os.environ.get("GENESIS_ADVISORY_QUERY_MS"), 50),
            MAX_ADVISORY_QUERY_MS,
        ),
    )
    deadline = time.monotonic() + query_ms / 1000
    effective_target = "COALESCE(a.target, json_extract(a.action_json, '$.expected_state.selector'))"

    conn: sqlite3.Connection | None = None
    try:
        conn = sqlite3.connect(
            f"{path.resolve().as_uri()}?mode=ro",
            uri=True,
            timeout=query_ms / 1000,
        )
        conn.execute("PRAGMA query_only = ON")
        conn.set_progress_handler(lambda: 1 if time.monotonic() >= deadline else 0, 100)
        outcome_columns = {
            row[1] for row in conn.execute("PRAGMA table_info(outcomes)").fetchall()
        }
        has_warning_kind = "warning_kind" in outcome_columns
        sample_count = conn.execute(
            f"""
            SELECT COUNT(*) FROM (
                SELECT o.action_id
                FROM outcomes AS o
                JOIN actions AS a USING (action_id)
                WHERE {effective_target} = ?
                ORDER BY o.timestamp_ms DESC
                LIMIT ?
            )
            """,
            (target, sample_limit),
        ).fetchone()[0]
        if sample_count == 0:
            return None, None
        failures = conn.execute(
            f"""
            SELECT COALESCE(failure_kind, 'Unknown'), COUNT(*)
            FROM (
                SELECT o.failure_kind, o.status
                FROM outcomes AS o
                JOIN actions AS a USING (action_id)
                WHERE {effective_target} = ?
                ORDER BY o.timestamp_ms DESC
                LIMIT ?
            )
            WHERE status = 'Failed'
            GROUP BY failure_kind
            ORDER BY COUNT(*) DESC, failure_kind
            """,
            (target, sample_limit),
        ).fetchall()
        last_verified = conn.execute(
            f"""
            SELECT a.act
            FROM outcomes AS o
            JOIN actions AS a USING (action_id)
            WHERE {effective_target} = ? AND o.status = 'Verified'
            ORDER BY o.timestamp_ms DESC
            LIMIT 1
            """,
            (target,),
        ).fetchone()
        action_counts = conn.execute(
            f"""
            SELECT COALESCE(a.act, 'unknown'), COUNT(*)
            FROM (
                SELECT o.action_id
                FROM outcomes AS o
                JOIN actions AS a USING (action_id)
                WHERE {effective_target} = ?
                ORDER BY o.timestamp_ms DESC
                LIMIT ?
            ) AS recent
            JOIN actions AS a USING (action_id)
            GROUP BY a.act
            ORDER BY COUNT(*) DESC, a.act
            """,
            (target, sample_limit),
        ).fetchall()
        warnings = []
        if has_warning_kind:
            warnings = conn.execute(
                f"""
                SELECT COALESCE(warning_kind, 'Unknown'), COUNT(*)
                FROM (
                    SELECT o.warning_kind
                    FROM outcomes AS o
                    JOIN actions AS a USING (action_id)
                    WHERE {effective_target} = ? AND o.warning_kind IS NOT NULL
                    ORDER BY o.timestamp_ms DESC
                    LIMIT ?
                )
                GROUP BY warning_kind
                ORDER BY COUNT(*) DESC, warning_kind
                """,
                (target, sample_limit),
            ).fetchall()
    except (sqlite3.Error, OSError):
        return None, None
    finally:
        if conn is not None:
            conn.close()

    failure_counts = _count_allowed(failures, ALLOWED_ADVISORY_FAILURE_KINDS, "Other")
    warning_counts = _count_allowed(warnings, ALLOWED_ADVISORY_WARNING_KINDS, "Other")
    recent_actions = _count_allowed(action_counts, allowed_acts, "unknown")
    last_verified_action = last_verified[0] if last_verified and last_verified[0] in allowed_acts else None

    advisory = {
        "scope": "active_step_target",
        "target_selector": target,
        "sample_count": int(sample_count),
        "recent_failures": failure_counts,
        "recent_warnings": warning_counts,
        "recent_actions": recent_actions,
        "last_verified_action": last_verified_action,
    }
    canonical = json.dumps(advisory, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    meta = {
        "scope": advisory["scope"],
        "sample_count": advisory["sample_count"],
        "hash": hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16],
    }
    return advisory, meta


def attach_advisory_meta(
    action: dict[str, Any], advisory_meta: dict[str, Any] | None
) -> dict[str, Any]:
    if advisory_meta is None:
        return action
    return {"action": action, "advisory_meta": advisory_meta}


def _count_allowed(
    rows: list[tuple[Any, Any]], allowed: set[str], fallback: str
) -> dict[str, int]:
    counts: dict[str, int] = {}
    for raw_kind, count in rows:
        kind = str(raw_kind)
        if kind not in allowed:
            kind = fallback
        counts[kind] = counts.get(kind, 0) + int(count)
    return counts


def _safe_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default
