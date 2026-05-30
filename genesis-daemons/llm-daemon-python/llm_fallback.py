from __future__ import annotations

import os
from typing import Any

from llm_actions import (
    ActionPolicy,
    failed_last_action,
    noop_after_failed_repeat,
    repeats_failed_action,
)
from llm_utils import clamp_text, safe_int


def fallback_action(
    request: dict[str, Any],
    payload: dict[str, Any],
    policy: ActionPolicy,
    reason: str | None = None,
) -> dict[str, Any]:
    active_step = payload.get("active_step")
    if isinstance(active_step, dict):
        return fallback_step_action(request, payload, active_step, policy, reason)

    macro_goal = payload.get("macro_goal")
    if isinstance(macro_goal, str) and macro_goal.strip():
        return fallback_plan(request, payload, macro_goal, policy, reason)

    failed = failed_last_action(payload)
    state = payload.get("fantasy_state") or {}
    health = safe_int(state.get("health"), 100)
    if health <= 65:
        action = {
            "tick": safe_int(request.get("tick_id"), 0),
            "act": "click",
            "target": "#heal-btn",
            "reason": clamp_text(
                reason or f"health={health} below threshold", policy.max_reason_len
            ),
        }
        if repeats_failed_action(action, failed):
            return noop_after_failed_repeat(request, failed, policy)
        return action

    web_state = payload.get("web_state")
    if isinstance(web_state, dict):
        if os.environ.get("GENESIS_WEB_FALLBACK_CLICK") == "1":
            web_targets = web_state.get("allowed_click_selectors") or []
            if isinstance(web_targets, list):
                for target in web_targets:
                    if isinstance(target, str) and target in policy.allowed_click_targets:
                        action = {
                            "tick": safe_int(request.get("tick_id"), 0),
                            "act": "click",
                            "target": target,
                            "reason": clamp_text(
                                reason or f"web fallback clicked allowlisted target={target}",
                                policy.max_reason_len,
                            ),
                        }
                        if repeats_failed_action(action, failed):
                            return noop_after_failed_repeat(request, failed, policy)
                        return action

        return {
            "tick": safe_int(request.get("tick_id"), 0),
            "act": "noop",
            "reason": clamp_text(
                reason
                or f"web arena observed title={str(web_state.get('title') or '')[:80]}",
                policy.max_reason_len,
            ),
        }

    return {
        "tick": safe_int(request.get("tick_id"), 0),
        "act": "noop",
        "reason": clamp_text(reason or f"health={health} stable", policy.max_reason_len),
    }


def fallback_step_action(
    request: dict[str, Any],
    payload: dict[str, Any],
    active_step: dict[str, Any],
    policy: ActionPolicy,
    reason: str | None = None,
) -> dict[str, Any]:
    tick = safe_int(request.get("tick_id"), 0)
    intent = clamp_text(str(active_step.get("intent") or "active step"), policy.max_reason_len)
    target = active_step.get("target_selector")
    if not isinstance(target, str) or target not in policy.allowed_click_targets:
        return {
            "tick": tick,
            "act": "noop",
            "reason": clamp_text(
                reason or f"active_step observation only: {intent}", policy.max_reason_len
            ),
        }

    fantasy_state = payload.get("fantasy_state")
    if target == "#heal-btn" and isinstance(fantasy_state, dict):
        health = safe_int(fantasy_state.get("health"), 100)
        if health <= 65:
            return {
                "tick": tick,
                "act": "click",
                "target": target,
                "reason": clamp_text(
                    f"active_step compiled: {intent}", policy.max_reason_len
                ),
            }

    web_state = payload.get("web_state")
    if isinstance(web_state, dict):
        wait_selector = os.environ.get("GENESIS_WEB_FALLBACK_WAIT_SELECTOR")
        if (
            isinstance(wait_selector, str)
            and wait_selector == target
            and target in policy.allowed_wait_selectors
        ):
            action = {
                "tick": tick,
                "act": "wait",
                "ms": min(
                    max(safe_int(os.environ.get("GENESIS_WEB_FALLBACK_WAIT_MS"), 1000), 0),
                    policy.max_wait_ms,
                ),
                "expected_state": {
                    "type": "element_visible",
                    "selector": target,
                },
                "reason": clamp_text(
                    f"active_step waits for visible selector: {target}",
                    policy.max_reason_len,
                ),
            }
            if repeats_failed_action(action, failed_last_action(payload)):
                return noop_after_failed_repeat(request, failed_last_action(payload), policy)
            return action

    dynamic_state = payload.get("dynamic_state")
    if isinstance(dynamic_state, dict):
        if os.environ.get("GENESIS_DYNAMIC_FALLBACK_ACTION") == "click_point":
            dynamic_action = fallback_dynamic_click_point(
                tick, target, dynamic_state, intent, policy
            )
        else:
            dynamic_action = fallback_dynamic_aim(tick, target, dynamic_state, intent, policy)
        if dynamic_action is not None:
            if repeats_failed_action(dynamic_action, failed_last_action(payload)):
                return noop_after_failed_repeat(request, failed_last_action(payload), policy)
            return dynamic_action

    if isinstance(web_state, dict) and os.environ.get("GENESIS_WEB_FALLBACK_CLICK") == "1":
        allowed = web_state.get("allowed_click_selectors") or []
        if isinstance(allowed, list) and target in allowed:
            action = {
                "tick": tick,
                "act": "click",
                "target": target,
                "reason": clamp_text(
                    f"active_step compiled: {intent}", policy.max_reason_len
                ),
            }
            if repeats_failed_action(action, failed_last_action(payload)):
                return noop_after_failed_repeat(request, failed_last_action(payload), policy)
            return action

    return {
        "tick": tick,
        "act": "noop",
        "reason": clamp_text(
            reason or f"active_step did not justify action: {intent}",
            policy.max_reason_len,
        ),
    }


