"""Isolated API fixtures; these are not hosted CI or release observations."""
import copy
import importlib.util
import pathlib
import json
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'ci-observations.py'


def fixture(attempt=1, status='completed', conclusion='success'):
    run = dict(id=10, run_attempt=attempt, head_sha='a' * 40, path='.github/workflows/ci.yml',
               event='push', status=status, conclusion=conclusion,
               created_at='2026-11-02T10:00:00Z', run_started_at='2026-11-02T10:00:05Z',
               updated_at='2026-11-02T12:00:00Z', html_url='https://github.com/example/repo/actions/runs/10')
    job = dict(id=100 + attempt, run_id=10, head_sha='a' * 40, name='native', labels=['macos-26'],
               status=status, conclusion=conclusion, started_at='2026-11-02T10:00:10Z',
               completed_at='2026-11-02T10:01:10Z' if status == 'completed' else None,
               steps=[dict(number=1, name='Build', status=status, conclusion=conclusion,
                           started_at='2026-11-02T10:00:20Z',
                           completed_at='2026-11-02T10:01:00Z' if status == 'completed' else None)])
    return dict(run=run, jobs=[job], jobs_total_count=1)


def packet(*attempts):
    return dict(schema_version=1, evidence_mode='simulated', repository='example/repo',
                collected_at='2026-11-02T12:00:00Z', selected_runs=[copy.deepcopy(attempts[-1]['run'])] if attempts else [],
                attempts=list(attempts), selection_total_count=1 if attempts else 0, selection_limit=1)


class ObservationsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert SCRIPT.exists(), 'missing read-only attempt collector'
        spec = importlib.util.spec_from_file_location('observations', SCRIPT)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_named_boundaries_not_updated_at(self):
        report = self.module.report(packet(fixture()))
        run = report['attempts'][0]
        self.assertEqual(run['attempt_creation_to_last_job_end_seconds'], 70)
        self.assertEqual(run['job_seconds_by_runner'], {'macos-26': 60})
        self.assertEqual(run['jobs'][0]['steps'][0]['seconds'], 40)
        self.assertIsNone(run['workflow_completion_at'])
        self.assertIsNone(run['accepted_availability_at'])
        self.assertIsNone(run['trigger_at'])
        self.assertIsNone(run['pipeline_revision'])

    def test_retains_failed_and_cancelled_and_running(self):
        for status, conclusion in [('completed', 'failure'), ('completed', 'cancelled'),
                                   ('in_progress', None), ('queued', None)]:
            with self.subTest(status=status, conclusion=conclusion):
                result = self.module.report(packet(fixture(status=status, conclusion=conclusion)))
                self.assertEqual(result['attempts'][0]['conclusion'], conclusion)
                if status != 'completed':
                    self.assertIsNone(result['attempts'][0]['attempt_creation_to_last_job_end_seconds'])

    def test_retry_is_not_a_new_intent_or_first_pass_success(self):
        first = fixture(conclusion='failure')
        second = fixture(attempt=2)
        result = self.module.report(packet(first, second))
        self.assertEqual(len(result['attempts']), 2)
        self.assertEqual(result['attempts'][1]['retry_of_attempt'], 1)
        self.assertIsNone(result['attempts'][1]['intent_id'])
        self.assertEqual(result['attempts'][0]['conclusion'], 'failure')

    def test_missing_attempt_rejected(self):
        value = packet(fixture(attempt=2))
        value['selected_runs'][0]['run_attempt'] = 2
        with self.assertRaisesRegex(ValueError, 'attempt'):
            self.module.report(value)

    def test_invalid_evidence_rejected(self):
        for change in ['missing job', 'duplicate job', 'negative time', 'wrong source', 'bad timestamp']:
            value = packet(fixture())
            entry = value['attempts'][0]
            if change == 'missing job':
                entry['jobs'] = []
            elif change == 'duplicate job':
                entry['jobs'].append(copy.deepcopy(entry['jobs'][0]))
                entry['jobs_total_count'] = 2
            elif change == 'negative time':
                entry['jobs'][0]['completed_at'] = '2026-11-02T09:00:00Z'
            elif change == 'wrong source':
                entry['jobs'][0]['head_sha'] = 'b' * 40
            else:
                entry['run']['created_at'] = 'not a time'
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.module.report(value)

    def test_skipped_missing_time_is_unknown_not_zero(self):
        value = packet(fixture())
        job = value['attempts'][0]['jobs'][0]
        job.update(conclusion='skipped', started_at=None, completed_at=None)
        result = self.module.report(value)['attempts'][0]
        self.assertIsNone(result['attempt_creation_to_last_job_end_seconds'])
        self.assertEqual(result['job_seconds_by_runner'], {})
        self.assertEqual(result['unknown_job_durations'], 1)

    def test_paginated_collection_includes_every_job_and_attempt(self):
        calls = []
        def get(endpoint):
            calls.append(endpoint)
            if '/attempts/' not in endpoint:
                return {'workflow_runs': [fixture(attempt=2)['run']], 'total_count': 1}
            n = int(endpoint.split('/attempts/')[1].split('/')[0])
            if '/jobs?' not in endpoint:
                return fixture(attempt=n)['run']
            if 'page=2' in endpoint:
                job = fixture(attempt=n)['jobs'][0]
                job['id'] = 1000 + n
                return {'total_count': 101, 'jobs': [job]}
            jobs = []
            for i in range(100):
                job = copy.deepcopy(fixture(attempt=n)['jobs'][0])
                job['id'] = n * 10000 + i
                jobs.append(job)
            return {'total_count': 101, 'jobs': jobs}
        value = self.module.collect('example/repo', 'ci.yml', 1, get)
        self.assertEqual([len(x['jobs']) for x in value['attempts']], [101, 101])
        self.module.report(value)
        self.assertTrue(all(x.startswith('repos/example/repo/actions/') for x in calls))

    def test_carried_forward_jobs_do_not_inflate_retry_compute(self):
        first, second = fixture(conclusion='failure'), fixture(attempt=2)
        second['run']['created_at'] = '2026-11-02T11:00:00Z'
        second['run']['run_started_at'] = '2026-11-02T11:00:00Z'
        result = self.module.report(packet(first, second))['attempts'][1]
        self.assertEqual(result['job_seconds_by_runner'], {})
        self.assertEqual(result['carried_job_seconds_by_runner'], {'macos-26': 60})
        self.assertEqual(result['jobs'][0]['execution_relation'], 'predates_attempt')
        self.assertIsNone(result['attempt_creation_to_last_job_end_seconds'])

    def test_empty_or_mismatched_snapshot_rejected(self):
        for value in [packet(), packet(fixture())]:
            if value['attempts']:
                value['selected_runs'][0]['head_sha'] = 'b' * 40
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.module.report(value)

    def test_unknown_result_is_malformed_not_success(self):
        value = packet(fixture())
        value['attempts'][0]['jobs'][0]['conclusion'] = 'greenish'
        with self.assertRaises(ValueError):
            self.module.report(value)

    def test_request_budget_is_enforced(self):
        calls = []
        def get(endpoint):
            calls.append(endpoint)
            if '/attempts/' not in endpoint:
                return {'workflow_runs': [fixture(attempt=100)['run']], 'total_count': 1}
            n = int(endpoint.split('/attempts/')[1].split('/')[0])
            if '/jobs?' in endpoint:
                return {'total_count': 1, 'jobs': fixture(attempt=n)['jobs']}
            return fixture(attempt=n)['run']
        with self.assertRaisesRegex(ValueError, 'request budget'):
            self.module.collect('example/repo', 'ci.yml', 1, get)
        self.assertEqual(len(calls), 100)

    def test_missing_late_job_start_cannot_shorten_span(self):
        value = packet(fixture())
        late = copy.deepcopy(value['attempts'][0]['jobs'][0])
        late.update(id=999, started_at=None, completed_at='2026-11-02T11:00:00Z')
        value['attempts'][0]['jobs'].append(late)
        value['attempts'][0]['jobs_total_count'] = 2
        result = self.module.report(value)['attempts'][0]
        self.assertIsNone(result['attempt_creation_to_last_job_end_seconds'])

    def test_original_creation_survives_retry_endpoint_creation(self):
        first, second = fixture(conclusion='failure'), fixture(attempt=2)
        second['run'].update(created_at='2026-11-02T10:02:00Z', run_started_at='2026-11-02T10:02:00Z')
        second['jobs'][0].update(started_at='2026-11-02T10:02:10Z', completed_at='2026-11-02T10:03:00Z')
        result = self.module.report(packet(first, second))['attempts'][1]
        self.assertEqual(result['attempt_creation_to_last_job_end_seconds'], 60)
        self.assertEqual(result['run_creation_to_last_job_end_seconds'], 180)

    def test_completed_result_without_conclusion_or_steps_rejected(self):
        for field in ['conclusion', 'steps']:
            value = packet(fixture())
            if field == 'conclusion':
                value['attempts'][0]['jobs'][0][field] = None
            else:
                del value['attempts'][0]['jobs'][0][field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.module.report(value)

    def test_truncated_selection_rejected(self):
        def get(_):
            return {'workflow_runs': [fixture()['run']], 'total_count': 8}
        with self.assertRaisesRegex(ValueError, 'incomplete run selection'):
            self.module.collect('example/repo', 'ci.yml', 8, get)

    def test_holdout_failed_attempt_then_partial_rerun_with_skipped_native(self):
        first, second = fixture(conclusion='failure'), fixture(attempt=2, conclusion='skipped')
        second['run'].update(created_at='2026-11-02T10:02:00Z', run_started_at='2026-11-02T10:02:00Z')
        second['jobs'][0].update(started_at=None, completed_at=None, steps=[])
        result = self.module.report(packet(first, second))
        self.assertEqual([a['conclusion'] for a in result['attempts']], ['failure', 'skipped'])
        self.assertIsNone(result['attempts'][1]['accepted_availability_at'])
        self.assertIsNone(result['attempts'][1]['run_creation_to_last_job_end_seconds'])
        self.assertEqual(result['attempts'][1]['unknown_job_durations'], 1)

    def test_cli_replay_failure_and_existing_output_preservation(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / 'capture.json'
            output.write_text('keep existing evidence')
            result = subprocess.run([sys.executable, str(SCRIPT), 'collect', '--repo',
                                     'example/repo', '--output', str(output)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_text(), 'keep existing evidence')
            self.assertEqual(result.stdout, '')
            output.write_text(json.dumps(packet(fixture())))
            result = subprocess.run([sys.executable, str(SCRIPT), 'report', str(output)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['attempt_count'], 1)
            output.write_text('{malformed')
            result = subprocess.run([sys.executable, str(SCRIPT), 'report', str(output)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')

    def test_api_failure_never_becomes_empty_success(self):
        def fail(_):
            raise RuntimeError('API unavailable')
        with self.assertRaisesRegex(RuntimeError, 'API unavailable'):
            self.module.collect('example/repo', 'ci.yml', 8, fail)


if __name__ == '__main__':
    unittest.main()
