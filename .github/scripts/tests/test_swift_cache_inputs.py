"""Cache metadata fault fixtures; no cached result represents a Swift test run."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'swift-cache-inputs.py'


class SwiftCacheInputsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('swift_cache', SCRIPT)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.inputs = ['Sources/A.swift', 'Tests/data.json', 'Package.swift', 'Package.resolved']
        for name in self.inputs:
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('original')
        self.build = self.root / '.build'
        self.binary = self.build / 'arm64-apple-macosx/debug/Fixture.xctest/Contents/MacOS/Fixture'
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text('binary')
        (self.build / 'build.db').write_text('build state')
        self.context = {'toolchain': 'compiler-sdk', 'configuration': 'debug-commands', 'triple': 'arm64-apple-macosx'}

    def capture(self):
        return self.module.capture(self.root, self.context, self.inputs)

    def restore(self, record):
        return self.module.restore(self.root, self.context, self.inputs, record)

    def test_verified_bytes_restore_timestamps_across_inode_replacement(self):
        record = self.capture()
        p = self.root / self.inputs[0]
        saved = p.stat().st_mtime_ns
        q = p.with_suffix('.new')
        q.write_bytes(p.read_bytes())
        q.chmod(p.stat().st_mode & 0o777)
        os.utime(q, ns=(saved + 5000000000, saved + 5000000000))
        q.replace(p)
        result = self.restore(record)
        self.assertEqual(result['status'], 'restored')
        self.assertEqual(p.stat().st_mtime_ns, saved)

    def test_changed_same_size_same_mtime_is_never_accepted_as_unchanged(self):
        record = self.capture()
        p = self.root / self.inputs[0]
        stamp = p.stat().st_mtime_ns
        p.write_text('modified')
        os.utime(p, ns=(stamp, stamp))
        result = self.restore(record)
        self.assertEqual(result['changed'], 1)
        self.assertNotEqual(p.stat().st_mtime_ns, stamp)
        self.assertEqual(p.read_text(), 'modified')

    def test_corrupt_artifact_invalidates_compiler_state_and_keeps_other_outputs(self):
        record = self.capture()
        for name in ['checkouts/keep', 'repositories/keep', 'postgres/bin/keep', 'postgres-dl/keep', 'DerivedData/keep']:
            p = self.build / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('keep')
        self.binary.write_text('tamper')
        result = self.restore(record)
        self.assertEqual(result['status'], 'regenerate')
        self.assertFalse((self.build / 'build.db').exists())
        self.assertFalse(self.binary.exists())
        self.assertTrue((self.build / 'DerivedData/keep').exists())
        self.assertTrue((self.build / 'postgres/bin/keep').exists())
        self.assertTrue((self.build / 'checkouts/keep').exists())

    def test_missing_bad_context_and_malformed_metadata_force_regeneration(self):
        for kind in ['missing', 'schema', 'context', 'root', 'timestamp']:
            with self.subTest(kind=kind):
                (self.build / 'build.db').write_text('build state')
                self.binary.parent.mkdir(parents=True, exist_ok=True)
                self.binary.write_text('binary')
                record = self.capture()
                if kind == 'missing': record = None
                elif kind == 'schema': record['schema_version'] = 99
                elif kind == 'context': record['context']['toolchain'] = 'different'
                elif kind == 'root': record['root'] = '/another-checkout'
                else: record['inputs'][self.inputs[0]]['mtime_ns'] = -1
                self.assertEqual(self.restore(record)['status'], 'regenerate')
                self.assertFalse((self.build / 'build.db').exists())

    def test_added_input_forces_full_compiled_regeneration(self):
        record = self.capture()
        new = self.root / 'Sources/New.swift'
        new.write_text('new test code')
        self.inputs.append('Sources/New.swift')
        self.assertEqual(self.restore(record)['status'], 'regenerate')
        self.assertFalse(self.binary.exists())

    def test_metadata_cannot_choose_an_outside_path_to_modify(self):
        record = self.capture()
        outside = self.root.parent / (self.root.name + '-outside')
        outside.write_text('untouched')
        self.addCleanup(lambda: outside.unlink(missing_ok=True))
        stamp = outside.stat().st_mtime_ns
        record['inputs']['../' + outside.name] = record['inputs'][self.inputs[0]]
        self.assertEqual(self.restore(record)['status'], 'regenerate')
        self.assertEqual(outside.stat().st_mtime_ns, stamp)
        self.assertEqual(outside.read_text(), 'untouched')

    def dependency(self):
        checkout = self.build / 'checkouts/fixture'
        checkout.mkdir(parents=True)
        def git(*args):
            return subprocess.check_output(['git', '-c', 'commit.gpgsign=false', '-c', 'user.name=Fixture',
                                           '-c', 'user.email=fixture@example.invalid', '-C', str(checkout), *args],
                                          stderr=subprocess.DEVNULL).decode().strip()
        git('init')
        (checkout / 'Package.swift').write_text('original')
        git('add', '.')
        git('commit', '-m', 'Fixture dependency')
        revision = git('rev-parse', 'HEAD')
        pins = [{'identity': 'fixture', 'state': {'revision': revision}}]
        (self.root / 'Package.resolved').write_text(json.dumps({'pins': pins}))
        return checkout

    def test_dependency_bytes_are_verified_against_pinned_git_tree(self):
        checkout = self.dependency()
        result = self.module.verify_dependencies(self.root)
        self.assertEqual(result['verified_packages'], 1)
        p = checkout / 'Package.swift'
        st = p.stat()
        p.write_text('modified')
        os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
        with self.assertRaises(ValueError):
            self.module.verify_dependencies(self.root)

    def test_untracked_dependency_source_is_rejected(self):
        checkout = self.dependency()
        (checkout / 'Extra.swift').write_text('unexpected input')
        with self.assertRaises(ValueError):
            self.module.verify_dependencies(self.root)

    def test_dependency_parent_symlink_is_rejected_before_timestamp_writes(self):
        checkout = self.dependency()
        parent = checkout.parent
        moved = self.root / 'outside-checkouts'
        parent.rename(moved)
        parent.symlink_to(moved, target_is_directory=True)
        stamp = (moved / 'fixture/Package.swift').stat().st_mtime_ns
        with self.assertRaises(ValueError):
            self.module.verify_dependencies(self.root)
        self.assertEqual((moved / 'fixture/Package.swift').stat().st_mtime_ns, stamp)

    def test_generated_state_links_and_symlink_build_cleanup_are_rejected(self):
        outside = self.root / 'outside'
        outside.mkdir()
        marker = outside / 'build.db'
        marker.write_text('preserve')
        (self.build / 'build.db').unlink()
        (self.build / 'build.db').symlink_to(marker)
        with self.assertRaises(ValueError):
            self.capture()
        import shutil
        shutil.rmtree(self.build)
        self.build.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.module.invalidate(self.root)
        self.assertEqual(marker.read_text(), 'preserve')

    def test_metadata_link_cannot_redirect_restore_or_capture(self):
        outside = self.root / 'outside-metadata.json'
        original = json.dumps({'outside': 'preserve outside data'})
        outside.write_text(original)
        location = self.build / self.module.MANIFEST
        location.symlink_to(outside)
        with self.assertRaises(ValueError):
            self.module.read_manifest(self.root)
        # Regeneration deliberately preserves unrelated data. Capture must replace
        # the link itself rather than following it, even after invalid metadata.
        self.module.invalidate(self.root)
        self.module.write_manifest(self.root, {'safe': True})
        self.assertFalse(location.is_symlink())
        self.assertEqual(json.loads(location.read_text()), {'safe': True})
        self.assertEqual(outside.read_text(), original)

    def test_regeneration_removes_workspace_state_link_before_swiftpm_can_write(self):
        record = self.capture()
        outside = self.root / 'outside-workspace.json'
        outside.write_text('outside state')
        state = self.build / 'workspace-state.json'
        state.symlink_to(outside)
        self.assertEqual(self.restore(record)['status'], 'regenerate')
        self.assertFalse(state.is_symlink())
        self.assertEqual(outside.read_text(), 'outside state')

    def test_repository_and_git_metadata_aliases_are_rejected(self):
        checkout = self.dependency()
        repositories = self.build / 'repositories'
        repositories.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.module.verify_dependencies(self.root)
        repositories.unlink()
        gitdir = checkout / '.git'
        moved = self.root / 'outside-git'
        gitdir.rename(moved)
        gitdir.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.module.verify_dependencies(self.root)
        gitdir.unlink()
        moved.rename(gitdir)
        (gitdir / 'commondir').write_text(str(moved))
        with self.assertRaises(ValueError):
            self.module.verify_dependencies(self.root)

    def test_git_object_alternates_cannot_escape_build_storage(self):
        checkout = self.dependency()
        alternate = checkout / '.git/objects/info/alternates'
        alternate.write_text(str(self.root / 'outside-objects') + '\n')
        with self.assertRaises(ValueError):
            self.module.verify_dependencies(self.root)
        internal = self.build / 'repositories/fixture.git/objects'
        internal.mkdir(parents=True)
        alternate.write_text(str(internal) + '\n')
        self.assertEqual(self.module.verify_dependencies(self.root)['verified_packages'], 1)
