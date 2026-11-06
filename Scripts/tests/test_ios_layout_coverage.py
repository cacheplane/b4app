"""Coverage gate unit tests; fixture result trees do not claim native UI execution."""
import importlib.util
import json
from pathlib import Path
import unittest

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("layout_coverage", root / "Scripts/verify_ios_layout_coverage.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def activity(identifier):
    return {"title": f"Added attachment named 'coverage:{identifier}'"}


class LayoutCoverageTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {"schema": 1, "reference": {"methods": 1, "scenarios": 1, "layouts": 2},
                         "scenarios": [{"id": "testNavigation#1", "method": "testNavigation", "ordinal": 1, "layouts": 2}]}
        self.ids = {"testNavigation#1/complete", "testNavigation#1/layout#1", "testNavigation#1/layout#2"}

    def test_complete_contract_passes(self):
        self.assertEqual(module.verify_coverage(self.manifest, [activity(x) for x in sorted(self.ids)]), self.ids)

    def test_missing_late_step_rejects_even_when_method_counts_pass(self):
        with self.assertRaisesRegex(ValueError, "missing"):
            module.verify_coverage(self.manifest, [activity(x) for x in self.ids if not x.endswith("layout#2")])

    def test_missing_scenario_completion_rejects(self):
        with self.assertRaisesRegex(ValueError, "missing"):
            module.verify_coverage(self.manifest, [activity(x) for x in self.ids if not x.endswith("complete")])

    def test_duplicate_and_unknown_markers_reject(self):
        for extra in ("testNavigation#1/complete", "testUnknown#1/complete"):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                module.verify_coverage(self.manifest, [activity(x) for x in self.ids] + [activity(extra)])

    def test_nested_activity_is_read_once(self):
        nested = {"testRuns": [{"activities": [{"childActivities": [activity(x) for x in self.ids]}]}]}
        self.assertEqual(module.verify_coverage(self.manifest, [nested]), self.ids)

    def test_component_attachments_do_not_count_as_ui_coverage(self):
        with self.assertRaises(ValueError):
            module.verify_coverage(self.manifest, [{"title": "Added attachment named 'sync-banner-320'"}])

    def test_focused_selection_requires_reviewed_nonempty_method_mapping(self):
        self.assertEqual(module.selected_ids(self.manifest, {"testNavigation"}), self.ids)
        for methods in (set(), {"testUnknown"}):
            with self.assertRaises(ValueError):
                module.selected_ids(self.manifest, methods)
        mapped = {**self.manifest, "journey_methods": {"testJourney": sorted(self.ids)}}
        self.assertEqual(module.selected_ids(mapped, {"testJourney"}), self.ids)
        mapped["journey_methods"]["testJourney"].append("testUnknown#1/complete")
        with self.assertRaises(ValueError):
            module.selected_ids(mapped, {"testJourney"})

    def test_actual_manifest_preserves_all_reference_obligations(self):
        manifest = json.loads((root / "Tests/iOSLayout/UITests/coverage.json").read_text())
        self.assertEqual(len(module.required_ids(manifest)), 131)
        self.assertEqual(len(manifest["scenarios"]), 62)
        self.assertEqual(len({x["method"] for x in manifest["scenarios"]}), 25)

    def test_manifest_cannot_silently_drop_or_duplicate_scenarios(self):
        for scenarios in ([], self.manifest["scenarios"] * 2):
            invalid = {**self.manifest, "scenarios": scenarios}
            with self.assertRaises(ValueError):
                module.required_ids(invalid)


if __name__ == "__main__":
    unittest.main()
