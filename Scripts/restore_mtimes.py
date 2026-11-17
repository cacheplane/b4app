#!/usr/bin/env python3
"""Set every tracked file's modification time from its content, so CI's build caches are reusable.

`actions/checkout` gives every file the time of the checkout, so a restored SwiftPM `.build` or Xcode
DerivedData sees every source as changed and rebuilds it all. Swift's build systems rebuild a file
whose modification time differs from the one they recorded, in either direction. Here a file's time
is a fixed epoch plus a number taken from its git blob id: the same content gets the same time in
every checkout, with no history needed, and changed content gets a different one (a collision needs
two blobs whose first 30 bits agree). Untracked and non-regular files are left alone.
"""
import argparse
import os
import subprocess

EPOCH = 1_000_000_000


def mtime_for(blob):
    """The modification time for a blob id (hex)."""
    return EPOCH + int(blob[:8], 16) % 2**30


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="the checkout (default: the current directory)")
    args = parser.parse_args()
    listing = subprocess.run(["git", "ls-files", "-s", "-z"], cwd=args.root, check=True,
                             capture_output=True).stdout
    count = 0
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        meta, path = entry.split(b"\t", 1)
        mode, blob, _stage = meta.split(b" ")
        if mode not in (b"100644", b"100755"):
            continue
        full = os.path.join(os.fsencode(args.root), path)
        if not os.path.isfile(full) or os.path.islink(full):
            continue
        when = mtime_for(blob.decode())
        os.utime(full, (when, when), follow_symlinks=False)
        count += 1
    print(f"restore_mtimes: {count} files")


if __name__ == "__main__":
    main()
