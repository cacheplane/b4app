#!/usr/bin/env python3
"""A stand-in for the `claude` CLI's stream-json mode used by fixture tests. Shapes follow the frames
recorded from Claude Code 2.1.282 (docs/research/2026-10-30-claude-cli-stream-protocol.md and the
2026-10-31 probe). Behavior is scripted by the user text: "tool" asks for a Bash permission,
"question" asks an AskUserQuestion, "elicitation" sends an MCP elicitation, "hang" waits for an
interrupt, "crash" exits mid-turn, "fail" returns an error result. Never a substitute for the real CLI
in anything the docs call live-tested."""
import json
import os
import sys
import time

args = sys.argv[1:]
if args[:1] == ["--version"]:
    print("2.1.282 (Claude Code)")
    sys.exit(0)
if args[:3] == ["auth", "status", "--json"]:
    print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty",
                      "email": "owner@example.com", "orgName": "Owner", "subscriptionType": "max",
                      "projectsDirectory": os.environ.get("FAKE_CLAUDE_PROJECTS", "/tmp/fake-claude-projects"),
                      "configDirectory": "/tmp/fake-claude"}))
    sys.exit(0)
if args[:2] == ["auth", "login"]:
    print("Browser didn't open? Use the url below to sign in:")
    print("https://claude.ai/oauth/authorize?fake=1&state=abc")
    sys.stdout.flush()
    time.sleep(0.5)
    sys.exit(0)

if "--input-format" not in args or "stream-json" not in args:
    sys.stderr.write("fake-claude: unsupported arguments %r\n" % args)
    sys.exit(2)
if "--bare" in args:
    sys.stderr.write("fake-claude: --bare must never be passed\n")
    sys.exit(3)


def arg(name):
    return args[args.index(name) + 1] if name in args else None


session_id = arg("--session-id") or arg("--resume") or "11111111-1111-4111-8111-111111111111"
resumed = arg("--resume") is not None


def send(obj):
    obj.setdefault("session_id", session_id)
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def log(text):
    sys.stderr.write("fake-claude: " + text + "\n")
    sys.stderr.flush()


log("argv %r" % args)
if resumed and session_id == "missing":
    send({"type": "result", "subtype": "error_during_execution", "duration_ms": 0, "is_error": True,
          "num_turns": 0, "stop_reason": None, "total_cost_usd": 0, "errors": []})
    sys.stderr.write("No conversation found with session ID: missing\n")
    sys.exit(1)

projects = os.environ.get("FAKE_CLAUDE_PROJECTS")
transcript = None
if projects:
    folder = os.path.join(projects, "-" + os.getcwd().strip("/").replace("/", "-"))
    os.makedirs(folder, exist_ok=True)
    transcript = open(os.path.join(folder, session_id + ".jsonl"), "a")


def record(obj):
    if transcript:
        transcript.write(json.dumps(obj) + "\n")
        transcript.flush()


def read():
    line = sys.stdin.readline()
    if not line:
        log("stdin closed; exiting")
        sys.exit(0)
    msg = json.loads(line)
    log("<- " + line.strip()[:300])
    return msg


def wait_control_response(request_id):
    while True:
        msg = read()
        if msg.get("type") == "control_response" and msg.get("response", {}).get("request_id") == request_id:
            return msg["response"]
        if msg.get("type") == "control_request" and msg["request"].get("subtype") == "interrupt":
            send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"],
                                                           "response": {"still_queued": 0, "cancelled": True}}})
            return {"subtype": "interrupted"}
        log("ignoring %s while waiting for %s" % (msg.get("type"), request_id))


counter = 0


def next_id(prefix):
    global counter
    counter += 1
    return "%s_%d" % (prefix, counter)


