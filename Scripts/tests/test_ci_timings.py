"""The CI clocks come from GitHub's timestamps, and a missing one stays missing."""
import io
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ci_timings  # noqa: E402


def run(attempt=1, started="2026-11-15T03:21:06Z", conclusion="success"):
    return {"id": 7, "run_attempt": attempt, "event": "pull_request", "head_branch": "b", "head_sha": "a" * 40,
            "created_at": "2026-11-15T03:21:06Z", "run_started_at": started, "conclusion": conclusion}


def job(name, labels, created, started, completed, conclusion="success", steps=()):
    return {"id": hash(name) % 1000, "name": name, "labels": labels, "conclusion": conclusion,
            "created_at": created, "started_at": started, "completed_at": completed, "runner_name": "r",
            "steps": list(steps)}


JOBS = [
    job("Change scope", ["ubuntu-latest"], "2026-11-15T03:21:07Z", "2026-11-15T03:21:44Z", "2026-11-15T03:21:48Z"),
    job("Package build and tests", ["macos-26"], "2026-11-15T03:21:50Z", "2026-11-15T03:21:52Z",
        "2026-11-15T03:37:52Z", steps=[{"name": "Build", "conclusion": "success",
                                        "started_at": "2026-11-15T03:22:00Z", "completed_at": "2026-11-15T03:24:12Z"},
                                       {"name": "Never ran", "conclusion": "skipped"}]),
    job("macOS recovery smoke tests", ["macos-26"], "2026-11-15T03:21:50Z", "2026-11-15T03:22:50Z",
        "2026-11-15T03:35:30Z"),
    job("macOS and iOS app builds", ["ubuntu-latest"], "2026-11-15T03:37:53Z", "2026-11-15T03:40:53Z",
        "2026-11-15T03:40:56Z"),
    job("Skipped", ["macos-26"], "2026-11-15T03:21:50Z", "2026-11-15T03:21:50Z", "2026-11-15T03:21:50Z",
        conclusion="skipped"),
]


class TimingTests(unittest.TestCase):
    def test_the_clocks_of_one_attempt(self):
        [row] = ci_timings.attempts(ci_timings.rows(run(), JOBS))
        self.assertEqual(row["span"], 19 * 60 + 50)
        self.assertEqual(row["head"], 44)            # the scope job and its wait
        self.assertEqual(row["queue"], 60)           # the smoke job's wait, the longest
        self.assertEqual((row["last_macos_job"], row["last_macos_ran"]), ("Package build and tests", 960))
        self.assertEqual(row["tail"], 184)           # the Linux check job and its wait
        self.assertEqual(row["seconds"], {"linux": 7, "macos": 960 + 760})

    def test_a_missing_timestamp_is_unknown_not_zero(self):
        self.assertIsNone(ci_timings.seconds(None, "2026-11-15T03:21:06Z"))
        observed = ci_timings.rows(run(), JOBS)
        self.assertEqual([step["seconds"] for step in observed[1]["steps"]], [132, None])
        queued = job("Queued", ["macos-26"], "2026-11-15T03:21:50Z", None, None, conclusion=None)
        [row] = ci_timings.attempts(ci_timings.rows(run(conclusion=None), [queued]))
        self.assertEqual((row["span"], row["queue"], row["tail"], row["seconds"]), (None, None, None, {}))

    def test_a_rerun_does_not_count_the_jobs_it_reused(self):
        # Attempt 2 re-ran only the package job; GitHub lists the smoke job with attempt 1's times.
        second = run(attempt=2, started="2026-11-15T04:00:00Z")
        jobs = [JOBS[2], job("Package build and tests", ["macos-26"], "2026-11-15T04:00:01Z",
                             "2026-11-15T04:00:31Z", "2026-11-15T04:10:31Z")]
        observed = ci_timings.rows(second, jobs)
        self.assertEqual([row["reused"] for row in observed], [True, False])
        [row] = ci_timings.attempts(observed)
        self.assertEqual((row["span"], row["queue"], row["seconds"]), (631, 30, {"macos": 600}))

    def test_the_summary_counts_first_attempts_that_passed(self):
        out = io.StringIO()
        failed = ci_timings.rows({**run(conclusion="failure"), "id": 8}, JOBS)
        ci_timings.summarize(ci_timings.rows(run(), JOBS) + failed, out)
        self.assertIn("first attempts that passed: 1 of 2; span median 19.8 min", out.getvalue())


if __name__ == "__main__":
    unittest.main()
