"""CI skips its macOS jobs only for a change it is sure they cannot read."""
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ci_scope import needs_apple  # noqa: E402

SCRIPT = Path(__file__).resolve().parents[1] / "ci_scope.py"


class ScopeTests(unittest.TestCase):
    def test_hub_infra_docs_and_root_markdown_need_no_macos_jobs(self):
        paths = ["Hub/crates/b4hub/src/main.rs", "Infra/main.tf", "docs/decisions/D-001-x.md", "README.md"]
        self.assertFalse(needs_apple(paths, len(paths)))

    def test_one_path_outside_those_trees_runs_everything(self):
        for path in ["Sources/Coordinator/Router.swift", "Tests/Fixtures/sync/changes.json",
                     ".github/workflows/ci.yml", "Scripts/ci_scope.py", "Package.swift", "project.yml",
                     "Tests/README.md", "Hubris/x", "docs", "Hub/../Sources/x.swift", "/Hub/x"]:
            self.assertTrue(needs_apple(["Hub/API.md", path], 2), path)

    def test_a_rename_out_of_a_tree_counts_under_both_names(self):
        self.assertTrue(needs_apple(["docs/notes.md", "Sources/notes.md"], 1))

    def test_a_missing_or_short_list_runs_everything(self):
        self.assertTrue(needs_apple([], 0))
        self.assertTrue(needs_apple([""], 1))
        self.assertTrue(needs_apple(["docs/a.md"], 0))
        self.assertTrue(needs_apple(["docs/a.md", "docs/b.md"], 3001))

    def test_the_command_prints_the_output_line(self):
        def run(text, expected):
            return subprocess.run([sys.executable, str(SCRIPT), "--expected", str(expected)], input=text,
                                  capture_output=True, text=True, check=True).stdout
        self.assertEqual(run("docs/a.md\nHub/b.rs\n", 2), "apple=false\n")
        self.assertEqual(run("docs/a.md\nSources/b.swift\n", 2), "apple=true\n")
        self.assertEqual(run("", 0), "apple=true\n")


class WorkflowTests(unittest.TestCase):
    """The workflow skips macOS jobs only on the script's explicit no, and never a required check."""

    def setUp(self):
        text = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        names = ["scope", "b4-runtime", "lint", "package", "apps", "ios-layout", "ios-layout-result",
                 "macos-smoke", "hub"]
        starts = [text.index(f"\n  {name}:\n") for name in names]
        self.assertEqual(starts, sorted(starts))
        self.jobs = {name: text[start:end] for name, start, end in zip(names, starts, starts[1:] + [len(text)])}

    def test_every_macos_job_runs_unless_the_scope_said_false(self):
        macos = [name for name, job in self.jobs.items() if "runs-on: macos-26" in job]
        self.assertEqual(macos, ["package", "ios-layout", "macos-smoke"])
        for name in macos:
            self.assertIn("    needs: scope\n    if: ${{ !cancelled() && needs.scope.outputs.apple != 'false' }}\n",
                          self.jobs[name], name)

    def test_a_push_runs_everything_and_a_pull_request_asks_the_script(self):
        scope = self.jobs["scope"]
        self.assertIn('if [ "$GITHUB_EVENT_NAME" != pull_request ]; then\n            echo "apple=true"', scope)
        self.assertIn(".filename, (.previous_filename // empty)", scope)
        self.assertIn('python3 Scripts/ci_scope.py --expected "$CHANGED_FILES"', scope)

    def test_the_app_builds_check_reads_the_four_build_steps(self):
        apps = self.jobs["apps"]
        self.assertIn("name: macOS and iOS app builds\n", apps)
        self.assertIn("needs: [scope, package, macos-smoke]\n    if: always()\n", apps)
        self.assertIn('if [ "$APPLE" = false ] && [ "$JOBS" = skipped/skipped ]; then', apps)
        self.assertIn('test "$IOS" = success/success\n          test "$MACOS" = success/success', apps)
        self.assertIn("ios-apps: ${{ steps.ios-app.outcome }}/${{ steps.ios-beta.outcome }}", self.jobs["package"])
        self.assertIn("macos-apps: ${{ steps.macos-app.outcome }}/${{ steps.macos-beta.outcome }}",
                      self.jobs["macos-smoke"])
        # The builds run whatever the tests before them did.
        for job, steps in (("package", ["ios-app", "ios-beta"]), ("macos-smoke", ["macos-app", "macos-beta"])):
            for step in steps:
                self.assertIn(f"        id: {step}\n        if: ${{{{ !cancelled() }}}}\n", self.jobs[job])
        for job, schemes in (("package", ["B4App-iOS ", "B4App-iOS-Beta "]),
                             ("macos-smoke", ["B4App-macOS ", "B4App-macOS-Beta "])):
            for scheme in schemes:
                self.assertIn(f"-scheme {scheme}", self.jobs[job])


