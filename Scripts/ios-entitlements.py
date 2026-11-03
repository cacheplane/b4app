#!/usr/bin/env python3
"""Entitlements for the iOS archive that Scripts/upload-ios.sh exports.

upload-ios.sh archives without signing (an automatically signed archive needs a development
profile, which needs a registered device), and Xcode then has no entitlements to carry into the
export, which signs the app and its widget with only the basic four. So the script signs the
archived bundles ad hoc with their entitlements first, and checks the exported ones afterwards.

  ios-entitlements.py resolve <project> <target> <configuration> <out.plist>
      Writes the target's CODE_SIGN_ENTITLEMENTS with every $(VAR) and ${VAR} replaced from that
      target's build settings for the configuration (the flavour's xcconfig decides the App Group,
      the site domain, and which file).
  ios-entitlements.py check <signed bundle> <resolved.plist>
      Fails unless every key of the resolved file is in the bundle's signature with the same
      value; aps-environment must be `production`, since a distribution export rewrites it.
"""
import json
import plistlib
import re
import subprocess
import sys


def resolve(project, target, configuration, out):
    raw = subprocess.run(
        ["xcodebuild", "-project", project, "-target", target, "-configuration", configuration,
         "-sdk", "iphoneos", "-showBuildSettings", "-json"],
        capture_output=True, check=True).stdout
    settings = json.loads(raw)[0]["buildSettings"]
    path = settings.get("CODE_SIGN_ENTITLEMENTS")
    if not path:
        sys.exit(f"{target} ({configuration}) has no CODE_SIGN_ENTITLEMENTS.")

    def substitute(value):
        if isinstance(value, str):
            def setting(match):
                name = match.group(1) or match.group(2)
                if name not in settings:
                    sys.exit(f"{path}: build setting {name} is not set for {target} ({configuration}).")
                return settings[name]
            return re.sub(r"\$\((\w+)\)|\$\{(\w+)\}", setting, value)
        if isinstance(value, list):
            return [substitute(item) for item in value]
        if isinstance(value, dict):
            return {key: substitute(item) for key, item in value.items()}
        return value

    with open(path, "rb") as handle:
        entitlements = substitute(plistlib.load(handle))
    with open(out, "wb") as handle:
        plistlib.dump(entitlements, handle)
    print(f"{target}: {', '.join(sorted(entitlements))}")


def check(bundle, resolved):
    signed = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", bundle],
                            capture_output=True, check=True).stdout
    have = plistlib.loads(signed) if signed.strip() else {}
    with open(resolved, "rb") as handle:
        want = plistlib.load(handle)
    problems = []
    for key, value in sorted(want.items()):
        expected = "production" if key == "aps-environment" else value
        if key not in have:
            problems.append(f"missing {key}")
        elif have[key] != expected:
            problems.append(f"{key} is {have[key]!r}, not {expected!r}")
    if problems:
        sys.exit(f"{bundle}: " + "; ".join(problems))
    print(f"{bundle.rsplit('/', 1)[-1]}: {', '.join(sorted(want))} signed")


if __name__ == "__main__":
    if len(sys.argv) == 6 and sys.argv[1] == "resolve":
        resolve(*sys.argv[2:])
    elif len(sys.argv) == 4 and sys.argv[1] == "check":
        check(*sys.argv[2:])
    else:
        sys.exit(__doc__)
