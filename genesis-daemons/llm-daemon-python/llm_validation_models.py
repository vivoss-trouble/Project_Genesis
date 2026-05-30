from __future__ import annotations

import json
import os
from typing import Any

from llm_actions import ActionPolicy
from llm_fallback import first_dynamic_target_id
from llm_utils import extract_prompt_json, safe_int


class MemoryGuidedValidationModel:
    """Validation-only model stub for deterministic advisory A/B live fire."""

    def __init__(self, allowed_click_targets: set[str]) -> None:
        self._allowed_click_targets = allowed_click_targets

    def __call__(
        self,
        prompt: str,
        max_tokens: int = 96,
        temperature: float = 0.0,
        stop: list[str] | None = None,
    ) -> dict[str, Any]:
        del max_tokens, temperature, stop
        target = (
            sorted(self._allowed_click_targets)[0]
            if self._allowed_click_targets
            else "#heal-btn"
        )
        if '"active_step"' not in prompt:
            result = {
                "tick": 1,
                "plan_id": "plan-memory-guided-validation",
                "goal": "test whether bounded history changes a tactical choice",
                "steps": [
                    {
                        "step_index": 0,
                        "intent": "choose a safe tactical interaction for the allowlisted target",
                        "target_selector": target,
                    }
                ],
            }
        elif "Historical Advisory JSON:" in prompt and '"ReadOnlyMode"' in prompt:
            result = {
                "tick": 1,
                "act": "wait",
                "ms": 1000,
                "expected_state": {
                    "type": "element_visible",
                    "selector": target,
                },
                "reason": "historical click rejection observed; verify visibility without click",
            }
        else:
            result = {
                "tick": 1,
                "act": "click",
                "target": target,
                "reason": "no historical rejection advisory; attempt allowlisted interaction",
            }
        return {"choices": [{"text": json.dumps(result)}]}


class DynamicAdvisoryValidationModel:
    """Validation-only model stub for deterministic dynamic advisory A/B tests."""

    def __init__(self, policy: ActionPolicy) -> None:
        self._policy = policy

    def __call__(
        self,
        prompt: str,
        max_tokens: int = 96,
        temperature: float = 0.0,
        stop: list[str] | None = None,
    ) -> dict[str, Any]:
        del max_tokens, temperature, stop
        state = extract_prompt_json(prompt, "System state JSON: ")
        advisory = extract_prompt_json(prompt, "Historical Advisory JSON: ")
        dynamic_state = state.get("dynamic_state") if isinstance(state, dict) else {}
        active_step = state.get("active_step") if isinstance(state, dict) else None
        target_id = first_dynamic_target_id(dynamic_state, self._policy) or "heal"

        if not isinstance(active_step, dict):
            result = {
                "tick": safe_int(state.get("tick_id") if isinstance(state, dict) else 1, 1),
                "plan_id": "plan-dynamic-advisory-validation",
                "goal": "test whether bounded dynamic history changes a tactical choice",
                "steps": [
                    {
                        "step_index": 0,
                        "intent": "compile a dynamic click point or stand down based on bounded history",
                        "target_selector": target_id,
                    }
                ],
            }
        elif dynamic_advisory_is_hot(advisory):
            result = {
                "tick": safe_int(state.get("tick_id") if isinstance(state, dict) else 1, 1),
                "act": "noop",
                "reason": "dynamic advisory reports repeated drift or stale frames; stand down for replan",
            }
        elif os.environ.get("GENESIS_DYNAMIC_ADVISORY_CONTROL_ACTION") == "click_point":
            result = dynamic_control_click_point(state, target_id)
        else:
            result = {
                "tick": safe_int(state.get("tick_id") if isinstance(state, dict) else 1, 1),
                "act": "aim_dynamic",
                "target_id": target_id,
                "reason": "validation model delegates coordinates to geometric shooter",
            }

        return {"choices": [{"text": json.dumps(result)}]}


def dynamic_advisory_is_hot(advisory: dict[str, Any]) -> bool:
    failures = advisory.get("recent_failures") if isinstance(advisory, dict) else {}
    warnings = advisory.get("recent_warnings") if isinstance(advisory, dict) else {}
    if not isinstance(failures, dict):
        failures = {}
    if not isinstance(warnings, dict):
        warnings = {}
    return (
        safe_int(failures.get("TargetDrift"), 0)
        + safe_int(failures.get("StaleFrame"), 0)
        + safe_int(warnings.get("StaleButHit"), 0)
        >= 3
    )


def dynamic_control_click_point(state: dict[str, Any], target_id: str) -> dict[str, Any]:
    dynamic_state = state.get("dynamic_state")
    if not isinstance(dynamic_state, dict):
        return {
            "tick": safe_int(state.get("tick_id"), 1),
            "act": "noop",
            "reason": "dynamic state missing",
        }
    targets = dynamic_state.get("targets")
    target = None
    if isinstance(targets, list):
        target = next(
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
    if target is None:
        return {
            "tick": safe_int(state.get("tick_id"), 1),
            "act": "noop",
            "reason": f"dynamic target missing: {target_id}",
        }
    return {
        "tick": safe_int(state.get("tick_id"), 1),
        "act": "click_point",
        "target_id": target_id,
        "x": float(target["x"]) + float(target["w"]) + 20.0,
        "y": float(target["y"]) + float(target["h"]) / 2.0,
        "frame_id": max(safe_int(dynamic_state.get("frame_id"), 0), 0),
        "reason": "validation model attempts risky dynamic click without advisory",
    }