class SimulatorSliceTests(unittest.TestCase):
    def test_the_ios_app_builds_compile_arm64_only(self):
        # D-232: the Intel Simulator slice is not built. The macOS builds keep their architectures.
        text = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        builds = [line + following for line, following in zip(text.split("\n"), text.split("\n")[1:])
                  if "xcodebuild build -project B4App.xcodeproj" in line]
        self.assertEqual(len(builds), 4)
        for build in builds:
            self.assertEqual(" ARCHS=arm64 " in build, "-scheme B4App-iOS" in build, build)


class CombiningCheckTests(unittest.TestCase):
    """The two required checks' own shell, run as the workflow runs it, on outcomes that must fail."""

    def script(self, job):
        text = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        step = {"apps": "Every app build passed", "ios-layout-result": "Every shard passed"}[job]
        body = text[text.index(f"\n  {job}:\n"):].split(f"      - name: {step}\n", 1)[1].split("        run: |\n", 1)[1]
        lines = []
        for line in body.split("\n"):
            if line.strip() and not line.startswith("          "):
                break
            lines.append(line[10:])
        return "\n".join(lines)

    def passes(self, job, **env):
        result = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", self.script(job)],
                                env={"PATH": "/usr/bin:/bin", **env}, capture_output=True, text=True)
        return result.returncode == 0

    def test_the_app_builds_check(self):
        good = dict(APPLE="true", JOBS="success/success", IOS="success/success", MACOS="success/success")
        self.assertTrue(self.passes("apps", **good))
        # A failed test in a job that holds a build does not fail the builds' check.
        self.assertTrue(self.passes("apps", **{**good, "JOBS": "failure/failure"}))
        self.assertTrue(self.passes("apps", APPLE="false", JOBS="skipped/skipped", IOS="/", MACOS=""))
        bad = [
            {"IOS": "failure/success"}, {"IOS": "success/failure"}, {"MACOS": "failure/success"},
            {"MACOS": "success/failure"}, {"IOS": "success/cancelled"}, {"IOS": "success/skipped"},
            # A build that never reported: empty, not a pass.
            {"IOS": "success/"}, {"IOS": "/success"}, {"MACOS": "/"}, {"MACOS": ""},
            # Jobs skipped without the scope's explicit false, and a false with a job that ran.
            {"APPLE": "true", "JOBS": "skipped/skipped", "IOS": "/", "MACOS": ""},
            {"APPLE": "", "JOBS": "skipped/skipped", "IOS": "/", "MACOS": ""},
            {"APPLE": "false", "JOBS": "skipped/success", "IOS": "/", "MACOS": ""},
            {"APPLE": "false", "JOBS": "cancelled/cancelled", "IOS": "/", "MACOS": ""},
        ]
        for change in bad:
            self.assertFalse(self.passes("apps", **{**good, **change}), change)

    def test_the_layout_check(self):
        self.assertTrue(self.passes("ios-layout-result", APPLE="true", SHARDS="success"))
        self.assertTrue(self.passes("ios-layout-result", APPLE="false", SHARDS="skipped"))
        for apple, shards in (("true", "failure"), ("true", "cancelled"), ("true", "skipped"), ("", "skipped"),
                              ("false", "failure"), ("true", "")):
            self.assertFalse(self.passes("ios-layout-result", APPLE=apple, SHARDS=shards), (apple, shards))


if __name__ == "__main__":
    unittest.main()
