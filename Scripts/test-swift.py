#!/usr/bin/env python3
"""Run every discovered Swift test, isolating suites with demonstrated fixture interference.

No test body, argument case, test deadline, or intra-suite concurrency is changed. Independent
test suites no longer all share one cooperative worker pool. See the retained unpartitioned
failure and workload amendment in docs/delivery/2026-11-03/reliability/isolation/manifest-v6.json.
The coordinator hello fixture group is documented in
docs/delivery/2026-11-03/swift-ci-latency/public-experiment.json.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time

SINGLE_SUITE_GROUPS = (
    'WorkspaceMirrorTests.MirrorLogOutTests',
    'CoordinatorTests.SocketShutdownTests',
    'CoordinatorTests.AccountCommandTests',
    'WorkspaceUITests.AttentionModelTests',
    'WorkspaceClientTests.WorkspaceClientTests',
)
HELLO_SUITES = ('CoordinatorTests.HubSyncTests', 'CoordinatorTests.LegacySecretCopyTests')
ISOLATED_SUITES = SINGLE_SUITE_GROUPS + HELLO_SUITES
ISOLATED_GROUPS = tuple((suite, (suite,)) for suite in SINGLE_SUITE_GROUPS) + (
    ('coordinator-hello', HELLO_SUITES),
)
TOTAL_BUDGET_SECONDS = 35 * 60

# Keep this session leader alive until the caller has cleaned its process group. Waiting on the
# actual command inside the supervisor retains its real exit status without reaping the group
# leader early and risking a reused group id. The command does not inherit the reporting pipe.
SUPERVISOR = '''
import json, os, resource, signal, subprocess, sys
signal.signal(signal.SIGTERM, lambda *_: None)
fd = int(sys.argv[1])
try:
    diagnostic = os.environ.get('B4APP_CI_DIAGNOSTICS') == '1'
    before = None
    if diagnostic:
        try:
            before = resource.getrusage(resource.RUSAGE_CHILDREN)
        except Exception:
            pass
    child = subprocess.Popen(json.loads(sys.argv[2]), close_fds=True)
    os.close(1)
    os.close(2)
    result = {"exit_code": child.wait(), "command_pid": child.pid}
    if diagnostic:
        try:
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            result["resources"] = {"user_seconds": after.ru_utime-before.ru_utime,
                "system_seconds": after.ru_stime-before.ru_stime,
                "max_rss_bytes": after.ru_maxrss if sys.platform == "darwin" else after.ru_maxrss*1024,
                "voluntary_context_switches": after.ru_nvcsw-before.ru_nvcsw,
                "involuntary_context_switches": after.ru_nivcsw-before.ru_nivcsw}
        except Exception as error:
            result["resource_error"] = type(error).__name__
except OSError as error:
    result = {"exit_code": 127, "error": str(error)}
os.write(fd, (json.dumps(result) + "\\n").encode())
while True:
    signal.pause()
'''


def parse_inventory(text):
    ids = text.splitlines()
    if not ids or any(not re.fullmatch(r'[A-Za-z_]\w*\.[^/\s]+/[^/\r\n]+', x) for x in ids):
        raise ValueError('missing or malformed Swift test inventory')
    if len(ids) != len(set(ids)):
        raise ValueError('duplicate discovered Swift test identifiers')
    return ids


def validate_plan(inventory, plan):
    seen = set()
    for part in plan:
        ids = part['ids']
        selected = {x for x in inventory
                    if bool(re.search(part['selector'], x)) == (part['selection_arg'] == '--filter')}
        if not ids or len(ids) != len(set(ids)) or selected != set(ids) or seen.intersection(ids):
            raise ValueError('empty, overlapping or incorrectly selected test partition')
        seen.update(ids)
    if seen != set(inventory):
        raise ValueError('test partitions do not cover the complete discovered inventory')


def make_plan(inventory):
    plan = []
    for name, suites in ISOLATED_GROUPS:
        pattern = '|'.join(re.escape(suite) for suite in suites)
        selector = '^' + (pattern if len(suites) == 1 else '(?:' + pattern + ')') + '/'
        plan.append({'name': name, 'selection_arg': '--filter', 'selector': selector,
                     'ids': [x for x in inventory if re.search(selector, x)]})
    selector = '^(?:' + '|'.join(re.escape(suite) for suite in ISOLATED_SUITES) + ')/'
    plan.append({'name': 'remaining-tests', 'selection_arg': '--skip', 'selector': selector,
                 'ids': [x for x in inventory if not re.search(selector, x)]})
    validate_plan(inventory, plan)
    return plan


def parse_summary(text):
    matches = re.findall(
        r'Test run with (\d+) tests? in (\d+) suites? (passed|failed) after ([\d.]+) seconds', text)
    if len(matches) != 1:
        raise ValueError('expected exactly one Swift Testing completion report')
    tests, suites, result, seconds = matches[0]
    if int(tests) <= 0 or int(suites) <= 0:
        raise ValueError('empty Swift Testing completion report')
    return {'tests': int(tests), 'suites': int(suites), 'library_seconds': float(seconds),
            'library_result': result}


def run_command(command, timeout, log):
    """Watch only our new child session; a failed/hung partition must never look like a pass."""
    started = time.monotonic()
    result = {'command': command, 'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'timed_out': False}
    def cleanup_error(message):
        previous = result.get('cleanup_error')
        result['cleanup_error'] = (previous + '; ' if previous else '') + message

    diagnostic = os.environ.get('B4APP_CI_DIAGNOSTICS') == '1'
    completion_offsets = []
    report_offsets = []
    chunks = []
    errors = []
    output = log.open('w')
    report_read, report_write = os.pipe()
    try:
        process = subprocess.Popen(
            [sys.executable, '-c', SUPERVISOR, str(report_write), json.dumps(command)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(report_write,),
            text=True, encoding='utf-8', errors='replace', start_new_session=True)
    except OSError as error:
        os.close(report_read)
        os.close(report_write)
        output.write(str(error))
        output.close()
        result.update(stdout=str(error), exit_code=127, output_closed=True,
                      wall_seconds=time.monotonic() - started)
        return result
    os.close(report_write)
    result['pid'] = process.pid
    result['execution_supervised'] = True
    report_ready = threading.Event()
    reported = {}

    def read_report():
        try:
            with os.fdopen(report_read) as stream:
                reported.update(json.loads(stream.readline()))
                if diagnostic:
                    report_offsets.append(time.monotonic() - started)
        except (OSError, ValueError) as error:
            reported.update(exit_code=127, error='missing supervisor report: ' + str(error))
        finally:
            report_ready.set()

    reporter = threading.Thread(target=read_report, daemon=True)
    reporter.start()
    output_lock = threading.Lock()
    open_readers = 2

    def read_output(stream, destination):
        nonlocal open_readers
        try:
            for line in stream:
                with output_lock:
                    if diagnostic and re.search(r'Test run with \d+ tests? in \d+ suites? (passed|failed) after ', line):
                        completion_offsets.append(time.monotonic() - started)
                    destination.append(line)
                    output.write(line)
                    output.flush()
                    print(line, end='', flush=True)
        except (OSError, ValueError) as error:
            with output_lock:
                result['output_error'] = str(error)
        finally:
            stream.close()
            with output_lock:
                open_readers -= 1
                if open_readers == 0:
                    output.close()

    readers = [threading.Thread(target=read_output, args=(stream, destination), daemon=True)
               for stream, destination in [(process.stdout, chunks), (process.stderr, errors)]]
    for reader in readers:
        reader.start()
    if not report_ready.wait(timeout=max(0.001, timeout)):
        result['timed_out'] = True
        # The supervisor remains an unreaped session leader during the whole cleanup, even if
        # the actual command exits after TERM while an owned descendant ignores it.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except OSError as error:
            cleanup_error('SIGTERM failed: ' + str(error))
        time.sleep(2)
    # On normal completion the command has already exited with the reported status. Remove the
    # supervisor and any leaked members of this owned group before the next partition starts.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError as error:
        cleanup_error('SIGKILL failed: ' + str(error))
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        cleanup_error('supervisor did not exit after KILL')
    reporter.join(timeout=1)
    for reader in readers:
        reader.join(timeout=1)
    output_incomplete = any(reader.is_alive() for reader in readers)
    result['output_closed'] = not output_incomplete and 'output_error' not in result
    if output_incomplete:
        # The reader owns its log until EOF, avoiding closing a file beneath a live reader.
        # Its incomplete output fails this partition; no unrelated process is signalled.
        result['error'] = 'child exited without closing its output stream'
    result.update(stdout=''.join(chunks), stderr=''.join(errors),
                  exit_code=reported.get('exit_code', 124), supervisor_exit_code=process.returncode,
                  command_pid=reported.get('command_pid'), supervisor_error=reported.get('error'),
                  wall_seconds=time.monotonic() - started)
    if diagnostic:
        result.update(command_resources=reported.get('resources'),
                      resource_error=reported.get('resource_error'),
                      observed_completion_report_count=len(completion_offsets),
                      observed_library_report_seconds=completion_offsets[0] if len(completion_offsets) == 1 else None,
                      observed_command_report_seconds=report_offsets[0] if report_offsets else None,
                      observed_report_to_exit_seconds=(report_offsets[0]-completion_offsets[0])
                      if len(completion_offsets) == 1 and report_offsets else None)
    return result


def run_pipeline(swift_args, results_dir, runner=run_command, budget_seconds=TOTAL_BUDGET_SECONDS):
    started = time.monotonic()
    deadline = started + budget_seconds
    results_dir.mkdir(parents=True, exist_ok=True)
    result = {'schema_version': 1, 'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'budget_seconds': budget_seconds, 'swift_build_arguments': swift_args, 'partitions': [],
              'complete': False, 'passed': False}

    def save():
        result['wall_seconds'] = time.monotonic() - started
        (results_dir / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')

    diagnostic = os.environ.get('B4APP_CI_DIAGNOSTICS') == '1'
    if diagnostic:
        print('CI_SWIFT_PHASE ' + json.dumps({'phase': 'discovery-begin', 'elapsed_seconds': time.monotonic()-started}), flush=True)
    discovery = runner(['swift', 'test', *swift_args, 'list'], max(0.001, deadline - time.monotonic()),
                       results_dir / 'discovery.log')
    result['discovery'] = discovery
    if diagnostic:
        print('CI_SWIFT_DISCOVERY ' + json.dumps({k: v for k, v in discovery.items()
              if k not in ['stdout', 'stderr']}), flush=True)
    try:
        if (discovery['exit_code'] != 0 or discovery['timed_out']
                or discovery.get('output_closed') is False or discovery.get('cleanup_error')
                or discovery.get('supervisor_error')):
            raise ValueError('Swift test discovery failed or exceeded the aggregate budget')
        inventory = parse_inventory(discovery['stdout'])
        plan = make_plan(inventory)
    except ValueError as error:
        result['error'] = str(error)
        save()
        print('CI_SWIFT_ERROR ' + str(error), flush=True)
        return 1

    digest = hashlib.sha256(('\n'.join(sorted(inventory)) + '\n').encode()).hexdigest()
    result.update(discovered_method_count=len(inventory), inventory_sha256=digest)
    (results_dir / 'plan.json').write_text(json.dumps(
        {'inventory': inventory, 'inventory_sha256': digest, 'partitions': plan}, indent=2) + '\n')
    print('CI_SWIFT_PLAN ' + json.dumps({'discovered_methods': len(inventory),
          'inventory_sha256': digest, 'partitions': [
              {'name': p['name'], 'methods': len(p['ids']), 'selection_arg': p['selection_arg'],
               'selector': p['selector']} for p in plan]}), flush=True)

    for index, part in enumerate(plan):
        remaining = len(plan) - index
        # Leave time for each remaining TERM/KILL/output cleanup even if every child hangs.
        allocation = max(0.001, (deadline - time.monotonic() - 6 * remaining) / remaining)
        command = ['swift', 'test', *swift_args, '--skip-build', part['selection_arg'], part['selector']]
        if diagnostic:
            print('CI_SWIFT_PHASE ' + json.dumps({'phase': 'partition-begin', 'name': part['name'],
                  'elapsed_seconds': time.monotonic()-started}), flush=True)
        child = runner(command, allocation, results_dir / f'partition-{index + 1}.log')
        child.update(name=part['name'], expected_methods=len(part['ids']), passed=False,
                     watchdog_seconds=allocation)
        try:
            parsed = parse_summary(child['stdout'] + child.get('stderr', ''))
            child.update(parsed)
            if parsed['library_result'] != 'passed':
                raise ValueError('Swift Testing reported a failed partition')
            if parsed['tests'] != len(part['ids']):
                raise ValueError('executed test count differs from the selected method inventory')
            if (child['exit_code'] != 0 or child['timed_out'] or child.get('output_closed') is False
                    or child.get('cleanup_error') or child.get('supervisor_error')):
                raise ValueError('test child failed, timed out or left its output incomplete')
            child['passed'] = True
        except ValueError as error:
            child['error'] = str(error)
        result['partitions'].append(child)
        save()
        print('CI_SWIFT_PARTITION ' + json.dumps({k: v for k, v in child.items()
              if k not in ['stdout', 'stderr']}), flush=True)

    parts = result['partitions']
    result['all_partitions_attempted'] = len(parts) == len(plan)
    result['missing_report_partitions'] = sum('tests' not in p for p in parts)
    result['known_reported_tests'] = sum(p.get('tests', 0) for p in parts)
    result['known_reported_suites'] = sum(p.get('suites', 0) for p in parts)
    result['known_sum_library_seconds'] = sum(p.get('library_seconds', 0) for p in parts)
    for total, known in [('reported_tests', 'known_reported_tests'),
                         ('reported_suites', 'known_reported_suites'),
                         ('sum_library_seconds', 'known_sum_library_seconds')]:
        result[total] = result[known] if not result['missing_report_partitions'] else None
    result['complete'] = (result['all_partitions_attempted'] and not result['missing_report_partitions']
                          and all(p.get('tests') == p['expected_methods'] for p in parts)
                          and result['reported_tests'] == len(inventory))
    result['passed'] = result['complete'] and all(p['passed'] for p in parts)
    save()
    print('CI_SWIFT_SUMMARY ' + json.dumps({k: v for k, v in result.items()
          if k not in ['discovery', 'partitions']}), flush=True)
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ['scratch-path', 'cache-path', 'config-path', 'security-path']:
        parser.add_argument('--' + flag)
    parser.add_argument('--jobs', type=int)
    parser.add_argument('--disable-dependency-cache', action='store_true')
    parser.add_argument('--manifest-cache', choices=['shared', 'local', 'none'])
    parser.add_argument('--only-use-versions-from-resolved-file', action='store_true')
    parser.add_argument('--results-path', type=Path, default=Path('.build/ci-swift-tests'))
    args = parser.parse_args()
    if args.jobs is not None and args.jobs <= 0:
        parser.error('--jobs must be positive')
    swift_args = []
    for name, value in vars(args).items():
        if name == 'results_path' or value is None or value is False:
            continue
        swift_args.append('--' + name.replace('_', '-'))
        if value is not True:
            swift_args.append(str(value))
    run = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S') + '-' + str(os.getpid())
    return run_pipeline(swift_args, args.results_path / run)


if __name__ == '__main__':
    sys.exit(main())
