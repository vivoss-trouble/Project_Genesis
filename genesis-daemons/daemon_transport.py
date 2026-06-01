from __future__ import annotations

import json
import io
import os
import socket
import socketserver
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler
from typing import Any, Callable


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
HTTP_REQUEST_TIMEOUT_SEC = parse_float_env("GENESIS_DAEMON_HTTP_TIMEOUT_SEC", 2.0, 0.001)
MAX_STATE_BYTES = parse_int_env("GENESIS_DAEMON_MAX_STATE_BYTES", 1048576, 128)
MAX_CLIENT_THREADS = parse_int_env("GENESIS_DAEMON_MAX_CLIENT_THREADS", 64, 1)

SERVICE_BRAIN = "genesis-brain"
SERVICE_WEB_ACT = "genesis-web-act"
SERVICE_DYNAMIC_ACT = "genesis-dynamic-act"

_LEGACY_UNIX_SOCKET_FILES = {
    SERVICE_BRAIN: "genesis_brain.sock",
    SERVICE_WEB_ACT: "genesis_act.sock",
    SERVICE_DYNAMIC_ACT: "genesis_dynamic_act.sock",
}


def validate_service_name(service_name: str) -> None:
    valid = bool(service_name) and all(
        char.isascii() and (char.isalnum() or char in {"-", "_"})
        for char in service_name
    )
    if not valid:
        raise ValueError("local service names must use ascii letters, digits, '-' or '_'")


def local_service_socket_path(service_name: str, runtime_dir: str | None = None) -> str:
    validate_service_name(service_name)
    try:
        file_name = _LEGACY_UNIX_SOCKET_FILES[service_name]
    except KeyError as exc:
        raise ValueError(f"unknown Genesis local service: {service_name}") from exc
    if runtime_dir is None:
        runtime_dir = tempfile.gettempdir()
    return os.path.join(runtime_dir, file_name)


def bind_unix_stream_socket(socket_path: str) -> socket.socket:
    if not hasattr(socket, "AF_UNIX"):
        raise RuntimeError("Unix domain sockets are not available on this Python platform")
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(socket_path)
        server.listen()
    except Exception:
        server.close()
        raise
    return server


