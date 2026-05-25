#!/usr/bin/env python3
"""
Project Genesis audit JSONL into a queryable SQLite database.

JSONL remains the append-only source of truth. This script builds a disposable
read model for analysis, dashboards, and release validation.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import tempfile
from pathlib import Path
from typing import Any


DEFAULT_AUDIT = ".genesis-state/audit.jsonl"
DEFAULT_DB = ".genesis-state/audit.sqlite"


SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

CREATE TABLE IF NOT EXISTS audit_records (
    source_path TEXT NOT NULL,
    line_no INTEGER NOT NULL,
    timestamp_ms INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    raw_json TEXT NOT NULL,
    PRIMARY KEY (source_path, line_no)
);

CREATE TABLE IF NOT EXISTS ticks (
    tick_id INTEGER PRIMARY KEY,
    timestamp_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS senses (
    tick_id INTEGER PRIMARY KEY,
    timestamp_ms INTEGER NOT NULL,
    sense_key TEXT,
    health INTEGER,
    web_title TEXT,
    web_mode TEXT,
    last_outcome_action_id TEXT,
    last_outcome_status TEXT,
    state_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS plugin_responses (
    tick_id INTEGER NOT NULL,
    plugin_id TEXT NOT NULL,
    timestamp_ms INTEGER NOT NULL,
    status INTEGER,
    error_code INTEGER,
    latency_ms INTEGER,
    data_hash TEXT,
    data_preview TEXT,
    PRIMARY KEY (tick_id, plugin_id)
);

CREATE TABLE IF NOT EXISTS actions (
    action_id TEXT PRIMARY KEY,
    decoded_tick_id INTEGER,
    source_tick_id INTEGER,
    dispatched_tick_id INTEGER,
    decoded_timestamp_ms INTEGER,
    dispatched_timestamp_ms INTEGER,
    action_json TEXT,
    act TEXT,
    target TEXT,
    reason TEXT
);

CREATE TABLE IF NOT EXISTS plans (
    plan_id TEXT PRIMARY KEY,
    tick_id INTEGER NOT NULL,
    source_tick_id INTEGER,
    timestamp_ms INTEGER NOT NULL,
    goal TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS plan_steps (
    plan_id TEXT NOT NULL,
    step_index INTEGER NOT NULL,
    intent TEXT NOT NULL,
    target_selector TEXT,
    PRIMARY KEY (plan_id, step_index),
    FOREIGN KEY(plan_id) REFERENCES plans(plan_id)
);

CREATE TABLE IF NOT EXISTS plan_events (
    plan_id TEXT NOT NULL,
    tick_id INTEGER NOT NULL,
    timestamp_ms INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    step_index INTEGER,
    from_step INTEGER,
    to_step INTEGER,
    intent TEXT,
    reason TEXT
);

CREATE TABLE IF NOT EXISTS outcomes (
    action_id TEXT PRIMARY KEY,
    tick_id INTEGER NOT NULL,
    source_tick_id INTEGER,
    dispatched_tick_id INTEGER,
    timestamp_ms INTEGER NOT NULL,
    status TEXT NOT NULL,
    reason TEXT,
    failure_kind TEXT,
    warning_kind TEXT,
    policy TEXT,
    target TEXT,
    evidence_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memory_advisories (
    tick_id INTEGER NOT NULL,
    timestamp_ms INTEGER NOT NULL,
    scope TEXT NOT NULL,
    sample_count INTEGER NOT NULL,
    advisory_hash TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS failures (
    tick_id INTEGER,
    timestamp_ms INTEGER NOT NULL,
    component TEXT NOT NULL,
    error TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS replay_snapshots (
    timestamp_ms INTEGER NOT NULL,
    label TEXT NOT NULL,
    path TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_audit_event_type ON audit_records(event_type);
CREATE INDEX IF NOT EXISTS idx_plugin_responses_plugin ON plugin_responses(plugin_id);
CREATE INDEX IF NOT EXISTS idx_actions_act ON actions(act);
CREATE INDEX IF NOT EXISTS idx_plan_steps_target ON plan_steps(target_selector);
CREATE INDEX IF NOT EXISTS idx_plan_events_plan ON plan_events(plan_id);
CREATE INDEX IF NOT EXISTS idx_plan_events_type ON plan_events(event_type);
CREATE INDEX IF NOT EXISTS idx_outcomes_status ON outcomes(status);
CREATE INDEX IF NOT EXISTS idx_outcomes_failure_kind ON outcomes(failure_kind);
CREATE INDEX IF NOT EXISTS idx_memory_advisories_scope ON memory_advisories(scope);
CREATE INDEX IF NOT EXISTS idx_failures_component ON failures(component);
"""


