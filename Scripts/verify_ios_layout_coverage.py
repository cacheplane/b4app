#!/usr/bin/env python3
"""Validate execution of the reviewed legacy scenario and assertion-checkpoint contract."""
import re


def required_ids(manifest):
    if manifest.get("schema") != 1:
        raise ValueError("Unsupported layout coverage schema")
    scenarios = manifest.get("scenarios", [])
    reference = manifest["reference"]
    ids = set()
    methods = set()
    layouts = 0
    for scenario in scenarios:
        identifier = scenario["id"]
        count = scenario["layouts"]
        if not isinstance(count, int) or count < 0 or identifier + "/complete" in ids:
            raise ValueError("Invalid or duplicate coverage scenario")
        methods.add(scenario["method"])
        ids.add(identifier + "/complete")
        ids.update(identifier + f"/layout#{i}" for i in range(1, count + 1))
        layouts += count
    if (len(scenarios), len(methods), layouts) != (
            reference["scenarios"], reference["methods"], reference["layouts"]):
        raise ValueError("Coverage manifest disagrees with its reference contract")
    if not ids:
        raise ValueError("Empty layout coverage contract")
    return ids


def verify_coverage(manifest, activities, expected=None):
    required = required_ids(manifest) if expected is None else set(expected)
    if not required:
        raise ValueError("Empty expected UI coverage")
    seen = set()

    def walk(value):
        if isinstance(value, dict):
            title = value.get("title", "")
            match = re.fullmatch(r"Added attachment named 'coverage:(.+)'", title)
            if match:
                identifier = match[1]
                if identifier not in required or identifier in seen:
                    raise ValueError(f"Unknown or duplicate UI coverage marker: {identifier}")
                seen.add(identifier)
            for child in value.values():
                if isinstance(child, (dict, list)):
                    walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(activities)
    missing = required - seen
    if missing:
        raise ValueError(f"UI coverage missing {len(missing)} required checkpoints: {sorted(missing)}")
    return seen


def selected_ids(manifest, methods):
    """Explicit diagnostic subset; full CI never requests this mode."""
    all_ids = required_ids(manifest)
    expected = set()
    legacy = {scenario["method"] for scenario in manifest["scenarios"]}
    for method in methods:
        if method in legacy:
            for scenario in manifest["scenarios"]:
                if scenario["method"] == method:
                    expected.add(scenario["id"] + "/complete")
                    expected.update(scenario["id"] + f"/layout#{i}" for i in range(1, scenario["layouts"] + 1))
        elif method in manifest.get("journey_methods", {}):
            expected.update(manifest["journey_methods"][method])
        else:
            raise ValueError(f"No reviewed coverage mapping for selected UI method: {method}")
    if not expected or not expected <= all_ids:
        raise ValueError("Invalid or empty selected UI coverage")
    return expected


def ui_cases(tests):
    def walk(node):
        yield node
        for child in node.get("children", []):
            yield from walk(child)
    return [case for root in tests.get("testNodes", []) for node in walk(root)
            if node.get("name") == "WorkspaceLayoutTests" and node.get("nodeType", "").lower().endswith("test bundle")
            for case in walk(node) if case.get("nodeType") == "Test Case"]


def read_activities(result_bundle, cases):
    import json
    import subprocess
    records = []
    for case in cases:
        identifier = case["nodeIdentifier"]
        result = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "activities", "--path", str(result_bundle),
             "--test-id", identifier, "--compact"], capture_output=True, text=True, check=False)
        if result.returncode:
            raise ValueError(f"Cannot read required UI activities for {identifier}: {result.stderr}")
        records.append(json.loads(result.stdout))
    return records
