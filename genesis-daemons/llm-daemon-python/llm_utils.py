from __future__ import annotations

import json
import math
from typing import Any


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


def safe_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except Exception:
        return default


def safe_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if not isinstance(value, (int, float)):
        return None
    result = float(value)
    return result if math.isfinite(result) else None


def extract_prompt_json(prompt: str, marker: str) -> dict[str, Any]:
    start = prompt.find(marker)
    if start < 0:
        return {}
    start += len(marker)
    extracted = extract_first_json_object(prompt[start:])
    if extracted is None:
        return {}
    try:
        value = json.loads(extracted)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def clamp_text(text: str, max_len: int) -> str:
    text = text.replace("\x00", "").strip()
    if len(text) <= max_len:
        return text
    return text[: max_len - 1] + "…"


def clamp_identifier(value: str, fallback: str, max_len: int = 80) -> str:
    cleaned = "".join(
        char for char in value.strip() if char.isalnum() or char in {"-", "_", "."}
    )
    if not cleaned:
        return fallback
    return cleaned[:max_len]