def main() -> None:
    args = parse_args()
    if args.selftest:
        run_selftest()
        return

    audit_path = Path(args.audit)
    db_path = Path(args.db)
    if args.rebuild and db_path.exists():
        db_path.unlink()
    db_path.parent.mkdir(parents=True, exist_ok=True)

    count = project(audit_path, db_path)
    print(f"[audit-sqlite] projected {count} records into {db_path}")
    if args.telemetry_report:
        print_telemetry_report(db_path)
    if args.assert_v46_baseline:
        assert_v46_baseline(db_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Project Genesis audit JSONL into SQLite."
    )
    parser.add_argument("--audit", default=DEFAULT_AUDIT, help="path to audit.jsonl")
    parser.add_argument("--db", default=DEFAULT_DB, help="path to SQLite database")
    parser.add_argument(
        "--rebuild",
        action="store_true",
        help="delete the database before projecting",
    )
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="run a small in-memory projection test",
    )
    parser.add_argument(
        "--telemetry-report",
        action="store_true",
        help="print a live-fire telemetry report after projection",
    )
    parser.add_argument(
        "--assert-v46-baseline",
        action="store_true",
        help="assert the v4.6 cerebellum shooter deterministic baseline",
    )
    return parser.parse_args()


def project(audit_path: Path, db_path: Path) -> int:
    if not audit_path.exists():
        raise SystemExit(f"audit path does not exist: {audit_path}")

    conn = sqlite3.connect(db_path)
    conn.executescript(SCHEMA)
    ensure_schema_compat(conn)

    source_path = str(audit_path)
    count = 0
    with audit_path.open("r", encoding="utf-8") as file:
        for line_no, line in enumerate(file, start=1):
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            timestamp_ms = int(record.get("timestamp_ms") or 0)
            event_type = str(record.get("type") or "")
            payload = record.get("payload") or {}
            payload_json = json.dumps(payload, ensure_ascii=False, sort_keys=True)

            conn.execute(
                """
                INSERT OR REPLACE INTO audit_records
                    (source_path, line_no, timestamp_ms, event_type, payload_json, raw_json)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (source_path, line_no, timestamp_ms, event_type, payload_json, line),
            )
            project_event(conn, timestamp_ms, event_type, payload)
            count += 1

    conn.commit()
    conn.close()
    return count


def ensure_schema_compat(conn: sqlite3.Connection) -> None:
    outcome_columns = {
        row[1] for row in conn.execute("PRAGMA table_info(outcomes)").fetchall()
    }
    if "warning_kind" not in outcome_columns:
        conn.execute("ALTER TABLE outcomes ADD COLUMN warning_kind TEXT")


def project_event(
    conn: sqlite3.Connection, timestamp_ms: int, event_type: str, payload: dict[str, Any]
) -> None:
    if event_type == "TickStarted":
        conn.execute(
            "INSERT OR REPLACE INTO ticks (tick_id, timestamp_ms) VALUES (?, ?)",
            (payload.get("tick_id"), timestamp_ms),
        )
    elif event_type == "SenseCaptured":
        project_sense(conn, timestamp_ms, payload)
    elif event_type == "PluginResponded":
        conn.execute(
            """
            INSERT OR REPLACE INTO plugin_responses
                (tick_id, plugin_id, timestamp_ms, status, error_code, latency_ms, data_hash, data_preview)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                payload.get("tick_id"),
                payload.get("plugin_id"),
                timestamp_ms,
                payload.get("status"),
                payload.get("error_code"),
                payload.get("latency_ms"),
                stringify_optional(payload.get("data_hash")),
                payload.get("data_preview"),
            ),
        )
    elif event_type == "BrainActionDecoded":
        project_brain_action(conn, timestamp_ms, payload)
    elif event_type == "MemoryAdvisoryAttached":
        conn.execute(
            """
            INSERT INTO memory_advisories
                (tick_id, timestamp_ms, scope, sample_count, advisory_hash)
            VALUES (?, ?, ?, ?, ?)
            """,
            (
                payload.get("tick_id"),
                timestamp_ms,
                payload.get("scope"),
                payload.get("sample_count"),
                payload.get("hash"),
            ),
        )
    elif event_type == "PlanDrafted":
        project_plan(conn, timestamp_ms, payload)
    elif event_type in {
        "PlanActivated",
        "StepActivated",
        "PlanAdvanced",
        "PlanAborted",
    }:
        project_plan_event(conn, timestamp_ms, event_type, payload)
    elif event_type == "ActionDispatched":
        conn.execute(
            """
            INSERT INTO actions (action_id, source_tick_id, dispatched_tick_id, dispatched_timestamp_ms)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(action_id) DO UPDATE SET
                source_tick_id=excluded.source_tick_id,
                dispatched_tick_id=excluded.dispatched_tick_id,
                dispatched_timestamp_ms=excluded.dispatched_timestamp_ms
            """,
            (
                payload.get("action_id"),
                payload.get("source_tick_id"),
                payload.get("tick_id"),
                timestamp_ms,
            ),
        )
    elif event_type == "OutcomeObserved":
        project_outcome(conn, timestamp_ms, payload)
    elif event_type == "FailureObserved":
        conn.execute(
            """
            INSERT INTO failures (tick_id, timestamp_ms, component, error)
            VALUES (?, ?, ?, ?)
            """,
            (
                payload.get("tick_id"),
                timestamp_ms,
                payload.get("component"),
                payload.get("error"),
            ),
        )
    elif event_type == "ReplaySnapshot":
        conn.execute(
            """
            INSERT INTO replay_snapshots (timestamp_ms, label, path)
            VALUES (?, ?, ?)
            """,
            (timestamp_ms, payload.get("label"), payload.get("path")),
        )


