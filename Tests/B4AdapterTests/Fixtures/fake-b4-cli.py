#!/usr/bin/env python3
"""A stand-in for the `b4` CLI (`@b4run/cli` 0.15.8) for managed-server fixture tests. The scratch
project builder copies this file to `node_modules/@b4run/cli/dist/index.js` and `fake-b4.py` beside
it as `fake_b4.py`; `fake-node.sh` runs it with python3.

Commands, with the real CLI's observable behavior:
  routes --json [--cwd DIR]   print a RouteManifest from src/app/*/index.ts (kind from the export)
  dev --port N [--env-file P] print "Loaded K variable(s) from …" when the env file exists, then
                              "B4.run dev ready at http://127.0.0.1:N" once listening; serves the
                              Agent Protocol from fake_b4; forwards SIGTERM to a grandchild runtime
                              when FAKE_B4_GRANDCHILD=1
  start --host H --port N     refuses without --host (the real default is 0.0.0.0); prints
                              "b4 start listening on http://127.0.0.1:N"; serves
  typegen [--cwd DIR]         exit 0
  --version                   0.15.8
Env knobs: FAKE_B4_MARK (echoed as "FAKE_B4_MARK=<value>" at boot so a test can see an env-file value
reached the child), FAKE_B4_ECHO_ENV=1 (echoes OPENAI_API_KEY=… at boot for redaction tests),
FAKE_B4_HANG_ON_TERM=<s> (ignore SIGTERM for that long), FAKE_B4_FAIL_START=1 (print "boot failed"
and exit 2 instead of listening). Never a substitute for the real CLI in anything the docs call
live-tested."""
import json
import os
import signal
import subprocess
import sys
import time
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

VERSION = "0.15.8"
KINDS = ("agent", "workflow", "graph", "chain")


def out(text):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def err(text):
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def option(args, name):
    if name in args:
        index = args.index(name)
        if index + 1 < len(args):
            return args[index + 1]
    return None


def app_root(cwd):
    here = os.path.abspath(cwd)
    while True:
        if os.path.exists(os.path.join(here, "b4.config.ts")) and os.path.exists(os.path.join(here, "package.json")):
            return here
        parent = os.path.dirname(here)
        if parent == here:
            return None
        here = parent


def routes(args):
    cwd = option(args, "--cwd") or os.getcwd()
    root = app_root(cwd)
    if root is None:
        err("Failed to discover routes: no b4.config.ts found from %s" % cwd)
        return 2
    manifest = {"appRoot": root, "routes": []}
    app_dir = os.path.join(root, "src", "app")
    for name in sorted(os.listdir(app_dir)) if os.path.isdir(app_dir) else []:
        if name.startswith("_"):
            continue
        entry = os.path.join(app_dir, name, "index.ts")
        if not os.path.exists(entry):
            continue
        with open(entry) as handle:
            source = handle.read()
        kind = next((k for k in KINDS if "%s(" % k in source), None)
        if kind is None:
            continue
        manifest["routes"].append({
            "id": "/" + name, "pathname": "/" + name, "kind": kind,
            "entryFile": "src/app/%s/index.ts" % name, "routeDir": "src/app/%s" % name, "segments": [name],
        })
    if "--json" in args:
        out(json.dumps(manifest, indent=2))
    else:
        out("Discovered %d B4.run routes in %s" % (len(manifest["routes"]), root))
    return 0


def boot_lines():
    if os.environ.get("FAKE_B4_MARK"):
        out("FAKE_B4_MARK=%s" % os.environ["FAKE_B4_MARK"])
    if os.environ.get("FAKE_B4_ECHO_ENV") == "1":
        out("OPENAI_API_KEY=%s" % os.environ.get("OPENAI_API_KEY", ""))
    if os.environ.get("FAKE_B4_FAIL_START") == "1":
        err("boot failed")
        sys.exit(2)


def install_term_handler(child=None):
    hang = float(os.environ.get("FAKE_B4_HANG_ON_TERM", "0"))

    def on_term(signum, frame):
        if hang > 0:
            time.sleep(hang)
        if child is not None:
            try:
                child.terminate()
            except OSError:
                pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)


def serve(port, ready_line):
    import fake_b4
    fake_b4.load_state()
    ThreadingHTTPServer.allow_reuse_address = True
    ThreadingHTTPServer.daemon_threads = True
    server = ThreadingHTTPServer(("127.0.0.1", port), fake_b4.Handler)
    out(ready_line % server.server_address[1])
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def dev(args):
    port = option(args, "--port")
    if port is None or not port.isdigit() or int(port) == 0:
        err("Invalid port: %s" % port)
        return 2
    if app_root(os.getcwd()) is None:
        err("No B4.run app found from %s" % os.getcwd())
        return 2
    env_file = option(args, "--env-file") or os.path.join(os.getcwd(), ".env")
    if os.path.exists(env_file):
        count = 0
        with open(env_file) as handle:
            for line in handle:
                stripped = line.strip()
                if stripped and not stripped.startswith("#") and "=" in stripped:
                    key, value = stripped.split("=", 1)
                    os.environ.setdefault(key.replace("export ", "").strip(), value.strip().strip('"\''))
                    count += 1
        out("Loaded %d variable(s) from %s" % (count, os.path.relpath(env_file, os.getcwd())))
    boot_lines()
    if os.environ.get("FAKE_B4_GRANDCHILD") == "1":
        child = subprocess.Popen(
            [sys.executable, "-I", os.path.abspath(__file__), "serve", "--host", "127.0.0.1", "--port", port],
            stdout=sys.stdout, stderr=sys.stderr)
        install_term_handler(child)
        time.sleep(0.5)
        out("B4.run dev ready at http://127.0.0.1:%s" % port)
        return child.wait()
    install_term_handler()
    return serve(int(port), "B4.run dev ready at http://127.0.0.1:%d")


def start(args):
    host = option(args, "--host")
    port = option(args, "--port")
    if host != "127.0.0.1":
        err("refusing to bind %s in tests; pass --host 127.0.0.1" % (host or "0.0.0.0"))
        return 2
    if port is None or not port.isdigit():
        err("Invalid port: %s" % port)
        return 2
    if app_root(os.getcwd()) is None:
        err("No B4.run app found from %s" % os.getcwd())
        return 2
    boot_lines()
    install_term_handler()
    return serve(int(port), "b4 start listening on http://127.0.0.1:%d")


def main():
    args = sys.argv[1:]
    if not args:
        err("usage: b4 <command>")
        return 1
    command = args[0]
    if command == "--version":
        out(VERSION)
        return 0
    if command == "routes":
        return routes(args[1:])
    if command == "dev":
        return dev(args[1:])
    if command == "start":
        return start(args[1:])
    if command == "serve":
        install_term_handler()
        return serve(int(option(args[1:], "--port")), "fake-b4 runtime child listening on http://127.0.0.1:%d")
    if command == "typegen":
        return 0
    err("unknown command: %s" % command)
    return 1


if __name__ == "__main__":
    sys.exit(main())
