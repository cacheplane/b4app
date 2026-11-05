"""Isolated runner fixtures; these are not Swift integration or hosted CI results."""
import errno
import importlib.util
import json
import os
import pathlib
import re
import signal
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parents[3] / 'Scripts' / 'test-swift.py'


class SwiftPartitionsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('ci_swift', SCRIPT)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def inventory(self):
        return [suite + '/example()' for suite in self.module.ISOLATED_SUITES] + [
            'OtherTests.OtherSuite/parameterized(_:)',
            'WorkspaceUITests.AttentionModelTestsExtra/staysInRemainder()',
        ]

    def test_discovery_rejects_empty_malformed_and_duplicate_ids(self):
        for text in ['', 'unexpected diagnostic\n', 'A.B/test()\nA.B/test()\n']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.module.parse_inventory(text)

    def test_exact_boundaries_and_complete_disjoint_inventory(self):
        ids = self.inventory()
        plan = self.module.make_plan(ids)
        self.assertEqual(len(plan), 7)
        self.assertEqual([len(p['ids']) for p in plan], [1, 1, 1, 1, 1, 2, 2])
        self.assertIn(ids[-1], plan[-1]['ids'])
        self.assertEqual(sorted(x for p in plan for x in p['ids']), sorted(ids))

    def test_coordinator_hello_suites_share_one_exact_group(self):
        expected = ['CoordinatorTests.HubSyncTests/example()',
                    'CoordinatorTests.LegacySecretCopyTests/example()']
        ids = self.inventory()
        ids += [x for x in expected if x not in ids]
        extra = 'CoordinatorTests.HubSyncTestsExtra/staysInRemainder()'
        ids.append(extra)
        plan = self.module.make_plan(ids)
        groups = [p for p in plan if p['name'] == 'coordinator-hello']
        self.assertEqual([sorted(p['ids']) for p in groups], [sorted(expected)])
        self.assertIn(extra, plan[-1]['ids'])

    def test_client_cancellation_suite_has_its_own_exact_partition(self):
        suite = 'WorkspaceClientTests.WorkspaceClientTests'
        target = suite + '/example()'
        lookalike = suite + 'Extra/staysInRemainder()'
        ids = self.inventory()
        if target not in ids:
            ids.append(target)
        ids.append(lookalike)
        plan = self.module.make_plan(ids)
        groups = [part for part in plan if part['name'] == suite]
        self.assertEqual([part['ids'] for part in groups], [[target]])
        self.assertIn(lookalike, plan[-1]['ids'])

    def test_plan_rejects_overlap_omission_empty_and_selector_mismatch(self):
        ids = self.inventory()
        import copy
        for mutation in ['overlap', 'omission', 'empty', 'selector']:
            plan = copy.deepcopy(self.module.make_plan(ids))
            if mutation == 'overlap':
                plan[-1]['ids'].append(plan[0]['ids'][0])
            elif mutation == 'omission':
                plan[-1]['ids'].pop()
            elif mutation == 'empty':
                plan[0]['ids'] = []
            else:
                plan[0]['selector'] = '.*'
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.module.validate_plan(ids, plan)

    def test_terminal_failure_measurements_survive_but_empty_reports_fail(self):
        for text in ['Executed 0 tests, with 0 failures',
                     'Test run with 0 tests in 0 suites passed after 0.001 seconds.']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.module.parse_summary(text)
        self.assertEqual(self.module.parse_summary(
            'Test run with 1 test in 1 suite passed after 0.001 seconds.')['tests'], 1)
        failed = self.module.parse_summary('Test run with 2 tests in 1 suite failed after 0.25 seconds.')
        self.assertEqual(failed['tests'], 2)
        self.assertEqual(failed['library_seconds'], 0.25)
        self.assertEqual(failed['library_result'], 'failed')

    def pipeline(self, bad=None, args=None):
        calls = []
        ids = self.inventory()

        def runner(command, timeout, log):
            calls.append(command)
            if command[-1] == 'list':
                text = '\n'.join(ids) + '\n'
            else:
                selection = '--filter' if '--filter' in command else '--skip'
                pattern = command[command.index(selection) + 1]
                selected = [x for x in ids if bool(re.search(pattern, x)) == (selection == '--filter')]
                text = (f'Test run with {len(selected)} tests in '
                        f'{len({x.split("/")[0] for x in selected})} suites passed after 0.001 seconds.')
                if len(calls) == 2 and bad == 'missing':
                    text = 'runner exited without a Swift Testing report'
                if len(calls) == 2 and bad == 'count':
                    text = 'Test run with 2 tests in 1 suite passed after 0.001 seconds.'
                if len(calls) == 2 and bad == 'report-failed':
                    text = text.replace('passed', 'failed')
            return {'command': command, 'stdout': text, 'exit_code': 1 if len(calls) == 2 and bad == 'exit' else 0,
                    'wall_seconds': 0.001, 'timed_out': False}

        with tempfile.TemporaryDirectory() as tmp:
            result = self.module.run_pipeline(args or [], pathlib.Path(tmp), runner=runner)
            summary = json.loads((pathlib.Path(tmp) / 'summary.json').read_text())
        return result, calls, summary

    def test_child_failure_propagates_and_remaining_partitions_still_execute(self):
        for bad in ['exit', 'report-failed']:
            result, calls, summary = self.pipeline(bad)
            self.assertEqual(result, 1)
            self.assertEqual(len(calls), 8)
            self.assertEqual(summary['reported_tests'], len(self.inventory()))
            self.assertEqual(summary['missing_report_partitions'], 0)

    def test_missing_report_or_count_mismatch_fails_closed_and_runs_remainder(self):
        for bad in ['missing', 'count']:
            result, calls, _ = self.pipeline(bad)
            self.assertEqual(result, 1)
            self.assertEqual(len(calls), 8)

    def test_identical_build_flags_and_dynamic_new_tests_are_preserved(self):
        flags = ['--scratch-path', '/tmp/example', '--jobs', '2']
        result, calls, _ = self.pipeline(args=flags)
        self.assertEqual(result, 0)
        self.assertEqual(len(calls), 8)
        for command in calls:
            self.assertEqual(command[:2 + len(flags)], ['swift', 'test', *flags])
        self.assertEqual(calls[0][-1], 'list')
        self.assertTrue(all('--skip-build' in command for command in calls[1:]))

    def test_watchdog_terminates_its_owned_child(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.module.run_command(
                [sys.executable, '-c', 'import time; time.sleep(30)'], 0.05,
                pathlib.Path(tmp) / 'child.log')
        self.assertTrue(result['timed_out'])
        self.assertNotEqual(result['exit_code'], 0)

    def test_signal_permission_failure_is_reported_without_losing_the_result(self):
        real_killpg = os.killpg
        owned_pids = []

        def deny_kill(pid, sig):
            owned_pids.append(pid)
            if sig == signal.SIGKILL:
                raise PermissionError(errno.EPERM, 'injected signal denial')
            return real_killpg(pid, sig)

        result = None
        with tempfile.TemporaryDirectory() as tmp:
            try:
                with mock.patch.object(self.module.os, 'killpg', side_effect=deny_kill):
                    result = self.module.run_command(
                        [sys.executable, '-c', 'import time; time.sleep(30)'], 1,
                        pathlib.Path(tmp) / 'denied.log')
                self.assertTrue(result['timed_out'])
                self.assertNotEqual(result['exit_code'], 0)
                self.assertIn('SIGKILL', result['cleanup_error'])
                self.assertIn('injected signal denial', result['cleanup_error'])
            finally:
                # The injected denial leaves only our supervised group alive. Dispose it using
                # the real signal function, and reap this test's own session leader.
                if owned_pids:
                    pid = owned_pids[-1]
                    try:
                        real_killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        os.waitpid(pid, 0)
                    except ChildProcessError:
                        pass

    def test_discovery_stdout_is_not_contaminated_by_build_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.module.run_command(
                [sys.executable, '-c',
                 'import sys; print("A.B/example()"); print("[0/1] Planning build", file=sys.stderr)'],
                5, pathlib.Path(tmp) / 'discovery.log')
        self.assertEqual(result['stdout'], 'A.B/example()\n')
        self.assertIn('Planning build', result['stderr'])

    def test_watchdog_cleans_descendant_after_leader_exits_on_term(self):
        child = ('import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                 'print("descendant-ready", flush=True); time.sleep(30)')
        parent = ('import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",sys.argv[1]]); '
                  'time.sleep(30)')
        with tempfile.TemporaryDirectory() as tmp:
            result = self.module.run_command(
                [sys.executable, '-c', parent, child], 1, pathlib.Path(tmp) / 'descendant.log')
            try:
                self.assertIn('descendant-ready', result['stdout'])
                self.assertTrue(result['timed_out'])
                self.assertTrue(result['output_closed'])
            finally:
                if not result['output_closed']:
                    # Dispose only this test's still-open process group after the red control.
                    try:
                        os.killpg(result['pid'], signal.SIGKILL)
                    except ProcessLookupError:
                        pass
