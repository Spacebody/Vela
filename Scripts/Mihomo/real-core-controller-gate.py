#!/usr/bin/python3
"""Exercise the pinned Mihomo Controller using loopback-only resources.

The caller owns the Mihomo process.  This probe creates an in-process HTTP
target so Connections can be tested without reaching the public network.
Only Python's standard library is used.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
import socket
import struct
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Iterable, Optional


class GateError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise GateError(message)


class ControllerClient:
    def __init__(self, port: int, secret: str) -> None:
        self.port = port
        self.secret = secret
        self.base_url = f"http://127.0.0.1:{port}"
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(
        self,
        path: str,
        *,
        method: str = "GET",
        payload: Optional[Any] = None,
        expected_statuses: Iterable[int] = (200,),
        authenticated: bool = True,
    ) -> tuple[int, bytes]:
        headers: dict[str, str] = {}
        if authenticated:
            headers["Authorization"] = f"Bearer {self.secret}"
        body = None
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with self.opener.open(request, timeout=5) as response:
                status = response.status
                data = response.read()
        except urllib.error.HTTPError as error:
            status = error.code
            data = error.read()
        except (OSError, urllib.error.URLError) as error:
            raise GateError(f"Controller request failed for {method} {path}: {error}") from error

        expected = tuple(expected_statuses)
        detail = data[:512].decode("utf-8", errors="replace").replace(self.secret, "<redacted>").strip()
        detail_suffix = f"; response: {detail}" if detail else ""
        require(
            status in expected,
            f"Controller returned HTTP {status} for {method} {path}; expected {expected}{detail_suffix}",
        )
        return status, data

    def json(self, path: str) -> dict[str, Any]:
        _, body = self.request(path)
        try:
            value = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise GateError(f"Controller returned invalid JSON for GET {path}") from error
        require(isinstance(value, dict), f"Controller JSON for GET {path} is not an object")
        return value


class HoldTarget(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self) -> None:
        self.release = threading.Event()
        super().__init__(("127.0.0.1", 0), HoldHandler)


class HoldHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/hold":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(64 * 1024 * 1024))
        self.end_headers()
        self.wfile.write(b"Vela")
        self.wfile.flush()
        server = self.server
        require(isinstance(server, HoldTarget), "Unexpected loopback server type")
        server.release.wait(timeout=30)

    def log_message(self, _format: str, *args: object) -> None:
        del args


def wait_until(description: str, predicate: Any, timeout: float = 8.0) -> Any:
    deadline = time.monotonic() + timeout
    last_error: Optional[BaseException] = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (GateError, OSError, urllib.error.URLError) as error:
            last_error = error
        time.sleep(0.05)
    suffix = f": {last_error}" if last_error is not None else ""
    raise GateError(f"Timed out waiting for {description}{suffix}")


def start_held_proxy_request(mixed_port: int, target_port: int) -> socket.socket:
    connection = socket.create_connection(("127.0.0.1", mixed_port), timeout=5)
    request = (
        f"GET http://127.0.0.1:{target_port}/hold HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{target_port}\r\n"
        "Connection: keep-alive\r\n"
        "\r\n"
    ).encode("ascii")
    connection.sendall(request)
    response = bytearray()
    while b"\r\n\r\n" not in response:
        chunk = connection.recv(4096)
        require(chunk != b"", "Loopback proxy connection closed before response headers")
        response.extend(chunk)
        require(len(response) <= 64 * 1024, "Loopback proxy response headers were oversized")
    status_line = bytes(response).split(b"\r\n", 1)[0]
    require(b" 200 " in status_line, f"Loopback proxy target returned {status_line!r}")
    return connection


def connection_entries(client: ControllerClient) -> list[dict[str, Any]]:
    value = client.json("/connections").get("connections", [])
    if value is None:
        value = []
    require(isinstance(value, list), "GET /connections did not return a connections array")
    return [entry for entry in value if isinstance(entry, dict)]


def target_connection(client: ControllerClient, target_port: int) -> Optional[dict[str, Any]]:
    expected_port = str(target_port)
    for entry in connection_entries(client):
        metadata = entry.get("metadata", {})
        if isinstance(metadata, dict) and str(metadata.get("destinationPort", "")) == expected_port:
            return entry
    return None


def receive_exact(connection: socket.socket, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        chunk = connection.recv(count - len(chunks))
        require(chunk != b"", "WebSocket closed during the first frame")
        chunks.extend(chunk)
    return bytes(chunks)


def receive_websocket_frame(connection: socket.socket) -> tuple[int, bytes]:
    first, second = receive_exact(connection, 2)
    opcode = first & 0x0F
    require(first & 0x80 != 0, "Fragmented first WebSocket frame is unsupported")
    require(second & 0x80 == 0, "Mihomo unexpectedly masked a server WebSocket frame")
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", receive_exact(connection, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", receive_exact(connection, 8))[0]
    require(length <= 32 * 1024 * 1024, "First WebSocket snapshot exceeded 32 MiB")
    return opcode, receive_exact(connection, length)


def websocket_first_snapshot(client: ControllerClient) -> dict[str, Any]:
    connection = socket.create_connection(("127.0.0.1", client.port), timeout=5)
    connection.settimeout(5)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        "GET /connections?interval=1000 HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{client.port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Authorization: Bearer {client.secret}\r\n"
        "\r\n"
    ).encode("ascii")
    try:
        connection.sendall(request)
        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = connection.recv(4096)
            require(chunk != b"", "WebSocket closed before the upgrade response completed")
            response.extend(chunk)
            require(len(response) <= 64 * 1024, "WebSocket upgrade headers were oversized")
        header_bytes, buffered = bytes(response).split(b"\r\n\r\n", 1)
        header_lines = header_bytes.decode("iso-8859-1").split("\r\n")
        require(header_lines[0].startswith("HTTP/1.1 101 "), "WebSocket upgrade was not accepted")
        headers = {
            name.strip().lower(): value.strip()
            for name, value in (line.split(":", 1) for line in header_lines[1:] if ":" in line)
        }
        expected_accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        require(headers.get("sec-websocket-accept") == expected_accept, "Invalid WebSocket accept key")

        # The first frame may already be buffered behind the upgrade response.
        if buffered:
            original_recv = connection.recv

            class BufferedReader:
                def __init__(self, initial: bytes) -> None:
                    self.initial = bytearray(initial)

                def recv(self, count: int) -> bytes:
                    if self.initial:
                        value = bytes(self.initial[:count])
                        del self.initial[:count]
                        return value
                    return original_recv(count)

            reader: Any = BufferedReader(buffered)
        else:
            reader = connection

        opcode, payload = receive_websocket_frame(reader)
        require(opcode == 1, f"Expected a text WebSocket frame, got opcode {opcode}")
        try:
            snapshot = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise GateError("First WebSocket frame was not a JSON snapshot") from error
        require(isinstance(snapshot, dict), "First WebSocket JSON value was not an object")
        require(isinstance(snapshot.get("connections"), list), "WebSocket snapshot lacks connections")
        for total_key in ("downloadTotal", "uploadTotal"):
            require(total_key in snapshot, f"WebSocket snapshot lacks {total_key}")
        return snapshot
    finally:
        connection.close()


def exercise(args: argparse.Namespace) -> str:
    secret = Path(args.secret_file).read_text(encoding="utf-8").strip()
    require(secret != "", "Controller secret file was empty")
    client = ControllerClient(args.controller_port, secret)

    version = wait_until("Controller readiness", lambda: client.json("/version"))
    reported_version = str(version.get("version", ""))
    require(reported_version.lstrip("v") == "1.19.29", f"Unexpected Controller version {reported_version!r}")
    client.request("/version", authenticated=False, expected_statuses=(401,))

    configs = client.json("/configs")
    require(configs.get("mixed-port") == args.mixed_port, "GET /configs reported the wrong mixed port")
    require(str(configs.get("mode", "")).lower() == "rule", "Initial Controller mode was not rule")

    proxy_providers = client.json("/providers/proxies").get("providers", {})
    rule_providers = client.json("/providers/rules").get("providers", {})
    require(isinstance(proxy_providers, dict), "GET /providers/proxies returned invalid providers")
    require(isinstance(rule_providers, dict), "GET /providers/rules returned invalid providers")
    require(args.proxy_provider in proxy_providers, "GET /providers/proxies omitted the local provider")
    require(args.rule_provider in rule_providers, "GET /providers/rules omitted the local provider")

    rules_before = client.json("/rules").get("rules", [])
    require(isinstance(rules_before, list) and len(rules_before) >= 3, "GET /rules returned too few rules")
    toggle_candidates = [
        rule
        for rule in rules_before
        if isinstance(rule, dict) and isinstance(rule.get("index"), int) and isinstance(rule.get("extra"), dict)
    ]
    if toggle_candidates:
        toggle_index = toggle_candidates[0]["index"]
        client.request("/rules/disable", method="PATCH", payload={str(toggle_index): True}, expected_statuses=(204,))
        toggled_rules = client.json("/rules").get("rules", [])
        toggled = next(
            (rule for rule in toggled_rules if isinstance(rule, dict) and rule.get("index") == toggle_index),
            None,
        )
        require(
            isinstance(toggled, dict)
            and isinstance(toggled.get("extra"), dict)
            and toggled["extra"].get("disabled") is True,
            "PATCH /rules/disable did not disable the selected rule",
        )
        client.request("/rules/disable", method="PATCH", payload={str(toggle_index): False}, expected_statuses=(204,))
        restored_rules = client.json("/rules").get("rules", [])
        restored = next(
            (rule for rule in restored_rules if isinstance(rule, dict) and rule.get("index") == toggle_index),
            None,
        )
        require(
            isinstance(restored, dict)
            and isinstance(restored.get("extra"), dict)
            and restored["extra"].get("disabled") is False,
            "PATCH /rules/disable did not restore the selected rule",
        )
        rule_disable_result = f"passed (index {toggle_index}, restored)"
    else:
        rule_disable_result = "skipped (running configuration exposed no rule runtime stats)"

    hot_config = Path(args.hot_config)
    require(hot_config.is_absolute(), "Hot-reload configuration path was not absolute")
    client.request(
        "/configs?force=false",
        method="PUT",
        # Preserve /var rather than resolving it to /private/var. Mihomo's
        # safe-path comparison intentionally uses the spelling of its home.
        payload={"path": str(hot_config)},
        expected_statuses=(204,),
    )
    wait_until("Controller recovery after hot reload", lambda: client.json("/version"))

    def hot_rules_loaded() -> bool:
        rules = client.json("/rules").get("rules", [])
        payloads = {rule.get("payload") for rule in rules if isinstance(rule, dict)}
        return args.hot_rule in payloads and args.initial_rule not in payloads

    wait_until("hot-reloaded rule generation", hot_rules_loaded)
    reloaded_proxy_providers = client.json("/providers/proxies").get("providers", {})
    reloaded_rule_providers = client.json("/providers/rules").get("providers", {})
    require(isinstance(reloaded_proxy_providers, dict), "Reloaded proxy providers were invalid")
    require(isinstance(reloaded_rule_providers, dict), "Reloaded rule providers were invalid")
    require(args.proxy_provider in reloaded_proxy_providers, "Proxy provider disappeared after hot reload")
    require(args.rule_provider in reloaded_rule_providers, "Rule provider disappeared after hot reload")

    target = HoldTarget()
    target_thread = threading.Thread(target=target.serve_forever, name="vela-loopback-target", daemon=True)
    target_thread.start()
    target_port = target.server_address[1]
    holders: list[socket.socket] = []
    try:
        first_holder = start_held_proxy_request(args.mixed_port, target_port)
        holders.append(first_holder)
        first_entry = wait_until(
            "the first loopback proxy connection",
            lambda: target_connection(client, target_port),
        )
        require(isinstance(first_entry, dict), "The first connection entry was invalid")
        first_id = first_entry.get("id")
        require(isinstance(first_id, str) and first_id != "", "The first connection had no ID")

        websocket_snapshot = websocket_first_snapshot(client)
        websocket_ids = {
            entry.get("id")
            for entry in websocket_snapshot.get("connections", [])
            if isinstance(entry, dict)
        }
        require(first_id in websocket_ids, "First WebSocket snapshot omitted the active connection")

        encoded_id = urllib.parse.quote(first_id, safe="")
        client.request(f"/connections/{encoded_id}", method="DELETE", expected_statuses=(204,))
        wait_until(
            "single connection closure",
            lambda: all(entry.get("id") != first_id for entry in connection_entries(client)),
        )
        first_holder.close()
        holders.remove(first_holder)

        holders.extend(
            [
                start_held_proxy_request(args.mixed_port, target_port),
                start_held_proxy_request(args.mixed_port, target_port),
            ]
        )
        wait_until(
            "two loopback proxy connections",
            lambda: len(
                [
                    entry
                    for entry in connection_entries(client)
                    if str(entry.get("metadata", {}).get("destinationPort", "")) == str(target_port)
                ]
            )
            >= 2,
        )
        client.request("/connections", method="DELETE", expected_statuses=(204,))
        wait_until("all connection closure", lambda: len(connection_entries(client)) == 0)
    finally:
        for holder in holders:
            holder.close()
        target.release.set()
        target.shutdown()
        target.server_close()
        target_thread.join(timeout=2)

    return rule_disable_result


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controller-port", type=int, required=True)
    parser.add_argument("--mixed-port", type=int, required=True)
    parser.add_argument("--secret-file", required=True)
    parser.add_argument("--hot-config", required=True)
    parser.add_argument("--proxy-provider", required=True)
    parser.add_argument("--rule-provider", required=True)
    parser.add_argument("--initial-rule", required=True)
    parser.add_argument("--hot-rule", required=True)
    args = parser.parse_args()
    for name in ("controller_port", "mixed_port"):
        port = getattr(args, name)
        require(1 <= port <= 65535, f"Invalid {name.replace('_', ' ')}")
    return args


def main() -> int:
    try:
        args = parse_arguments()
        rule_disable_result = exercise(args)
    except (GateError, OSError, ValueError) as error:
        print(f"error: {error}", file=os.sys.stderr)
        return 1

    print("Controller API integration passed:")
    print("  PUT /configs hot reload:     passed")
    print("  GET proxy providers:         passed")
    print("  GET rule providers:          passed")
    print("  GET rules:                   passed")
    print(f"  PATCH rules disable:         {rule_disable_result}")
    print("  WS connections first frame: passed")
    print("  DELETE one connection:      passed")
    print("  DELETE all connections:     passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