def project_sense(
    conn: sqlite3.Connection, timestamp_ms: int, payload: dict[str, Any]
) -> None:
    state_json = str(payload.get("state_json") or "{}")
    try:
        state = json.loads(state_json)
    except json.JSONDecodeError:
        state = {}

    fantasy_state = state.get("fantasy_state") if isinstance(state, dict) else None
    web_state = state.get("web_state") if isinstance(state, dict) else None
    last_outcome = state.get("last_outcome") if isinstance(state, dict) else None

    sense_key = None
    if isinstance(fantasy_state, dict):
        sense_key = "fantasy_state"
    elif isinstance(web_state, dict):
        sense_key = "web_state"

    conn.execute(
        """
        INSERT OR REPLACE INTO senses
            (tick_id, timestamp_ms, sense_key, health, web_title, web_mode,
             last_outcome_action_id, last_outcome_status, state_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            payload.get("tick_id"),
            timestamp_ms,
            sense_key,
            fantasy_state.get("health") if isinstance(fantasy_state, dict) else None,
            web_state.get("title") if isinstance(web_state, dict) else None,
            web_state.get("mode") if isinstance(web_state, dict) else None,
            last_outcome.get("action_id") if isinstance(last_outcome, dict) else None,
            last_outcome.get("status") if isinstance(last_outcome, dict) else None,
            state_json,
        ),
    )


def project_brain_action(
    conn: sqlite3.Connection, timestamp_ms: int, payload: dict[str, Any]
) -> None:
    action_json = str(payload.get("action_json") or "{}")
    action = parse_json_obj(action_json)
    conn.execute(
        """
        INSERT INTO actions
            (action_id, decoded_tick_id, source_tick_id, decoded_timestamp_ms,
             action_json, act, target, reason)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(action_id) DO UPDATE SET
            decoded_tick_id=excluded.decoded_tick_id,
            source_tick_id=excluded.source_tick_id,
            decoded_timestamp_ms=excluded.decoded_timestamp_ms,
            action_json=excluded.action_json,
            act=excluded.act,
            target=excluded.target,
            reason=excluded.reason
        """,
        (
            payload.get("action_id"),
            payload.get("tick_id"),
            payload.get("source_tick_id"),
            timestamp_ms,
            action_json,
            action.get("act"),
            action.get("target") or action.get("target_id"),
            action.get("reason"),
        ),
    )


def project_plan(
    conn: sqlite3.Connection, timestamp_ms: int, payload: dict[str, Any]
) -> None:
    plan_id = payload.get("plan_id")
    if not isinstance(plan_id, str) or not plan_id:
        return

    conn.execute(
        """
        INSERT OR REPLACE INTO plans
            (plan_id, tick_id, source_tick_id, timestamp_ms, goal)
        VALUES (?, ?, ?, ?, ?)
        """,
        (
            plan_id,
            payload.get("tick_id"),
            payload.get("source_tick_id"),
            timestamp_ms,
            payload.get("goal"),
        ),
    )
    conn.execute("DELETE FROM plan_steps WHERE plan_id = ?", (plan_id,))

    steps = payload.get("steps") or []
    if not isinstance(steps, list):
        return

    for fallback_index, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        conn.execute(
            """
            INSERT OR REPLACE INTO plan_steps
                (plan_id, step_index, intent, target_selector)
            VALUES (?, ?, ?, ?)
            """,
            (
                plan_id,
                step.get("step_index", fallback_index),
                step.get("intent"),
                step.get("target_selector"),
            ),
        )


def project_plan_event(
    conn: sqlite3.Connection,
    timestamp_ms: int,
    event_type: str,
    payload: dict[str, Any],
) -> None:
    conn.execute(
        """
        INSERT INTO plan_events
            (plan_id, tick_id, timestamp_ms, event_type, step_index,
             from_step, to_step, intent, reason)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            payload.get("plan_id"),
            payload.get("tick_id"),
            timestamp_ms,
            event_type,
            payload.get("step_index"),
            payload.get("from_step"),
            payload.get("to_step"),
            payload.get("intent"),
            payload.get("reason"),
        ),
    )


