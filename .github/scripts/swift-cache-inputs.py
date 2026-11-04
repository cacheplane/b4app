#!/usr/bin/env python3
"""Verify SwiftPM cache inputs before restoring checkout timestamps; never reuse test results."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import tempfile
import time

SCHEMA = 1
MANIFEST = 'ci-inputs-v1.json'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fingerprint(path):
    s = path.lstat()
    if stat.S_ISLNK(s.st_mode):
        data = os.fsencode(os.readlink(path))
    elif stat.S_ISREG(s.st_mode):
        data = path.read_bytes()
    else:
        raise ValueError('unsupported cache input type')
    return {'sha256': digest(data), 'size': len(data), 'mode': s.st_mode,
            'mtime_ns': s.st_mtime_ns}


def same_bytes(a, b):
    return all(a[k] == b[k] for k in ['sha256', 'size', 'mode'])


def inputs(root):
    raw = subprocess.check_output(['git', 'ls-files', '-z', '--', 'Sources', 'Tests',
                                   'Package.swift', 'Package.resolved'], cwd=root)
    return sorted(os.fsdecode(x) for x in raw.split(b'\0') if x)


def compiler_roots(build):
    return list(build.glob('*-apple-macosx')) + [build / 'plugins']


def artifact_files(root):
    build = root / '.build'
    if build.is_symlink() or not build.resolve().is_relative_to(root.resolve()):
        raise ValueError('unsafe build directory')
    found = [build / 'build.db', build / 'debug.yaml', build / 'workspace-state.json']
    if any(p.is_symlink() for p in found):
        raise ValueError('unsafe generated build state link')
    for directory in compiler_roots(build):
        if directory.is_symlink():
            raise ValueError('unsafe compiler output directory')
        if directory.exists():
            for p in directory.rglob('*'):
                if 'index' in p.relative_to(directory).parts or p.name.endswith(('.lock', '.tmp')):
                    continue
                if p.is_symlink() and not p.resolve().is_relative_to(build.resolve()):
                    raise ValueError('compiler output link escapes build directory')
                if p.is_file() or p.is_symlink():
                    found.append(p)
    return sorted({str(p.relative_to(root)) for p in found if p.is_file() or p.is_symlink()})


def invalidate(root):
    build = root / '.build'
    if build.is_symlink() or not build.resolve().is_relative_to(root.resolve()):
        raise ValueError('build directory escapes checkout')
    for p in compiler_roots(build):
        if p.is_symlink() or p.is_file():
            p.unlink()
        elif p.exists():
            shutil.rmtree(p)
    for name in ['build.db', 'build.db-journal', 'build.db-wal', 'build.db-shm', 'debug.yaml']:
        (build / name).unlink(missing_ok=True)


def capture(root, context, paths, dependency_inputs=None):
    artifacts = artifact_files(root)
    if '.build/build.db' not in artifacts or not any('.xctest/Contents/MacOS/' in p for p in artifacts):
        raise ValueError('complete compiled test state unavailable')
    return {'schema_version': SCHEMA, 'root': str(root.resolve()),
            'context': json.loads(json.dumps(context)),
            'inputs': {p: fingerprint(root / p) for p in paths},
            'dependencies': dependency_inputs or {},
            'artifacts': {p: fingerprint(root / p) for p in artifacts}}


def restore(root, context, paths, record, dependency_inputs=None):
    dependencies = dependency_inputs or {}
    try:
        if (not isinstance(record, dict) or record.get('schema_version') != SCHEMA
                or record.get('root') != str(root.resolve()) or record.get('context') != context):
            raise ValueError('missing or incompatible metadata')
        if set(record['inputs']) != set(paths) or set(record['dependencies']) != set(dependencies):
            raise ValueError('input set changed')
        artifacts = artifact_files(root)
        if set(record['artifacts']) != set(artifacts):
            raise ValueError('partial compiled state')
        # Validate every record and artifact before any timestamp writes. Cached path names
        # never choose writable source paths: paths and dependency keys were freshly discovered.
        all_records = [*record['inputs'].values(), *record['dependencies'].values(),
                       *record['artifacts'].values()]
        for item in all_records:
            if (type(item['mtime_ns']) is not int or not 0 < item['mtime_ns'] <= time.time_ns() + 86400 * 10**9
                    or not re.fullmatch('[0-9a-f]{64}', item['sha256'])
                    or type(item['size']) is not int or type(item['mode']) is not int):
                raise ValueError('malformed input record')
        for p in artifacts:
            if not same_bytes(fingerprint(root / p), record['artifacts'][p]):
                raise ValueError('compiled or generated artifact changed')
        for p, current in dependencies.items():
            if not same_bytes(current, record['dependencies'][p]):
                raise ValueError('dependency input changed')
        current = {p: fingerprint(root / p) for p in paths}
    except (ValueError, KeyError, TypeError, OSError) as error:
        invalidate(root)
        return {'status': 'regenerate', 'reason': str(error), 'restored': 0, 'changed': 0}

    restored = changed = 0
    for p in paths:
        before = current[p]
        old = record['inputs'][p]
        if same_bytes(before, old):
            if stat.S_ISREG(before['mode']):
                os.utime(root / p, ns=((root / p).stat().st_atime_ns, old['mtime_ns']))
                restored += 1
        else:
            changed += 1
            # A content change with colliding size/time must still invalidate SwiftPM's rule.
            if before['mtime_ns'] == old['mtime_ns'] and stat.S_ISREG(before['mode']):
                os.utime(root / p, ns=((root / p).stat().st_atime_ns,
                                      max(time.time_ns(), old['mtime_ns'] + 10**9)))
    for p, old in {**record['dependencies'], **record['artifacts']}.items():
        if stat.S_ISREG(old['mode']):
            os.utime(root / p, ns=((root / p).stat().st_atime_ns, old['mtime_ns']))
    return {'status': 'restored', 'restored': restored, 'changed': changed,
            'artifacts_verified': len(artifacts), 'dependency_files_verified': len(dependencies)}


def verify_dependencies(root):
    """Authenticate checkout bytes against Package.resolved's content-addressed Git trees.

    Read-only cat-file avoids checkout filters/hooks and verifies commit/tree object hashes.
    No optional Git fetch, credentials or external diff/filter program is allowed.
    """
    pins = {p['identity'].lower(): p['state']['revision']
            for p in json.loads((root / 'Package.resolved').read_text())['pins']}
    checkouts = root / '.build/checkouts'
    if (checkouts.parent.is_symlink() or checkouts.is_symlink()
            or not checkouts.resolve().is_relative_to(root.resolve() / '.build')):
        raise ValueError('unsafe dependency checkout directory')
    result = {'verified_packages': 0, 'missing_packages': len(pins), 'inputs': {}}
    if not checkouts.exists():
        return result
    for checkout in sorted(checkouts.iterdir()):
        if not checkout.is_dir() or checkout.is_symlink() or checkout.name.lower() not in pins:
            raise ValueError('unexpected dependency checkout')
        revision = pins[checkout.name.lower()]
        if not re.fullmatch('[0-9a-f]{40}', revision):
            raise ValueError('unsupported locked dependency revision')
        env = dict(os.environ, GIT_NO_LAZY_FETCH='1', GIT_TERMINAL_PROMPT='0',
                   GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
        command = ['git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
                   '-c', 'protocol.allow=never', '-c', 'credential.helper=',
                   '-C', str(checkout), 'cat-file', '--batch']
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=env)

        def object_bytes(oid, kind):
            process.stdin.write(oid.encode() + b'\n')
            process.stdin.flush()
            header = process.stdout.readline().split()
            if len(header) != 3 or header[0].decode() != oid or header[1].decode() != kind:
                raise ValueError('locked Git object unavailable')
            size = int(header[2]); data = process.stdout.read(size)
            if len(data) != size or process.stdout.read(1) != b'\n':
                raise ValueError('truncated Git object')
            if hashlib.sha1(kind.encode() + b' ' + str(size).encode() + b'\0' + data).hexdigest() != oid:
                raise ValueError('corrupt locked Git object')
            return data

        expected = set()

        def tree(oid, relative):
            directory = checkout / relative
            if directory.is_symlink() or not directory.is_dir():
                raise ValueError('dependency directory changed')
            data = object_bytes(oid, 'tree'); offset = 0
            while offset < len(data):
                end = data.index(b'\0', offset)
                mode, name = data[offset:end].split(b' ', 1)
                child_oid = data[end + 1:end + 21].hex(); offset = end + 21
                name = os.fsdecode(name)
                if name in ['.', '..', '.git'] or '/' in name:
                    raise ValueError('unsafe Git tree path')
                path = relative / name
                if mode == b'40000':
                    tree(child_oid, path)
                elif mode in [b'100644', b'100755', b'120000']:
                    p = checkout / path; s = p.lstat()
                    if mode == b'120000':
                        if not p.is_symlink(): raise ValueError('dependency link changed')
                        contents = os.fsencode(os.readlink(p))
                    else:
                        if not stat.S_ISREG(s.st_mode): raise ValueError('dependency file type changed')
                        if bool(s.st_mode & 0o111) != (mode == b'100755'):
                            raise ValueError('dependency executable mode changed')
                        contents = p.read_bytes()
                    if hashlib.sha1(b'blob ' + str(len(contents)).encode() + b'\0' + contents).hexdigest() != child_oid:
                        raise ValueError('dependency source differs from locked Git tree')
                    expected.add(str(path))
                    result['inputs'][str(p.relative_to(root))] = fingerprint(p)
                else:
                    raise ValueError('unsupported Git dependency entry')
        try:
            commit = object_bytes(revision, 'commit')
            tree_oid = commit.splitlines()[0].removeprefix(b'tree ').decode()
            tree(tree_oid, Path())
            actual = set()
            for directory, dirs, files in os.walk(checkout, followlinks=False):
                if Path(directory) == checkout and '.git' in dirs: dirs.remove('.git')
                for name in list(dirs):
                    p = Path(directory) / name
                    if p.is_symlink(): actual.add(str(p.relative_to(checkout))); dirs.remove(name)
                actual.update(str((Path(directory) / name).relative_to(checkout)) for name in files
                              if not (Path(directory) == checkout and name == '.git'))
            if actual != expected:
                raise ValueError('untracked or missing dependency input')
        finally:
            process.stdin.close()
            process.stdout.close()
            process.wait(timeout=10)
        result['verified_packages'] += 1
    result['missing_packages'] -= result['verified_packages']
    return result


def context(root):
    version = subprocess.check_output(['swift', '--version'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-build-version'], text=True).strip()
    files = ['Package.swift', 'Package.resolved', '.github/workflows/ci.yml',
             '.github/scripts/swift-cache-inputs.py', 'Scripts/test-swift.py']
    flags = {k: os.environ.get(k) for k in ['SWIFT_EXEC', 'SWIFT_FLAGS', 'CFLAGS', 'CXXFLAGS',
                                         'LDFLAGS', 'SDKROOT', 'DEVELOPER_DIR', 'CPATH',
                                         'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH',
                                         'MACOSX_DEPLOYMENT_TARGET', 'ARCHS', 'OTHER_SWIFT_FLAGS']}
    return {'compiler': version, 'sdk_build': sdk, 'architecture': platform.machine(),
            'host_target': next(x for x in version.splitlines() if x.startswith('Target:')),
            'configuration': 'debug; no CLI triple override; Package/workflow flags hashed',
            'configuration_files': {p: digest((root / p).read_bytes()) for p in files},
            'build_environment_digest': digest(json.dumps(flags, sort_keys=True).encode())}


def read_manifest(root):
    location = root / '.build' / MANIFEST
    if location.is_symlink():
        raise ValueError('unsafe cache metadata link')
    return json.loads(location.read_text())


def write_manifest(root, record):
    build = root / '.build'
    if build.is_symlink() or build.resolve() != root.resolve() / '.build':
        raise ValueError('unsafe metadata directory')
    fd, name = tempfile.mkstemp(dir=build, prefix='.ci-inputs-', suffix='.tmp')
    temporary = Path(name)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(json.dumps(record, sort_keys=True) + '\n')
        temporary.replace(build / MANIFEST)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['identity', 'capture', 'restore'])
    args = parser.parse_args(); root = Path.cwd().resolve(); paths = inputs(root); ctx = context(root)
    if args.operation == 'identity':
        source = {p: {k: v for k, v in fingerprint(root / p).items() if k != 'mtime_ns'} for p in paths}
        outputs = {'context': digest(json.dumps({'root': str(root), **ctx}, sort_keys=True).encode()),
                   'inputs': digest(json.dumps(source, sort_keys=True).encode())}
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
                for k, v in outputs.items(): stream.write(f'{k}={v}\n')
        print(json.dumps({'operation': args.operation, **outputs, 'identity': ctx}))
        return
    try:
        deps = verify_dependencies(root)
        if args.operation == 'capture':
            if deps['missing_packages']: raise ValueError('dependency checkout incomplete after tests')
            record = capture(root, ctx, paths, deps['inputs'])
            record['producer'] = {'source_sha': os.environ.get('GITHUB_SHA'),
                                  'run_id': os.environ.get('GITHUB_RUN_ID'),
                                  'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
                                  'identity_scope': 'successful package job; cache is not a test result'}
            write_manifest(root, record)
            print(json.dumps({'operation': 'capture', 'input_files': len(paths),
                              'dependency_files': len(deps['inputs']), 'artifacts': len(record['artifacts'])}))
        else:
            try: record = read_manifest(root)
            except (OSError, ValueError): record = None
            print(json.dumps({'operation': 'restore', **restore(root, ctx, paths, record, deps['inputs'])}))
    except (ValueError, OSError) as error:
        invalidate(root)
        raise SystemExit('cache input verification failed; compiled state invalidated: ' + str(error))


if __name__ == '__main__':
    main()
