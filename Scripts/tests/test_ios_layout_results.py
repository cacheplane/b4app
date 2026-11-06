"""Unit tests for the result gate, not simulated native integration evidence."""
import importlib.util
import os
import subprocess
import sys
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "layout_results", Path(__file__).resolve().parents[1] / "verify_ios_layout_results.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def bundle(name, count, result="Passed"):
    return {"name": name, "nodeType": "UI test bundle" if name == "WorkspaceLayoutTests" else "Unit test bundle",
            "children": [{"nodeType": "Test Suite", "children": [
                {"nodeType": "Test Case", "name": f"test{i}", "result": result} for i in range(count)]}]}


def tree(ui=25, component=3):
    return {"testNodes": [{"nodeType": "Test Plan", "children": [
        bundle("WorkspaceLayoutTests", ui), bundle("WorkspaceLayoutComponentTests", component)]}]}


def summary(total=28):
    return {"result": "Passed", "totalTestCount": total, "passedTests": total,
            "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}


class LayoutResultTests(unittest.TestCase):
    def test_ci_rejects_focused_override_at_both_entry_points(self):
        root = Path(__file__).resolve().parents[2]
        env = {**os.environ, "CI": "true", "B4APP_LAYOUT_FOCUSED_COVERAGE": "1",
               "PATH": "/usr/bin:/bin"}
        commands = [
            [sys.executable, str(root / "Scripts/verify_ios_layout_results.py"),
             "missing-summary.json", "missing-tests.json", "--focused-coverage"],
            ["/bin/sh", str(root / "Scripts/test-ios-layout.sh")],
        ]
        for command in commands:
            with self.subTest(command=command):
                result = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Focused UI coverage is local-only", result.stderr)

    def test_requires_both_full_targets(self):
        self.assertEqual(module.verify(summary(), tree(), 25, 3),
                         {"WorkspaceLayoutTests": 25, "WorkspaceLayoutComponentTests": 3})

    def test_component_only_does_not_replace_ui(self):
        with self.assertRaises(ValueError):
            module.verify(summary(3), tree(0, 3), 25, 3)

    def test_same_total_with_missing_ui_is_rejected(self):
        with self.assertRaises(ValueError):
            module.verify(summary(), tree(24, 4), 25, 3)

    def test_failed_or_skipped_cases_are_rejected(self):
        for result in ("Failed", "Skipped", "Expected Failure"):
            nodes = tree()
            nodes["testNodes"][0]["children"][1] = bundle("WorkspaceLayoutComponentTests", 3, result)
            with self.subTest(result=result), self.assertRaises(ValueError):
                module.verify(summary(), nodes, 25, 3)

    def test_empty_or_inconsistent_summary_is_rejected(self):
        for counts in ((0, 0), (-1, 3)):
            with self.assertRaises(ValueError):
                module.verify(summary(0), tree(0, 0), *counts)
        with self.assertRaises(ValueError):
            module.verify(summary(27), tree(), 25, 3)
        for key in ("failedTests", "skippedTests", "expectedFailures"):
            value = summary()
            value[key] = 1
            with self.assertRaises(ValueError):
                module.verify(value, tree(), 25, 3)

    def test_explicit_focused_run_is_supported(self):
        self.assertEqual(module.verify(summary(3), tree(0, 3), 0, 3),
                         {"WorkspaceLayoutTests": 0, "WorkspaceLayoutComponentTests": 3})

    def test_unknown_or_duplicate_bundles_are_rejected(self):
        for extra in (bundle("UnexpectedTests", 1), bundle("WorkspaceLayoutTests", 25)):
            nodes = tree()
            nodes["testNodes"][0]["children"].append(extra)
            with self.assertRaises(ValueError):
                module.verify(summary(), nodes, 25, 3)


if __name__ == "__main__":
    unittest.main()
