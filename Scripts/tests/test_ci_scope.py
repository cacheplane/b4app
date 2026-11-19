"""CI skips its macOS jobs only for a change it is sure they cannot read."""
from pathlib import Path
import ast
import re
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ci_scope import needs_apple  # noqa: E402

SCRIPT = Path(__file__).resolve().parents[1] / "ci_scope.py"


def workflow_job_sections(text):
    """Read the workflow's canonical root jobs mapping, preserving its source slices."""
    in_jobs = False
    headers = {}
    offset = 0
    for line in text.splitlines(keepends=True):
        if not in_jobs:
            if re.fullmatch(r"jobs:[ \t]*(?:#.*)?(?:\r?\n)?", line):
                in_jobs = True
        elif line.strip() and not line.lstrip().startswith("#"):
            if not line[0].isspace():
                break
            if line.startswith("  ") and not line[2].isspace():
                header = re.fullmatch(r"  ([A-Za-z_][A-Za-z0-9_-]*):[ \t]*(?:#.*)?(?:\r?\n)?", line)
                if header is None:
                    raise ValueError(f"Unsupported two-space job entry: {line.strip()}")
                name = header.group(1)
                if name in headers:
                    raise ValueError(f"Duplicate job ID: {name}")
                headers[name] = offset
        offset += len(line)
    if not in_jobs:
        raise ValueError("Missing root jobs mapping")
    if not headers:
        raise ValueError("No job headers in root jobs mapping")
    starts = list(headers.values())
    return {name: text[start:end] for name, start, end in zip(headers, starts, starts[1:] + [offset])}


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
        names = ["scope", "b4-runtime", "lint", "package", "app-builds", "apps", "ios-layout",
                 "ios-layout-result", "macos-smoke", "hub"]
        jobs = workflow_job_sections(text)
        self.assertEqual([name for name in jobs if name in names], names)
        self.jobs = {name: jobs[name] for name in names}

    def test_every_macos_job_runs_unless_the_scope_said_false(self):
        macos = [name for name, job in self.jobs.items() if "runs-on: macos-26" in job]
        self.assertEqual(macos, ["package", "app-builds", "ios-layout", "macos-smoke"])
        for name in macos:
            self.assertIn("    needs: scope\n    if: ${{ !cancelled() && needs.scope.outputs.apple != 'false' }}\n",
                          self.jobs[name], name)

    def test_a_push_runs_everything_and_a_pull_request_asks_the_script(self):
        scope = self.jobs["scope"]
        self.assertIn('if [ "$GITHUB_EVENT_NAME" != pull_request ]; then\n            echo "apple=true"', scope)
        self.assertIn(".filename, (.previous_filename // empty)", scope)
        self.assertIn('python3 Scripts/ci_scope.py --expected "$CHANGED_FILES"', scope)

    def test_the_app_builds_check_reads_the_app_builds_job(self):
        apps = self.jobs["apps"]
        self.assertIn("name: macOS and iOS app builds\n", apps)
        self.assertIn("needs: [scope, app-builds]\n    if: always()\n", apps)
        self.assertIn("JOBS: ${{ needs.app-builds.result }}", apps)
        self.assertIn("IOS: ${{ needs.app-builds.outputs.ios-app }}", apps)
        self.assertIn("MACOS: ${{ needs.app-builds.outputs.macos-app }}", apps)
        self.assertIn('if [ "$APPLE" = false ] && [ "$JOBS" = skipped ]; then', apps)
        self.assertIn('test "$IOS" = success\n          test "$MACOS" = success', apps)
        builds = self.jobs["app-builds"]
        self.assertIn("ios-app: ${{ steps.ios-app.outcome }}", builds)
        self.assertIn("macos-app: ${{ steps.macos-app.outcome }}", builds)
        self.assertIn("-scheme B4App-iOS ", builds)
        self.assertIn("-scheme B4App-macOS ", builds)
        # The macOS build runs whatever the iOS build did.
        self.assertIn("        id: macos-app\n        if: ${{ !cancelled() }}\n", builds)
        for name, job in self.jobs.items():
            self.assertNotIn("-Beta", job, name)

    def test_a_push_to_main_is_never_cancelled_by_the_next(self):
        # Main's runs save the build caches at their end; a later merge must not cancel them first.
        text = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        self.assertIn("  cancel-in-progress: ${{ github.event_name != 'push' }}\n", text)

    def test_build_caches_are_saved_from_main_only(self):
        for name in ["package", "app-builds", "ios-layout", "macos-smoke"]:
            job = self.jobs[name]
            self.assertIn("python3 Scripts/restore_mtimes.py", job, name)
            self.assertIn("uses: actions/cache/restore@", job, name)
            self.assertIn("        if: github.event_name != 'push'\n", job, name)
            self.assertIn("uses: actions/cache/save@", job, name)
            self.assertIn(
                "        if: success() && github.event_name == 'push' && github.ref == 'refs/heads/main'\n",
                job, name)
            self.assertIn("-${{ github.sha }}", job, name)
            # The timestamps are set before anything builds.
            self.assertLess(job.index("restore_mtimes.py"), job.index("uses: actions/cache/restore@"), name)
            # The always-saving cache step is used only for downloads (.spm, the PostgreSQL archive).
            self.assertNotRegex(job, r"uses: actions/cache@\S+(?: # \S+)?\n        with:\n          path: \|?\n?\s*\.build(\n|/\w*DerivedData)",
                                name)


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
                          "Focused Node probe observation controls", "Test",
                          "Focused owned protocol proof writer regressions", "Focused scope owner publication regressions"]]
        positions = [package.index(step) for step in ordered_steps]
        self.assertEqual(positions, sorted(positions))
        # No gap can move a slow aggregate between the compiler block and its native invocation.
        for before, after in zip(ordered_steps[3:17], ordered_steps[4:18]):
            self.assertEqual(package.index(after), package.index(before) + len(before))
        native = by_id["account-session-comparison-controls"]
        selector = "swift test --filter 'AccountSessionComparisonTests|AccountSessionComparisonOwnerTests'"
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
        self.assertIn("        run: swift test --filter 'AgentProtocol|ProtocolProjectionStoreTests|ProtocolActivation'\n",
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

    def test_focused_native_precedes_slow_checks_with_all_prerequisites(self):
        self.assert_native_scheduling(self.jobs["package"])

    def test_native_scheduling_rejects_tail_duplicate_and_missing_dependency(self):
        package = self.jobs["package"]
        match = re.search(r"      - name: Focused account session comparison regressions\n.*?(?=^      - )",
                          package, re.M | re.S)
        self.assertIsNotNone(match)
        native = match.group(0)
        mutations = [package.replace(native, "") + native, package + native,
                     package.replace("steps.owner-carrier-receipt-controls.outcome == 'success' && ", "")]
        for mutated in mutations:
            with self.subTest(mutation=mutations.index(mutated)):
                with self.assertRaises(AssertionError):
                    self.assert_native_scheduling(mutated)

    def test_compiler_profile_closed_inventory_and_derived_counts_without_import(self):
        root = Path(__file__).resolve().parents[2]
        tree = ast.parse((root / "Scripts/check-owner-carrier-compiler-controls.py").read_text())
        assignments = [node for node in ast.walk(tree) if isinstance(node, ast.Assign)
                       and any(isinstance(target, ast.Name) and target.id == "SOURCE_NAMES" for target in node.targets)]
        self.assertEqual(len(assignments), 1)
        names = ast.literal_eval(assignments[0].value)
        self.assertIsInstance(assignments[0].value, ast.List)
        actual = sorted(path.name for path in (root / "Tests/CoordinatorTests").glob("*.swift"))
        self.assertEqual(names, actual)
        self.assertEqual(names, sorted(set(names)))
        preparations = [node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)
                        and node.name == "prepare"]
        self.assertEqual(len(preparations), 1)
        prepare = preparations[0]
        # Keep the literal package pins coupled to the guard that reads and hashes each root file.
        import hashlib
        package_loops = [node for node in ast.walk(prepare) if isinstance(node, ast.For)
                         and isinstance(node.target, ast.Tuple) and isinstance(node.iter, ast.Tuple)]
        self.assertEqual(len(package_loops), 1)
        package_loop = package_loops[0]
        self.assertIn(package_loop, prepare.body)
        target = ast.parse("for relative, expected in (): pass").body[0].target
        self.assertEqual(ast.dump(package_loop.target), ast.dump(target))
        self.assertEqual(len(package_loop.iter.elts), 2)
        for entry in package_loop.iter.elts:
            self.assertIsInstance(entry, ast.Tuple)
            self.assertEqual(len(entry.elts), 2)
            self.assertTrue(all(isinstance(value, ast.Constant) and isinstance(value.value, str)
                                for value in entry.elts))
        package_pins = ast.literal_eval(package_loop.iter)
        self.assertEqual([name for name, digest in package_pins], ["Package.swift", "Package.resolved"])
        guard = ast.parse(
            "_, content = read_regular(checkout / relative, checkout, MAX_INPUT)\n"
            'require(hashlib.sha256(content).hexdigest() == expected, "package_pin")').body
        self.assertEqual([ast.dump(node) for node in package_loop.body], [ast.dump(node) for node in guard])
        self.assertFalse(package_loop.orelse)
        for relative, expected_digest in package_pins:
            self.assertRegex(expected_digest, r"^[0-9a-f]{64}$")
            self.assertEqual(expected_digest, hashlib.sha256((root / relative).read_bytes()).hexdigest(), relative)
        profiles = [node for node in ast.walk(prepare) if isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Name) and node.func.id == "emit" and node.args
                    and isinstance(node.args[0], ast.Constant)
                    and node.args[0].value == "owner_carrier_compiler_profile"]
        self.assertEqual(len(profiles), 1)
        fields = {keyword.arg: keyword.value for keyword in profiles[0].keywords}
        for name, expression in {"sources": "len(SOURCE_NAMES)", "inputs": 'len(expected["inputs"])',
                                 "outputs": 'len(expected["outputs"])'}.items():
            self.assertEqual(ast.dump(fields[name]), ast.dump(ast.parse(expression, mode="eval").body))
        # The counted expected graph must remain the same graph compared strictly to the compiler command.
        strict = ast.parse("command == expected", mode="eval").body
        self.assertTrue(any(ast.dump(node) == ast.dump(strict) for node in ast.walk(prepare)))
        for variable, expression in {
            "source_paths": '[str(checkout / "Tests/CoordinatorTests" / name) for name in SOURCE_NAMES]',
            "object_paths": '[debug + "/CoordinatorTests.build/" + name + ".o" for name in SOURCE_NAMES]',
        }.items():
            values = [node.value for node in ast.walk(prepare) if isinstance(node, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id == variable for target in node.targets)]
            self.assertEqual(len(values), 1)
            self.assertEqual(ast.dump(values[0]), ast.dump(ast.parse(expression, mode="eval").body))
        expected_nodes = [node.value for node in ast.walk(prepare) if isinstance(node, ast.Assign)
                          and any(isinstance(target, ast.Name) and target.id == "expected" for target in node.targets)]
        self.assertEqual(len(expected_nodes), 1)
        self.assertIsInstance(expected_nodes[0], ast.Dict)
        self.assertEqual(len(expected_nodes[0].keys), 15)
        expected = dict(zip([ast.literal_eval(key) for key in expected_nodes[0].keys], expected_nodes[0].values))
        for key, expression in {
            "sources": "source_paths",
            "inputs": '[{"kind": "file", "name": name} for name in source_paths + ['
                      'debug + "/swift-version-7974D3F7F03D5E95.txt", debug + "/Modules/Coordinator.swiftmodule", '
                      'debug + "/Modules/NIOTransport.swiftmodule", debug + "/CoordinatorTests.build/sources"]]',
            "outputs": '[{"kind": "file", "name": name} for name in object_paths + '
                       '[debug + "/Modules/CoordinatorTests.swiftmodule"]]',
        }.items():
            self.assertEqual(ast.dump(expected[key]), ast.dump(ast.parse(expression, mode="eval").body))

    def test_startup_diagnostics_have_closed_private_safe_fields_and_finite_cap(self):
        # Source-only privacy/cap oracle; managed Swift execution remains required.
        text = (Path(__file__).resolve().parents[2] / "Tests/CoordinatorTests/HubOwnerCarrierTests.swift").read_text()
        diagnostic = text.split("private final class OwnerStartupDiagnostics: Sendable {", 1)[1].split(
            "private enum OwnerNativeDiagnostics", 1)[0]
        stages = re.search(r"enum Stage: String, CaseIterable, Hashable, Sendable \{(.*?)\n  \}",
                           diagnostic, re.S).group(1)
        stage_names = re.findall(r"\b[a-z][A-Za-z]+\b", stages.replace("case", ""))
        expected = {
            "collectorArmed", "managerStartReturned", "refreshJoined", "failed", "pullEntryEntered", "pullEntryReturned",
            "secretReadEntered", "secretReadReturned", "displayNameEntered", "displayNameReturned", "collectorReadyEntered",
            "collectorReadyReturned", "firstCollectorJoinEntered", "firstCollectorJoinReturned", "hubStopEntered",
            "hubStopReturned", "pullSettledReturned", "secondCollectorJoinEntered", "secondCollectorJoinReturned",
            "socketClosedReturned", "observationGuardEntered", "baselineDrainEntered", "baselineDrainReturned",
            "originCaptureEntered", "originCaptureReturned", "baselineAssertReturned"}
        self.assertEqual(set(stage_names), expected)
        self.assertEqual(len(stage_names), 26)
        self.assertEqual(set(re.findall(r"startupDiagnostics\.emit\(\s*\.([A-Za-z]+)", text)), expected)
        self.assertIn("static let maximumRecords = Stage.allCases.count", diagnostic)
        self.assertIn("var emitted: Set<Stage> = []", diagnostic)
        self.assertIn("state.emitted.insert(stage).inserted", diagnostic)
        self.assertIn("guard ordinal > 0 && observation.0 else { return }", diagnostic)
        self.assertIn("guard count < 10_000 else { return 0 }", diagnostic)
        self.assertIn("enum Role: String, Sendable { case unjoined, linked, heldSecret, sharedAPI, heldSecretSharedAPI }",
                      diagnostic)
        record = re.search(r'"A5_STARTUP ([^"\n]+)"', diagnostic).group(1)
        fields = re.findall(r"([A-Za-z]+)=\\\(([^)]+)\)", record)
        self.assertEqual(fields, [(name, value) for name, value in [
            ("role", "role.rawValue"), ("fixture", "ordinal"), ("stage", "stage.rawValue"), ("armed", "armed"),
            ("elapsedMillis", "elapsed"), ("remainingMillis", "remaining"), ("expired", "expired"),
            ("observationArmed", "observationArmed"), ("observationElapsedMillis", "observationElapsedMillis"),
            ("observationRemainingMillis", "observationRemainingMillis"), ("observationExpired", "observationExpired"),
            ("parentCancelled", "parentCancelled"), ("collectorCancelled", "collectorCancelled"),
            ("readEntered", "readEntered"), ("readSettled", "readSettled"), ("activeRead", "activeRead"),
            ("opens", "opens"), ("collectorStarted", "collectorStarted"), ("collectorReturned", "collectorReturned"),
            ("collectorSucceeded", "collectorSucceeded")]])
        self.assertEqual(record, " ".join(f"{name}=\\({value})" for name, value in fields))
        self.assertIn("let parts = duration.components", text)
        self.assertIn("return Int(min(max(whole + fraction, 0), 60_000))", text)
        self.assertIn("static func count(_ value: Int) -> Int { min(max(value, 0), 10_000) }", text)
        self.assertRegex(text, r'Issue\.record\(\s*"The direct owner-carrier fixture setup failed; private details were suppressed\."\)')
        self.assertNotIn("print(error", diagnostic)


