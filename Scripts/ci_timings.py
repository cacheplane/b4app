#!/usr/bin/env python3
"""Where a CI run's time went: one row per job of each attempt, and the clocks derived from them.

    Scripts/ci_timings.py collect --limit 40 > observations.json    # reads GitHub through `gh`
    Scripts/ci_timings.py summarize observations.json               # one line per attempt, then medians
    Scripts/ci_timings.py steps observations.json --run 43671966677 # the steps of one attempt

`collect` only reads (runs, attempts and jobs of one workflow). A value GitHub did not report is
null, never a guess. The clocks, all from GitHub's own timestamps:

  span       run_started_at of the attempt to its last job's completed_at
  head       run_started_at to the first macOS job being created (the scope job and its runner wait)
  queue      a job's created_at to its started_at (waiting for a runner); the attempt's is the longest
  ran        a job's started_at to its completed_at
  tail       the last macOS job's completed_at to the attempt's last job's (the Linux check jobs)
  seconds    summed `ran` by runner class: what the attempt used, not how long it took

A re-run attempt lists the jobs it did not re-run with an earlier attempt's times; those rows are
marked `reused` and are in no clock of the later attempt. A job cancelled before a runner took it
has no runner, and GitHub gives it a started_at all the same: here it never started (started_at is
null), it is in no `ran` or `seconds`, and the time it waited is `gave_up`, a wait that did not end.
"""
import argparse
from datetime import datetime
import json
import statistics
import subprocess
import sys


def parse(stamp):
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")) if stamp else None


def seconds(start, end):
    """Whole seconds between two GitHub timestamps, or None when either is missing."""
    if not start or not end:
        return None
    return round((parse(end) - parse(start)).total_seconds())


def runner_class(labels):
    for label in labels:
        if label.startswith("macos"):
            return "macos"
    return "linux" if labels else None


def rows(run, jobs):
    """One observation per job of one attempt. `run` and `jobs` are GitHub's API objects."""
    out = []
    for job in jobs:
        # Either stamp before this attempt began means an earlier attempt ran the job.
        reused = any(job.get(key) and parse(job[key]) < parse(run["run_started_at"])
                     for key in ("started_at", "completed_at"))
        runner = job.get("runner_name") or None
        out.append({
            "run": run["id"], "attempt": run["run_attempt"], "event": run["event"],
            "branch": run["head_branch"], "sha": run["head_sha"],
            "run_created_at": run["created_at"], "run_started_at": run["run_started_at"],
            "run_conclusion": run.get("conclusion"),
            "job_id": job["id"], "job": job["name"], "conclusion": job.get("conclusion"),
            "runner_class": runner_class(job.get("labels", [])), "runner": runner,
            "created_at": job.get("created_at"), "started_at": job.get("started_at") if runner else None,
            "completed_at": job.get("completed_at"), "reused": reused,
            "steps": [{"name": step["name"], "conclusion": step.get("conclusion"),
                       "seconds": seconds(step.get("started_at"), step.get("completed_at"))}
                      for step in job.get("steps", []) if runner],
        })
    return out


def attempts(observations):
    """The clocks of each attempt, oldest first. A clock with no job to measure is None."""
    grouped = {}
    for row in observations:
        grouped.setdefault((row["run"], row["attempt"]), []).append(row)
    out = []
    for (run, attempt), jobs in sorted(grouped.items()):
        ran = [job for job in jobs if not job["reused"] and job["started_at"] and job["completed_at"]
               and job["conclusion"] != "skipped"]
        mac = [job for job in ran if job["runner_class"] == "macos"]
        first = jobs[0]
        end = max((job["completed_at"] for job in ran), key=parse, default=None)
        last_mac = max(mac, key=lambda job: parse(job["completed_at"]), default=None)
        gave_up = [seconds(job["created_at"], job["completed_at"]) for job in jobs
                   if not job["reused"] and job["runner_class"] == "macos" and not job["started_at"]
                   and job["completed_at"] and job["conclusion"] != "skipped"]
        used = {}
        for job in ran:
            used[job["runner_class"]] = used.get(job["runner_class"], 0) + seconds(job["started_at"], job["completed_at"])
        out.append({
            "run": run, "attempt": attempt, "event": first["event"], "branch": first["branch"],
            "sha": first["sha"], "conclusion": first["run_conclusion"],
            "span": seconds(first["run_started_at"], end),
            "head": seconds(first["run_started_at"], min((job["created_at"] for job in mac), key=parse, default=None)),
            "queue": max((seconds(job["created_at"], job["started_at"]) for job in mac), default=None),
            "gave_up": max(gave_up, default=None),
            "last_macos_job": last_mac["job"] if last_mac else None,
            "last_macos_ran": seconds(last_mac["started_at"], last_mac["completed_at"]) if last_mac else None,
            "tail": seconds(last_mac["completed_at"], end) if last_mac else None,
            "seconds": used,
        })
    return out


