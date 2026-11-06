#!/usr/bin/env python3
"""Begin OS boot before app compilation; never launch or warm the fixture app."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid


def prepare(output, requested_udid=None):
    started = time.monotonic()
    result = subprocess.run(
        ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'],
        check=True, capture_output=True, text=True, timeout=60)
    inventory = json.loads(result.stdout)['devices']
    candidates = []
    for runtime, group in inventory.items():
        version = re.search(r'\.iOS-(\d+)', runtime)
        if version and int(version[1]) >= 26:
            candidates.extend((runtime, d) for d in group
                              if d.get('isAvailable') and d['name'].startswith('iPhone'))
    candidates.sort(key=lambda pair: pair[1]['state'] != 'Booted')
    if requested_udid is not None:
        # Local experiments must bind an explicitly created task-owned device.
        uuid.UUID(requested_udid)
        candidates = [pair for pair in candidates if pair[1]['udid'] == requested_udid]
    if not candidates:
        raise ValueError('No matching available iPhone Simulator on iOS 26 or later.')
    runtime, device = candidates[0]
    udid = device['udid']
    if str(uuid.UUID(udid)).upper() != udid.upper():
        raise ValueError('Simulator UUID must use the canonical hyphenated format.')
    state = device['state']
    if state == 'Shutdown':
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True, timeout=60)
    elif state != 'Booted':
        raise ValueError(f'Unexpected Simulator state: {state}')
    with Path(output).open('a') as f:
        f.write(f'udid={udid}\ndestination=platform=iOS Simulator,id={udid}\n')
    print(json.dumps({'udid': udid, 'runtime': runtime, 'name': device['name'],
                      'initial_state': state, 'setup_wall_seconds': time.monotonic() - started,
                      'scope': 'OS boot only; exact readiness is checked before UI tests.'}))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--github-output', required=True)
    parser.add_argument('--udid', help='Exact eligible Simulator UUID for task-owned local validation')
    args = parser.parse_args(argv)
    try:
        prepare(args.github_output, args.udid)
    except subprocess.CalledProcessError as error:
        print(f'Simulator preparation failed: {error}', file=sys.stderr)
        return error.returncode if error.returncode > 0 else 1
    except subprocess.TimeoutExpired as error:
        print(f'Simulator preparation timed out: {error}', file=sys.stderr)
        return 124
    except (ValueError, KeyError, TypeError, AttributeError, OSError) as error:
        print(f'Simulator preparation failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
