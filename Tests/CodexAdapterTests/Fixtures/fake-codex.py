#!/usr/bin/env python3
"""A stand-in for `codex app-server` used by fixture tests. It speaks the same NDJSON JSON-RPC
shapes as codex-cli 0.166.0 for the handful of methods the adapter uses, and scripts its behavior
from the turn text: "approve" asks for a command approval, "permissions" asks for a permissions
grant, "question" asks a user question, "hang" waits for turn/interrupt, "crash" exits mid-turn.
Never run in place of the real server for anything the docs call live-tested."""
import json
import os
import sys

if len(sys.argv) > 1 and sys.argv[1] == "--version":
    print("codex-cli 0.166.0")
    sys.exit(0)
if len(sys.argv) < 2 or sys.argv[1] != "app-server":
    sys.stderr.write("fake-codex: unsupported arguments\n")
    sys.exit(2)

pidfile = os.environ.get("FAKE_CODEX_PIDFILE")
if pidfile:
    with open(pidfile, "w") as f:
        f.write(str(os.getpid()))


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def log(text):
    sys.stderr.write("fake-codex: " + text + "\n")
    sys.stderr.flush()


def read():
    line = sys.stdin.readline()
    if not line:
        log("stdin closed; exiting")
        sys.exit(0)
    msg = json.loads(line)
    log("<- " + line.strip())
    return msg


def wait_response(req_id):
    while True:
        msg = read()
        if msg.get("id") == req_id and "method" not in msg:
            return msg
        log("ignoring message while waiting for response %s" % req_id)


def notify(method, params):
    send({"method": method, "params": params})


def thread_record(thread_id, cwd, name=None):
    return {
        "id": thread_id, "sessionId": thread_id, "cwd": cwd, "name": name, "preview": "",
        "status": {"type": "idle"}, "turns": [], "modelProvider": "openai", "model": "gpt-fake",
        "createdAt": 1, "updatedAt": 1, "ephemeral": False, "cliVersion": "0.166.0", "source": "appServer",
        "projectId": None,
    }