def connect_unix_stream_socket(socket_path: str) -> socket.socket:
    if not hasattr(socket, "AF_UNIX"):
        raise RuntimeError("Unix domain sockets are not available on this Python platform")
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        client.connect(socket_path)
    except Exception:
        client.close()
        raise
    return client


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

    def transport_health(self) -> dict[str, int | float]:
        return {
            "max_client_threads": MAX_CLIENT_THREADS,
            "rejected_clients": self.transport_rejected_clients,
            "thread_start_failures": self.transport_thread_start_failures,
            "http_request_timeout_sec": HTTP_REQUEST_TIMEOUT_SEC,
            "max_state_bytes": MAX_STATE_BYTES,
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


class BoundedTCPServer(BoundedThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True

    def __init__(
        self,
        server_address: tuple[str, int],
        request_handler_class: type[socketserver.BaseRequestHandler],
        *,
        label: str,
    ) -> None:
        self.transport_name = label
        super().__init__(server_address, request_handler_class)

    def get_request(self) -> tuple[socket.socket, Any]:
        request, client_address = super().get_request()
        request.settimeout(HTTP_REQUEST_TIMEOUT_SEC)
        return request, client_address


StateSnapshotProvider = Callable[[], dict[str, Any]]


def _json_state_handler(snapshot_provider: StateSnapshotProvider) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def write_json(self, status_code: int, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            if self.path != "/state":
                self.send_response(404)
                self.send_header("Connection", "close")
                self.end_headers()
                return

            snapshot = dict(snapshot_provider())
            snapshot["transport"] = self.server.transport_health()
            body = json.dumps(snapshot, ensure_ascii=False).encode("utf-8")
            if len(body) > MAX_STATE_BYTES:
                self.write_json(
                    503,
                    {
                        "status": "error",
                        "error_kind": "StateSnapshotTooLarge",
                        "max_state_bytes": MAX_STATE_BYTES,
                        "actual_state_bytes": len(body),
                        "transport": self.server.transport_health(),
                    },
                )
                return

            self.write_json(200, snapshot)

        def log_message(self, format: str, *args: Any) -> None:
            return

    return Handler


def serve_json_state(
    host: str,
    port: int,
    *,
    label: str,
    log_prefix: str,
    snapshot_provider: StateSnapshotProvider,
) -> None:
    handler = _json_state_handler(snapshot_provider)
    with BoundedTCPServer((host, port), handler, label=label) as httpd:
        print(f"[{log_prefix}] state available at http://{host}:{port}/state")
        httpd.serve_forever()


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


def run_selftest() -> None:
    global MAX_STATE_BYTES
    calls = 0

    def snapshot_provider() -> dict[str, Any]:
        nonlocal calls
        calls += 1
        return {"mode": "transport-selftest", "calls": calls}

    class NonClosingBytesIO(io.BytesIO):
        def close(self) -> None:
            self.flush()

    class MemorySocket:
        def __init__(self, raw_request: bytes) -> None:
            self.reader = io.BytesIO(raw_request)
            self.writer = NonClosingBytesIO()

        def makefile(self, mode: str, buffering: int | None = None) -> io.BytesIO:
            if "r" in mode:
                return self.reader
            return self.writer

        def sendall(self, data: bytes) -> None:
            self.writer.write(data)

    class FakeServer:
        def transport_health(self) -> dict[str, int | float]:
            return {
                "max_client_threads": MAX_CLIENT_THREADS,
                "rejected_clients": 0,
                "thread_start_failures": 0,
                "http_request_timeout_sec": HTTP_REQUEST_TIMEOUT_SEC,
                "max_state_bytes": MAX_STATE_BYTES,
            }

    def roundtrip(path: str) -> tuple[int, dict[str, Any] | None, bytes]:
        request = (
            f"GET {path} HTTP/1.1\r\n"
            "Host: 127.0.0.1\r\n"
            "Connection: close\r\n"
            "\r\n"
        ).encode("ascii")
        memory_socket = MemorySocket(request)
        handler(memory_socket, ("127.0.0.1", 0), FakeServer())
        response = memory_socket.writer.getvalue()
        header_bytes, _, body = response.partition(b"\r\n\r\n")
        status_line = header_bytes.splitlines()[0].decode("ascii")
        status_code = int(status_line.split()[1])
        payload = json.loads(body.decode("utf-8")) if body else None
        return status_code, payload, response

    handler = _json_state_handler(snapshot_provider)
    status_code, payload, response = roundtrip("/state")
    assert status_code == 200, response
    assert payload is not None, response
    assert payload["mode"] == "transport-selftest", payload
    assert payload["calls"] == 1, payload
    transport = payload["transport"]
    assert transport["max_client_threads"] == MAX_CLIENT_THREADS, transport
    assert transport["rejected_clients"] == 0, transport
    assert transport["thread_start_failures"] == 0, transport
    assert transport["http_request_timeout_sec"] == HTTP_REQUEST_TIMEOUT_SEC, transport
    assert transport["max_state_bytes"] == MAX_STATE_BYTES, transport

    status_code, payload, response = roundtrip("/missing")
    assert status_code == 404, response
    assert payload is None, payload

    previous_max_state_bytes = MAX_STATE_BYTES
    try:
        MAX_STATE_BYTES = 256

        def oversized_snapshot_provider() -> dict[str, Any]:
            return {"mode": "oversized", "payload": "x" * 512}

        handler = _json_state_handler(oversized_snapshot_provider)
        status_code, payload, response = roundtrip("/state")
        assert status_code == 503, response
        assert payload is not None, response
        assert payload["status"] == "error", payload
        assert payload["error_kind"] == "StateSnapshotTooLarge", payload
        assert payload["max_state_bytes"] == 256, payload
        assert payload["actual_state_bytes"] > payload["max_state_bytes"], payload
        assert payload["transport"]["max_state_bytes"] == 256, payload
    finally:
        MAX_STATE_BYTES = previous_max_state_bytes

    print("[daemon-transport] selftest ok")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        run_selftest()
    else:
        print("usage: daemon_transport.py --selftest", file=sys.stderr)
        raise SystemExit(2)
