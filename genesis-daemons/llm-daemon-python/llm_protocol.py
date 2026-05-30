from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class BrainRequestEnvelope:
    task_id: str
    request: dict[str, Any]
    payload: dict[str, Any]


def parse_brain_request(line: str) -> BrainRequestEnvelope:
    request = json.loads(line)
    if not isinstance(request, dict):
        raise ValueError("request must be a JSON object")

    task_id = request.get("task_id")
    if not isinstance(task_id, str) or not task_id.strip():
        raise ValueError("missing task_id")

    payload_value = request.get("payload", "{}")
    payload = json.loads(payload_value) if isinstance(payload_value, str) else payload_value
    if not isinstance(payload, dict):
        raise ValueError("payload must be a JSON object")

    return BrainRequestEnvelope(task_id=task_id, request=request, payload=payload)


def encode_brain_response(task_id: str, status: str, action: str) -> bytes:
    response = {"task_id": task_id, "status": status, "action": action}
    return json.dumps(response, ensure_ascii=False).encode("utf-8") + b"\n"
