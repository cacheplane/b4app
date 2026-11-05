"""Opt-in compiler tracing must preserve strict inventory and the aggregate deadline."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
FLAGS = ['--verbose', '-Xswiftc', '-driver-show-incremental', '-Xswiftc', '-driver-show-job-lifecycle']


def load():
    spec = importlib.util.spec_from_file_location('compiler_trace_helper', ROOT / 'Scripts/test-swift.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    return helper


class CompilerTraceTests(unittest.TestCase):
    def invoke(self, *args):
        helper = load()
        with mock.patch.object(sys, 'argv', ['test-swift.py', *args]), mock.patch.object(helper, 'run_pipeline', return_value=0) as run:
            self.assertEqual(helper.main(), 0)
        return run.call_args

    def test_default_has_no_trace_prebuild(self):
        call = self.invoke()
        self.assertEqual(call.args[0], [])
        self.assertFalse(call.kwargs['trace_build'])

    def test_trace_is_opt_in_and_does_not_become_a_swift_argument(self):
        call = self.invoke('--trace-build', '--jobs', '2', '--only-use-versions-from-resolved-file')
        self.assertTrue(call.kwargs['trace_build'])
        self.assertEqual(call.args[0], ['--jobs', '2', '--only-use-versions-from-resolved-file'])

    def pipeline(self, fail_prebuild=False):
        helper = load()
        inventory = [s + '/example()' for s in helper.ISOLATED_SUITES] + ['OtherTests.Suite/example()']
        calls = []

        def runner(command, timeout, log):
            calls.append((command, timeout))
            if command[:2] == ['swift', 'build']:
                text = 'compiler diagnostics are not inventory\n'
                code = 9 if fail_prebuild is True else 0
            elif command[-1] == 'list':
                text = '\n'.join(inventory) + '\n'
                code = 0
            else:
                selection = '--filter' if '--filter' in command else '--skip'
                pattern = command[command.index(selection) + 1]
                selected = [x for x in inventory if bool(re.search(pattern, x)) == (selection == '--filter')]
                text = f'Test run with {len(selected)} tests in 1 suite passed after 0.001 seconds.'
                code = 0
            row = {'stdout': text, 'exit_code': code, 'timed_out': False, 'output_closed': True, 'wall_seconds': .001}
            if command[:2] == ['swift', 'build'] and isinstance(fail_prebuild, str):
                row[fail_prebuild] = False if fail_prebuild == 'output_closed' else True
            return row

        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            result = helper.run_pipeline(['--jobs', '2'], Path(tmp), runner=runner, budget_seconds=12, trace_build=True)
            summary = json.loads((Path(tmp) / 'summary.json').read_text())
        return helper, result, calls, summary

    def test_prebuild_uses_same_options_and_plain_inventory_with_existing_deadline(self):
        helper, result, calls, summary = self.pipeline()
        self.assertEqual(result, 0)
        self.assertEqual(len(calls), 9)
        self.assertEqual(calls[0][0], ['swift', 'build', '--jobs', '2', '--build-tests', *FLAGS])
        self.assertEqual(calls[1][0], ['swift', 'test', '--jobs', '2', '--skip-build', 'list'])
        self.assertEqual(summary['budget_seconds'], 12)
        self.assertEqual(helper.TOTAL_BUDGET_SECONDS, 35 * 60)
        self.assertTrue(summary['complete'])
        for command, timeout in calls[1:]:
            self.assertIn('--skip-build', command)
            self.assertNotIn('--verbose', command)
            self.assertLessEqual(timeout, 12)

    def test_failed_prebuild_is_not_accepted_or_followed_by_discovery(self):
        for failure in [True, 'timed_out', 'output_closed', 'cleanup_error', 'supervisor_error']:
            with self.subTest(failure=failure):
                _, result, calls, summary = self.pipeline(fail_prebuild=failure)
                self.assertEqual(result, 1)
                self.assertEqual(len(calls), 1)
                self.assertFalse(summary['passed'])
                self.assertFalse(summary['complete'])
                self.assertEqual(summary['compilation']['exit_code'], 9 if failure is True else 0)
                self.assertIn('compilation', summary['error'])
