from __future__ import annotations

import copy
import threading
from typing import Any


class SnapshotCommitter:
    """Atomic committed-frame reference for v4 dynamic Sense."""

    def __init__(self, initial_snapshot: dict[str, Any]) -> None:
        self._lock = threading.Lock()
        self._snapshot = copy.deepcopy(initial_snapshot)

    def commit(self, snapshot: dict[str, Any]) -> None:
        immutable_snapshot = copy.deepcopy(snapshot)
        with self._lock:
            self._snapshot = immutable_snapshot

    def read(self) -> dict[str, Any]:
        with self._lock:
            return copy.deepcopy(self._snapshot)
