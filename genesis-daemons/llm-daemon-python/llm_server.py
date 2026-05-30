from __future__ import annotations

import os
import socket
from typing import Any, Callable

from daemon_transport import ClientThreadLimiter


ClientHandler = Callable[[socket.socket, Any | None], None]


def serve_unix_socket(
    socket_path: str,
    model: Any | None,
    client_threads: ClientThreadLimiter,
    handle_client: ClientHandler,
) -> None:
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    server.listen()
    print(f"[llm-daemon] listening on {socket_path}")

    while True:
        conn, _ = server.accept()
        client_threads.spawn(handle_client, conn, model)
