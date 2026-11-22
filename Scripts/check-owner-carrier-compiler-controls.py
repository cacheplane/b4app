"""Check that another package module cannot manufacture an admitted owner or storage proof."""
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    target = root / "Tests" / "CoordinatorTests"
    # SwiftPM sets the same package access and imports as the real coordinator tests. Compile
    # one new source on the disposable qualification runner, after building the unmodified suite.
    expressions = [
        "HubSync.ConfiguredClientOrigin.init(hub:database:baseURL:reference:store:makeAPI:)",
        "ProtocolOwnedProofWriteReceipt.init(payload:)",
        "AccountSessionComparisonSnapshot.init",
        "HubOwnerCarrier.AccountSessionComparison.init",
    ]
    with tempfile.NamedTemporaryFile(mode="w", suffix=".swift", prefix="AccessCheck", dir=target) as probe:
        lines = ["@testable import Coordinator", "@testable import WorkspaceStorage", "import Foundation"]
        expected = set()
        for index, expression in enumerate(expressions):
            lines.append(f"private func checkAccess{index}() {{")
            lines.append(f"  _ = {expression}")
            expected.add(len(lines))
            lines.append("}")
        probe.write("\n".join(lines) + "\n")
        probe.flush()
        build = subprocess.run(
            ["swift", "build", "--build-tests"], cwd=root, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, check=False,
        )
        if build.returncode != 1:
            raise SystemExit(f"Expected a compiler rejection, got exit status {build.returncode}")
        actual = set()
        for line in build.stdout.splitlines():
            if line.startswith("error:"):
                if line in {
                    "error: emit-module command failed with exit code 1 (use -v to see invocation)",
                    "error: fatalError",
                }:
                    continue
                raise SystemExit(line)
            if ": error:" not in line:
                continue
            match = re.fullmatch(r"(.+\.swift):(\d+):\d+: error: (.+)", line)
            if not match or Path(match[1]).name != Path(probe.name).name:
                raise SystemExit(line)
            if "inaccessible due to 'fileprivate' protection level" not in match[3]:
                raise SystemExit(line)
            actual.add(int(match[2]))
        if actual != expected:
            raise SystemExit(f"Expected access errors on lines {sorted(expected)}, got {sorted(actual)}")
    print("All four restricted initializers refused construction from another module.")


if __name__ == "__main__":
    main()
