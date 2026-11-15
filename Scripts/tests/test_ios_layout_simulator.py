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
    def run_wrapper(self, statuses):
        """The real wrapper with fake tools; `statuses` maps a tool call's first words to its exit."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = root / 'calls'
            for tool in ['xcodebuild', 'xcrun', 'xcodegen']:
                fake = root / tool
                fake.write_text('#!/bin/sh\n'
                                'case "$*" in *test-without-building*) key=test;; *build-for-testing*) key=build;;\n'
                                '  *bootstatus*) key=bootstatus;; *) key=other;; esac\n'
                                f'printf "%s %s\\n" {tool} "$key" >> "$SIM_CALLS"\n'
                                'eval "exit \\${STATUS_$key:-0}"\n')
                fake.chmod(0o755)
            env = {k: v for k, v in os.environ.items() if k not in ('CI', 'B4APP_LAYOUT_SHARD')}
            env.update(PATH=str(root) + os.pathsep + env['PATH'], SIM_CALLS=str(calls),
                       B4APP_LAYOUT_SIMULATOR_UDID=FIRST, B4APP_LAYOUT_RESULTS=str(root / 'none.xcresult'),
                       B4APP_LAYOUT_DESTINATION=f'platform=iOS Simulator,id={FIRST}',
                       **{f'STATUS_{key}': str(value) for key, value in statuses.items()})
            result = subprocess.run(['/bin/sh', str(ROOT / 'Scripts/test-ios-layout.sh')], env=env,
                                    capture_output=True, text=True, timeout=30)
            return result, calls.read_text().split('\n')[:-1]

    def test_the_wrapper_builds_then_waits_for_the_boot_then_tests(self):
        # The fake test run fails with 7, so the wrapper stops before it reads a result bundle.
        result, calls = self.run_wrapper({'test': 7})
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(calls, ['xcodegen other', 'xcodebuild build', 'xcrun bootstatus', 'xcodebuild test'])

    def test_no_test_runs_when_the_boot_does_not_finish_or_the_build_fails(self):
        result, calls = self.run_wrapper({'bootstatus': 29})
        self.assertEqual(result.returncode, 29, result.stderr)
        self.assertEqual(calls, ['xcodegen other', 'xcodebuild build', 'xcrun bootstatus'])
        result, calls = self.run_wrapper({'build': 65})
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual(calls, ['xcodegen other', 'xcodebuild build'])

    def test_boot_begins_before_the_wrapper_which_is_told_which_simulator_to_wait_for(self):
        # The boot begins in its own step and the wrapper builds while it runs (D-232); the wrapper
        # waits for it, so the workflow no longer does.
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        job = workflow.index('\n  ios-layout:')
        setup = workflow.index('python3 Scripts/prepare_ios_layout_simulator.py')
        wrapper = workflow.index('run: ./Scripts/test-ios-layout.sh -clonedSourcePackagesDirPath .spm')
        self.assertLess(job, setup)
        self.assertLess(setup, wrapper)
        self.assertLess(wrapper, workflow.index('\n  hub:'))
        self.assertNotIn('simctl bootstatus', workflow)
        self.assertIn('B4APP_LAYOUT_SIMULATOR_UDID: ${{ steps.simulator.outputs.udid }}', workflow)
        self.assertIn('B4APP_LAYOUT_DESTINATION: ${{ steps.simulator.outputs.destination }}', workflow)
        self.assertIn('timeout-minutes: 30', workflow[job:])

    def test_both_shards_run_and_the_required_check_needs_them(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        shards = workflow[workflow.index('\n  ios-layout:'):workflow.index('\n  ios-layout-result:')]
        plan = json.loads((ROOT / 'Tests/iOSLayout/UITests/shards.json').read_text())
        numbers = ', '.join(str(n) for n in range(1, len(plan['shards']) + 1))
        self.assertIn(f'shard: [{numbers}]', shards)
        self.assertIn('fail-fast: false', shards)
        self.assertIn('B4APP_LAYOUT_SHARD: ${{ matrix.shard }}', shards)
        self.assertNotIn('B4APP_LAYOUT_EXPECTED', shards)
        result = workflow[workflow.index('\n  ios-layout-result:'):workflow.index('\n  macos-smoke:')]
        # The name the branch protection requires, on a job that cannot be skipped.
        self.assertIn('name: iOS navigation and banner regression tests\n', result)
        self.assertIn('needs: [scope, ios-layout]\n', result)
        # The one skip it accepts is the scope job's explicit "false" (test_ci_scope.py).
        self.assertIn('if [ "$APPLE" = false ] && [ "$SHARDS" = skipped ]; then', result)
        self.assertIn('if: always()\n', result)
        self.assertIn('test "$SHARDS" = success', result)

if __name__ == '__main__':
    unittest.main()