def collect(workflow, limit):
    def gh(path):
        return json.loads(subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout)
    repo = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                          check=True, capture_output=True, text=True).stdout.strip()
    listed = gh(f"repos/{repo}/actions/workflows/{workflow}/runs?per_page={limit}")["workflow_runs"]
    out = []
    for run in listed:
        for attempt in range(1, run["run_attempt"] + 1):
            base = f"repos/{repo}/actions/runs/{run['id']}/attempts/{attempt}"
            out.extend(rows(gh(base), gh(f"{base}/jobs?per_page=100")["jobs"]))
    return out


def minutes(value):
    return "    -" if value is None else f"{value / 60:5.1f}"


def queues(observations):
    """Every wait for a macOS runner that ended in a start, sorted; and how many never did."""
    mac = [row for row in observations if row["runner_class"] == "macos" and not row["reused"]
           and row["conclusion"] != "skipped"]
    waits = sorted(seconds(row["created_at"], row["started_at"]) for row in mac if row["started_at"])
    return waits, sum(1 for row in mac if not row["started_at"] and row["completed_at"])


def summarize(observations, out=sys.stdout):
    table = attempts(observations)
    print("run attempt sha event conclusion | span head queue tail (min) | last macOS job, ran | macOS, Linux runner-min",
          file=out)
    for row in table:
        print(f"{row['run']} {row['attempt']} {row['sha'][:7]} {row['event'][:4]} {row['conclusion'] or 'running':9} |"
              f" {minutes(row['span'])} {minutes(row['head'])} {minutes(row['queue'])} {minutes(row['tail'])} |"
              f" {(row['last_macos_job'] or '-')[:34]:34} {minutes(row['last_macos_ran'])} |"
              f" {minutes(row['seconds'].get('macos'))} {minutes(row['seconds'].get('linux'))}", file=out)
    green = [row for row in table if row["attempt"] == 1 and row["conclusion"] == "success" and row["span"]]
    if green:
        spans = sorted(row["span"] for row in green)
        print(f"first attempts that passed: {len(green)} of {sum(1 for row in table if row['attempt'] == 1)};"
              f" span median {minutes(statistics.median(spans)).strip()} min,"
              f" range {minutes(spans[0]).strip()} to {minutes(spans[-1]).strip()}", file=out)
    waits, never = queues(observations)
    if waits:
        at = lambda share: waits[int(share * (len(waits) - 1))]  # noqa: E731
        print(f"waits for a macOS runner: {len(waits)} jobs in {len({row['run'] for row in observations})} runs;"
              f" median {at(.5)} s, 75th percentile {at(.75)} s, 90th {at(.9)} s, longest {waits[-1]} s;"
              f" {never} more were cancelled while waiting", file=out)


def steps(observations, run, attempt, floor, out=sys.stdout):
    for row in observations:
        if row["run"] == run and row["attempt"] == attempt and not row["reused"] and row["started_at"]:
            print(f"{row['job']}: waited {seconds(row['created_at'], row['started_at'])} s,"
                  f" ran {seconds(row['started_at'], row['completed_at'])} s, {row['conclusion']}", file=out)
            for step in row["steps"]:
                if step["seconds"] is not None and step["seconds"] >= floor:
                    print(f"  {step['seconds']:5d} s  {step['name']} ({step['conclusion']})", file=out)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    fetch = commands.add_parser("collect")
    fetch.add_argument("--workflow", default="ci.yml")
    fetch.add_argument("--limit", type=int, default=40)
    for name in ("summarize", "steps"):
        command = commands.add_parser(name)
        command.add_argument("observations")
    commands.choices["steps"].add_argument("--run", type=int, required=True)
    commands.choices["steps"].add_argument("--attempt", type=int, default=1)
    commands.choices["steps"].add_argument("--floor", type=int, default=8, help="hide steps shorter than this")
    args = parser.parse_args(argv)
    if args.command == "collect":
        json.dump(collect(args.workflow, args.limit), sys.stdout, separators=(",", ":"))
        return 0
    with open(args.observations) as file:
        observations = json.load(file)
    if args.command == "summarize":
        summarize(observations)
    else:
        steps(observations, args.run, args.attempt, args.floor)
    return 0


if __name__ == "__main__":
    sys.exit(main())
