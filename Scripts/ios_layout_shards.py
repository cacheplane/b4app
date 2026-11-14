#!/usr/bin/env python3
"""The reviewed split of the iOS layout suite across parallel CI jobs.

Every shard checks the whole plan before it trusts its own part: the shards hold each journey and the
component bundle exactly once, and together they owe every checkpoint of the coverage contract. So
when every shard passes, the full contract ran, as it did in one job.
"""
import argparse
import json
from pathlib import Path

from verify_ios_layout_coverage import required_ids, selected_ids

PLAN = Path("Tests/iOSLayout/UITests/shards.json")
MANIFEST = Path("Tests/iOSLayout/UITests/coverage.json")


def validate(plan, manifest):
    """The plan's shards, or ValueError when they are not a partition of the full contract."""
    if plan.get("schema") != 1:
        raise ValueError("Unsupported layout shard schema")
    shards = plan.get("shards")
    if not isinstance(shards, list) or len(shards) < 2:
        raise ValueError("A shard plan needs at least two shards")
    methods = [method for shard in shards for method in shard["ui"]]
    if len(set(methods)) != len(methods):
        raise ValueError("A journey is in more than one shard")
    journeys = set(manifest.get("journey_methods", {}))
    if set(methods) != journeys:
        raise ValueError(f"The shards do not hold every journey once: {sorted(journeys ^ set(methods))}")
    if [bool(shard["component"]) for shard in shards].count(True) != 1:
        raise ValueError("Exactly one shard runs the component bundle")
    if any(not shard["ui"] for shard in shards):
        raise ValueError("Every shard runs at least one journey")
    owed = [selected_ids(manifest, set(shard["ui"])) for shard in shards]
    if sum(len(ids) for ids in owed) != len(set().union(*owed)):
        raise ValueError("A checkpoint is owed by more than one shard")
    if set().union(*owed) != required_ids(manifest):
        raise ValueError("The shards together do not owe the full coverage contract")
    return shards


def shard(plan, manifest, number):
    shards = validate(plan, manifest)
    if not 1 <= number <= len(shards):
        raise ValueError(f"No shard {number} of {len(shards)}")
    return shards[number - 1]


def xcodebuild_args(plan, manifest, number):
    """Every shard but the last names its tests. The last skips what the others name, so a test that
    is in no shard runs there and fails the count instead of running nowhere."""
    shards = validate(plan, manifest)
    mine = shard(plan, manifest, number)
    prefix, bundle = plan["class"], plan["component_bundle"]
    if number < len(shards):
        args = [f"-only-testing:{prefix}/{method}()" for method in mine["ui"]]
        return args + ([f"-only-testing:{bundle}"] if mine["component"] else [])
    others = [other for other in shards if other is not mine]
    args = [f"-skip-testing:{prefix}/{method}()" for other in others for method in other["ui"]]
    return args + ([] if mine["component"] else [f"-skip-testing:{bundle}"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["xcodebuild-args", "check"])
    parser.add_argument("shard", type=int, nargs="?")
    args = parser.parse_args()
    plan, manifest = json.loads(PLAN.read_text()), json.loads(MANIFEST.read_text())
    if args.command == "check":
        print(f"{len(validate(plan, manifest))} shards hold the full contract")
    else:
        if args.shard is None:
            parser.error("xcodebuild-args needs a shard number")
        print("\n".join(xcodebuild_args(plan, manifest, args.shard)))


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        raise SystemExit(f"error: {error}")
