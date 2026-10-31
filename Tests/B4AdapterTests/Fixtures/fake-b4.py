#!/usr/bin/env python3
"""A stand-in for a B4 Agent Protocol server (`@b4run/cli` 0.15.8, `runtime-fetch-core.ts`) used by
fixture tests. Endpoint shapes follow docs/research/2026-10-30-b4-runtime.md and the M3 design.
Behavior is scripted by the user text: "tool" runs a tool call, "approve" parks on a command
permission, "hang" waits for POST /cancel, "fail" ends with an error, "drop" closes the response
mid-run while the run continues (reattach with GET /runs/stream), "slow" streams for three seconds,
"plan" emits a capability event, "reason" streams reasoning first. Env: FAKE_B4_ROUTE (default
/chat#agent), FAKE_B4_TOKEN (bearer required on middleware paths), FAKE_B4_STATE (JSON file that
persists threads across restarts). Never a substitute for the real server in anything the docs call
live-tested."""
import argparse
import json
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

ROUTE = os.environ.get("FAKE_B4_ROUTE", "/chat#agent")
TOKEN = os.environ.get("FAKE_B4_TOKEN")
STATE_FILE = os.environ.get("FAKE_B4_STATE")
LOCK = threading.RLock()
STATE = {"threads": {}, "counter": 0}
LIVE = {}

MIDDLEWARE_PATHS = ("runs/stream", "resume", "pending_interrupts", "turns", "events")


def log(text):
    sys.stderr.write("fake-b4: %s\n" % text)
    sys.stderr.flush()


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".000Z"


def load_state():
    global STATE
    if STATE_FILE and os.path.exists(STATE_FILE):
        with open(STATE_FILE) as handle:
            STATE = json.load(handle)
        log("loaded %d threads from %s" % (len(STATE["threads"]), STATE_FILE))


def save_state():
    if not STATE_FILE:
        return
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(STATE, handle)
    os.replace(tmp, STATE_FILE)


def lc(cls, kwargs):
    return {"lc": 1, "type": "constructor", "id": ["langchain_core", "messages", cls], "kwargs": kwargs}


def next_id(prefix):
    STATE["counter"] += 1
    return "%s_%d" % (prefix, STATE["counter"])


class Run:
    def __init__(self, thread_id, text, resume=None):
        self.id = next_id("run")
        self.thread_id = thread_id
        self.text = text
        self.resume = resume
        self.frames = []
        self.cond = threading.Condition()
        self.done = False
        self.cancel = threading.Event()
        self.started_at = now()

    def emit(self, event, data):
        with self.cond:
            self.frames.append((event, data))
            if event == "done":
                self.done = True
            self.cond.notify_all()

    def wait_frame(self, index, timeout=20.0):
        with self.cond:
            deadline = time.time() + timeout
            while len(self.frames) <= index and not self.done:
                remaining = deadline - time.time()
                if remaining <= 0:
                    return None
                self.cond.wait(remaining)
            return self.frames[index] if index < len(self.frames) else None

    def wait_cancel(self, seconds):
        return self.cancel.wait(seconds)