def stream_text(user_uuid, text):
    message_id = next_id("msg")
    send({"type": "stream_event", "event": {"type": "message_start", "message": {"id": message_id, "role": "assistant", "content": []}},
          "parent_tool_use_id": None, "user_message_uuid": user_uuid})
    send({"type": "stream_event", "event": {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
          "parent_tool_use_id": None, "user_message_uuid": user_uuid})
    half = max(1, len(text) // 2)
    for piece in (text[:half], text[half:]):
        if piece:
            send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": piece}},
                  "parent_tool_use_id": None, "user_message_uuid": user_uuid})
    send({"type": "stream_event", "event": {"type": "content_block_stop", "index": 0}, "parent_tool_use_id": None, "user_message_uuid": user_uuid})
    send({"type": "stream_event", "event": {"type": "message_stop"}, "parent_tool_use_id": None, "user_message_uuid": user_uuid})
    message = {"id": message_id, "role": "assistant", "model": "claude-fake", "content": [{"type": "text", "text": text}],
               "stop_reason": "end_turn", "usage": {"input_tokens": 1, "output_tokens": 1}}
    send({"type": "assistant", "message": message, "parent_tool_use_id": None, "uuid": next_id("uuid"), "user_message_uuid": user_uuid})
    record({"type": "assistant", "uuid": next_id("uuid"), "message": message})
    return message_id


def result(user_uuid, is_error=False, text="", terminal_reason=None, subtype="success"):
    send({"type": "result", "subtype": subtype, "is_error": is_error, "duration_ms": 10, "num_turns": 1,
          "total_cost_usd": 0.001, "result": text, "stop_reason": "end_turn", "terminal_reason": terminal_reason,
          "permission_denials": [], "user_message_uuid": user_uuid, "errors": []})


