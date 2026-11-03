#!/usr/bin/env python3
"""Read-only, bounded GitHub Actions observation capture and offline replay.

No release acceptance is inferred. Only allowlisted API metadata is retained;
logs, actors, credentials, titles and commit messages are not collected.
"""
import argparse
import datetime as dt
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import quote

RUN_FIELDS = ('id', 'run_attempt', 'head_sha', 'path', 'event', 'status', 'conclusion',
              'created_at', 'run_started_at', 'updated_at', 'html_url')
JOB_FIELDS = ('id', 'run_id', 'head_sha', 'name', 'labels', 'status', 'conclusion',
              'started_at', 'completed_at', 'html_url')
STEP_FIELDS = ('number', 'name', 'status', 'conclusion', 'started_at', 'completed_at')


def keep(value, fields):
    return {key: value.get(key) for key in fields}


def timestamp(value):
    if value is None:
        return None
    parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('timestamp lacks timezone')
    return parsed


def seconds(start, end):
    start, end = timestamp(start), timestamp(end)
    if start is None or end is None:
        return None
    result = (end - start).total_seconds()
    if result < 0:
        raise ValueError('negative time interval')
    return result


def positive(value):
    return type(value) is int and value > 0


def validate_result(value):
    statuses = {'queued', 'in_progress', 'completed', 'waiting', 'pending', 'requested'}
    conclusions = {None, 'success', 'failure', 'neutral', 'cancelled', 'skipped',
                   'timed_out', 'action_required', 'stale', 'startup_failure'}
    if (value['status'] not in statuses or value['conclusion'] not in conclusions
            or (value['status'] == 'completed') != (value['conclusion'] is not None)):
        raise ValueError('malformed result status/conclusion')


def report(packet):
    """Reject incomplete observation sets; report missing timings as unknown."""
    if packet['schema_version'] != 1:
        raise ValueError('unsupported evidence schema')
    selected = packet['selected_runs']
    if len(selected) != min(packet['selection_limit'], packet['selection_total_count']):
        raise ValueError('incomplete run selection')
    if not selected:
        raise ValueError('empty observation selection')
    snapshots = {r['id']: r for r in selected}
    if len({r['id'] for r in selected}) != len(selected):
        raise ValueError('duplicate selected run')
    expected = set()
    for run in selected:
        if not positive(run['id']) or not positive(run['run_attempt']) or run['run_attempt'] > 100:
            raise ValueError('invalid selected run/attempt')
        expected.update((run['id'], n) for n in range(1, run['run_attempt'] + 1))
    seen, observations = set(), []
    identities = {}
    origins = {e['run']['id']: e['run'].get('created_at') for e in packet['attempts'] if e['run']['run_attempt'] == 1}
    for entry in packet['attempts']:
        run, jobs = entry['run'], entry['jobs']
        key = run['id'], run['run_attempt']
        if key in seen or key not in expected:
            raise ValueError('duplicate or unexpected attempt')
        seen.add(key)
        validate_result(run)
        snapshot = snapshots[run['id']]
        identity = (run['head_sha'], run['path'], run['event'])
        if identity != (snapshot['head_sha'], snapshot['path'], snapshot['event']):
            raise ValueError('attempt source/pipeline differs from snapshot')
        if run['id'] in identities and identities[run['id']] != identity:
            raise ValueError('source/pipeline identity changed between attempts')
        identities[run['id']] = identity
        if not re.fullmatch(r'[0-9a-f]{40}', run['head_sha'] or ''):
            raise ValueError('invalid source SHA')
        for field in ('created_at', 'run_started_at', 'updated_at'):
            timestamp(run.get(field))
        if entry['jobs_total_count'] != len(jobs):
            raise ValueError('incomplete job set')
        job_ids, totals, carried, unknown, normalized_jobs = set(), {}, {}, 0, []
        for job in jobs:
            validate_result(job)
            if job['id'] in job_ids:
                raise ValueError('duplicate job')
            job_ids.add(job['id'])
            if job['run_id'] != run['id'] or job['head_sha'] != run['head_sha']:
                raise ValueError('job belongs to wrong run/source')
            duration = seconds(job.get('started_at'), job.get('completed_at'))
            # Do not turn running jobs' partial intervals into completed resources.
            if job['status'] != 'completed':
                duration = None
            runner = ','.join(sorted(job.get('labels') or [])) or 'unknown'
            relation = 'unknown'
            if duration is None:
                unknown += 1
            elif run.get('run_started_at') is None:
                unknown += 1
            else:
                # Attempt endpoints can contain cloned prior jobs with new IDs.
                predates = timestamp(job['completed_at']) < timestamp(run['run_started_at'])
                relation = 'predates_attempt' if predates else 'within_attempt'
                bucket = carried if predates else totals
                bucket[runner] = bucket.get(runner, 0) + duration
            steps, numbers = [], set()
            if 'steps' not in job:
                raise ValueError('missing step inventory')
            for step in job['steps']:
                validate_result(step)
                if step['number'] in numbers:
                    raise ValueError('duplicate step')
                numbers.add(step['number'])
                interval = seconds(step.get('started_at'), step.get('completed_at'))
                steps.append(dict(step, seconds=interval if step['status'] == 'completed' else None))
            normalized_jobs.append(dict(job, seconds=duration, steps=steps, requiredness='unknown', execution_relation=relation))
        complete = (run['status'] == 'completed' and bool(jobs)
                    and all(j['status'] == 'completed' and j.get('completed_at') for j in jobs)
                    and all(j['execution_relation'] != 'unknown' for j in normalized_jobs))
        current_ends = [j['completed_at'] for j in normalized_jobs if j['execution_relation'] == 'within_attempt']
        last_end = max(current_ends, key=timestamp) if complete and current_ends else None
        observations.append(dict(
            run, intent_id=None, retry_of_attempt=run['run_attempt'] - 1 if run['run_attempt'] > 1 else None,
            pipeline_revision=None, pipeline_identity_limitation='head SHA/path observed; executed workflow/reusable revisions not resolved',
            trigger_at=None, workflow_completion_at=None, publication_at=None,
            accepted_availability_at=None, cache_state='unknown', artifact_lineage=None,
            run_created_at=origins.get(run['id']),
            attempt_creation_to_last_job_end_seconds=seconds(run.get('created_at'), last_end),
            run_creation_to_last_job_end_seconds=seconds(origins.get(run['id']), last_end),
            attempt_start_to_last_job_end_seconds=seconds(run.get('run_started_at'), last_end),
            last_observed_job_end_at=last_end, job_seconds_by_runner=totals,
            carried_job_seconds_by_runner=carried, unknown_job_durations=unknown, cost=None, jobs=normalized_jobs))
    if seen != expected:
        raise ValueError('missing attempt evidence')
    return dict(schema_version=1, evidence_mode=packet['evidence_mode'], repository=packet['repository'],
                collected_at=packet['collected_at'], selected_run_count=len(selected),
                attempt_count=len(observations), attempts=observations,
                limitations=['No release intents grouped or acceptance inferred.',
                             'Job intervals are not billing/CPU measurements; labels are not runner image versions.',
                             'Creation-to-job-end is not trigger-to-workflow-completion.',
                             'Partial reruns may reuse earlier jobs; this report does not certify their coverage.',
                             'Queue/dependency/approval intervals cannot be separated with these API fields.'])


