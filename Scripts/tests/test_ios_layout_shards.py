"""Unit tests for the shard plan: every shard passing must mean the full contract ran."""
import copy
import importlib.util
import json
import sys
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
spec = importlib.util.spec_from_file_location("layout_shards", ROOT / "Scripts/ios_layout_shards.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
from verify_ios_layout_coverage import required_ids, selected_ids  # noqa: E402

PLAN = json.loads((ROOT / "Tests/iOSLayout/UITests/shards.json").read_text())
MANIFEST = json.loads((ROOT / "Tests/iOSLayout/UITests/coverage.json").read_text())


class ShardPlanTests(unittest.TestCase):
    def test_actual_plan_is_a_partition_of_the_full_contract(self):
        shards = module.validate(PLAN, MANIFEST)
        owed = [selected_ids(MANIFEST, set(shard["ui"])) for shard in shards]
        self.assertEqual(set().union(*owed), required_ids(MANIFEST))
        self.assertEqual(sum(len(ids) for ids in owed), len(required_ids(MANIFEST)))
        self.assertEqual(sum(len(shard["ui"]) for shard in shards), 13)

    def test_dropped_duplicated_or_unknown_journeys_are_rejected(self):
        def dropped(plan): plan["shards"][1]["ui"].pop()
        def duplicated(plan): plan["shards"][1]["ui"].append(plan["shards"][0]["ui"][0])
        def unknown(plan): plan["shards"][0]["ui"].append("testNotAJourney")
        def emptied(plan): plan["shards"][0]["ui"], plan["shards"][1]["ui"] = [], sum(
            (shard["ui"] for shard in plan["shards"]), [])
        def one_shard(plan): plan["shards"] = [{"component": True, "ui": sum(
            (shard["ui"] for shard in plan["shards"]), [])}]
        for change in (dropped, duplicated, unknown, emptied, one_shard):
            plan = copy.deepcopy(PLAN)
            change(plan)
            with self.subTest(change=change.__name__), self.assertRaises(ValueError):
                module.validate(plan, MANIFEST)

    def test_component_bundle_runs_in_exactly_one_shard(self):
        for flags in ([True, True], [False, False]):
            plan = copy.deepcopy(PLAN)
            for shard, flag in zip(plan["shards"], flags):
                shard["component"] = flag
            with self.subTest(flags=flags), self.assertRaises(ValueError):
                module.validate(plan, MANIFEST)

    def test_a_journey_new_to_the_manifest_must_be_placed(self):
        manifest = copy.deepcopy(MANIFEST)
        manifest["journey_methods"]["testNewJourney"] = []
        with self.assertRaises(ValueError):
            module.validate(PLAN, manifest)

    def test_last_shard_skips_the_others_so_an_unplaced_test_runs_there(self):
        first = module.xcodebuild_args(PLAN, MANIFEST, 1)
        last = module.xcodebuild_args(PLAN, MANIFEST, len(PLAN["shards"]))
        self.assertTrue(all(arg.startswith("-only-testing:") for arg in first))
        self.assertTrue(all(arg.startswith("-skip-testing:") for arg in last))
        self.assertEqual({arg.split(":", 1)[1] for arg in first}, {arg.split(":", 1)[1] for arg in last})
        self.assertIn("-only-testing:WorkspaceLayoutComponentTests", first)
        with self.assertRaises(ValueError):
            module.xcodebuild_args(PLAN, MANIFEST, 3)


if __name__ == "__main__":
    unittest.main()