while True:
    msg = read()
    kind = msg.get("type")
    if kind == "control_request":
        request = msg["request"]
        if request.get("subtype") == "initialize":
            send({"type": "system", "subtype": "hook_started", "hook_name": "SessionStart:startup", "uuid": next_id("uuid")})
            send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": {
                "commands": [], "agents": [], "models": [], "account": {"email": "owner@example.com", "organization": "Owner",
                                                                        "subscriptionType": "max", "apiProvider": "firstParty"},
                "current_permission_mode": "default", "session_state": "idle", "pid": os.getpid()}}})
        elif request.get("subtype") == "interrupt":
            send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"],
                                                           "response": {"still_queued": 0, "cancelled": False}}})
        else:
            send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": {}}})
        continue
    if kind != "user":
        continue
    user_uuid = msg.get("uuid") or next_id("user")
    text = msg["message"]["content"][0]["text"]
    record({"type": "user", "uuid": user_uuid, "message": {"role": "user", "content": text}})
    send({"type": "system", "subtype": "init", "cwd": os.getcwd(), "tools": ["Bash", "Read", "AskUserQuestion"],
          "mcp_servers": [], "model": "claude-fake", "permissionMode": "default", "apiKeySource": "none",
          "claude_code_version": "2.1.282", "capabilities": ["interrupt_receipt_v1", "interrupt_cancel_queued_v1"], "uuid": next_id("uuid")})
    send({"type": "system", "subtype": "session_state_changed", "state": "running", "uuid": next_id("uuid")})
    if "--replay-user-messages" in args:
        send({"type": "user", "message": msg["message"], "parent_tool_use_id": None, "uuid": user_uuid, "isReplay": True})
    if "crash" in text:
        log("crashing on request")
        os._exit(1)
    if "fail" in text:
        message = {"id": next_id("msg"), "role": "assistant", "model": "<synthetic>",
                   "content": [{"type": "text", "text": "Failed to authenticate: OAuth session expired"}], "stop_reason": "stop_sequence"}
        send({"type": "assistant", "message": message, "error": "authentication_failed", "is_api_error_message": True,
              "parent_tool_use_id": None, "uuid": next_id("uuid"), "user_message_uuid": user_uuid})
        result(user_uuid, is_error=True, text="Failed to authenticate: OAuth session expired", terminal_reason="api_error")
        continue
    if "hang" in text:
        message_id = next_id("msg")
        send({"type": "stream_event", "event": {"type": "message_start", "message": {"id": message_id, "role": "assistant", "content": []}},
              "parent_tool_use_id": None, "user_message_uuid": user_uuid})
        send({"type": "stream_event", "event": {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
              "parent_tool_use_id": None, "user_message_uuid": user_uuid})
        send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Counting 1"}},
              "parent_tool_use_id": None, "user_message_uuid": user_uuid})
        while True:
            pending = read()
            if pending.get("type") == "control_request" and pending["request"].get("subtype") == "interrupt":
                send({"type": "control_response", "response": {"subtype": "success", "request_id": pending["request_id"],
                                                               "response": {"still_queued": 0, "cancelled": True}}})
                break
        # As Claude Code 2.1.282 does live: a requested stop is an error result with reason aborted_streaming.
        result(user_uuid, is_error=True, text="Counting 1", terminal_reason="aborted_streaming", subtype="error_during_execution")
        continue
    reply = "Hello from fake Claude."
    if "tool" in text:
        request_id = next_id("req")
        tool_use_id = next_id("toolu")
        send({"type": "control_request", "request_id": request_id, "request": {"subtype": "can_use_tool", "tool_name": "Bash",
              "input": {"command": "ls -la", "description": "List files"}, "tool_use_id": tool_use_id, "permission_suggestions": [],
              "decision_reason": None}})
        response = wait_control_response(request_id)
        behavior = (response.get("response") or {}).get("behavior")
        send({"type": "system", "subtype": "session_state_changed", "state": "running", "uuid": next_id("uuid")})
        message = {"id": next_id("msg"), "role": "assistant", "model": "claude-fake",
                   "content": [{"type": "tool_use", "id": tool_use_id, "name": "Bash", "input": {"command": "ls -la"}}], "stop_reason": "tool_use"}
        send({"type": "assistant", "message": message, "parent_tool_use_id": None, "uuid": next_id("uuid"), "user_message_uuid": user_uuid})
        record({"type": "assistant", "uuid": next_id("uuid"), "message": message})
        if behavior == "allow":
            tool_result = {"type": "tool_result", "tool_use_id": tool_use_id, "content": [{"type": "text", "text": "total 0\n"}], "is_error": False}
            reply = "The directory is empty."
        else:
            tool_result = {"type": "tool_result", "tool_use_id": tool_use_id, "content": "User declined", "is_error": True}
            reply = "I could not run the command."
        send({"type": "user", "message": {"role": "user", "content": [tool_result]}, "parent_tool_use_id": None, "uuid": next_id("uuid")})
        record({"type": "user", "uuid": next_id("uuid"), "message": {"role": "user", "content": [tool_result]}})
    if "question" in text:
        request_id = next_id("req")
        questions = [{"question": "Which color?", "header": "Color", "options": [{"label": "red", "description": "warm"},
                                                                                  {"label": "blue", "description": "cool"}], "multiSelect": False}]
        send({"type": "control_request", "request_id": request_id, "request": {"subtype": "can_use_tool", "tool_name": "AskUserQuestion",
              "input": {"questions": questions}, "tool_use_id": next_id("toolu"), "permission_suggestions": [], "decision_reason": None}})
        response = wait_control_response(request_id)
        answers = ((response.get("response") or {}).get("updatedInput") or {}).get("answers") or {}
        reply = "You chose %s." % (answers.get("Which color?") or "nothing")
    if "elicitation" in text:
        request_id = next_id("req")
        send({"type": "control_request", "request_id": request_id, "request": {"subtype": "elicitation", "message": "Enter a token",
              "requestedSchema": {"type": "object", "properties": {}}}})
        response = wait_control_response(request_id)
        reply = "Elicitation answered with %s." % json.dumps(response.get("response") or response.get("error"), sort_keys=True)
    stream_text(user_uuid, reply)
    result(user_uuid, text=reply)
