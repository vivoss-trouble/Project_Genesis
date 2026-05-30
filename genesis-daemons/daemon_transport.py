from __future__ import annotations

import os
import socket
import socketserver
import sys
import threading
from typing import Any


def parse_int_env(name: str, default: int, minimum: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return max(minimum, int(raw))
    except ValueError:
        print(
            f"[daemon-transport] invalid {name}={raw!r}; using default {default}",
            file=sys.stderr,
        )
        return default


def parse_float_env(name: str, default: float, minimum: float) -> float:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return max(minimum, float(raw))
    except ValueError:
        print(
            f"[daemon-transport] invalid {name}={raw!r}; using default {default}",
            file=sys.stderr,
        )
        return default


MAX_FRAME_BYTES = parse_int_env("GENESIS_DAEMON_MAX_FRAME_BYTES", 65536, 1)
FRAME_READ_TIMEOUT_SEC = parse_float_env("GENESIS_DAEMON_FRAME_TIMEOUT_SEC", 1.0, 0.001)
MAX_CLIENT_THREADS = parse_int_env("GENESIS_DAEMON_MAX_CLIENT_THREADS", 64, 1)


class ClientThreadLimiter:
    def __init__(self, label: str, connection_arg_index: int) -> None:
        self.label = label
        self.connection_arg_index = connection_arg_index
        self.slots = threading.BoundedSemaphore(MAX_CLIENT_THREADS)

    def spawn(self, target: Any, *args: Any) -> bool:
        if not self.slots.acquire(blocking=False):
            conn = args[self.connection_arg_index] if len(args) > self.connection_arg_index else None
            if isinstance(conn, socket.socket):
                conn.close()
            print(f"[{self.label}] client rejected: worker limit reached", file=sys.stderr)
            return False

        def run() -> None:
            try:
                target(*args)
            finally:
                self.slots.release()

        try:
            threading.Thread(target=run, daemon=True).start()
            return True
        except Exception as exc:
            self.slots.release()
            conn = args[self.connection_arg_index] if len(args) > self.connection_arg_index else None
            if isinstance(conn, socket.socket):
                conn.close()
            print(
                f"[{self.label}] client rejected: worker thread start failed: {exc}",
                file=sys.stderr,
            )
            return False


class BoundedThreadingMixIn(socketserver.ThreadingMixIn):
    daemon_threads = True

    def server_activate(self) -> None:
        self._transport_slots = threading.BoundedSemaphore(MAX_CLIENT_THREADS)
        self.transport_rejected_clients = 0
        self.transport_thread_start_failures = 0
        super().server_activate()

    def process_request(self, request: Any, client_address: Any) -> None:
        if not self._transport_slots.acquire(blocking=False):
            self.transport_rejected_clients += 1
            print(
                f"[{self.transport_label()}] client rejected: worker limit reached",
                file=sys.stderr,
            )
            self._reject_request(request)
            return

        def run() -> None:
            try:
                self.process_request_thread(request, client_address)
            finally:
                self._transport_slots.release()

        try:
            threading.Thread(target=run, daemon=self.daemon_threads).start()
        except Exception as exc:
            self._transport_slots.release()
            self.transport_thread_start_failures += 1
            print(
                f"[{self.transport_label()}] client rejected: worker thread start failed: {exc}",
                file=sys.stderr,
            )
            self._reject_request(request)

    def transport_health(self) -> dict[str, int]:
        return {
            "max_client_threads": MAX_CLIENT_THREADS,
            "rejected_clients": self.transport_rejected_clients,
            "thread_start_failures": self.transport_thread_start_failures,
        }

    def transport_label(self) -> str:
        return getattr(self, "transport_name", self.__class__.__name__)

    def _reject_request(self, request: Any) -> None:
        if isinstance(request, socket.socket):
            try:
                request.sendall(
                    b"HTTP/1.1 503 Service Unavailable\r\n"
                    b"Connection: close\r\n"
                    b"Content-Length: 0\r\n\r\n"
                )
            except OSError:
                pass
        self.shutdown_request(request)


def read_line(conn: socket.socket) -> str:
    chunks: list[bytes] = []
    total = 0
    conn.settimeout(FRAME_READ_TIMEOUT_SEC)
    while True:
        chunk = conn.recv(4096)
        if not chunk:
            break
        if b"\n" in chunk:
            before, _, _ = chunk.partition(b"\n")
            total += len(before)
            if total > MAX_FRAME_BYTES:
                raise ValueError(f"frame exceeds {MAX_FRAME_BYTES} bytes")
            chunks.append(before)
            break
        total += len(chunk)
        if total > MAX_FRAME_BYTES:
            raise ValueError(f"frame exceeds {MAX_FRAME_BYTES} bytes")
        chunks.append(chunk)
    return b"".join(chunks).decode("utf-8", errors="replace")
