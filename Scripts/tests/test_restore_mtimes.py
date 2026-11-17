"""Scripts/restore_mtimes.py: a tracked file's modification time comes from its content alone."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import restore_mtimes  # noqa: E402

GIT = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]


def git(cwd, *args):
    return subprocess.run(GIT + list(args), cwd=cwd, check=True, capture_output=True, text=True).stdout


def run(cwd):
    subprocess.run([sys.executable, str(SCRIPTS / "restore_mtimes.py")], cwd=cwd, check=True,
                   capture_output=True, text=True)


def blob(cwd, path):
    return git(cwd, "rev-parse", f"HEAD:{path}").strip()


class RestoreMtimesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        (self.repo / "a.swift").write_text("1")
        (self.repo / "sub").mkdir()
        (self.repo / "sub" / "b.swift").write_text("b")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "one")

    def tearDown(self):
        self.tmp.cleanup()

    def test_mtime_is_a_function_of_the_blob(self):
        self.assertEqual(restore_mtimes.mtime_for("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
                         1_000_000_000 + 0xE69DE29B % 2**30)

    def test_same_content_same_time_across_checkouts(self):
        clone = Path(self.tmp.name) / "clone"
        git(self.tmp.name, "clone", "-q", str(self.repo), str(clone))
        run(self.repo)
        run(clone)
        for path in ("a.swift", "sub/b.swift"):
            expected = restore_mtimes.mtime_for(blob(self.repo, path))
            self.assertEqual(os.stat(self.repo / path).st_mtime, expected)
            self.assertEqual(os.stat(clone / path).st_mtime, expected)

    def test_changed_content_changes_the_time(self):
        run(self.repo)
        before = os.stat(self.repo / "a.swift").st_mtime
        (self.repo / "a.swift").write_text("2")
        git(self.repo, "commit", "-q", "-am", "two")
        run(self.repo)
        self.assertNotEqual(os.stat(self.repo / "a.swift").st_mtime, before)

    def test_untracked_files_are_left_alone(self):
        untracked = self.repo / "loose.txt"
        untracked.write_text("x")
        os.utime(untracked, (123, 123))
        run(self.repo)
        self.assertEqual(os.stat(untracked).st_mtime, 123)


if __name__ == "__main__":
    unittest.main()