class WorkflowJobSectionsTests(unittest.TestCase):
    def test_adjacent_jobs_have_exact_sections_without_nested_or_root_keys(self):
        before = (
            "name: example\non:\n  pull_request:\nenv:\n  package: ROOT_BEFORE\n"
            "concurrency:\n  group: example\njobs: # root jobs\n"
        )
        package = (
            "  package: \t# ordinary package\n"
            "    runs-on: macos-26\n"
            "    env:\n      package: PACKAGE_ENV\n"
            "    strategy:\n      matrix:\n        app-builds: [PACKAGE_MATRIX]\n"
            "    steps:\n"
            "      - name: PACKAGE_SENTINEL\n"
            "        uses: actions/cache/restore@v4\n"
            "        with:\n"
            "          account-session-aggregate-serial-diagnostic: PACKAGE_WITH\n"
            "          path: .build/package\n"
            "      - run: |\n"
            "          app-builds:\n"
            "          package:\n"
            "\n  # A comment between jobs stays with the preceding section.\n"
        )
        diagnostic = (
            "  account-session-aggregate-serial-diagnostic:\n"
            "    runs-on: macos-26\n"
            "    steps:\n"
            "      - name: DIAGNOSTIC_SENTINEL\n"
            "        uses: actions/cache@v4\n"
            "        with:\n          path: .build/diagnostic\n"
        )
        app_builds = (
            "  app-builds: \t\n"
            "    runs-on: macos-26\n"
            "    steps:\n"
            "      - name: APP_SENTINEL\n"
            "        uses: actions/cache/save@v4\n"
            "        with:\n          path: .build/app\n"
        )
        after = "env:\n  app-builds: ROOT_AFTER\n"
        jobs = workflow_job_sections(before + package + diagnostic + app_builds + after)
        self.assertEqual(list(jobs), ["package", "account-session-aggregate-serial-diagnostic", "app-builds"])
        self.assertEqual(jobs, {"package": package, "account-session-aggregate-serial-diagnostic": diagnostic,
                                "app-builds": app_builds})
        for name in ["package", "app-builds"]:
            self.assertNotIn("DIAGNOSTIC_SENTINEL", jobs[name])
            self.assertNotIn(".build/diagnostic", jobs[name])

    def test_unsupported_or_ambiguous_job_mappings_fail_clearly(self):
        cases = [
            ("env:\n  package: value\n", "Missing root jobs mapping"),
            ("jobs:\n  # no jobs\nenv:\n  package: value\n", "No job headers"),
            ("jobs:\n  package:\n  package:\n", "Duplicate job ID: package"),
            ("jobs:\n  package: {runs-on: macos-26}\n", "Unsupported two-space job entry"),
            ("jobs:\n  'package':\n", "Unsupported two-space job entry"),
            ("jobs:\n  1package:\n", "Unsupported two-space job entry"),
        ]
        for text, error in cases:
            with self.subTest(text=text):
                with self.assertRaisesRegex(ValueError, error):
                    workflow_job_sections(text)

    def test_cache_policy_rejects_a_prohibited_package_cache(self):
        case = WorkflowTests("test_build_caches_are_saved_from_main_only")
        case.setUp()
        jobs = case.jobs.copy()
        jobs["package"] += (
            "      - uses: actions/cache@v4\n"
            "        with:\n"
            "          path: .build\n"
        )
        case.jobs = jobs
        with self.assertRaisesRegex(AssertionError, "package"):
            case.test_build_caches_are_saved_from_main_only()


