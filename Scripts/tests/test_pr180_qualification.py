"""Temporary PR 180 checks for the protocol qualification workflow."""
from pathlib import Path
import re
import unittest

from Scripts.tests.test_ci_scope import workflow_job_sections


class ProtocolQualificationTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[2]
        self.workflow = (root / ".github/workflows/pr-180-qualification.yml").read_text()
        self.jobs = workflow_job_sections(self.workflow)
        self.focused = self.jobs["package"]
        self.ordinary = workflow_job_sections((root / ".github/workflows/ci.yml").read_text())["package"]

    def test_gate_and_database_companions(self):
        self.assertEqual(set(self.jobs), {"verify-checkout", "package", "bounded-database-aggregate",
                                         "account-session-aggregate-serial-diagnostic"})
        self.assertIn("    types: [labeled]", self.workflow)
        for required in ("github.repository == 'cacheplane/b4app'",
                         "github.event.label.name == 'qualify-pr-180'",
                         "github.event.pull_request.number == 180",
                         "github.event.pull_request.head.repo.full_name == 'cacheplane/b4app'",
                         "github.event.pull_request.head.ref == 'blove/protocol-client-foundation-f9a-20261111'",
                         'test "${parents[0]}" = "$BASE_SHA"', 'test "${parents[1]}" = "$HEAD_SHA"'):
            self.assertIn(required, self.jobs["verify-checkout"])

        start = self.ordinary.index("      - name: File times from content\n")
        end = self.ordinary.index("      - name: Format lint\n", start)
        for name in ("package", "bounded-database-aggregate", "account-session-aggregate-serial-diagnostic"):
            job = self.jobs[name]
            self.assertIn("    needs: verify-checkout\n", job, name)
            self.assertIn("    timeout-minutes: 45\n", job, name)
            self.assertIn(self.ordinary[start:end], job, name)
            self.assertNotIn("uses: actions/cache/save@", job, name)
        width = "--experimental-maximum-parallelization-width 2"
        for job_name, scheduling in (("bounded-database-aggregate", width),
                                     ("account-session-aggregate-serial-diagnostic", "--no-parallel")):
            job = self.jobs[job_name]
            self.assertIn("        timeout-minutes: 35\n", job)
            self.assertIn(f"swift test --skip-build {scheduling} --filter "
                          r"'^(WorkspaceStorageTests|CoordinatorTests)\.' 2>&1 | tee", job)
        self.assertEqual(self.workflow.count("--experimental-maximum-parallelization-width"), 2)

    def assert_native_scheduling(self, package):
        # Canonical six-space step headers, including unnamed uses/run steps, delimit source slices.
        starts = [match.start() for match in re.finditer(r"^      - (?:name|uses|run):", package, re.M)]
        steps = [package[start:end] for start, end in zip(starts, starts[1:] + [len(package)])]
        named = {}
        preceding_ids = set()
        for step in steps:
            for dependency in re.findall(r"steps\.([A-Za-z0-9_-]+)\.outcome", step):
                self.assertIn(dependency, preceding_ids, dependency)
            identifier = re.search(r"^        id: ([A-Za-z0-9_-]+)$", step, re.M)
            if identifier:
                self.assertNotIn(identifier.group(1), preceding_ids)
                preceding_ids.add(identifier.group(1))
            name = re.match(r"      - name: (.+)\n", step)
            if name:
                self.assertNotIn(name.group(1), named)
                named[name.group(1)] = step
        compiler_ids = ["owner-carrier-origin-controls", "owner-carrier-receipt-controls",
                        "account-session-package-controls", "account-session-storage-fields-controls",
                        "account-session-coordinator-controls", "account-session-check-boundary-controls",
                        "account-session-probe-boundary-controls", "account-session-reference-receipt-controls",
                        "account-session-presence-authority-controls", "account-session-decoder-boundary-controls",
                        "account-session-fileprivate-contexts-controls"]
        by_id = {re.search(r"^        id: (.+)$", step, re.M).group(1): step
                 for step in steps if re.search(r"^        id: (.+)$", step, re.M)}
        order = ["Start the tests' PostgreSQL", "Focused socket ownership and shutdown regressions",
                 "Focused Agent Protocol transport regressions",
                 "Sample owner-carrier build metadata (compiler controls held)", "Save owner-carrier metadata sample"]
        ordered_steps = [named[name] for name in order] + [by_id[key] for key in compiler_ids]
        ordered_steps += [named[name] for name in ["Focused account session comparison regressions",
                          "Historical action admission regressions", "Focused Agent Protocol foundation regressions",
                          "Focused Node probe observation controls",
                          "Focused owned protocol proof writer regressions", "Focused scope owner publication regressions"]]
        positions = [package.index(step) for step in ordered_steps]
        self.assertEqual(positions, sorted(positions))
        # No gap can move a slow aggregate between the compiler block and its native invocation.
        for before, after in zip(ordered_steps[3:17], ordered_steps[4:18]):
            self.assertEqual(package.index(after), package.index(before) + len(before))
        native = by_id["account-session-comparison-controls"]
        selector = "swift test --skip-build --filter 'AccountSessionComparisonTests|AccountSessionComparisonOwnerTests'"
        self.assertEqual(package.count(selector), 1)
        self.assertIn("        run: " + selector + "\n", native)
        dependencies = ["package-build", "test-postgres-prewarm", "socket-ownership-controls",
                        "owner-carrier-metadata", *compiler_ids]
        condition = "        if: ${{ !cancelled() && " + " && ".join(
            f"steps.{key}.outcome == 'success'" for key in dependencies) + " }}\n"
        self.assertIn(condition, native)
        self.assertIn("        env:\n          B4APP_TEST_POSTGRES_DIR: ${{ runner.temp }}/pg\n", native)
        availability = ("        if: ${{ !cancelled() && steps.package-build.outcome == 'success' "
                        "&& steps.test-postgres-prewarm.outcome == 'success' }}\n")
        foundation = named["Focused Agent Protocol foundation regressions"]
        self.assertIn(availability, foundation)
        self.assertIn("        run: swift test --skip-build --filter 'AgentProtocol|ProtocolProjectionStoreTests|ProtocolActivation'\n",
                      foundation)
        historical = by_id["historical-action-controls"]
        self.assertEqual(historical, "      - name: Historical action admission regressions\n"
                         "        id: historical-action-controls\n" + availability +
                         "        run: swift test --skip-build --filter AgentProtocolHistoricalActionTests\n")
        self.assertEqual(package.count("swift test --skip-build --filter AgentProtocolHistoricalActionTests"), 1)
        for key in compiler_ids:
            self.assertIn("        timeout-minutes: 1\n", by_id[key])
        self.assertNotIn("continue-on-error", package)
        self.assertIn("    timeout-minutes: 45\n", package)
        # Prewarm compiles the test bundle once for all subsequent test invocations.
        commands = re.findall(r"^\s*(?:run: |B4APP_TIMING=1 )?(swift test .+)$", package, re.M)
        self.assertEqual(len(commands), 9)
        self.assertEqual(commands[0], "swift test --filter 'AccountRegistryTests/aLedgerIsCreatedOnlyWhenMissing'")
        for command in commands[1:]:
            self.assertTrue(command.startswith("swift test --skip-build "), command)
        # Bound only independent database/writer cases; scenario-internal tasks stay concurrent.
        width = "--experimental-maximum-parallelization-width 2"
        self.assertEqual(package.count("--experimental-maximum-parallelization-width"), 1)
        self.assertIn("        run: swift test --skip-build " + width +
                      " --filter OwnedProtocolProofWriteTests\n",
                      named["Focused owned protocol proof writer regressions"])

    def test_focused_native_precedes_slow_checks_with_all_prerequisites(self):
        self.assert_native_scheduling(self.focused)

    def test_native_scheduling_rejects_tail_duplicate_and_missing_dependency(self):
        package = self.focused
        match = re.search(r"      - name: Focused account session comparison regressions\n.*?(?=^      - )",
                          package, re.M | re.S)
        self.assertIsNotNone(match)
        native = match.group(0)
        mutations = [package.replace(native, "") + native, package + native,
                     package.replace("steps.owner-carrier-receipt-controls.outcome == 'success' && ", ""),
                     package.replace(" --experimental-maximum-parallelization-width 2", "", 1),
                     package.replace("--experimental-maximum-parallelization-width 2",
                                     "--experimental-maximum-parallelization-width 1"),
                     package.replace("--experimental-maximum-parallelization-width 2",
                                     "--experimental-maximum-parallelization-width 4"),
                     package.replace("run: swift test --skip-build --filter NodeVersionProbeObservationTests",
                                     "run: swift test --skip-build --experimental-maximum-parallelization-width 2"
                                     " --filter NodeVersionProbeObservationTests")]
        for mutated in mutations:
            with self.subTest(mutation=mutations.index(mutated)):
                with self.assertRaises(AssertionError):
                    self.assert_native_scheduling(mutated)
