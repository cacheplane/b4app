#!/usr/bin/env python3
"""Owned local HTTP/SSE and RFC 6455 test peer; never a provider integration.

Credentials are synthetic test values sent in HTTP headers. The fixture records
only their equality to the expected synthetic value, never the values themselves.
"""
import base64
import copy
import hashlib
import json
import os
import struct
import threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer

corpus = json.loads((Path(__file__).parent / "agent-protocol/agent-protocol.fixtures.json").read_text())
fixtures = {entry["name"]: entry["value"] for entry in corpus["upstream"] + corpus["b4"]}


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests = []
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def respond(self, status, value, headers=None):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def handle_request(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length)) if length else None
        record = {
            "method": self.command, "path": self.path, "body": body,
            "bearer": self.headers.get("Authorization") == "Bearer Basic synthetic-only",
            "basic": self.headers.get("Authorization") == "Basic synthetic-only",
            "apiKey": self.headers.get("x-api-key") == "synthetic-only",
            "hasAuthorization": "Authorization" in self.headers,
            "hasCookie": "Cookie" in self.headers,
            "upgrade": self.headers.get("Upgrade", "").lower() == "websocket",
        }
        if self.path == "/records":
            with self.lock:
                self.respond(200, list(self.requests))
            return
        with self.lock:
            self.requests.append(record)
        if "/redirect/" in self.path:
            self.respond(307, {"code": "redirect"}, {"Location": "/other/agents/search"})
        elif "/http-error/" in self.path:
            self.respond(401, {"code": "auth_required", "message": "synthetic-only"})
        elif self.path.endswith("/agents/search"):
            self.respond(200, [{"agent_id": "route/child#agent", "name": "Test", "capabilities": {}}], {"Set-Cookie": "session=synthetic-only; Path=/"})
        elif "/agents/" in self.path:
            if self.path.endswith("/schemas"):
                self.respond(200, {"agent_id": "route/child#agent", "input_schema": {}, "output_schema": {}, "state_schema": {}, "config_schema": {}})
            else:
                self.respond(200, {"agent_id": "route/child#agent", "name": "Test", "capabilities": {}})
        elif self.path.endswith("/commands"):
            namespace = body.get("params", {}).get("namespace", [])
            if len(namespace) == 2 and namespace[0] == "diagnostic":
                self.respond(200, {"type": "error", "id": body["id"], "error": "invalid_argument", "message": "synthetic-only", "meta": {"b4": {"v": 1, "code": namespace[1]}}})
            elif namespace == ["reject"]:
                response = {"type": "error", "id": body["id"], "error": "permission_denied", "message": "synthetic-only"}
                if "/generic-extension/" in self.path:
                    response["meta"] = {"b4": {"v": 2, "code": "synthetic-only", "echo": "synthetic-only"}}
                self.respond(200, response)
            else:
                correlation = body["id"] + (1 if body.get("params", {}).get("namespace") == ["mismatch"] else 0)
                self.respond(200, self.success(correlation))
        elif self.path.endswith("/stream") and self.command == "GET":
            self.websocket()
        elif self.path.endswith("/stream"):
            event = self.event()
            if "/b4-v1/" in self.path:
                identity = ("id: " + event["eventId"] + "\r\n") if "eventId" in event else ""
            else:
                identity = "id: sse-cursor\r\n"
            stream = (identity + "event: message\r\ndata: " + json.dumps(event, ensure_ascii=False) + "\r\n\r\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(stream)))
            self.end_headers()
            for byte in stream:
                self.wfile.write(bytes([byte]))
                self.wfile.flush()
        else:
            self.respond(200, {"method": self.command, "body": body})

    def websocket(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key or self.headers.get("Sec-WebSocket-Version") != "13":
            self.respond(400, {"code": "bad_upgrade"})
            return
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        try:
            while True:
                first, second = self.rfile.read(2)
                size = second & 127
                if size == 126:
                    size = struct.unpack("!H", self.rfile.read(2))[0]
                elif size == 127:
                    size = struct.unpack("!Q", self.rfile.read(8))[0]
                mask = self.rfile.read(4) if second & 128 else b""
                payload = self.rfile.read(size)
                if mask:
                    payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
                opcode = first & 15
                if opcode == 8:
                    self.frame(8, payload)
                    return
                if opcode == 9:
                    self.frame(10, payload)
                    continue
                command = json.loads(payload)
                with self.lock:
                    self.requests.append({"webSocketCommand": command})
                self.frame(1, json.dumps(self.success(command["id"])).encode())
                self.frame(1, json.dumps(self.event()).encode())
        except (ValueError, OSError, json.JSONDecodeError):
            return

    def frame(self, opcode, payload):
        size = len(payload)
        header = bytes([128 | opcode, size]) if size < 126 else bytes([128 | opcode, 126]) + struct.pack("!H", size)
        self.wfile.write(header + payload)
        self.wfile.flush()

    def success(self, correlation):
        response = {"type": "success", "id": correlation, "result": {"values": {}}}
        if "/generic-extension/" in self.path:
            response["meta"] = {"appliedThroughSeq": 42, "b4": "opaque-unnegotiated"}
        elif "/b4-v1/" in self.path:
            response["meta"] = copy.deepcopy(fixtures["response meta extensible"])
        return response

    def event(self):
        if "/b4-v1/" in self.path:
            fixture = "hydration no invented sequence" if "/snapshot/" in self.path else "extensible event"
            return copy.deepcopy(fixtures[fixture])
        event = {"type": "event", "method": "future.extension", "params": {"data": "🦉"}, "eventId": "opaque-id", "seq": 42}
        if "/generic-extension/" in self.path:
            event["method"] = "values"
            event["params"] = {"namespace": [], "timestamp": 0, "data": {"text": "🦉"}}
            event["b4"] = {"v": 2, "delivery": "snapshot", "extra": "opaque"}
        return event

    do_GET = handle_request
    do_POST = handle_request
    do_PATCH = handle_request
    do_DELETE = handle_request
    do_PUT = handle_request


server = Server(("127.0.0.1", 0), Handler)
if os.environ.get("B4APP_A2_PEER_RECORD_DIR"):
    directory = Path(os.environ["B4APP_A2_PEER_RECORD_DIR"])
    directory.mkdir(parents=True, exist_ok=True)
    record = {"pid": os.getpid(), "pgid": os.getpgid(0), "parentPID": os.getppid(), "nonce": os.environ.get("B4APP_A2_PEER_NONCE"),
              "fixture": str(Path(__file__).resolve()), "port": server.server_port,
              "stopped": False}
    (directory / (str(os.getpid()) + ".json")).write_text(json.dumps(record))
print("listening on http://127.0.0.1:%d" % server.server_port, flush=True)
server.serve_forever()