def execute(run):
    """Worker: produce frames and update durable state like the real route execution."""
    thread = STATE["threads"][run.thread_id]
    text = run.text
    if run.resume is None:
        turn = {"runId": run.id, "status": "working", "text": "", "steps": [], "approvals": [],
                "startedAt": int(time.time() * 1000), "failed": 0}
        with LOCK:
            thread["turns"].append(turn)
            thread["messages"].append(lc("HumanMessage", {"content": text, "id": next_id("msg")}))
            save_state()
    else:
        turn = thread["turns"][-1]
        turn["status"] = "working"

    def say(chunk):
        run.emit("chunk", chunk)
        turn["text"] += chunk

    def finish(status, output=None, error=None, cancelled=False):
        with LOCK:
            if turn["text"]:
                thread["messages"].append(lc("AIMessage", {"content": turn["text"], "id": next_id("msg")}))
            turn["status"] = status
            turn["endedAt"] = int(time.time() * 1000)
            if error:
                turn["error"] = error
            thread["status"] = "interrupted" if (cancelled or thread["pending"]) else "idle"
            thread["updated_at"] = now()
            save_state()
        if error:
            run.emit("done", {"output": {"error": error}})
        elif cancelled:
            run.emit("done", {"output": {"cancelled": True}})
        else:
            run.emit("done", {"output": output if output is not None else
                              {"messages": [{"role": "assistant", "content": turn["text"]}]}})
        with LOCK:
            if LIVE.get(run.thread_id) is run:
                del LIVE[run.thread_id]

    try:
        if run.resume is not None:
            decision = run.resume
            if decision == "cancelled":
                say("Cancelled by the user.")
            elif decision == "deny":
                say("Denied; stopping here.")
            else:
                say("Approved (%s). Command ran." % decision)
            run.emit("message_end", {"messageId": next_id("m")})
            return finish("done")
        if "fail" in text:
            say("Trying...")
            return finish("failed", error="boom")
        if "hang" in text:
            say("Working...")
            if run.wait_cancel(20):
                return finish("stopped", cancelled=True)
            return finish("done")
        if "slow" in text:
            for i in range(6):
                if run.cancel.is_set():
                    return finish("stopped", cancelled=True)
                say("tick %d. " % (i + 1))
                time.sleep(0.5)
            run.emit("message_end", {"messageId": next_id("m")})
            return finish("done")
        if "drop" in text:
            say("Part one. ")
            run.emit("__drop__", None)
            time.sleep(1.0)
            say("Part two.")
            run.emit("message_end", {"messageId": next_id("m")})
            return finish("done")
        if "approve" in text:
            say("I need to run a command.")
            run.emit("message_end", {"messageId": next_id("m")})
            interrupt_id = next_id("perm")
            grant = "grant-" + uuid.uuid4().hex[:8]
            value = {"interruptId": interrupt_id, "type": "permission-request", "kind": "command",
                     "detail": {"command": "rm -rf tmp", "suggestedPattern": "rm -rf *"},
                     "toolCallId": "call_9", "grant": grant}
            with LOCK:
                thread["pending"].append({"interruptId": interrupt_id, "resumeKey": uuid.uuid4().hex,
                                          "value": value, "grant": grant})
                turn["status"] = "awaiting"
                turn["approvals"].append({"interruptId": interrupt_id, "kind": "command",
                                          "detail": value["detail"], "grant": grant, "offersAlways": True})
            run.emit("interrupt", value)
            with LOCK:
                thread["status"] = "interrupted"
                thread["updated_at"] = now()
                save_state()
            run.emit("done", {"output": None})
            with LOCK:
                if LIVE.get(run.thread_id) is run:
                    del LIVE[run.thread_id]
            return
        if "reason" in text:
            run.emit("reasoning", "Thinking about it. ")
            run.emit("reasoning", "Decided.")
        if "plan" in text:
            run.emit("plan_update", {"todos": [{"content": "step one", "status": "pending"}]})
        if "tool" in text:
            say("Checking.")
            run.emit("message_end", {"messageId": next_id("m")})
            # Live 0.15.8 order: tool_call_args deltas, usage, tool_call, step running, step completed,
            # tool_result whose output is a serialized ToolMessage.
            run.emit("tool_call_args", {"id": "call_1", "name": "search", "delta": "{\"q\":", "messageId": "m_x"})
            run.emit("tool_call_args", {"id": "call_1", "name": "search", "delta": "\"b4\"}", "messageId": "m_x"})
            run.emit("usage", {"provider": "fake", "model": "fake-1",
                               "usage_metadata": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15}})
            run.emit("tool_call", {"id": "call_1", "name": "search", "input": {"q": "b4"}, "messageId": "m_x"})
            started = int(time.time() * 1000)
            run.emit("step", {"v": 1, "kind": "server", "toolCallId": "call_1", "status": "running",
                              "startedAt": started, "icon": "search", "label": "Searching b4"})
            turn["steps"].append({"kind": "tool", "id": "call_1", "name": "search", "status": "done",
                                  "args": "{\"q\":\"b4\"}", "result": "{\"hits\":2}", "startedAt": started})
            time.sleep(0.05)
            run.emit("step", {"v": 1, "kind": "server", "toolCallId": "call_1", "status": "completed",
                              "startedAt": started, "settledAt": int(time.time() * 1000), "icon": "search",
                              "label": "Searched b4"})
            run.emit("tool_result", {"id": "call_1", "name": "search", "output": lc("ToolMessage", {
                "tool_call_id": "call_1", "name": "search", "status": "success", "content": "{\"hits\":2}",
                "additional_kwargs": {"b4_step": {"v": 1, "kind": "server", "status": "completed",
                                                  "label": "Searched b4"}}})})
            with LOCK:
                thread["messages"].append(lc("AIMessage", {"content": "Checking.", "id": next_id("msg"),
                                                           "tool_calls": [{"id": "call_1", "name": "search",
                                                                           "args": {"q": "b4"}}]}))
                thread["messages"].append(lc("ToolMessage", {"content": "{\"hits\":2}", "tool_call_id": "call_1",
                                                             "name": "search", "id": next_id("msg")}))
            turn["text"] = ""
            say("Found 2 hits.")
            run.emit("message_end", {"messageId": next_id("m")})
            return finish("done")
        for chunk in ("Hello ", "from ", "fake B4."):
            say(chunk)
            time.sleep(0.02)
        run.emit("usage", {"provider": "fake", "model": "fake-1",
                           "usage_metadata": {"input_tokens": 3, "output_tokens": 4, "total_tokens": 7}})
        run.emit("message_end", {"messageId": next_id("m")})
        return finish("done")
    except Exception as error:  # pragma: no cover - fixture bug surface
        log("worker error %r" % error)
        finish("failed", error=str(error))