def project_outcome(
    conn: sqlite3.Connection, timestamp_ms: int, payload: dict[str, Any]
) -> None:
    result = payload.get("result") or {}
    evidence = payload.get("evidence") or {}
    status = result.get("status") if isinstance(result, dict) else None
    detail = result.get("detail") if isinstance(result, dict) else None
    reason = detail.get("reason") if isinstance(detail, dict) else None

    conn.execute(
        """
        INSERT OR REPLACE INTO outcomes
            (action_id, tick_id, source_tick_id, dispatched_tick_id, timestamp_ms,
             status, reason, failure_kind, warning_kind, policy, target, evidence_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            payload.get("action_id"),
            payload.get("tick_id"),
            payload.get("source_tick_id"),
            payload.get("dispatched_tick_id"),
            timestamp_ms,
            status,
            reason,
            evidence.get("failure_kind") if isinstance(evidence, dict) else None,
            evidence.get("warning_kind") if isinstance(evidence, dict) else None,
            evidence.get("policy") if isinstance(evidence, dict) else None,
            evidence.get("target") if isinstance(evidence, dict) else None,
            json.dumps(evidence, ensure_ascii=False, sort_keys=True),
        ),
    )


def parse_json_obj(raw: str) -> dict[str, Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def stringify_optional(value: Any) -> str | None:
    if value is None:
        return None
    return str(value)


def print_telemetry_report(db_path: Path) -> None:
    report = build_telemetry_report(db_path)
    print("[telemetry] Genesis live-fire report")
    print(
        "[telemetry] intents total={total} decoded={decoded} decoder_failures={failures} "
        "json_legal_rate_pct={legal:.2f} fallback_actions={fallback} fallback_rate_pct={fallback_rate:.2f}".format(
            total=report["intent_total"],
            decoded=report["decoded_actions"],
            failures=report["brain_decoder_failures"],
            legal=report["json_legal_rate_pct"],
            fallback=report["fallback_actions"],
            fallback_rate=report["fallback_rate_pct"],
        )
    )
    print_mapping("[telemetry] action_distribution", report["action_distribution"])
    print_mapping("[telemetry] failure_distribution", report["failure_distribution"])
    print_mapping("[telemetry] warning_distribution", report["warning_distribution"])
    print(
        "[telemetry] stale_but_hit lucky_hits={count} avg_frame_delta={avg:.2f}".format(
            count=report["stale_but_hit"]["count"],
            avg=report["stale_but_hit"]["avg_frame_delta"],
        )
    )
    print(
        "[telemetry] advisory count={count} avg_sample_count={avg:.2f}".format(
            count=report["advisory"]["count"],
            avg=report["advisory"]["avg_sample_count"],
        )
    )
    print("[telemetry-json] " + json.dumps(report, ensure_ascii=False, sort_keys=True))


def build_telemetry_report(db_path: Path) -> dict[str, Any]:
    conn = sqlite3.connect(db_path)
    try:
        decoded_actions = scalar(conn, "SELECT COUNT(*) FROM actions WHERE decoded_tick_id IS NOT NULL")
        brain_decoder_failures = scalar(
            conn,
            """
            SELECT COUNT(*)
            FROM failures
            WHERE component = 'BrainActionDecoder'
            """,
        )
        fallback_actions = scalar(
            conn,
            """
            SELECT COUNT(*)
            FROM actions
            WHERE reason LIKE 'fallback after invalid model output:%'
            """,
        )
        intent_total = decoded_actions + brain_decoder_failures
        action_distribution = query_counts(
            conn,
            """
            SELECT COALESCE(act, 'unknown'), COUNT(*)
            FROM actions
            WHERE decoded_tick_id IS NOT NULL
            GROUP BY act
            ORDER BY COUNT(*) DESC, act
            """,
        )
        failure_distribution = query_counts(
            conn,
            """
            SELECT COALESCE(failure_kind, 'Unknown'), COUNT(*)
            FROM outcomes
            WHERE status = 'Failed'
            GROUP BY failure_kind
            ORDER BY COUNT(*) DESC, failure_kind
            """,
        )
        warning_distribution = query_counts(
            conn,
            """
            SELECT COALESCE(warning_kind, 'Unknown'), COUNT(*)
            FROM outcomes
            WHERE warning_kind IS NOT NULL
            GROUP BY warning_kind
            ORDER BY COUNT(*) DESC, warning_kind
            """,
        )
        stale = conn.execute(
            """
            SELECT COUNT(*), COALESCE(AVG(json_extract(evidence_json, '$.frame_delta')), 0)
            FROM outcomes
            WHERE status = 'Verified' AND warning_kind = 'StaleButHit'
            """
        ).fetchone()
        advisory = conn.execute(
            """
            SELECT COUNT(*), COALESCE(AVG(sample_count), 0)
            FROM memory_advisories
            """
        ).fetchone()
    finally:
        conn.close()

    return {
        "intent_total": int(intent_total),
        "decoded_actions": int(decoded_actions),
        "brain_decoder_failures": int(brain_decoder_failures),
        "json_legal_rate_pct": percent(decoded_actions, intent_total),
        "fallback_actions": int(fallback_actions),
        "fallback_rate_pct": percent(fallback_actions, max(decoded_actions, 1)),
        "action_distribution": action_distribution,
        "failure_distribution": failure_distribution,
        "warning_distribution": warning_distribution,
        "stale_but_hit": {
            "count": int(stale[0] or 0),
            "avg_frame_delta": float(stale[1] or 0),
        },
        "advisory": {
            "count": int(advisory[0] or 0),
            "avg_sample_count": float(advisory[1] or 0),
        },
    }


def scalar(conn: sqlite3.Connection, sql: str) -> int:
    row = conn.execute(sql).fetchone()
    return int(row[0] or 0)


def query_counts(conn: sqlite3.Connection, sql: str) -> dict[str, int]:
    return {str(key): int(count) for key, count in conn.execute(sql).fetchall()}


def percent(numerator: int, denominator: int) -> float:
    if denominator <= 0:
        return 100.0
    return round(numerator * 100.0 / denominator, 2)


def print_mapping(label: str, values: dict[str, int]) -> None:
    if not values:
        print(f"{label} <none>")
        return
    rendered = ", ".join(f"{key}={value}" for key, value in values.items())
    print(f"{label} {rendered}")


def assert_v46_baseline(db_path: Path) -> None:
    conn = sqlite3.connect(db_path)
    try:
        click_points = scalar(
            conn,
            """
            SELECT COUNT(*)
            FROM actions
            WHERE act = 'click_point'
            """,
        )
        if click_points <= 0:
            raise SystemExit("[v4.6-assert] expected at least one click_point action")

        non_cerebellum = scalar(
            conn,
            """
            SELECT COUNT(*)
            FROM actions
            WHERE act = 'click_point'
              AND COALESCE(reason, '') NOT LIKE 'cerebellum shooter resolved:%'
            """,
        )
        if non_cerebellum:
            raise SystemExit(
                f"[v4.6-assert] found {non_cerebellum} click_point action(s) not resolved by cerebellum"
            )

        stale_frames = scalar(
            conn,
            """
            SELECT COUNT(*)
            FROM outcomes
            WHERE failure_kind = 'StaleFrame'
            """,
        )
        if stale_frames:
            raise SystemExit(
                f"[v4.6-assert] expected zero StaleFrame outcomes, found {stale_frames}"
            )

        max_frame_delta = scalar(
            conn,
            """
            SELECT COALESCE(MAX(json_extract(evidence_json, '$.frame_delta')), 0)
            FROM outcomes
            WHERE action_id IN (
                SELECT action_id FROM actions WHERE act = 'click_point'
            )
            """,
        )
        if max_frame_delta > 2:
            raise SystemExit(
                f"[v4.6-assert] expected max frame_delta <= 2, found {max_frame_delta}"
            )

        verified = scalar(
            conn,
            """
            SELECT COUNT(*)
            FROM outcomes
            WHERE status = 'Verified'
              AND action_id IN (
                  SELECT action_id FROM actions WHERE act = 'click_point'
              )
            """,
        )
        if verified <= 0:
            raise SystemExit(
                "[v4.6-assert] expected at least one verified cerebellum click_point"
            )

        fallback_actions = scalar(
            conn,
            """
            SELECT COUNT(*)
            FROM actions
            WHERE reason LIKE 'fallback after invalid model output:%'
            """
        )
        if fallback_actions:
            raise SystemExit(
                f"[v4.6-assert] expected zero purifier fallback actions, found {fallback_actions}"
            )
    finally:
        conn.close()

    print(
        "[v4.6-assert] baseline passed: "
        f"click_points={click_points} verified={verified} max_frame_delta={max_frame_delta}"
    )


def run_selftest() -> None:
    records = [
        {
            "timestamp_ms": 1,
            "type": "TickStarted",
            "payload": {"tick_id": 1},
        },
        {
            "timestamp_ms": 2,
            "type": "SenseCaptured",
            "payload": {
                "tick_id": 2,
                "state_json": json.dumps(
                    {
                        "tick_id": 2,
                        "web_state": {
                            "title": "Example Domain",
                            "mode": "http_probe",
                        },
                        "last_outcome": {
                            "status": "Failed",
                            "action_id": "act-1-1",
                        },
                    }
                ),
            },
        },
        {
            "timestamp_ms": 3,
            "type": "MemoryAdvisoryAttached",
            "payload": {
                "tick_id": 1,
                "scope": "active_step_target",
                "sample_count": 3,
                "hash": "abc123",
            },
        },
        {
            "timestamp_ms": 4,
            "type": "BrainActionDecoded",
            "payload": {
                "tick_id": 1,
                "source_tick_id": 1,
                "action_id": "act-1-1",
                "action_json": json.dumps(
                    {"tick": 1, "act": "click", "target": "a", "reason": "test"}
                ),
            },
        },
        {
            "timestamp_ms": 5,
            "type": "ActionDispatched",
            "payload": {
                "tick_id": 1,
                "source_tick_id": 1,
                "action_id": "act-1-1",
            },
        },
        {
            "timestamp_ms": 7,
            "type": "PlanDrafted",
            "payload": {
                "tick_id": 3,
                "source_tick_id": 2,
                "plan_id": "plan-2",
                "goal": "inspect web state",
                "steps": [
                    {
                        "step_index": 0,
                        "intent": "observe web title",
                        "target_selector": None,
                    }
                ],
            },
        },
        {
            "timestamp_ms": 8,
            "type": "PlanActivated",
            "payload": {"tick_id": 3, "plan_id": "plan-2"},
        },
        {
            "timestamp_ms": 9,
            "type": "StepActivated",
            "payload": {
                "tick_id": 3,
                "plan_id": "plan-2",
                "step_index": 0,
                "intent": "observe web title",
            },
        },
        {
            "timestamp_ms": 6,
            "type": "OutcomeObserved",
            "payload": {
                "tick_id": 2,
                "source_tick_id": 1,
                "dispatched_tick_id": 1,
                "action_id": "act-1-1",
                "result": {
                    "status": "Failed",
                    "detail": {"reason": "web_failure:ReadOnlyMode:test"},
                },
                "evidence": {
                    "policy": "web_last_action_matches",
                    "failure_kind": "ReadOnlyMode",
                    "target": "a",
                },
            },
        },
    ]

    with tempfile.TemporaryDirectory() as tmp:
        audit = Path(tmp) / "audit.jsonl"
        db = Path(tmp) / "audit.sqlite"
        with audit.open("w", encoding="utf-8") as file:
            for record in records:
                file.write(json.dumps(record) + "\n")

        count = project(audit, db)
        conn = sqlite3.connect(db)
        outcome = conn.execute(
            "SELECT status, failure_kind FROM outcomes WHERE action_id='act-1-1'"
        ).fetchone()
        sense = conn.execute(
            "SELECT last_outcome_status FROM senses WHERE tick_id=2"
        ).fetchone()
        plan = conn.execute(
            "SELECT goal FROM plans WHERE plan_id='plan-2'"
        ).fetchone()
        step = conn.execute(
            "SELECT intent FROM plan_steps WHERE plan_id='plan-2' AND step_index=0"
        ).fetchone()
        event = conn.execute(
            "SELECT event_type, step_index FROM plan_events WHERE plan_id='plan-2' AND event_type='StepActivated'"
        ).fetchone()
        advisory = conn.execute(
            "SELECT scope, sample_count, advisory_hash FROM memory_advisories WHERE tick_id=1"
        ).fetchone()
        conn.close()

    assert count == len(records)
    assert outcome == ("Failed", "ReadOnlyMode")
    assert sense == ("Failed",)
    assert plan == ("inspect web state",)
    assert step == ("observe web title",)
    assert event == ("StepActivated", 0)
    assert advisory == ("active_step_target", 3, "abc123")
    print("[audit-sqlite] selftest passed")


if __name__ == "__main__":
    main()
