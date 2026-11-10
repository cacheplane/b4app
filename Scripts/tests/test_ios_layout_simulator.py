"""Exercise real setup CLI boundaries without booting the developer's Simulators."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'Scripts/prepare_ios_layout_simulator.py'
FIRST = '11111111-1111-4111-8111-111111111111'
SECOND = '22222222-2222-4222-8222-222222222222'


def device(udid=FIRST, state='Shutdown', name='iPhone 17 Pro', available=True):
    return dict(udid=udid, state=state, name=name, isAvailable=available)


class SimulatorPreparationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.calls = self.root / 'calls.jsonl'
        self.output = self.root / 'github-output'
        fake = self.root / 'xcrun'
        fake.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['SIM_CALLS'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:5] == ['simctl', 'list', 'devices', 'available']:
    print(os.environ['SIM_DEVICES_JSON'])
    sys.exit(int(os.environ.get('SIM_FAIL_LIST', '0')))
if sys.argv[1:3] == ['simctl', 'boot']:
    sys.exit(int(os.environ.get('SIM_FAIL_BOOT', '0')))
sys.exit(99)
''')
        fake.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'],
                        SIM_CALLS=str(self.calls))

    def run_setup(self, groups=None, *args, raw=None, **env):
        self.env.update(env)
        self.env['SIM_DEVICES_JSON'] = raw if raw is not None else json.dumps({
            'devices': groups or {'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [device()]}})
        return subprocess.run([sys.executable, str(SCRIPT), '--github-output', str(self.output), *args],
                              env=self.env, capture_output=True, text=True, timeout=10)

    def recorded_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_shutdown_device_boots_once_and_hands_off_exact_destination(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded_calls(), [
            ['simctl', 'list', 'devices', 'available', '--json'], ['simctl', 'boot', FIRST]])
        self.assertEqual(self.output.read_text(),
                         f'udid={FIRST}\ndestination=platform=iOS Simulator,id={FIRST}\n')

    def test_default_policy_prefers_booted_eligible_iphone_without_boot(self):
        groups = {
            'com.apple.CoreSimulator.SimRuntime.iOS-25-0': [device(state='Booted')],
            'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [
                device(name='iPad Pro', state='Booted'), device(available=False, state='Booted'),
                device(), device(SECOND, state='Booted')],
        }
        result = self.run_setup(groups)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.recorded_calls()), 1)
        self.assertIn(f'udid={SECOND}\n', self.output.read_text())

    def test_local_override_does_not_boot_or_use_owners_booted_device(self):
        result = self.run_setup({'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [
            device(state='Booted'), device(SECOND)]}, '--udid', SECOND)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded_calls()[-1], ['simctl', 'boot', SECOND])
        self.assertIn(f'udid={SECOND}\n', self.output.read_text())
        self.assertNotIn(FIRST, self.output.read_text())

    def test_missing_override_never_falls_back_to_owner_device(self):
        result = self.run_setup(None, '--udid', SECOND)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(len(self.recorded_calls()), 1)

    def test_blank_override_never_falls_back_to_default_device(self):
        result = self.run_setup(None, '--udid', '')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(len(self.recorded_calls()), 1)

    def test_no_eligible_device_fails_without_boot_or_handoff(self):
        result = self.run_setup({'com.apple.CoreSimulator.SimRuntime.iOS-25-0': [device()]})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(len(self.recorded_calls()), 1)

    def test_list_failure_propagates_without_boot_or_handoff(self):
        result = self.run_setup(SIM_FAIL_LIST='17')
        self.assertEqual(result.returncode, 17)
        self.assertFalse(self.output.exists())
        self.assertEqual(len(self.recorded_calls()), 1)

    def test_boot_failure_propagates_without_handoff(self):
        result = self.run_setup(SIM_FAIL_BOOT='23')
        self.assertEqual(result.returncode, 23)
        self.assertFalse(self.output.exists())
        self.assertEqual(len(self.recorded_calls()), 2)

    def test_malformed_inventory_uuid_and_unexpected_state_fail_closed(self):
        bad_inputs = [
            '{', '{}', '{"devices": []}',
            json.dumps({'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [
                device(udid=FIRST + '\ndestination=other')]}}),
            json.dumps({'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [
                device(state='Booting')]}}),
        ]
        for raw in bad_inputs:
            with self.subTest(raw=raw):
                result = self.run_setup(raw=raw)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.output.exists())
        self.assertTrue(all(c[1] == 'list' for c in self.recorded_calls()))

    def test_list_and_boot_timeouts_fail_without_output_or_retry(self):
        spec = importlib.util.spec_from_file_location('simulator_setup', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        inventory = json.dumps({'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [device()]}})
        listed = subprocess.CompletedProcess([], 0, stdout=inventory)
        for responses in [[subprocess.TimeoutExpired('xcrun', 60)],
                          [listed, subprocess.TimeoutExpired('xcrun', 60)]]:
            with self.subTest(stage=len(responses)), mock.patch.object(
                    module.subprocess, 'run', side_effect=responses) as run:
                self.assertEqual(module.main(['--github-output', str(self.output)]), 124)
                self.assertEqual(run.call_count, len(responses))
                self.assertEqual([c.kwargs['timeout'] for c in run.call_args_list], [300, 60][:len(responses)])
                self.assertFalse(self.output.exists())


class SimulatorWorkflowTests(unittest.TestCase):
    def test_actual_ui_shell_body_stops_before_tests_when_readiness_fails(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        step = workflow.split('      - name: iOS navigation and banner regression tests\n', 1)[1]
        step = step.split('      - name: Save iOS layout screenshots and test results', 1)[0]
        body = textwrap.dedent(step.split('        run: |\n', 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Scripts').mkdir()
            fake = root / 'xcrun'
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*" > "$SIM_CALLS"\nexit "$SIM_FAIL_STATUS"\n')
            fake.chmod(0o755)
            wrapper = root / 'Scripts/test-ios-layout.sh'
            wrapper.write_text('#!/bin/sh\nprintf "%s\\n" "$B4APP_LAYOUT_DESTINATION" > ran-tests\n')
            wrapper.chmod(0o755)
            for status in [0, 29]:
                with self.subTest(readiness_exit=status):
                    marker = root / 'ran-tests'
                    marker.unlink(missing_ok=True)
                    destination = f'platform=iOS Simulator,id={FIRST}'
                    env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                               SIM_CALLS=str(root / 'calls'), SIM_FAIL_STATUS=str(status),
                               B4APP_LAYOUT_SIMULATOR_UDID=FIRST, B4APP_LAYOUT_DESTINATION=destination)
                    result = subprocess.run(['bash', '-c', body], cwd=root, env=env,
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertEqual((root / 'calls').read_text().strip(), f'simctl bootstatus {FIRST} -b')
                    self.assertEqual(marker.exists(), status == 0)
                    if status == 0:
                        self.assertEqual(marker.read_text().strip(), destination)

    def test_boot_is_in_the_layout_job_and_exact_readiness_precedes_full_wrapper(self):
        # The layout tests run in their own job (D-197), so the boot no longer overlaps the app builds.
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        job = workflow.index('\n  ios-layout:')
        setup = workflow.index('python3 Scripts/prepare_ios_layout_simulator.py')
        readiness = workflow.index('xcrun simctl bootstatus "$B4APP_LAYOUT_SIMULATOR_UDID" -b')
        wrapper = workflow.index('./Scripts/test-ios-layout.sh -clonedSourcePackagesDirPath .spm')
        self.assertLess(job, setup)
        self.assertLess(setup, readiness)
        self.assertLess(readiness, wrapper)
        self.assertLess(wrapper, workflow.index('\n  hub:'))
        self.assertIn('B4APP_LAYOUT_SIMULATOR_UDID: ${{ steps.simulator.outputs.udid }}', workflow)
        self.assertIn('B4APP_LAYOUT_DESTINATION: ${{ steps.simulator.outputs.destination }}', workflow)
        self.assertIn('set -euo pipefail\n          xcrun simctl bootstatus', workflow)
        self.assertIn('timeout-minutes: 40', workflow[job:])

if __name__ == '__main__':
    unittest.main()
