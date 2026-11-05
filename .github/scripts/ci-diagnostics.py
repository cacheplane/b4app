#!/usr/bin/env python3
"""Opt-in numeric CI sampling; primary stdout/stderr and exit status pass through unchanged."""
import argparse
import datetime
import json
import os
import re
import subprocess
import threading
import time


def emit(marker, **values):
    print(marker + ' ' + json.dumps(values, sort_keys=True), flush=True)


def parse_vm_stat(text):
    result = {}
    size = re.search(r'page size of (\d+) bytes', text)
    if size:
        result['page_bytes'] = int(size[1])
    allowed = {'Pages free', 'Pages active', 'Pages inactive', 'Pages speculative',
               'Pages wired down', 'Pages occupied by compressor', 'Pageouts', 'Swapins', 'Swapouts'}
    for line in text.splitlines():
        match = re.fullmatch(r'([^:]+):\s*(\d+)\.?', line.strip())
        if match and match[1] in allowed:
            result[match[1]] = int(match[2])
    return result


def parse_processes(text, root_pid):
    processes = []
    for line in text.splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) != 5:
            continue
        try:
            processes.append((int(fields[0]), int(fields[1]), float(fields[2]), int(fields[3]), fields[4]))
        except ValueError:
            continue
    owned = {root_pid} if any(p[0] == root_pid for p in processes) else set()
    for _ in range(16):
        expanded = owned | {p[0] for p in processes if p[1] in owned}
        if expanded == owned:
            break
        owned = expanded
    result = {}
    for pid, _, cpu, rss, name in processes:
        if pid not in owned:
            continue
        executable = name.rsplit('/', 1)[-1]
        role = ('compiler' if executable in {'swift-frontend', 'swiftc', 'clang', 'clang++'} else
                'test' if executable in {'swiftpm-testing-helper', 'b4appPackageTests'} else
                'swiftpm' if executable in {'swift-build', 'swift-test', 'swift-package'} else 'other')
        row = result.setdefault(role, {'count': 0, 'sum_ps_cpu_percent': 0.0, 'max_rss_kib': 0})
        row['count'] += 1
        row['sum_ps_cpu_percent'] += cpu
        row['max_rss_kib'] = max(row['max_rss_kib'], rss)
    return result


def probe(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=1, check=True)
    return result.stdout


def sample(root_pid):
    result = {}
    try:
        result['process_roles'] = parse_processes(probe(['/bin/ps', '-axo', 'pid=,ppid=,%cpu=,rss=,comm=']), root_pid)
        result['process_status'] = 'ok' if result['process_roles'] else 'root_not_observed'
    except Exception as error:
        result.update(process_roles=None, process_status=type(error).__name__)
    try:
        result['vm_pages'] = parse_vm_stat(probe(['/usr/bin/vm_stat']))
        result['vm_status'] = 'ok' if 'page_bytes' in result['vm_pages'] and 'Pages free' in result['vm_pages'] else 'parse_empty'
    except Exception as error:
        result.update(vm_pages=None, vm_status=type(error).__name__)
    try:
        lines = probe(['/usr/sbin/iostat', '-Id']).splitlines()
        devices = re.findall(r'\bdisk\d+\b', lines[0]) if lines else []
        values = lines[-1].split() if len(lines) >= 3 else []
        result['system_disk_cumulative'] = {}
        if devices and len(values) == 3 * len(devices):
            for i, name in enumerate(devices):
                result['system_disk_cumulative'][name] = dict(zip(['kb_per_transfer', 'transfers', 'mb'], map(float, values[3*i:3*i+3])))
        result['disk_status'] = 'ok' if result['system_disk_cumulative'] else 'parse_empty'
    except Exception as error:
        result.update(system_disk_cumulative=None, disk_status=type(error).__name__)
    return result


def observe_command(command, label, enabled=None, interval=10):
    enabled = os.environ.get('B4APP_CI_DIAGNOSTICS') == '1' if enabled is None else enabled
    started = time.monotonic()
    child = subprocess.Popen(command)
    stop = threading.Event()
    totals = {'samples': 0, 'partial_samples': 0, 'errors': 0, 'probe_wall_seconds': 0.0}

    def monitor():
        while not stop.is_set():
            began = time.monotonic()
            try:
                value = sample(child.pid)
                if any(value.get(k) != 'ok' for k in ['process_status', 'vm_status', 'disk_status']):
                    totals['partial_samples'] += 1
                emit('CI_MACHINE_SAMPLE', label=label, elapsed_seconds=began-started, **value)
                totals['samples'] += 1
            except Exception as error:
                totals['errors'] += 1
                # Never include exception messages: they may contain process/path information.
                emit('CI_DIAGNOSTIC_ERROR', label=label, error_type=type(error).__name__)
            totals['probe_wall_seconds'] += time.monotonic()-began
            stop.wait(interval)

    if enabled:
        emit('CI_STAGE_BEGIN', label=label, logical_cpus=os.cpu_count(), started_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
        thread = threading.Thread(target=monitor, daemon=True)
        thread.start()
    status = child.wait()
    stop.set()
    if enabled:
        thread.join(timeout=4)
        emit('CI_STAGE_END', label=label, wall_seconds=time.monotonic()-started,
             exit_code=status, sampler_closed=not thread.is_alive(), **totals)
    return 128-status if status < 0 else status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('label', choices=['build', 'test'])
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('a primary command is required')
    return observe_command(command, args.label)


if __name__ == '__main__':
    raise SystemExit(main())
