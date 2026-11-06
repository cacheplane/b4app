#!/usr/bin/env python3
"""Reject missing, partial, skipped, or failing required iOS test targets."""
import argparse
import json
import os
from pathlib import Path


def verify(summary, tests, ui_count, component_count):
    expected = {"WorkspaceLayoutTests": ui_count, "WorkspaceLayoutComponentTests": component_count}
    total = sum(expected.values())
    if min(expected.values()) < 0 or total <= 0:
        raise ValueError("Expected test counts must be nonnegative and include at least one test.")
    if summary.get("result") != "Passed" or summary.get("totalTestCount") != total:
        raise ValueError(f"Expected {total} passing tests: {summary}")
    if any(summary.get(key, 0) != 0 for key in ("failedTests", "skippedTests", "expectedFailures")):
        raise ValueError("Failed, skipped, or expected-failure tests do not satisfy coverage.")

    def descendants(node):
        yield node
        for child in node.get("children", []):
            yield from descendants(child)

    bundles = {}
    for root in tests.get("testNodes", []):
        for node in descendants(root):
            if node.get("nodeType", "").lower().endswith("test bundle"):
                name = node.get("name")
                if name not in expected or name in bundles:
                    raise ValueError(f"Unexpected or duplicate test bundle: {name}")
                bundles[name] = node
    observed = {}
    for name, count in expected.items():
        cases = [node for node in descendants(bundles.get(name, {}))
                 if node.get("nodeType") == "Test Case"]
        if len(cases) != count or any(case.get("result") != "Passed" for case in cases):
            raise ValueError(f"{name}: expected {count} passed cases, observed {len(cases)}: {cases}")
        observed[name] = len(cases)
    return observed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", type=Path)
    parser.add_argument("tests", type=Path)
    parser.add_argument("--ui-count", type=int, default=25)
    parser.add_argument("--component-count", type=int, default=3)
    parser.add_argument("--result-bundle", type=Path)
    parser.add_argument("--coverage-manifest", type=Path, default=Path("Tests/iOSLayout/UITests/coverage.json"))
    parser.add_argument("--focused-coverage", action="store_true")
    args = parser.parse_args()
    if args.focused_coverage and os.environ.get("CI"):
        parser.error("Focused UI coverage is local-only; CI requires the full contract")
    summary = json.loads(args.summary.read_text())
    tests = json.loads(args.tests.read_text())
    counts = verify(summary, tests, args.ui_count, args.component_count)
    if args.ui_count:
        from verify_ios_layout_coverage import read_activities, required_ids, selected_ids, ui_cases, verify_coverage
        if args.result_bundle is None:
            raise ValueError("Required UI coverage needs the actual result bundle")
        manifest = json.loads(args.coverage_manifest.read_text())
        cases = ui_cases(tests)
        methods = {case["nodeIdentifier"].split("/")[-1].removesuffix("()") for case in cases}
        expected = selected_ids(manifest, methods) if args.focused_coverage else required_ids(manifest)
        activities = read_activities(args.result_bundle, cases)
        verified = verify_coverage(manifest, activities, expected)
        print("B4_UI_OBLIGATIONS " + json.dumps({"required": len(expected), "verified": len(verified),
                                               "focused": args.focused_coverage}))
    print(json.dumps(summary))
    print("B4_LAYOUT_COVERAGE " + json.dumps(counts, sort_keys=True))


if __name__ == "__main__":
    main()