def fallback_plan(
    request: dict[str, Any],
    payload: dict[str, Any],
    goal: str,
    policy: ActionPolicy,
    reason: str | None = None,
) -> dict[str, Any]:
    tick = safe_int(request.get("tick_id"), 0)
    goal = clamp_text(goal, policy.max_plan_goal_len)
    steps = [
        {
            "step_index": 0,
            "intent": "Observe the current state and preserve v2 Act/Verify boundaries",
            "target_selector": None,
        }
    ]

    fantasy_state = payload.get("fantasy_state")
    web_state = payload.get("web_state")
    dynamic_state = payload.get("dynamic_state")
    if isinstance(fantasy_state, dict):
        health = safe_int(fantasy_state.get("health"), 100)
        heal_target = "#heal-btn" if "#heal-btn" in policy.allowed_click_targets else None
        if health <= 65:
            steps.append(
                {
                    "step_index": 1,
                    "intent": clamp_text(
                        f"Candidate future action: health={health} is below threshold; consider heal control through existing Act pipeline",
                        policy.max_plan_intent_len,
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
                        policy.max_plan_intent_len,
                    ),
                    "target_selector": None,
                }
            )
    elif isinstance(dynamic_state, dict):
        frame_id = safe_int(dynamic_state.get("frame_id"), 0)
        steps.append(
            {
                "step_index": 1,
                "intent": clamp_text(
                    f"Compile a click_point only from the latest committed dynamic frame={frame_id}",
                    policy.max_plan_intent_len,
                ),
                "target_selector": first_dynamic_target_id(dynamic_state, policy),
            }
        )
        steps.append(
            {
                "step_index": len(steps),
                "intent": "Verify the dynamic arena last_verdict and classify any frame or drift failure",
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
                    policy.max_plan_intent_len,
                ),
                "target_selector": None,
            }
        )
        for target in web_state.get("allowed_click_selectors") or []:
            if isinstance(target, str) and target in policy.allowed_click_targets:
                steps.append(
                    {
                        "step_index": len(steps),
                        "intent": clamp_text(
                            f"Candidate future selector is allowlisted: {target}",
                            policy.max_plan_intent_len,
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
                    f"Planner fallback reason: {reason}", policy.max_plan_intent_len
                ),
                "target_selector": None,
            }
        )

    return {
        "tick": tick,
        "plan_id": f"plan-{tick}",
        "goal": goal,
        "steps": steps[: policy.max_plan_steps],
    }


def first_dynamic_target_id(
    dynamic_state: dict[str, Any], policy: ActionPolicy
) -> str | None:
    for target_id in dynamic_target_ids(dynamic_state):
        if target_id in policy.allowed_click_targets:
            return target_id
    return None


def dynamic_target_ids(dynamic_state: dict[str, Any]) -> list[str]:
    targets = dynamic_state.get("targets")
    if not isinstance(targets, list):
        return []
    result: list[str] = []
    seen: set[str] = set()
    for target in targets:
        if not isinstance(target, dict):
            continue
        target_id = target.get("id")
        if not isinstance(target_id, str):
            continue
        target_id = target_id.strip()
        if not target_id or len(target_id) > 64 or target_id in seen:
            continue
        result.append(target_id)
        seen.add(target_id)
    return result


def dynamic_target(dynamic_state: dict[str, Any], target_id: str) -> dict[str, Any] | None:
    targets = dynamic_state.get("targets")
    if not isinstance(targets, list):
        return None
    return next(
        (
            item
            for item in targets
            if isinstance(item, dict)
            and item.get("id") == target_id
            and isinstance(item.get("x"), (int, float))
            and isinstance(item.get("y"), (int, float))
            and isinstance(item.get("w"), (int, float))
            and isinstance(item.get("h"), (int, float))
        ),
        None,
    )


def fallback_dynamic_click_point(
    tick: int,
    target_id: str,
    dynamic_state: dict[str, Any],
    intent: str,
    policy: ActionPolicy,
) -> dict[str, Any] | None:
    target = dynamic_target(dynamic_state, target_id)
    if target is None:
        return None

    frame_id = max(safe_int(dynamic_state.get("frame_id"), 0), 0)
    mode = os.environ.get("GENESIS_DYNAMIC_FALLBACK_MODE", "hit").strip().lower()
    if mode == "stale":
        x = -100.0
        y = -100.0
        frame_id = max(0, frame_id - 99)
    elif mode == "oob":
        x = -100.0
        y = -100.0
    elif mode == "drift":
        x = float(target["x"]) + float(target["w"]) + 20.0
        y = float(target["y"]) + float(target["h"]) / 2.0
    else:
        x = float(target["x"]) + float(target["w"]) / 2.0
        y = float(target["y"]) + float(target["h"]) / 2.0

    return {
        "tick": tick,
        "act": "click_point",
        "target_id": target_id,
        "x": x,
        "y": y,
        "frame_id": frame_id,
        "reason": clamp_text(
            f"dynamic active_step compiled: {intent}", policy.max_reason_len
        ),
    }


def fallback_dynamic_aim(
    tick: int,
    target_id: str,
    dynamic_state: dict[str, Any],
    intent: str,
    policy: ActionPolicy,
) -> dict[str, Any] | None:
    if dynamic_target(dynamic_state, target_id) is None:
        return None
    return {
        "tick": tick,
        "act": "aim_dynamic",
        "target_id": target_id,
        "reason": clamp_text(
            f"dynamic active_step aims: {intent}", policy.max_reason_len
        ),
    }