def error_body(message, code=None, kind="request_error"):
    body = {"error": {"kind": kind, "message": message}}
    if code:
        body["error"]["details"] = {"code": code}
    return body


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        log("%s %s" % (self.command, self.path))

    # -- helpers -------------------------------------------------------------

    def send_json(self, status, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        if data:
            self.wfile.write(data)
        self.wfile.flush()

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if not raw.strip():
            return {}
        try:
            return json.loads(raw)
        except ValueError:
            return None

    def authorized(self):
        if not TOKEN:
            return True
        return self.headers.get("Authorization") == "Bearer " + TOKEN

    def gate(self):
        """Middleware runs on execution paths only; returns False after answering 401."""
        if self.authorized():
            return True
        self.send_json(401, error_body("Unauthorized"))
        return False

    def thread_or_404(self, thread_id):
        thread = STATE["threads"].get(thread_id)
        if thread is None:
            self.send_json(404, error_body("Thread not found", "thread_not_found"))
        return thread

    def row(self, thread):
        return {"thread_id": thread["thread_id"], "created_at": thread["created_at"],
                "updated_at": thread["updated_at"], "metadata": thread["metadata"], "status": thread["status"]}

    def start_sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()

    def write_frame(self, event, data):
        self.wfile.write(("event: %s\ndata: %s\n\n" % (event, json.dumps(data))).encode())
        self.wfile.flush()

    def pump(self, run, start_index):
        """Stream frames from start_index until the terminal done. Returns False on a scripted drop."""
        index = start_index
        while True:
            frame = run.wait_frame(index)
            if frame is None:
                if run.done:
                    return True
                self.wfile.write(b": ping\n\n")
                self.wfile.flush()
                continue
            index += 1
            event, data = frame
            if event == "__drop__":
                log("dropping the response for %s" % run.thread_id)
                self.close_connection = True
                try:
                    self.connection.shutdown(2)
                except OSError:
                    pass
                return False
            self.write_frame(event, data)
            if event == "done":
                return True

    # -- routes --------------------------------------------------------------

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/healthz":
            return self.send_json(200, {"status": "ready"})
        if path == "/readyz":
            return self.send_json(200, {"status": "ready", "checks": {"threads": {"status": "ok"}}})
        parts = path.strip("/").split("/")
        if parts[0] != "threads" or len(parts) < 2:
            return self.send_json(404, error_body("Not found"))
        thread_id = parts[1]
        tail = "/".join(parts[2:])
        if tail in MIDDLEWARE_PATHS and not self.gate():
            return None
        with LOCK:
            thread = self.thread_or_404(thread_id)
            if thread is None:
                return None
            if tail == "":
                return self.send_json(200, self.row(thread))
            if tail == "pending_interrupts":
                return self.send_json(200, {"interrupts": [
                    {"interruptId": p["interruptId"], "resumeKey": p["resumeKey"], "value": p["value"],
                     "grant": p["grant"]} for p in thread["pending"]]})
            if tail == "turns":
                # Live 0.15.8 nests the TurnsView object under `turns`.
                return self.send_json(200, {"threadId": thread_id, "status": thread["status"],
                                            "turns": {"threadId": thread_id, "turns": thread["turns"]},
                                            "warnings": [], "truncated": False})
            if tail == "state":
                if not thread["messages"]:
                    return self.send_json(404, error_body("No checkpoint for thread"))
                return self.send_json(200, {"config": {}, "created_at": thread["created_at"],
                                            "metadata": thread["metadata"], "next": [], "parent_config": None,
                                            "values": {"messages": thread["messages"]}})
            if tail == "events":
                return self.send_json(200, {"threadId": thread_id, "status": thread["status"], "events": [],
                                            "warnings": [], "truncated": False})
            if tail != "runs/stream":
                return self.send_json(404, error_body("Not found"))
            run = LIVE.get(thread_id)
        # attach
        self.start_sse()
        if run is not None and not run.done:
            with run.cond:
                index = len(run.frames)
            self.write_frame("state", {"status": "busy", "live": True, "anchor": "cp_1", "input": None,
                                       "resume": run.resume is not None, "run_started_at": run.started_at,
                                       "turn": None, "values": None})
            self.pump(run, index)
            return None
        with LOCK:
            interrupts = [{"interruptId": p["interruptId"], "resumeKey": p["resumeKey"], "value": p["value"],
                           "grant": p["grant"]} for p in thread["pending"]]
            status = thread["status"]
        self.write_frame("state", {"status": status, "live": False, "anchor": None, "input": None,
                                   "resume": False, "run_started_at": None, "turn": None, "values": None,
                                   "interrupts": interrupts})
        self.wfile.write(b"retry: 3000\n\n")
        self.write_frame("done", {"output": None})
        return None

    def do_DELETE(self):
        parts = urlparse(self.path).path.strip("/").split("/")
        if parts[0] == "threads" and len(parts) == 2:
            with LOCK:
                STATE["threads"].pop(parts[1], None)
                save_state()
            return self.send_json(204)
        return self.send_json(404, error_body("Not found"))

    def do_POST(self):
        path = urlparse(self.path).path
        parts = path.strip("/").split("/")
        if parts == ["threads"]:
            body = self.read_body()
            if body is None:
                return self.send_json(400, error_body("Malformed request body"))
            with LOCK:
                thread_id = next_id("thr")
                thread = {"thread_id": thread_id, "created_at": now(), "updated_at": now(),
                          "metadata": body.get("metadata") or {}, "status": "idle", "turns": [], "pending": [],
                          "messages": []}
                STATE["threads"][thread_id] = thread
                save_state()
                return self.send_json(200, self.row(thread))
        if parts[0] != "threads" or len(parts) < 3:
            return self.send_json(404, error_body("Not found"))
        thread_id = parts[1]
        tail = "/".join(parts[2:])
        if tail == "cancel":
            with LOCK:
                run = LIVE.get(thread_id)
                if run is not None and not run.done:
                    run.cancel.set()
                    return self.send_json(200, {"status": "interrupted", "thread_id": thread_id})
                if thread_id not in STATE["threads"]:
                    return self.send_json(404, error_body("Thread not found", "thread_not_found"))
                return self.send_json(409, error_body("No run in flight for thread \"%s\"" % thread_id,
                                                      "no_run_in_flight"))
        if tail == "runs/stream":
            body = self.read_body()
            if body is None or not isinstance(body.get("route"), str):
                return self.send_json(400, error_body("Request body must include route as a string"))
            if body["route"] != ROUTE:
                return self.send_json(404, error_body("Unknown route: %s" % body["route"]))
            if not self.gate():
                return None
            messages = (body.get("input") or {}).get("messages") or []
            text = " ".join(m.get("content", "") for m in messages if isinstance(m, dict) and m.get("role") == "user")
            with LOCK:
                thread = STATE["threads"].get(thread_id)
                if thread is None:
                    thread = {"thread_id": thread_id, "created_at": now(), "updated_at": now(), "metadata": {},
                              "status": "idle", "turns": [], "pending": [], "messages": []}
                    STATE["threads"][thread_id] = thread
                live = LIVE.get(thread_id)
                if live is not None and not live.done:
                    return self.send_json(409, error_body("A run is already in flight for thread \"%s\"" % thread_id,
                                                          "run_in_flight"))
                if thread["pending"]:
                    return self.send_json(409, error_body("Pending interrupts require resume entries",
                                                          "resume_required"))
                run = Run(thread_id, text)
                LIVE[thread_id] = run
                thread["metadata"]["route"] = body["route"]
                thread["status"] = "busy"
                save_state()
            threading.Thread(target=execute, args=(run,), daemon=True).start()
            self.start_sse()
            self.pump(run, 0)
            return None
        if tail == "resume":
            body = self.read_body()
            if body is None or set(body.keys()) != {"resume", "route"} or not isinstance(body.get("resume"), list):
                return self.send_json(400, error_body("Malformed resume request body"))
            if not self.gate():
                return None
            with LOCK:
                thread = self.thread_or_404(thread_id)
                if thread is None:
                    return None
                live = LIVE.get(thread_id)
                if live is not None and not live.done:
                    return self.send_json(409, error_body("A run is already in flight", "run_in_flight"))
                pending = thread["pending"]
                if not pending:
                    return self.send_json(409, error_body("No pending interrupts match the resume entries",
                                                          "stale_interrupt"))
                entries = body["resume"]
                if len(entries) != len(pending) or {e.get("interruptId") for e in entries} != {
                        p["interruptId"] for p in pending}:
                    return self.send_json(409, error_body("Resume entries must exactly match pending interrupts",
                                                          "interrupt_set_mismatch"))
                entry = entries[0]
                keys = set(entry.keys())
                if entry.get("status") == "resolved":
                    if keys not in ({"interruptId", "status", "payload"}, {"interruptId", "status", "payload", "grant"}) \
                            or entry.get("payload") not in ("once", "always", "deny"):
                        return self.send_json(400, error_body("Resolved resume entries require a once, always, or deny payload",
                                                              "invalid_resume_payload"))
                    decision = entry["payload"]
                elif entry.get("status") == "cancelled":
                    if keys not in ({"interruptId", "status"}, {"interruptId", "status", "grant"}):
                        return self.send_json(400, error_body("Malformed resume request body"))
                    decision = "cancelled"
                else:
                    return self.send_json(400, error_body("Malformed resume request body"))
                if pending[0].get("grant") and entry.get("grant") != pending[0]["grant"]:
                    return self.send_json(409, error_body("Approval grant missing or mismatched", "grant_mismatch"))
                thread["pending"] = []
                thread["status"] = "busy"
                run = Run(thread_id, "", resume=decision)
                LIVE[thread_id] = run
                save_state()
            threading.Thread(target=execute, args=(run,), daemon=True).start()
            self.start_sse()
            self.pump(run, 0)
            return None
        if tail == "runs/wait":
            return self.send_json(501, error_body("runs/wait is not implemented by fake-b4"))
        return self.send_json(404, error_body("Not found"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--host", default="127.0.0.1")
    options = parser.parse_args()
    load_state()
    ThreadingHTTPServer.allow_reuse_address = True
    ThreadingHTTPServer.daemon_threads = True
    server = ThreadingHTTPServer((options.host, options.port), Handler)
    port = server.server_address[1]
    port_file = os.environ.get("FAKE_B4_PORT_FILE")
    if port_file:
        with open(port_file, "w") as handle:
            handle.write(str(port))
    sys.stdout.write("fake-b4 listening on http://127.0.0.1:%d\n" % port)
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
