from __future__ import annotations

import socket
from typing import Any, Callable

from daemon_transport import ClientThreadLimiter, bind_unix_stream_socket


ClientHandler = Callable[[socket.socket, Any | None], None]


def serve_unix_socket(
    socket_path: str,
    model: Any | None,
    client_threads: ClientThreadLimiter,
    handle_client: ClientHandler,
) -> None:
    server = bind_unix_stream_socket(socket_path)
    print(f"[llm-daemon] listening on {socket_path}")

    while True:
        conn, _ = server.accept()
        client_threads.spawn(handle_client, conn, model)
