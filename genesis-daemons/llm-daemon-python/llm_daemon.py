#!/usr/bin/env python3
"""
Genesis real LLM daemon skeleton.

Protocol:
  - listens on /tmp/genesis_brain.sock
  - receives one newline-delimited JSON BrainRequest
  - returns one newline-delimited JSON BrainResponse

Optional real model path:
  GENESIS_MODEL_PATH=/path/to/model.gguf python3 llm_daemon.py

If llama_cpp is not installed or no model path is provided, the daemon falls
back to deterministic rules so the IPC contract remains testable.
"""

from __future__ import annotations

import json
import os
import socket
import threading
import time
from pathlib import Path
from typing import Any


SOCKET_PATH = "/tmp/genesis_brain.sock"
ALLOWED_CLICK_TARGETS = set(
    item.strip()
    for item in os.environ.get("GENESIS_ALLOWED_CLICK_TARGETS", "#heal-btn").split(",")
    if item.strip()
)
ALLOWED_ACTS = {"noop", "click", "type", "key", "wait", "assert_ui_state"}
MAX_REASON_LEN = 240
MAX_TEXT_LEN = 500
MAX_PLAN_GOAL_LEN = 300
MAX_PLAN_INTENT_LEN = 240
MAX_PLAN_STEPS = 8

def main() -> None:
    if os.environ.get("GENESIS_DAEMON_SELFTEST") == "1":
        run_selftest()
        return

    model = load_model()
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    server.listen()
    print(f"[llm-daemon] listening on {SOCKET_PATH}")

    while True:
        conn, _ = server.accept()
        threading.Thread(target=handle_client, args=(conn, model), daemon=True).start()


def load_model() -> Any | None:
    model_path = os.environ.get("GENESIS_MODEL_PATH")
    if not model_path:
        print("[llm-daemon] GENESIS_MODEL_PATH not set; using deterministic fallback")
        return None

    try:
        from llama_cpp import Llama  # type: ignore
    except Exception as exc:
        print(f"[llm-daemon] llama_cpp unavailable ({exc}); using deterministic fallback")
        return None

    if not Path(model_path).exists():
        print(f"[llm-daemon] model path missing: {model_path}; using deterministic fallback")
        return None

    print(f"[Brain] 正在点燃硅基灵魂: {model_path}")
    return Llama(
        model_path=model_path,
        n_ctx=int(os.environ.get("GENESIS_N_CTX", "4096")),
        n_gpu_layers=int(os.environ.get("GENESIS_N_GPU_LAYERS", "-1")),
        n_threads=int(os.environ.get("GENESIS_N_THREADS", "8")),
        verbose=False,
    )


def handle_client(conn: socket.socket, model: Any | None) -> None:
    with conn:
        line = read_line(conn)
        if not line:
            return

        try:
            request = json.loads(line)
            payload = json.loads(request.get("payload", "{}"))
        except Exception as exc:
            write_response(conn, "unknown", "error", f"invalid request: {exc}")
            return

        print(f"[llm-daemon] task={request.get('task_id')} tick={request.get('tick_id')}")
        time.sleep(float(os.environ.get("GENESIS_LLM_LATENCY_SEC", "0.2")))

        if model is None:
            action = fallback_action(request, payload)
        else:
            action = infer_action(model, request, payload)

        write_response(conn, request["task_id"], "ok", json.dumps(action, ensure_ascii=False))


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