class CombiningCheckTests(unittest.TestCase):
    """The two required checks' own shell, run as the workflow runs it, on outcomes that must fail."""

    def script(self, job):
        text = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        step = {"apps": "Every app build passed", "ios-layout-result": "The layout job passed"}[job]
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
        good = dict(APPLE="true", JOBS="success", IOS="success", MACOS="success")
        self.assertTrue(self.passes("apps", **good))
        self.assertTrue(self.passes("apps", APPLE="false", JOBS="skipped", IOS="", MACOS=""))
        for change in (
            [{key: value} for key in ("IOS", "MACOS") for value in ("failure", "cancelled", "skipped", "")]
            + [{"APPLE": "true", "JOBS": "skipped", "IOS": "", "MACOS": ""},
               {"APPLE": "", "JOBS": "skipped", "IOS": "", "MACOS": ""},
               {"APPLE": "false", "JOBS": "cancelled", "IOS": "", "MACOS": ""}]
        ):
            self.assertFalse(self.passes("apps", **{**good, **change}), change)

    def test_the_layout_check(self):
        self.assertTrue(self.passes("ios-layout-result", APPLE="true", LAYOUT="success"))
        self.assertTrue(self.passes("ios-layout-result", APPLE="false", LAYOUT="skipped"))
        for apple, layout in (("true", "failure"), ("true", "cancelled"), ("true", "skipped"), ("", "skipped"),
                              ("false", "failure"), ("true", "")):
            self.assertFalse(self.passes("ios-layout-result", APPLE=apple, LAYOUT=layout), (apple, layout))


if __name__ == "__main__":
    unittest.main()