def stream_message(thread_id, turn_id, text):
    item_id = "item_%s_msg" % turn_id
    notify("item/started", {"threadId": thread_id, "turnId": turn_id,
                            "item": {"id": item_id, "type": "agentMessage", "text": ""}, "startedAtMs": 1})
    half = max(1, len(text) // 2)
    for piece in (text[:half], text[half:]):
        if piece:
            notify("item/agentMessage/delta", {"threadId": thread_id, "turnId": turn_id, "itemId": item_id, "delta": piece})
    notify("item/completed", {"threadId": thread_id, "turnId": turn_id,
                              "item": {"id": item_id, "type": "agentMessage", "text": text}, "completedAtMs": 2})


finished = {}


def finish_turn(thread_id, turn_id, status, error=None):
    finished.setdefault(thread_id, []).append((turn_id, status))
    notify("turn/completed", {"threadId": thread_id,
                              "turn": {"id": turn_id, "status": status, "items": [], "error": error}})
    notify("thread/status/changed", {"threadId": thread_id, "status": {"type": "idle"}})


turn_counter = 0
thread_counter = 0
# Real runtimes mint unique ids across restarts; a restarted fixture would reuse thr_1 and turn_1,
# so tests that restart it pass a prefix.
ID_PREFIX = os.environ.get("FAKE_CODEX_ID_PREFIX", "")
loaded = {}
hanging = None

while True:
    msg = read()
    method = msg.get("method")
    req_id = msg.get("id")
    params = msg.get("params") or {}
    if method == "initialize":
        send({"id": req_id, "result": {"userAgent": "fake-codex/0.166.0", "codexHome": "/tmp/fake-codex",
                                       "platformFamily": "unix", "platformOs": "macos"}})
        notify("account/updated", {"authMode": "chatgpt", "planType": "plus"})
    elif method == "initialized":
        pass
    elif method == "account/read":
        send({"id": req_id, "result": {"account": {"type": "chatgpt", "email": os.environ.get("FAKE_CODEX_EMAIL", "owner@example.com"),
                                                   "planType": "plus", "workspaceName": None},
                                       "requiresOpenaiAuth": True}})
    elif method == "account/login/start":
        send({"id": req_id, "result": {"type": "chatgpt", "authUrl": "https://auth.example/login?state=1",
                                       "loginId": "login_1"}})
    elif method == "thread/start":
        thread_counter += 1
        thread_id = "thr_%s%d" % (ID_PREFIX, thread_counter)
        cwd = params.get("cwd") or "/tmp"
        loaded[thread_id] = cwd
        notify("thread/started", {"thread": thread_record(thread_id, cwd)})
        send({"id": req_id, "result": {"thread": thread_record(thread_id, cwd), "model": "gpt-fake",
                                       "modelProvider": "openai", "cwd": cwd, "approvalPolicy": "on-request",
                                       "approvalsReviewer": "user", "sandbox": {"type": "workspaceWrite"}}})
    elif method == "thread/resume":
        thread_id = params["threadId"]
        if thread_id == "thr_missing":
            send({"id": req_id, "error": {"code": -32600, "message": "thread thr_missing not found"}})
        else:
            cwd = params.get("cwd") or loaded.get(thread_id) or "/tmp"
            loaded[thread_id] = cwd
            send({"id": req_id, "result": {"thread": thread_record(thread_id, cwd, name="Resumed thread"),
                                           "model": "gpt-fake", "modelProvider": "openai", "cwd": cwd,
                                           "approvalPolicy": "on-request", "approvalsReviewer": "user",
                                           "sandbox": {"type": "workspaceWrite"}}})
    elif method == "thread/read":
        thread_id = params["threadId"]
        status = {"type": "active", "activeFlags": []} if hanging and hanging[0] == thread_id else {"type": "idle"}
        record = thread_record(thread_id, loaded.get(thread_id, "/tmp"))
        record["status"] = status
        send({"id": req_id, "result": {"thread": record}})
    elif method == "thread/turns/list":
        thread_id = params["threadId"]
        turns = [{"id": "turn_h1", "status": "completed", "error": None, "items": [
            {"id": "u_h1", "type": "userMessage", "content": [{"type": "text", "text": "earlier question"}]},
            {"id": "a_h1", "type": "agentMessage", "text": "earlier answer"},
        ]}]
        turns += [{"id": t, "status": s, "error": None, "items": []} for (t, s) in finished.get(thread_id, [])]
        if params.get("sortDirection") == "desc":
            turns = list(reversed(turns))[: params.get("limit") or 50]
        send({"id": req_id, "result": {"data": turns, "nextCursor": None}})
    elif method == "turn/start":
        thread_id = params["threadId"]
        if thread_id not in loaded:
            send({"id": req_id, "error": {"code": -32600, "message": "thread %s is not loaded" % thread_id}})
            continue
        text = params["input"][0]["text"]
        if "swallow" in text:
            # Lost request: no acknowledgement, nothing started. The adapter must report an unknown
            # submission and nothing may be re-sent.
            log("swallowing turn/start")
            continue
        turn_counter += 1
        turn_id = "turn_%s%d" % (ID_PREFIX, turn_counter)
        if "late ack" not in text:
            send({"id": req_id, "result": {"turn": {"id": turn_id, "status": "inProgress", "items": [], "error": None}}})
        # "late ack": the turn runs and its notifications flow, but the RPC response is lost.
        notify("turn/started", {"threadId": thread_id, "turn": {"id": turn_id, "status": "inProgress", "items": [], "error": None}})
        if "crash" in text:
            log("crashing on request")
            os._exit(1)
        if "hang" in text:
            hanging = (thread_id, turn_id)
            continue
        reply = "Hello from fake Codex."
        if "approve" in text:
            send({"id": 7, "method": "item/commandExecution/requestApproval",
                  "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "item_cmd", "command": "ls -la",
                             "cwd": "/tmp", "reason": None, "environmentId": "env_1", "startedAtMs": 1}})
            response = wait_response(7)
            decision = (response.get("result") or {}).get("decision")
            notify("serverRequest/resolved", {"threadId": thread_id, "requestId": 7})
            status = "completed" if decision in ("accept", "acceptForSession") else "declined"
            notify("item/completed", {"threadId": thread_id, "turnId": turn_id, "completedAtMs": 3,
                                      "item": {"id": "item_cmd", "type": "commandExecution", "command": "ls -la",
                                               "cwd": "/tmp", "status": status, "exitCode": 0 if status == "completed" else None,
                                               "aggregatedOutput": "total 0\n" if status == "completed" else None,
                                               "commandActions": []}})
            reply = "Command %s." % status
        if "permissions" in text:
            send({"id": 8, "method": "item/permissions/requestApproval",
                  "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "item_perm", "cwd": "/tmp",
                             "permissions": {"network": {"enabled": True}}, "reason": "needs network", "startedAtMs": 1}})
            response = wait_response(8)
            notify("serverRequest/resolved", {"threadId": thread_id, "requestId": 8})
            reply = "Permissions answered with %s." % json.dumps(response.get("result") or response.get("error"), sort_keys=True)
        if "question" in text:
            send({"id": 9, "method": "item/tool/requestUserInput",
                  "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "item_q", "isBlocking": True,
                             "questions": [{"id": "color", "header": "Color", "question": "Which color?",
                                            "options": [{"label": "red", "description": "warm"}, {"label": "blue", "description": "cool"}]}]}})
            response = wait_response(9)
            notify("serverRequest/resolved", {"threadId": thread_id, "requestId": 9})
            answers = ((response.get("result") or {}).get("answers") or {}).get("color", {}).get("answers", [])
            reply = "You chose %s." % (answers[0] if answers else "nothing")
        if "signout" in text:
            finish_turn(thread_id, turn_id, "failed", {"message": "401 Unauthorized: token expired", "codexErrorInfo": "unauthorized"})
            continue
        if "leak" in text:
            finish_turn(thread_id, turn_id, "failed", {
                "message": "upstream said no: Authorization: Bearer abc.def.ghi; key sk-proj-ABCDEFGHIJKLMNOP; see https://auth.example/cb?code=SECRETCODE&state=xyz&access_token=tok123",
                "codexErrorInfo": "other"})
            continue
        if "fail" in text:
            finish_turn(thread_id, turn_id, "failed", {"message": "usage limit reached", "codexErrorInfo": "usageLimitExceeded"})
            continue
        stream_message(thread_id, turn_id, reply)
        finish_turn(thread_id, turn_id, "completed")
    elif method == "turn/interrupt":
        send({"id": req_id, "result": {}})
        if hanging and hanging[1] == params.get("turnId"):
            finish_turn(hanging[0], hanging[1], "interrupted")
            hanging = None
    elif req_id is not None:
        send({"id": req_id, "error": {"code": -32601, "message": "fake-codex does not implement %s" % method}})