def gh_get(endpoint):
    # Explicit GET and fixed endpoint construction: never dispatch, rerun, or mutate.
    result = subprocess.run(['gh', 'api', '--method', 'GET', endpoint], check=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
    return json.loads(result.stdout)


def collect(repo, workflow, limit, get=gh_get, selection=None):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ValueError('expected owner/repository')
    if not 1 <= limit <= 100:
        raise ValueError('limit must be 1..100')
    request_count = 0
    fetch = get
    def bounded_get(endpoint):
        nonlocal request_count
        if request_count >= 100:
            raise ValueError('API request budget exhausted; choose a smaller sample')
        request_count += 1
        return fetch(endpoint)
    get = bounded_get
    base = f'repos/{repo}/actions'
    if selection is None:
        selection = get(f'{base}/workflows/{quote(workflow, safe="")}/runs?per_page={limit}')
    selected = selection['workflow_runs'][:limit]
    if len(selected) != min(limit, selection['total_count']):
        raise ValueError('incomplete run selection page')
    packet = dict(schema_version=1, evidence_mode='actual-api', repository=repo,
                  collection_started_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                  selection='latest unfiltered runs at selection snapshot; attempts bounded by that snapshot',
                  selection_total_count=selection['total_count'], selection_limit=limit,
                  selected_runs=[keep(r, RUN_FIELDS) for r in selected], attempts=[])
    for selected_run in selected:
        if not positive(selected_run['id']) or not positive(selected_run['run_attempt']) or selected_run['run_attempt'] > 100:
            raise ValueError('invalid selected run/attempt')
        for attempt in range(1, selected_run['run_attempt'] + 1):
            endpoint = f'{base}/runs/{selected_run["id"]}/attempts/{attempt}'
            run = keep(get(endpoint), RUN_FIELDS)
            if (run['id'], run['run_attempt'], run['head_sha']) != (
                    selected_run['id'], attempt, selected_run['head_sha']):
                raise ValueError('attempt response differs from selected run')
            jobs, page, total = [], 1, None
            while True:
                response = get(f'{endpoint}/jobs?per_page=100&page={page}')
                if total is not None and total != response['total_count']:
                    raise ValueError('job set changed while collecting; recapture')
                total = response['total_count']
                batch = response['jobs']
                for job in batch:
                    jobs.append(dict(keep(job, JOB_FIELDS), steps=[keep(s, STEP_FIELDS) for s in job['steps']]))
                if len(jobs) >= total:
                    break
                if not batch:
                    raise ValueError('incomplete jobs pagination')
                page += 1
            packet['attempts'].append(dict(run=run, jobs=jobs, jobs_total_count=total))
    packet['api_request_count'] = request_count
    packet['collected_at'] = dt.datetime.now(dt.timezone.utc).isoformat()
    report(packet)  # No success-shaped output on malformed or incomplete evidence.
    return packet


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    capture = commands.add_parser('collect', help='Read metadata using gh GET only; creates a new local file')
    capture.add_argument('--repo', required=True)
    capture.add_argument('--workflow', default='ci.yml')
    capture.add_argument('--limit', type=int, default=8)
    capture.add_argument('--selection', type=Path, help='Previously saved workflow-runs API response; freezes population')
    capture.add_argument('--output', type=Path, required=True)
    replay = commands.add_parser('report', help='Offline JSON report; no network calls')
    replay.add_argument('input', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'report':
            print(json.dumps(report(json.loads(args.input.read_text())), indent=2))
        else:
            # Refuse replacement before any API request; preserve older evidence.
            if args.output.exists():
                raise ValueError('output exists; use a new capture path')
            selection = json.loads(args.selection.read_text()) if args.selection else None
            packet = collect(args.repo, args.workflow, args.limit, selection=selection)
            with args.output.open('x') as output:
                output.write(json.dumps(packet, indent=2) + '\n')
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        # Do not print gh stderr, response bodies or environment values.
        parser.exit(1, f'observation capture/report failed ({type(error).__name__}): '
                       + (str(error) if isinstance(error, ValueError) else 'check schema, local paths and gh read access') + '\n')


if __name__ == '__main__':
    main()
