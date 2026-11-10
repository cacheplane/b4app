import { lstat, realpath, rename, writeFile } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join } from 'node:path';
import { createInterface } from 'node:readline';
import { startRuntimeFixture } from './runtime-fixture.mjs';

const [root, ...extra] = process.argv.slice(2);
const controller = new AbortController();
let fixture;
let state = 'stopped';
let id = 'startup';
let failure;
let closing = false;
let validRoot = false;
let finalizer;

async function publish() {
  if (!validRoot) return;
  const manifest = {
    id, state, url: fixture?.url ?? '', modelURL: fixture?.modelURL ?? '',
    projectPath: fixture?.root ?? '', requests: fixture?.requests() ?? [],
    toolCalls: fixture?.savedToolCalls ?? await fixture?.toolCalls() ?? [],
  };
  if (failure) manifest.error = failure.message;
  const temporary = join(root, 'b4-runtime.json.tmp');
  await writeFile(temporary, `${JSON.stringify(manifest)}\n`, { mode: 0o600 });
  await rename(temporary, join(root, 'b4-runtime.json'));
}

function fail(error) {
  if (closing && error.name === 'AbortError') return;
  failure ??= error;
  process.exitCode = 1;
  console.error(error.stack ?? error);
  shutdown();
}

function shutdown() {
  if (closing) return;
  closing = true;
  controller.abort();
  input.close();
  process.stdin.pause();
  // Wait for startup/current command to settle before final cleanup. Abort makes readiness
  // polling stop promptly; no queued command may spawn after this ownership boundary closes.
  finalizer = queue.then(async () => {
    try { await fixture?.close(); }
    catch (error) { failure ??= error; process.exitCode = 1; console.error(error.stack ?? error); }
    state = failure ? 'failed' : 'stopped';
    await publish();
  }).catch((error) => { process.exitCode = 1; console.error(error.stack ?? error); });
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
let queue = Promise.resolve().then(async () => {
  if (!root || extra.length || !isAbsolute(root) || !/^b4smk-[a-zA-Z0-9_-]+$/.test(basename(root))) {
    throw new Error('Expected one private /tmp/b4smk-* directory');
  }
  const info = await lstat(root);
  if (!info.isDirectory() || (info.mode & 0o777) !== 0o700 || info.uid !== process.getuid()
      || await realpath(dirname(root)) !== await realpath('/tmp')) {
    throw new Error('Owner root must be an owned private 0700 directory directly under /tmp');
  }
  validRoot = true;
  await startRuntimeFixture({
    parentDirectory: root, artifactDirectory: join(root, 'b4-artifacts'),
    signal: controller.signal, onCreate: (created) => { fixture = created; },
  });
  state = 'ready';
  if (!closing) await publish();
}).catch(fail);

input.on('line', (line) => {
  queue = queue.then(async () => {
    if (closing) return;
    let command;
    try { command = JSON.parse(line); }
    catch { throw new Error('Malformed command JSON'); }
    if (typeof command?.id === 'string' && command.id.trim()) id = command.id;
    if (!command || typeof command !== 'object' || Array.isArray(command)
        || typeof command.id !== 'string' || !command.id.trim()
        || !['stop', 'start', 'snapshot'].includes(command.command)) {
      throw new Error('Invalid command: requires nonempty id and stop, start, or snapshot');
    }
    if (command.command === 'stop') { await fixture.stop(); state = 'stopped'; }
    if (command.command === 'start' && state === 'stopped') { await fixture.start(); state = 'ready'; }
    await publish();
  }).catch(fail);
});
input.on('close', shutdown);
input.on('error', fail);
process.stdin.on('error', fail);
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
