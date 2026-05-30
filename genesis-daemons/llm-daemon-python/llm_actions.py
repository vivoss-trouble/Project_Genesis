from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from llm_utils import (
    clamp_identifier,
    clamp_text,
    extract_first_json_object,
    safe_float,
    safe_int,
)


@dataclass(frozen=True)
class ActionPolicy:
    allowed_click_targets: set[str]
    allowed_wait_selectors: set[str]
    allowed_acts: set[str]
    max_reason_len: int
    max_text_len: int
    max_wait_ms: int
    max_plan_goal_len: int
    max_plan_intent_len: int
    max_plan_steps: int
    coordinate_abs_limit: int
    target_id_max_len: int


def purify_action(
    text: str,
    request: dict[str, Any],
    payload: dict[str, Any],
    policy: ActionPolicy,
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

    if contains_active_step(payload):
        if "steps" in candidate or "plan_id" in candidate:
            return None, "active_step expects action, not plan"
        return normalize_action(candidate, request, payload, policy)

    if contains_macro_goal(payload) or "steps" in candidate or "plan_id" in candidate:
        return normalize_plan(candidate, request, payload, policy)

    return normalize_action(candidate, request, payload, policy)


def contains_macro_goal(payload: dict[str, Any]) -> bool:
    goal = payload.get("macro_goal")
    return isinstance(goal, str) and bool(goal.strip())


def contains_active_step(payload: dict[str, Any]) -> bool:
    return isinstance(payload.get("active_step"), dict)


def normalize_plan(
    candidate: dict[str, Any],
    request: dict[str, Any],
    payload: dict[str, Any],
    policy: ActionPolicy,
) -> tuple[dict[str, Any] | None, str | None]:
    goal = candidate.get("goal")
    if not isinstance(goal, str) or not goal.strip():
        goal = payload.get("macro_goal")
    if not isinstance(goal, str) or not goal.strip():
        return None, "plan requires non-empty goal"

    raw_steps = candidate.get("steps")
    if not isinstance(raw_steps, list) or not raw_steps:
        return None, "plan requires non-empty steps"
    if len(raw_steps) > policy.max_plan_steps:
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
            if target_selector not in policy.allowed_click_targets:
                return None, f"plan target not allowed: {target_selector}"

        normalized_steps.append(
            {
                "step_index": safe_int(raw_step.get("step_index"), fallback_index),
                "intent": clamp_text(intent, policy.max_plan_intent_len),
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
        "goal": clamp_text(goal, policy.max_plan_goal_len),
        "steps": normalized_steps,
    }, None


def normalize_action(
    action: dict[str, Any],
    request: dict[str, Any],
    payload: dict[str, Any],
    policy: ActionPolicy,
) -> tuple[dict[str, Any] | None, str | None]:
    act = action.get("act")
    if not isinstance(act, str):
        return None, "missing string act"
    act = act.strip().lower()
    if act not in policy.allowed_acts:
        return None, f"unsupported act: {act}"

    tick = safe_int(action.get("tick"), safe_int(request.get("tick_id"), 0))
    reason = clamp_text(str(action.get("reason") or ""), policy.max_reason_len)

    if act == "noop":
        return {"tick": tick, "act": "noop", "reason": reason or "model chose noop"}, None

    if act == "click":
        target = action.get("target")
        if not isinstance(target, str):
            return None, "click target must be string"
        target = target.strip()
        if target not in policy.allowed_click_targets:
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
            "text": clamp_text(text, policy.max_text_len),
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
        if ms < 0 or ms > policy.max_wait_ms:
            return None, f"wait ms outside 0..{policy.max_wait_ms}"
        expected_state = action.get("expected_state")
        if not isinstance(expected_state, dict):
            return None, "wait requires expected_state object"
        if expected_state.get("type") != "element_visible":
            return None, "wait expected_state type must be element_visible"
        selector = expected_state.get("selector")
        if not isinstance(selector, str) or not selector.strip():
            return None, "wait expected selector must be string"
        selector = selector.strip()
        if selector not in policy.allowed_wait_selectors:
            return None, f"wait selector not allowed: {selector}"
        normalized = {
            "tick": tick,
            "act": "wait",
            "ms": ms,
            "expected_state": {
                "type": "element_visible",
                "selector": selector,
            },
            "reason": reason or "model chose wait",
        }
        if repeats_failed_action(normalized, failed_last_action(payload)):
            return None, "repeated exact failed action"
        return normalized, None

    if act == "aim_dynamic":
        target_id = action.get("target_id")
        if not isinstance(target_id, str):
            return None, "aim_dynamic target_id must be string"
        target_id = target_id.strip()
        if not target_id or len(target_id) > policy.target_id_max_len:
            return None, f"aim_dynamic target_id outside 1..{policy.target_id_max_len}"
        if target_id not in policy.allowed_click_targets:
            return None, f"aim_dynamic target_id not allowed: {target_id}"
        normalized = {
            "tick": tick,
            "act": "aim_dynamic",
            "target_id": target_id,
            "reason": reason or "model chose aim_dynamic",
        }
        if repeats_failed_action(normalized, failed_last_action(payload)):
            return None, "repeated exact failed action"
        return normalized, None

    if act == "click_point":
        if contains_active_step(payload) and isinstance(payload.get("dynamic_state"), dict):
            return None, "dynamic active_step requires aim_dynamic, not click_point"
        target_id = action.get("target_id")
        if not isinstance(target_id, str):
            return None, "click_point target_id must be string"
        target_id = target_id.strip()
        if not target_id or len(target_id) > policy.target_id_max_len:
            return None, f"click_point target_id outside 1..{policy.target_id_max_len}"
        x = safe_float(action.get("x"))
        y = safe_float(action.get("y"))
        if x is None or y is None:
            return None, "click_point coordinates must be finite numbers"
        if abs(x) > policy.coordinate_abs_limit or abs(y) > policy.coordinate_abs_limit:
            return None, f"click_point coordinate outside abs limit {policy.coordinate_abs_limit}"
        frame_id = action.get("frame_id")
        if isinstance(frame_id, bool) or not isinstance(frame_id, int) or frame_id < 0:
            return None, "click_point frame_id must be a non-negative integer"
        normalized = {
            "tick": tick,
            "act": "click_point",
            "target_id": target_id,
            "x": x,
            "y": y,
            "frame_id": frame_id,
            "reason": reason or "model chose click_point",
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
            "expected": clamp_text(expected, policy.max_text_len),
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
        return action.get("ms") == failed.get("ms") and action.get(
            "expected_state"
        ) == failed.get("expected_state")
    if act == "click_point":
        return (
            action.get("target_id") == failed.get("target_id")
            and action.get("x") == failed.get("x")
            and action.get("y") == failed.get("y")
            and action.get("frame_id") == failed.get("frame_id")
        )
    return act == "noop"


def noop_after_failed_repeat(
    request: dict[str, Any],
    failed: dict[str, Any] | None,
    policy: ActionPolicy,
) -> dict[str, Any]:
    return {
        "tick": safe_int(request.get("tick_id"), 0),
        "act": "noop",
        "reason": clamp_text(
            f"previous identical action failed; refusing repeat: {failed}",
            policy.max_reason_len,
        ),
    }
