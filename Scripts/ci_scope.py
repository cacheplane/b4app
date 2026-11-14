#!/usr/bin/env python3
"""Say whether a pull request needs CI's macOS jobs (the Swift package, the apps and their UI tests).

Reads the pull request's changed paths on stdin, one per line (a renamed file gives both names), and
prints `apple=true` or `apple=false` for $GITHUB_OUTPUT. It answers false only when it is sure: every
path is in a tree nothing in those jobs reads, and the list is as long as GitHub says the change is.
Anything else (an empty list, a short list, a path outside those trees) answers true.
"""
import argparse
import sys

# Trees no Swift target, app, fixture or UI test reads. The hub's tests read Tests/Fixtures/sync, but
# that is not under Hub/, so a change to a shared contract still runs everything.
UNREAD_TREES = ("Hub/", "Infra/", "docs/")


def unread(path):
    """A path the macOS jobs never read: in one of the trees, or a Markdown file at the root."""
    if path.startswith("/") or ".." in path.split("/"):
        return False
    return path.startswith(UNREAD_TREES) or ("/" not in path and path.endswith(".md"))


def needs_apple(paths, expected):
    """`paths` are the listed names; `expected` is the number of changed files GitHub reported."""
    files = [path for path in paths if path]
    if not files or expected <= 0 or len(files) < expected:
        return True
    return not all(unread(path) for path in files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected", type=int, required=True,
                        help="the pull request's changed_files count")
    args = parser.parse_args()
    paths = [line.rstrip("\n") for line in sys.stdin]
    print("apple=" + ("true" if needs_apple(paths, args.expected) else "false"))


if __name__ == "__main__":
    main()
