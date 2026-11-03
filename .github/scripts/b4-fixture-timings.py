#!/usr/bin/env python3
"""Print bind/readiness timings; a bounded unpatched DNS probe is advisory only.

Actual HTTP/SSE behavior remains covered by the full Swift fixture suites.
This runs no release commands and never prints environment values or tokens.
"""
import contextlib
import hashlib
import http.server
import importlib.util
import inspect
import io
import json
import platform
import subprocess
import sys
import time
from pathlib import Path
from unittest import mock


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    root = Path(__file__).resolve().parents[2] / 'Tests/B4AdapterTests/Fixtures'
    # Do not wait out an OS resolver stall on every CI run. This process-level timeout
    # includes interpreter startup and must never be reported as a DNS-duration sample.
    probe = "import json,socket,time; print('lookup-started',flush=True); start=time.monotonic(); socket.getfqdn('127.0.0.1'); print(json.dumps({'lookup_seconds':time.monotonic()-start}))"
    start = time.monotonic()
    try:
        result = subprocess.run([sys.executable, '-c', probe], capture_output=True, text=True, timeout=1, check=True)
        dns = dict(status='completed', **json.loads(result.stdout.splitlines()[-1]))
    except subprocess.TimeoutExpired as error:
        dns = dict(status='probe_process_timed_out', lookup_seconds=None,
                   timeout_includes_interpreter_startup=True,
                   lookup_started=b'lookup-started' in (error.stdout or b''))
    except (subprocess.SubprocessError, ValueError, IndexError):
        dns = dict(status='unavailable', lookup_seconds=None)
    dns['probe_process_wall_seconds'] = time.monotonic() - start

    fixture = load('profile_b4_fixture', root / 'fake-b4.py')
    fixture.STATE_FILE = None
    with mock.patch.object(sys, 'path', sys.path.copy()):
        cli = load('profile_b4_cli', root / 'fake-b4-cli.py')
    timings = []
    for entry in ['standalone', 'managed']:
        output = io.StringIO()
        with mock.patch.object(http.server.ThreadingHTTPServer, 'serve_forever', side_effect=KeyboardInterrupt), \
             mock.patch.dict(sys.modules, {'fake_b4': fixture}), \
             mock.patch.object(sys, 'argv', ['fake-b4', '--port', '0']), \
             contextlib.redirect_stdout(output):
            start = time.monotonic()
            if entry == 'standalone':
                fixture.main()
            else:
                if cli.serve(0, 'ready at %d') != 0:
                    raise RuntimeError('managed fixture did not reach readiness')
            elapsed = time.monotonic() - start
        if not output.getvalue().strip():
            raise RuntimeError('fixture emitted no readiness')
        timings.append(dict(entry=entry, bind_readiness_cleanup_seconds=elapsed))
    print(json.dumps(dict(
        schema_version=1, python=platform.python_version(), executable=sys.executable,
        platform=platform.platform(), resolver_probe=dns, fixture_timings=timings,
        source_hashes={name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                       for name in ['fake-b4.py', 'fake-b4-cli.py']},
        stdlib_bind_source_sha256=hashlib.sha256(inspect.getsource(http.server.HTTPServer.server_bind).encode()).hexdigest(),
        requiredness=dict(resolver_probe='advisory', fixture_bind_readiness='required'),
        boundary='Real socket bind, readiness and immediate cleanup; serve loop interrupted. Excludes imports and HTTP traffic.'
    ), indent=2))


if __name__ == '__main__':
    main()
