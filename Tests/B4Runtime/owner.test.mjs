import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { once } from 'node:events';
import { chmod, mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';

const packageDir = dirname(fileURLToPath(import.meta.url));

async function owner(t) {
  const root = await mkdtemp('/tmp/b4smk-');
  await chmod(root, 0o700);
  const child = spawn(process.execPath, [join(packageDir, 'owner.mjs'), root], {
    env: { PATH: `${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`, TMPDIR: tmpdir() },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (data) => { stderr += data; });
  const exited = once(child, 'exit');
  t.after(async () => {
    child.stdin.end();
    if (child.exitCode === null && child.signalCode === null) {
      const timer = setTimeout(() => child.kill('SIGKILL'), 15_000);
      try { await exited; } finally { clearTimeout(timer); }
    }
    await rm(root, { recursive: true, force: true });
  });
  async function manifest(id) {
    const deadline = Date.now() + 40_000;
    while (Date.now() < deadline) {
      try {
        const value = JSON.parse(await readFile(join(root, 'b4-runtime.json'), 'utf8'));
        if (value.id === id) return value;
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      assert.equal(child.exitCode, null, `owner exited before ${id}: ${stderr}`);
      await delay(25);
    }
    assert.fail(`owner did not acknowledge ${id}: ${stderr}`);
  }
  async function command(id, command) {
    child.stdin.write(`${JSON.stringify({ id, command })}\n`);
    return manifest(id);
  }
  return { root, child, exited, manifest, command, stderr: () => stderr };
}

async function closed(url) {
  await assert.rejects(fetch(url, { signal: AbortSignal.timeout(1_000) }));
}

async function request(url, path, body) {
  const response = await fetch(`${url}${path}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  assert.equal(response.status, 200, await response.clone().text());
  return response;
}

test('owner preserves endpoint and journal across commands and EOF closes both listeners with artifacts', { timeout: 90_000 }, async (t) => {
  const fixture = await owner(t);
  const ready = await fixture.manifest('startup');
  assert.deepEqual(Object.keys(ready).sort(), ['id', 'modelURL', 'projectPath', 'requests', 'state', 'toolCalls', 'url']);
  assert.equal(ready.state, 'ready');
  assert.ok(ready.projectPath.startsWith(`${fixture.root}/`));
  assert.equal(new URL(ready.url).hostname, '127.0.0.1');
  assert.equal(new URL(ready.modelURL).hostname, '127.0.0.1');
  const thread = await (await request(ready.url, '/threads', {})).json();
  await (await request(ready.url, `/threads/${thread.id}/runs/stream`, {
    route: '/chat#agent', input: { messages: [{ role: 'user', content: 'smoke-tool' }] },
  })).text();
  const snapshot = await fixture.command('journal-snapshot', 'snapshot');
  assert.equal(snapshot.state, 'ready');
  assert.equal(snapshot.requests.length, 2);
  for (const entry of snapshot.requests) {
    assert.deepEqual(Object.keys(entry).sort(), ['body', 'matched', 'method', 'path', 'status']);
    assert.equal(entry.matched, true);
    assert.equal(entry.status, 200);
  }
  assert.deepEqual(snapshot.toolCalls, [{ query: 'fixture-proof' }]);
  const stopped = await fixture.command('stop-1', 'stop');
  assert.equal(stopped.state, 'stopped');
  assert.equal(stopped.url, ready.url);
  assert.equal(stopped.modelURL, ready.modelURL);
  await closed(`${ready.url}/healthz`);
  assert.equal((await fetch(`${ready.modelURL}/health`, { signal: AbortSignal.timeout(1_000) })).status, 200);
  assert.equal((await fixture.command('stopped-snapshot', 'snapshot')).state, 'stopped');
  const restarted = await fixture.command('start-1', 'start');
  assert.equal(restarted.state, 'ready');
  assert.equal(restarted.url, ready.url);
  assert.equal(restarted.projectPath, ready.projectPath);
  const previous = await (await fetch(`${ready.url}/threads/${thread.id}`)).json();
  assert.equal(previous.id, thread.id);
  fixture.child.stdin.end();
  assert.deepEqual(await fixture.exited, [0, null], fixture.stderr());
  await closed(`${ready.url}/healthz`);
  await closed(`${ready.modelURL}/health`);
  assert.ok((await stat(join(fixture.root, 'b4-artifacts/b4.log'))).size > 0);
  assert.deepEqual(JSON.parse(await readFile(join(fixture.root, 'b4-artifacts/tool-calls.json'))), snapshot.toolCalls);
  assert.equal(JSON.parse(await readFile(join(fixture.root, 'b4-artifacts/provider-requests.json'))).length, 2);
  await assert.rejects(stat(ready.projectPath), { code: 'ENOENT' });
});

for (const [name, line, id] of [
  ['unknown command', JSON.stringify({ id: 'unknown-1', command: 'erase' }), 'unknown-1'],
  ['malformed JSON', '{oops', 'startup'],
  ['missing operation id', JSON.stringify({ command: 'snapshot' }), 'startup'],
]) {
  test(`owner rejects ${name} and cleans up`, { timeout: 60_000 }, async (t) => {
    const fixture = await owner(t);
    const ready = await fixture.manifest('startup');
    fixture.child.stdin.write(`${line}\n`);
    assert.deepEqual(await fixture.exited, [1, null]);
    const failed = await fixture.manifest(id);
    assert.equal(failed.state, 'failed');
    assert.match(failed.error, /command|JSON/i);
    await closed(`${ready.url}/healthz`);
    await closed(`${ready.modelURL}/health`);
    assert.ok((await stat(join(fixture.root, 'b4-artifacts/b4.log'))).size > 0);
  });
}

test('SIGTERM after readiness closes both owned servers normally', { timeout: 60_000 }, async (t) => {
  const fixture = await owner(t);
  const ready = await fixture.manifest('startup');
  assert.equal(ready.state, 'ready', fixture.stderr());
  fixture.child.kill('SIGTERM');
  assert.deepEqual(await fixture.exited, [0, null], fixture.stderr());
  await closed(`${ready.url}/healthz`);
  await closed(`${ready.modelURL}/health`);
  assert.equal((await fixture.manifest('startup')).state, 'stopped');
});

for (const termination of ['EOF', 'SIGTERM']) {
  test(`${termination} during startup closes normally without leaving runtime processes`, { timeout: 60_000 }, async (t) => {
    const fixture = await owner(t);
    // Observe an owned inner project before closing, rather than ending the pipe before startup runs.
    const deadline = Date.now() + 30_000;
    while (!(await readdir(fixture.root)).some((name) => name.startsWith('b4aimock-'))) {
      assert.ok(Date.now() < deadline, 'owner did not begin fixture startup');
      assert.equal(fixture.child.exitCode, null, fixture.stderr());
      await delay(5);
    }
    if (termination === 'EOF') fixture.child.stdin.end();
    else fixture.child.kill('SIGTERM');
    assert.deepEqual(await fixture.exited, [0, null], fixture.stderr());
    const manifest = JSON.parse(await readFile(join(fixture.root, 'b4-runtime.json')));
    assert.equal(manifest.state, 'stopped');
    if (manifest.url) await closed(`${manifest.url}/healthz`);
    if (manifest.modelURL) await closed(`${manifest.modelURL}/health`);
    assert.ok((await stat(join(fixture.root, 'b4-artifacts/provider-requests.json'))).isFile());
  });
}

test('EOF after B4 spawn cancels startup and reaps that owned child', { timeout: 60_000 }, async (t) => {
  const fixture = await owner(t);
  let pid;
  const deadline = Date.now() + 30_000;
  while (!pid) {
    // Inspect only this owner's immediate child; no process names or global signals.
    const { stdout } = await promisify(execFile)('/usr/bin/pgrep', ['-P', String(fixture.child.pid)])
      .catch((error) => { if (error.code === 1) return { stdout: '' }; throw error; });
    pid = Number(stdout.trim()) || undefined;
    assert.ok(Date.now() < deadline, 'owner never spawned B4');
    assert.equal(fixture.child.exitCode, null, fixture.stderr());
    if (!pid) await delay(5);
  }
  fixture.child.stdin.end();
  assert.deepEqual(await fixture.exited, [0, null], fixture.stderr());
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  const manifest = await fixture.manifest('startup');
  assert.equal(manifest.state, 'stopped');
  await closed(`${manifest.modelURL}/health`);
});