def fallback_action(
    request: dict[str, Any], payload: dict[str, Any], reason: str | None = None
) -> dict[str, Any]:
    macro_goal = payload.get("macro_goal")
    if isinstance(macro_goal, str) and macro_goal.strip():
        return fallback_plan(request, payload, macro_goal, reason)

    failed = failed_last_action(payload)
    state = payload.get("fantasy_state") or {}
    health = safe_int(state.get("health"), 100)
    if health <= 65:
        action = {
            "tick": safe_int(request.get("tick_id"), 0),
            "act": "click",
            "target": "#heal-btn",
            "reason": clamp_text(reason or f"health={health} below threshold", MAX_REASON_LEN),
        }
        if repeats_failed_action(action, failed):
            return noop_after_failed_repeat(request, failed)
        return action

    web_state = payload.get("web_state")
    if isinstance(web_state, dict):
        if os.environ.get("GENESIS_WEB_FALLBACK_CLICK") == "1":
            web_targets = web_state.get("allowed_click_selectors") or []
            if isinstance(web_targets, list):
                for target in web_targets:
                    if isinstance(target, str) and target in ALLOWED_CLICK_TARGETS:
                        action = {
                            "tick": safe_int(request.get("tick_id"), 0),
                            "act": "click",
                            "target": target,
                            "reason": clamp_text(
                                reason or f"web fallback clicked allowlisted target={target}",
                                MAX_REASON_LEN,
                            ),
                        }
                        if repeats_failed_action(action, failed):
                            return noop_after_failed_repeat(request, failed)
                        return action

        return {
            "tick": safe_int(request.get("tick_id"), 0),
            "act": "noop",
            "reason": clamp_text(
                reason
                or f"web arena observed title={str(web_state.get('title') or '')[:80]}",
                MAX_REASON_LEN,
            ),
        }

    return {
        "tick": safe_int(request.get("tick_id"), 0),
        "act": "noop",
        "reason": clamp_text(reason or f"health={health} stable", MAX_REASON_LEN),
    }


