import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { chmod, cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { LLMock } from '@copilotkit/aimock';
import { parseEvents } from './sse.mjs';

const packageDir = dirname(fileURLToPath(import.meta.url));
const cli = join(packageDir, 'node_modules/@b4run/cli/dist/index.js');
const results = resolve(packageDir, '../../.build/B4Runtime');

export async function startRuntimeFixture({ parentDirectory = tmpdir(), artifactDirectory, onCreate, signal } = {}) {
  const root = await mkdtemp(join(parentDirectory, 'b4aimock-'));
  await chmod(root, 0o700);
  const mock = new LLMock({ host: '127.0.0.1', port: 0, strict: true, strictToolArguments: true });
  const fixture = new RuntimeFixture(root, mock, artifactDirectory, signal);
  try {
    // Register ownership before the first startup await so pipe closure can cancel startup.
    onCreate?.(fixture);
    signal?.throwIfAborted();
    await cp(join(packageDir, 'project'), root, { recursive: true });
    await writeFile(join(root, 'package.json'), JSON.stringify({ private: true, type: 'module' }));
    await symlink(join(packageDir, 'node_modules'), join(root, 'node_modules'), 'dir');
    mock.loadFixtureFile(join(packageDir, 'fixtures/responses.json'));
    signal?.throwIfAborted();
    await mock.start();
    fixture.mockStarted = true;
    fixture.modelURL = mock.url;
    await fixture.start();
    return fixture;
  } catch (error) {
    try { await fixture.close(); }
    catch (cleanupError) { throw new AggregateError([error, cleanupError], 'Runtime fixture startup failed'); }
    throw error;
  }
}

class RuntimeFixture {
  constructor(root, mock, artifactDirectory, signal) {
    this.root = root;
    this.mock = mock;
    this.log = '';
    this.artifactDirectory = artifactDirectory;
    this.signal = signal;
  }

  async start() {
    this.signal?.throwIfAborted();
    assert.ok(!this.child || this.child.exitCode !== null || this.child.signalCode !== null);
    const endpoint = new URL(`${this.mock.url}/v1`);
    assert.equal(endpoint.hostname, '127.0.0.1');
    let readyURL;
    this.childReady = false;
    const child = spawn(process.execPath, [cli, 'start', '--host', '127.0.0.1', '--port', String(this.port ?? 0)], {
      cwd: this.root,
      env: {
        PATH: `${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`,
        TMPDIR: tmpdir(),
        OPENAI_API_KEY: 'fixture-only-not-a-real-key',
        OPENAI_BASE_URL: endpoint.href,
        B4APP_FIXTURE_TOOL_LOG: join(this.root, 'tool-calls.jsonl'),
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    this.child = child;
    let startup = '';
    const capture = (data) => { this.log += data.toString(); };
    child.stderr.on('data', capture);
    child.stdout.on('data', (data) => {
      capture(data);
      startup += data.toString();
      const match = startup.match(/b4 start listening on (http:\/\/127\.0\.0\.1:(\d+))/);
      if (match) {
        this.url = match[1];
        readyURL = match[1];
        this.port = Number(match[2]);
      }
    });
    let spawnError;
    child.on('error', (error) => { spawnError = error; });
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      this.signal?.throwIfAborted();
      if (spawnError) throw spawnError;
      if (child.exitCode !== null || child.signalCode !== null) {
        throw new Error(`B4 exited before readiness: ${this.log}`);
      }
      if (readyURL) {
        try {
          const response = await fetch(`${readyURL}/healthz`, { signal: AbortSignal.timeout(1_000) });
          if (response.ok && (await response.json()).status === 'ready') {
            this.childReady = true;
            return;
          }
        } catch { /* A listener can become ready after the startup line. */ }
      }
      await delay(25);
    }
    throw new Error(`B4 readiness deadline exceeded: ${this.log}`);
  }

  async get(path) {
    const response = await fetch(`${this.url}${path}`, { signal: AbortSignal.timeout(10_000) });
    assert.equal(response.status, 200, await response.clone().text());
    return response.json();
  }

  async createThread() {
    const response = await fetch(`${this.url}/threads`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}',
      signal: AbortSignal.timeout(10_000),
    });
    assert.equal(response.status, 200, await response.clone().text());
    return response.json();
  }

  async *send(threadId, text) {
    const response = await fetch(`${this.url}/threads/${threadId}/runs/stream`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ route: '/chat#agent', input: { messages: [{ role: 'user', content: text }] } }),
      signal: AbortSignal.timeout(30_000),
    });
    if (response.status !== 200) {
      throw new Error(`B4 stream returned ${response.status}: ${await response.text()}`);
    }
    yield* parseEvents(response.body);
  }

  assertProviderRequests() {
    const requests = this.mock.getRequests();
    assert.ok(requests.length > 0, 'the real runtime must reach aimock');
    for (const entry of requests) {
      assert.ok(entry.response.fixture, `Unmatched provider request: ${JSON.stringify(entry.body)}`);
      assert.equal(entry.response.status, 200);
      assert.equal(entry.headers.host, new URL(this.mock.url).host);
    }
    return requests;
  }

  async toolCalls() {
    try { return (await readFile(join(this.root, 'tool-calls.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse); }
    catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  }

  requests() {
    if (this.savedRequests) return this.savedRequests;
    return (this.mockStarted ? this.mock.getRequests() : []).map(({ method, path, body, response }) => ({
      method, path, body, status: response.status, matched: response.fixture !== null,
    }));
  }

  async stop() {
    const child = this.child;
    if (!child?.pid || child.exitCode !== null || child.signalCode !== null) return;
    const exited = once(child, 'exit');
    child.kill('SIGTERM');
    let timer;
    const timedOut = await Promise.race([
      exited.then(() => false),
      new Promise((r) => { timer = setTimeout(() => r(true), 10_000); }),
    ]);
    clearTimeout(timer);
    if (timedOut) {
      child.kill('SIGKILL');
      await exited;
      throw new Error('Owned B4 child needed SIGKILL after shutdown deadline');
    }
    // Startup cancellation can precede B4's installation of its SIGTERM handler.
    // A ready runtime must still prove a graceful exit; the cancelled pre-ready child
    // may instead be reaped after our SIGTERM, without treating normal owner EOF as failure.
    if (!(this.signal?.aborted && !this.childReady && child.signalCode === 'SIGTERM')) {
      assert.equal(child.exitCode, 0, `B4 did not exit normally: ${this.log}`);
    }
  }

  async close() {
    this.closing ??= this.finish();
    return this.closing;
  }

  async finish() {
    const failures = [];
    try { await this.stop(); } catch (error) { failures.push(error); }
    // aimock discards its journal when stop() returns; capture it after B4 has drained.
    this.savedRequests = [];
    try {
      if (this.mockStarted) this.savedRequests = this.mock.getRequests().map(({ method, path, body, response }) => ({
        method, path, body, status: response.status, matched: response.fixture !== null,
      }));
      this.savedToolCalls = await this.toolCalls();
    }
    catch (error) { failures.push(error); }
    try { if (this.mockStarted) await this.mock.stop(); } catch (error) { failures.push(error); }
    try {
      const destination = this.artifactDirectory ?? join(results, this.root.split('/').at(-1));
      await mkdir(destination, { recursive: true });
      await writeFile(join(destination, 'b4.log'), this.log);
      await writeFile(join(destination, 'provider-requests.json'), JSON.stringify(this.savedRequests, null, 2));
      await writeFile(join(destination, 'tool-calls.json'), JSON.stringify(this.savedToolCalls ?? [], null, 2));
    } catch (error) { failures.push(error); }
    await rm(this.root, { recursive: true, force: true });
    if (failures.length) throw new AggregateError(failures, 'Runtime fixture cleanup failed');
  }
}
