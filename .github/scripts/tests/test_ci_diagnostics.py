"""Numeric diagnostic controls, not hosted runtime evidence."""
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DiagnosticTests(unittest.TestCase):
    def test_helper_reports_resources_and_observed_exit_tail_without_masking_failure(self):
        helper = load('diagnostic_helper', ROOT / 'Scripts/test-swift.py')
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, B4APP_CI_DIAGNOSTICS='1'):
            result = helper.run_command(
                [sys.executable, '-c', 'import sys; print("Test run with 1 test in 1 suite passed after 0.001 seconds.", flush=True); sys.exit(7)'],
                5, Path(tmp) / 'child.log')
        self.assertEqual(result['exit_code'], 7)
        self.assertGreaterEqual(result['command_resources']['user_seconds'], 0)
        self.assertEqual(result['observed_completion_report_count'], 1)
        self.assertIsNotNone(result['observed_report_to_exit_seconds'])

    def test_vm_stat_has_explicit_page_units_and_unknown_fields_stay_absent(self):
        module = load('numeric_diag', ROOT / '.github/scripts/ci-diagnostics.py')
        parsed = module.parse_vm_stat('Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 12.\nPageouts: 3.\nSECRET=never-log\n')
        self.assertEqual(parsed, {'page_bytes': 16384, 'Pages free': 12, 'Pageouts': 3})

    def test_process_snapshot_emits_only_owned_numeric_roles(self):
        module = load('numeric_diag', ROOT / '.github/scripts/ci-diagnostics.py')
        text = '10 1 1.0 100 /usr/bin/time\n11 10 95.0 200 /tool/swift-frontend\n12 99 40.0 900 /private/SECRET\n'
        result = module.parse_processes(text, 10)
        self.assertEqual(result['compiler']['count'], 1)
        self.assertEqual(result['compiler']['max_rss_kib'], 200)
        self.assertNotIn('SECRET', json.dumps(result))
        self.assertNotIn('private', json.dumps(result))

    def test_primary_exit_survives_diagnostic_failure(self):
        module = load('numeric_diag', ROOT / '.github/scripts/ci-diagnostics.py')
        with mock.patch.object(module, 'sample', side_effect=RuntimeError('SECRET')), mock.patch('sys.stdout', new_callable=io.StringIO) as output:
            result = module.observe_command([sys.executable, '-c', 'import time; time.sleep(.1); raise SystemExit(9)'], 'fixture', enabled=True, interval=.01)
        self.assertEqual(result, 9)
        self.assertNotIn('SECRET', output.getvalue())
        self.assertIn('CI_DIAGNOSTIC_ERROR', output.getvalue())

    def test_disabled_observer_does_not_run_probes(self):
        module = load('numeric_diag', ROOT / '.github/scripts/ci-diagnostics.py')
        with mock.patch.object(module, 'sample') as probe:
            self.assertEqual(module.observe_command([sys.executable, '-c', 'pass'], 'fixture', enabled=False), 0)
        probe.assert_not_called()

    def test_resource_collection_error_does_not_replace_primary_status(self):
        helper = load('failed_resource_helper', ROOT / 'Scripts/test-swift.py')
        helper.SUPERVISOR = helper.SUPERVISOR.replace(
            'signal.signal(',
            'resource.getrusage = lambda *_: (_ for _ in ()).throw(OSError("PRIVATE"))\nsignal.signal(', 1)
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, B4APP_CI_DIAGNOSTICS='1'):
            result = helper.run_command([sys.executable, '-c', 'pass'], 5, Path(tmp) / 'child.log')
        self.assertEqual(result['exit_code'], 0)
        self.assertEqual(result['resource_error'], 'OSError')
        self.assertNotIn('PRIVATE', json.dumps(result))

    def test_empty_machine_output_is_not_a_valid_zero_sample(self):
        module = load('missing_machine_fields', ROOT / '.github/scripts/ci-diagnostics.py')
        with mock.patch.object(module, 'probe', side_effect=['10 1 0.0 100 /usr/bin/time\n', 'bad VM output', 'bad disk output']):
            result = module.sample(10)
        self.assertEqual(result['process_status'], 'ok')
        self.assertEqual(result['vm_status'], 'parse_empty')
        self.assertEqual(result['disk_status'], 'parse_empty')
        self.assertEqual(result['vm_pages'], {})
        self.assertEqual(result['system_disk_cumulative'], {})