def infer_action(model: Any, request: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    prompt = (
        f"{system_prompt()}\n"
        f"Current tick: {request.get('tick_id')}\n"
        f"System state JSON: {json.dumps(payload, ensure_ascii=False)}\n"
        "Action JSON:"
    )
    result = model(prompt, max_tokens=96, temperature=0.0, stop=["\n"])
    text = result["choices"][0]["text"].strip()
    action, error = purify_action(text, request, payload)
    if action is not None:
        return action

    print(f"[llm-daemon] purifier fallback: {error}; raw={text!r}")
    return fallback_action(request, payload, f"fallback after invalid model output: {error}")


def system_prompt() -> str:
    allowed_targets = ", ".join(sorted(ALLOWED_CLICK_TARGETS)) or "<none>"
    return (
        "You are the decision center of a local control system. "
        "Return only valid JSON matching one of these forms: "
        '{"tick":1,"act":"click","target":"#selector","reason":"specific reason"} '
        'or {"tick":1,"act":"noop","reason":"state stable"}. '
        "If the state contains macro_goal, return a read-only plan draft instead: "
        '{"tick":1,"plan_id":"plan-1","goal":"goal text","steps":['
        '{"step_index":0,"intent":"observe current state","target_selector":null}]}. '
        "Plans are for audit only and must not assume execution. "
        "No markdown, no commentary, no extra text. "
        "If the state contains last_outcome with status Failed, the previous action did not "
        "produce the expected physical effect. Use its evidence to re-evaluate the current "
        "state, and do not repeat exactly the same failed act/target. "
        f"Only allowed click targets: {allowed_targets}."
    )


def purify_action(
    text: str, request: dict[str, Any], payload: dict[str, Any]
) -> tuple[dict[str, Any] | None, str | None]:
    extracted = extract_first_json_object(text)
    if extracted is None:
        return None, "no JSON object found"

    try:
        candidate = json.loads(extracted)
    except Exception as exc:
        return None, f"invalid JSON: {exc}"

    if isinstance(candidate, list):
        if not candidate:
            return None, "empty JSON array"
        candidate = candidate[0]

    if not isinstance(candidate, dict):
        return None, "action is not a JSON object"

    if contains_macro_goal(payload) or "steps" in candidate or "plan_id" in candidate:
        return normalize_plan(candidate, request, payload)

    return normalize_action(candidate, request, payload)


def contains_macro_goal(payload: dict[str, Any]) -> bool:
    goal = payload.get("macro_goal")
    return isinstance(goal, str) and bool(goal.strip())


def fallback_plan(
    request: dict[str, Any],
    payload: dict[str, Any],
    goal: str,
    reason: str | None = None,
) -> dict[str, Any]:
    tick = safe_int(request.get("tick_id"), 0)
    goal = clamp_text(goal, MAX_PLAN_GOAL_LEN)
    steps = [
        {
            "step_index": 0,
            "intent": "Observe the current state and preserve v2 Act/Verify boundaries",
            "target_selector": None,
        }
    ]

    fantasy_state = payload.get("fantasy_state")
    web_state = payload.get("web_state")
    if isinstance(fantasy_state, dict):
        health = safe_int(fantasy_state.get("health"), 100)
        heal_target = "#heal-btn" if "#heal-btn" in ALLOWED_CLICK_TARGETS else None
        if health <= 65:
            steps.append(
                {
                    "step_index": 1,
                    "intent": clamp_text(
                        f"Candidate future action: health={health} is below threshold; consider heal control through existing Act pipeline",
                        MAX_PLAN_INTENT_LEN,
                    ),
                    "target_selector": heal_target,
                }
            )
            steps.append(
                {
                    "step_index": 2,
                    "intent": "Verify that a future heal action restores health to at least 90",
                    "target_selector": None,
                }
            )
        else:
            steps.append(
                {
                    "step_index": 1,
                    "intent": clamp_text(
                        f"Health={health} is stable; prefer observation over action",
                        MAX_PLAN_INTENT_LEN,
                    ),
                    "target_selector": None,
                }
            )
    elif isinstance(web_state, dict):
        title = str(web_state.get("title") or "")[:80]
        mode = str(web_state.get("mode") or "unknown")[:40]
        steps.append(
            {
                "step_index": 1,
                "intent": clamp_text(
                    f"Classify web arena mode={mode} title={title!r} before any future action",
                    MAX_PLAN_INTENT_LEN,
                ),
                "target_selector": None,
            }
        )
        for target in web_state.get("allowed_click_selectors") or []:
            if isinstance(target, str) and target in ALLOWED_CLICK_TARGETS:
                steps.append(
                    {
                        "step_index": len(steps),
                        "intent": clamp_text(
                            f"Candidate future selector is allowlisted: {target}",
                            MAX_PLAN_INTENT_LEN,
                        ),
                        "target_selector": target,
                    }
                )
                break
        steps.append(
            {
                "step_index": len(steps),
                "intent": "Verify future Web Arena last_error remains null after any action",
                "target_selector": None,
            }
        )
    else:
        steps.append(
            {
                "step_index": 1,
                "intent": "No recognized arena state; keep plan observational",
                "target_selector": None,
            }
        )

    if reason:
        steps.append(
            {
                "step_index": len(steps),
                "intent": clamp_text(
                    f"Planner fallback reason: {reason}", MAX_PLAN_INTENT_LEN
                ),
                "target_selector": None,
            }
        )

    return {
        "tick": tick,
        "plan_id": f"plan-{tick}",
        "goal": goal,
        "steps": steps[:MAX_PLAN_STEPS],
    }


def normalize_plan(
    candidate: dict[str, Any], request: dict[str, Any], payload: dict[str, Any]
) -> tuple[dict[str, Any] | None, str | None]:
    goal = candidate.get("goal")
    if not isinstance(goal, str) or not goal.strip():
        goal = payload.get("macro_goal")
    if not isinstance(goal, str) or not goal.strip():
        return None, "plan requires non-empty goal"

    raw_steps = candidate.get("steps")
    if not isinstance(raw_steps, list) or not raw_steps:
        return None, "plan requires non-empty steps"
    if len(raw_steps) > MAX_PLAN_STEPS:
        return None, f"plan has too many steps: {len(raw_steps)}"

    normalized_steps: list[dict[str, Any]] = []
    for fallback_index, raw_step in enumerate(raw_steps):
        if not isinstance(raw_step, dict):
            return None, f"step {fallback_index} is not an object"
        intent = raw_step.get("intent")
        if not isinstance(intent, str) or not intent.strip():
            return None, f"step {fallback_index} missing intent"

        target_selector = raw_step.get("target_selector")
        if target_selector is not None:
            if not isinstance(target_selector, str):
                return None, f"step {fallback_index} target_selector must be string or null"
            target_selector = target_selector.strip()
            if target_selector not in ALLOWED_CLICK_TARGETS:
                return None, f"plan target not allowed: {target_selector}"

        normalized_steps.append(
            {
                "step_index": safe_int(raw_step.get("step_index"), fallback_index),
                "intent": clamp_text(intent, MAX_PLAN_INTENT_LEN),
                "target_selector": target_selector,
            }
        )

    tick = safe_int(candidate.get("tick"), safe_int(request.get("tick_id"), 0))
    plan_id = candidate.get("plan_id")
    if not isinstance(plan_id, str) or not plan_id.strip():
        plan_id = f"plan-{tick}"

    return {
        "tick": tick,
        "plan_id": clamp_identifier(plan_id, f"plan-{tick}"),
        "goal": clamp_text(goal, MAX_PLAN_GOAL_LEN),
        "steps": normalized_steps,
    }, None


def extract_first_json_object(text: str) -> str | None:
    start = text.find("{")
    if start < 0:
        return None

    depth = 0
    in_string = False
    escaped = False
    for index in range(start, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue

        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]

    return None


def normalize_action(
    action: dict[str, Any], request: dict[str, Any], payload: dict[str, Any]
) -> tuple[dict[str, Any] | None, str | None]:
    act = action.get("act")
    if not isinstance(act, str):
        return None, "missing string act"
    act = act.strip().lower()
    if act not in ALLOWED_ACTS:
        return None, f"unsupported act: {act}"

    tick = safe_int(action.get("tick"), safe_int(request.get("tick_id"), 0))
    reason = clamp_text(str(action.get("reason") or ""), MAX_REASON_LEN)

    if act == "noop":
        return {"tick": tick, "act": "noop", "reason": reason or "model chose noop"}, None

    if act == "click":
        target = action.get("target")
        if not isinstance(target, str):
            return None, "click target must be string"
        target = target.strip()
        if target not in ALLOWED_CLICK_TARGETS:
            return None, f"click target not allowed: {target}"
        normalized = {
            "tick": tick,
            "act": "click",
            "target": target,
            "reason": reason or "model chose click",
        }
        if repeats_failed_action(normalized, failed_last_action(payload)):
            return None, "repeated exact failed action"
        return normalized, None

    if act == "type":
        target = action.get("target")
        text = action.get("text")
        if not isinstance(target, str) or not isinstance(text, str):
            return None, "type requires string target and text"
        normalized = {
            "tick": tick,
            "act": "type",
            "target": target.strip(),
            "text": clamp_text(text, MAX_TEXT_LEN),
            "reason": reason or "model chose type",
        }
        if repeats_failed_action(normalized, failed_last_action(payload)):
            return None, "repeated exact failed action"
        return normalized, None

    if act == "key":
        code = action.get("code")
        if not isinstance(code, str):
            return None, "key requires string code"
        normalized = {
            "tick": tick,
            "act": "key",
            "code": code.strip(),
            "reason": reason or "model chose key",
        }
        if repeats_failed_action(normalized, failed_last_action(payload)):
            return None, "repeated exact failed action"
        return normalized, None

    if act == "wait":
        ms = safe_int(action.get("ms"), 0)
        if ms < 0 or ms > 10_000:
            return None, "wait ms outside 0..10000"
        normalized = {
            "tick": tick,
            "act": "wait",
            "ms": ms,
            "reason": reason or "model chose wait",
        }
        if repeats_failed_action(normalized, failed_last_action(payload)):
            return None, "repeated exact failed action"
        return normalized, None

    if act == "assert_ui_state":
        target = action.get("target")
        expected = action.get("expected")
        if not isinstance(target, str) or not isinstance(expected, str):
            return None, "assert_ui_state requires string target and expected"
        normalized = {
            "tick": tick,
            "act": "assert_ui_state",
            "target": target.strip(),
            "expected": clamp_text(expected, MAX_TEXT_LEN),
            "reason": reason or "model chose assert_ui_state",
        }
        if repeats_failed_action(normalized, failed_last_action(payload)):
            return None, "repeated exact failed action"
        return normalized, None

    return None, "unreachable action"


def failed_last_action(payload: dict[str, Any]) -> dict[str, Any] | None:
    outcome = payload.get("last_outcome")
    if not isinstance(outcome, dict) or outcome.get("status") != "Failed":
        return None
    action = outcome.get("action")
    return action if isinstance(action, dict) else None


def repeats_failed_action(action: dict[str, Any], failed: dict[str, Any] | None) -> bool:
    if not failed or action.get("act") != failed.get("act"):
        return False
    act = action.get("act")
    if act in {"click", "type", "assert_ui_state"}:
        return action.get("target") == failed.get("target")
    if act == "key":
        return action.get("code") == failed.get("code")
    if act == "wait":
        return action.get("ms") == failed.get("ms")
    return act == "noop"


def noop_after_failed_repeat(
    request: dict[str, Any], failed: dict[str, Any] | None
) -> dict[str, Any]:
    return {
        "tick": safe_int(request.get("tick_id"), 0),
        "act": "noop",
        "reason": clamp_text(
            f"previous identical action failed; refusing repeat: {failed}",
            MAX_REASON_LEN,
        ),
    }


def safe_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except Exception:
        return default


def clamp_text(text: str, max_len: int) -> str:
    text = text.replace("\x00", "").strip()
    if len(text) <= max_len:
        return text
    return text[: max_len - 1] + "…"


def clamp_identifier(value: str, fallback: str) -> str:
    cleaned = "".join(
        char for char in value.strip() if char.isalnum() or char in {"-", "_", "."}
    )
    if not cleaned:
        return fallback
    return cleaned[:80]


def write_response(conn: socket.socket, task_id: str, status: str, action: str) -> None:
    response = {"task_id": task_id, "status": status, "action": action}
    try:
        conn.sendall(json.dumps(response, ensure_ascii=False).encode("utf-8") + b"\n")
    except (BrokenPipeError, ConnectionResetError, OSError) as exc:
        print(f"[llm-daemon] response dropped: client disconnected ({exc})")


def run_selftest() -> None:
    request = {"tick_id": 7}
    payload = {"fantasy_state": {"health": 40}}
    cases = [
        (
            '```json\n{"act":"click","target":"#heal-btn","reason":"low"}\n```',
            "click",
        ),
        ('[{"act":"noop","reason":"stable"}]', "noop"),
        ('{"act":"click","target":"#evil","reason":"bad"}', None),
        ("no json here", None),
        ('{"act":"wait","ms":12000,"reason":"too long"}', None),
    ]

    for raw, expected_act in cases:
        action, error = purify_action(raw, request, payload)
        if expected_act is None:
            assert action is None, (raw, action)
            assert error is not None
        else:
            assert action is not None, (raw, error)
            assert action["act"] == expected_act, action

    fallback = fallback_action(request, payload, "fallback test")
    assert fallback["act"] == "click"

    plan_payload = {"macro_goal": "heal the system without unsafe actions"}
    plan = fallback_action(request, plan_payload)
    assert plan["plan_id"] == "plan-7"
    assert plan["steps"][0]["step_index"] == 0

    fantasy_plan = fallback_action(
        request,
        {
            "macro_goal": "heal the system without unsafe actions",
            "fantasy_state": {"health": 40},
        },
    )
    assert len(fantasy_plan["steps"]) >= 3
    assert fantasy_plan["steps"][1]["target_selector"] == "#heal-btn"

    plan_action, error = purify_action(
        json.dumps(
            {
                "tick": 7,
                "plan_id": "plan-demo",
                "goal": "heal the system",
                "steps": [
                    {
                        "step_index": 0,
                        "intent": "observe health",
                        "target_selector": None,
                    }
                ],
            }
        ),
        request,
        plan_payload,
    )
    assert error is None
    assert plan_action is not None
    assert plan_action["plan_id"] == "plan-demo"

    invalid_plan, error = purify_action(
        json.dumps(
            {
                "tick": 7,
                "plan_id": "plan-bad",
                "goal": "unsafe plan",
                "steps": [
                    {
                        "step_index": 0,
                        "intent": "touch unsafe selector",
                        "target_selector": "#evil",
                    }
                ],
            }
        ),
        request,
        plan_payload,
    )
    assert invalid_plan is None
    assert error == "plan target not allowed: #evil"

    failed_payload = {
        "fantasy_state": {"health": 40},
        "last_outcome": {
            "status": "Failed",
            "action": {"act": "click", "target": "#heal-btn", "reason": "old"},
        },
    }
    repeated = fallback_action(request, failed_payload)
    assert repeated["act"] == "noop"
    action, error = purify_action(
        '{"act":"click","target":"#heal-btn","reason":"repeat"}',
        request,
        failed_payload,
    )
    assert action is None
    assert error == "repeated exact failed action"
    print("[llm-daemon] purifier selftest passed")


if __name__ == "__main__":
    main()
