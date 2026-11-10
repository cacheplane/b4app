import assert from 'node:assert/strict';
import test from 'node:test';
import { parseEvents } from './sse.mjs';

test('SSE parsing preserves UTF-8 and CRLF frames across arbitrary byte boundaries', async () => {
  const bytes = new TextEncoder().encode(': heartbeat\r\n\r\nevent: chunk\r\ndata: "café"\r\n\r\nevent: done\r\ndata: {"output":{}}\r\n\r\n');
  async function* fragments() {
    for (const byte of bytes) yield Uint8Array.of(byte);
  }
  assert.deepEqual(await Array.fromAsync(parseEvents(fragments())), [
    { event: 'chunk', data: 'café' }, { event: 'done', data: { output: {} } },
  ]);
});
