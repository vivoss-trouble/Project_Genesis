#!/usr/bin/env python3
"""
Genesis real LLM daemon skeleton.

Protocol:
  - listens on the genesis-brain local service socket
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
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from daemon_transport import (
    ClientThreadLimiter,
    SERVICE_BRAIN,
    local_service_socket_path,
    parse_float_env,
    parse_int_env,
    read_line,
)
from llm_actions import (
    ActionPolicy,
    purify_action,
)
from llm_advisory import attach_advisory_meta, read_memory_advisory
from llm_fallback import dynamic_target_ids, fallback_action
from llm_protocol import encode_brain_response, parse_brain_request
from llm_server import serve_unix_socket
from llm_selftest import run_selftest
from llm_validation_models import (
    DynamicAdvisoryValidationModel,
    MemoryGuidedValidationModel,
)


SOCKET_PATH = os.environ.get("GENESIS_BRAIN_SOCKET", local_service_socket_path(SERVICE_BRAIN))
ALLOWED_CLICK_TARGETS = set(
    item.strip()
    for item in os.environ.get("GENESIS_ALLOWED_CLICK_TARGETS", "#heal-btn").split(",")
    if item.strip()
)
ALLOWED_WAIT_SELECTORS = set(
    item.strip()
    for item in os.environ.get(
        "GENESIS_ALLOWED_WAIT_SELECTORS",
        os.environ.get("GENESIS_ALLOWED_CLICK_TARGETS", "#heal-btn"),
    ).split(",")
    if item.strip()
)
ALLOWED_ACTS = {
    "noop",
    "click",
    "type",
    "key",
    "wait",
    "aim_dynamic",
    "click_point",
    "assert_ui_state",
}
MAX_REASON_LEN = 240
MAX_TEXT_LEN = 500
MAX_WAIT_MS = 2_000
MAX_PLAN_GOAL_LEN = 300
MAX_PLAN_INTENT_LEN = 240
MAX_PLAN_STEPS = 8
COORDINATE_ABS_LIMIT = 1_000_000
TARGET_ID_MAX_LEN = 64
CLIENT_THREADS = ClientThreadLimiter("llm-daemon", connection_arg_index=0)
ACTION_POLICY = ActionPolicy(
    allowed_click_targets=ALLOWED_CLICK_TARGETS,
    allowed_wait_selectors=ALLOWED_WAIT_SELECTORS,
    allowed_acts=ALLOWED_ACTS,
    max_reason_len=MAX_REASON_LEN,
    max_text_len=MAX_TEXT_LEN,
    max_wait_ms=MAX_WAIT_MS,
    max_plan_goal_len=MAX_PLAN_GOAL_LEN,
    max_plan_intent_len=MAX_PLAN_INTENT_LEN,
    max_plan_steps=MAX_PLAN_STEPS,
    coordinate_abs_limit=COORDINATE_ABS_LIMIT,
    target_id_max_len=TARGET_ID_MAX_LEN,
)


def main() -> None:
    if os.environ.get("GENESIS_DAEMON_SELFTEST") == "1":
        run_selftest(
            ACTION_POLICY,
            ALLOWED_CLICK_TARGETS,
            ALLOWED_WAIT_SELECTORS,
            ALLOWED_ACTS,
            context_rules,
            infer_action,
            lambda: MemoryGuidedValidationModel(ALLOWED_CLICK_TARGETS),
        )
        return

    model = load_model()
    serve_unix_socket(SOCKET_PATH, model, CLIENT_THREADS, handle_client)


def load_model() -> Any | None:
    if os.environ.get("GENESIS_TEST_DYNAMIC_ADVISORY_MODEL") == "1":
        print("[llm-daemon] using validation-only dynamic-advisory model")
        return DynamicAdvisoryValidationModel(ACTION_POLICY)

    if os.environ.get("GENESIS_TEST_MEMORY_GUIDED_MODEL") == "1":
        print("[llm-daemon] using validation-only memory-guided model")
        return MemoryGuidedValidationModel(ALLOWED_CLICK_TARGETS)

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
        n_ctx=parse_int_env("GENESIS_N_CTX", 4096, 1),
        n_gpu_layers=parse_int_env("GENESIS_N_GPU_LAYERS", -1, -1),
        n_threads=parse_int_env("GENESIS_N_THREADS", 8, 1),
        verbose=False,
    )


def handle_client(conn: socket.socket, model: Any | None) -> None:
    with conn:
        try:
            line = read_line(conn)
            if not line:
                return
            envelope = parse_brain_request(line)
        except Exception as exc:
            write_response(conn, "unknown", "error", f"invalid request: {exc}")
            return

        request = envelope.request
        payload = envelope.payload
        task_id = envelope.task_id
        print(f"[llm-daemon] task={task_id} tick={request.get('tick_id')}")
        time.sleep(parse_float_env("GENESIS_LLM_LATENCY_SEC", 0.2, 0.0))
        advisory, advisory_meta = read_memory_advisory(
            payload,
            ALLOWED_CLICK_TARGETS,
            ALLOWED_WAIT_SELECTORS,
            ALLOWED_ACTS,
        )

        if model is None:
            action = fallback_action(request, payload, ACTION_POLICY)
        else:
            action = infer_action(model, request, payload, advisory)

        decision = attach_advisory_meta(action, advisory_meta)
        write_response(conn, task_id, "ok", json.dumps(decision, ensure_ascii=False))


def infer_action(
    model: Any,
    request: dict[str, Any],
    payload: dict[str, Any],
    advisory: dict[str, Any] | None = None,
) -> dict[str, Any]:
    advisory_panel = (
        f"Historical Advisory JSON: {json.dumps(advisory, ensure_ascii=False)}\n"
        if advisory is not None
        else ""
    )
    prompt = (
        f"{system_prompt()}\n"
        f"Current tick: {request.get('tick_id')}\n"
        f"System state JSON: {json.dumps(payload, ensure_ascii=False)}\n"
        f"{context_rules(payload)}"
        f"{advisory_panel}"
        "Action JSON:"
    )
    result = model(prompt, max_tokens=96, temperature=0.0, stop=["\n"])
    text = result["choices"][0]["text"].strip()
    action, error = purify_action(text, request, payload, ACTION_POLICY)
    if action is not None:
        return action

    print(f"[llm-daemon] purifier fallback: {error}; raw={text!r}")
    return fallback_action(
        request,
        payload,
        ACTION_POLICY,
        f"fallback after invalid model output: {error}",
    )


def system_prompt() -> str:
    allowed_targets = ", ".join(sorted(ALLOWED_CLICK_TARGETS)) or "<none>"
    wait_selectors = ", ".join(sorted(ALLOWED_WAIT_SELECTORS)) or "<none>"
    return (
        "You are the decision center of a local control system. "
        "Return only valid JSON matching one of these forms: "
        '{"tick":1,"act":"click","target":"#selector","reason":"specific reason"} '
        'or {"tick":1,"act":"noop","reason":"state stable"} '
        'or {"tick":1,"act":"wait","ms":1000,"expected_state":'
        '{"type":"element_visible","selector":"#selector"},"reason":"wait for element"}. '
        'For dynamic_state active steps, you MUST return {"tick":1,"act":"aim_dynamic",'
        '"target_id":"heal","reason":"target is the tactical objective"}. '
        "Do not return click_point for dynamic_state active steps; click_point is "
        "reserved for the local geometric shooter, which will convert aim_dynamic "
        "to the freshest coordinates and frame_id. "
        "For dynamic_state, target_selector and click_point.target_id must use raw "
        "arena target IDs from dynamic_state.targets[].id, e.g. \"heal\"; never CSS "
        "selectors such as \"#heal\". CSS selector syntax only applies to web/fantasy "
        "click and wait targets. "
        "If the state contains macro_goal, return a read-only plan draft instead: "
        '{"tick":1,"plan_id":"plan-1","goal":"goal text","steps":['
        '{"step_index":0,"intent":"observe current state","target_selector":null}]}. '
        "Plans are for audit only and must not assume execution. "
        "If the state contains active_step, return a normal GenesisAction for that step, "
        "not a plan. Compile active_step.intent against the current state only. "
        "No markdown, no commentary, no extra text. "
        "If the state contains last_outcome with status Failed, the previous action did not "
        "produce the expected physical effect. Use its evidence to re-evaluate the current "
        "state, and do not repeat exactly the same failed act/target. "
        "Historical Advisory, when present, is bounded statistical advice only; current "
        "System state JSON has priority and all actions must still obey allowlists. "
        "For dynamic_state, TargetDrift, StaleFrame, CoordinateOutOfBounds, and StaleButHit "
        "advisory counts are tactical risk signals, never permission to bypass verification. "
        f"Only allowed click targets: {allowed_targets}. "
        f"Wait is verified on the next tick, must use ms <= {MAX_WAIT_MS}, and may only "
        f"observe these selectors: {wait_selectors}."
    )


def context_rules(payload: dict[str, Any]) -> str:
    dynamic_state = payload.get("dynamic_state")
    if not isinstance(dynamic_state, dict):
        return ""

    target_ids = dynamic_target_ids(dynamic_state)
    if not target_ids:
        return ""

    allowed_ids = [target_id for target_id in target_ids if target_id in ALLOWED_CLICK_TARGETS]
    return (
        "Dynamic Target ID Rules:\n"
        "- dynamic_state.targets[].id values are raw arena IDs, not CSS selectors.\n"
        f"- Current raw target IDs: {', '.join(target_ids)}.\n"
        f"- Allowlisted raw IDs for plan target_selector and click_point.target_id: "
        f"{', '.join(allowed_ids) or '<none>'}.\n"
        "- Never prefix dynamic target IDs with '#'; '#heal' is invalid when the raw ID is 'heal'.\n"
    )


def write_response(conn: socket.socket, task_id: str, status: str, action: str) -> None:
    try:
        conn.sendall(encode_brain_response(task_id, status, action))
    except (BrokenPipeError, ConnectionResetError, OSError) as exc:
        print(f"[llm-daemon] response dropped: client disconnected ({exc})")


if __name__ == "__main__":
    main()
