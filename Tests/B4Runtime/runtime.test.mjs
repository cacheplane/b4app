import assert from 'node:assert/strict';
import test from 'node:test';
import { startRuntimeFixture } from './runtime-fixture.mjs';

test('real B4 routes to aimock and streams before the turn finishes', { timeout: 60_000 }, async (t) => {
  const fixture = await startRuntimeFixture();
  t.after(() => fixture.close());
  const thread = await fixture.createThread();
  const events = [];
  let sawBusyPartialReply = false;
  for await (const event of fixture.send(thread.id, 'smoke-stream')) {
    events.push(event);
    if (event.event === 'chunk' && !sawBusyPartialReply) {
      const current = await fixture.get(`/threads/${thread.id}`);
      assert.equal(current.status, 'busy', 'first text must arrive while B4 is still working');
      assert.notEqual(text(events), 'Streaming fixture reply arrives in several pieces.');
      sawBusyPartialReply = true;
    }
  }
  assert.ok(sawBusyPartialReply, 'a completed/buffered answer cannot prove live streaming');
  assert.ok(events.filter((e) => e.event === 'chunk').length > 1);
  assert.equal(text(events), 'Streaming fixture reply arrives in several pieces.');
  assertCompleted(events);
  const requests = fixture.assertProviderRequests();
  assert.equal(requests.length, 1);
  assert.equal(requests[0].path, '/v1/chat/completions');
  assert.equal(requests[0].body.model, 'gpt-4.1-mini');
  assert.equal(requests[0].body.stream, true);
});

function text(events) {
  return events.filter((e) => e.event === 'chunk').map((e) => e.data).join('');
}

function assertCompleted(events) {
  const terminal = events.filter((e) => e.event === 'done');
  assert.equal(terminal.length, 1, 'each positive turn needs one terminal event');
  assert.equal(events.at(-1).event, 'done');
  const output = terminal[0].data.output;
  assert.ok(output && typeof output === 'object', 'a detached stream is not successful completion');
  assert.equal(Object.hasOwn(output, 'error'), false, JSON.stringify(output));
  assert.notEqual(output.cancelled, true);
}

test('real B4 executes a tool and sends its actual result to the next model round', { timeout: 60_000 }, async (t) => {
  const fixture = await startRuntimeFixture();
  t.after(() => fixture.close());
  const thread = await fixture.createThread();
  const events = await Array.fromAsync(fixture.send(thread.id, 'smoke-tool'));
  const calls = events.filter((e) => e.event === 'tool_call');
  const results = events.filter((e) => e.event === 'tool_result');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].data.name, 'fixture_lookup');
  assert.equal(results.length, 1);
  assert.match(JSON.stringify(results[0].data), /fixture-value/);
  assert.deepEqual(await fixture.toolCalls(), [{ query: 'fixture-proof' }]);
  assert.equal(text(events), 'The real fixture lookup returned fixture-value.');
  assertCompleted(events);
  const requests = fixture.assertProviderRequests();
  assert.equal(requests.length, 2);
  const toolResult = requests[1].body.messages.find((m) => m.role === 'tool');
  assert.ok(toolResult, 'the runtime must return the tool result to the provider');
  assert.equal(toolResult.tool_call_id, 'call_fixture_lookup');
  assert.match(toolResult.content, /fixture-value/);
  assert.ok(events.indexOf(results[0]) < events.findIndex((e) => e.event === 'chunk'));
});

test('real B4 restart retains the same thread and continues without replaying a turn', { timeout: 90_000 }, async (t) => {
  const fixture = await startRuntimeFixture();
  t.after(() => fixture.close());
  const thread = await fixture.createThread();
  const first = await Array.fromAsync(fixture.send(thread.id, 'smoke-tool'));
  assert.equal(text(first), 'The real fixture lookup returned fixture-value.');
  assertCompleted(first);
  assert.deepEqual(await fixture.toolCalls(), [{ query: 'fixture-proof' }]);
  const endpoint = fixture.url;
  await fixture.stop();
  await assert.rejects(fetch(`${endpoint}/healthz`, { signal: AbortSignal.timeout(1_000) }));
  await fixture.start();
  assert.equal(fixture.url, endpoint);
  assert.equal((await fixture.get(`/threads/${thread.id}`)).id, thread.id);
  const previous = await fixture.get(`/threads/${thread.id}/state`);
  assert.match(JSON.stringify(previous), /The real fixture lookup returned fixture-value\./);
  assert.deepEqual(await fixture.toolCalls(), [{ query: 'fixture-proof' }]);
  const followUp = await Array.fromAsync(fixture.send(thread.id, 'smoke-after-restart'));
  assert.equal(text(followUp), 'The same conversation continued after restart.');
  assertCompleted(followUp);
  const requests = fixture.assertProviderRequests();
  assert.equal(requests.length, 3, 'one tool round and one follow-up must not be replayed');
  assert.equal(requests[2].body.messages.filter((m) => m.role === 'user' && m.content === 'smoke-tool').length, 1);
  assert.ok(requests[2].body.messages.some((m) => m.role === 'assistant' && m.content === text(first)));
  assert.deepEqual(await fixture.toolCalls(), [{ query: 'fixture-proof' }]);
});

test('an unmatched model request fails explicitly and is rejected by the fixture assertions', { timeout: 60_000 }, async (t) => {
  const fixture = await startRuntimeFixture();
  t.after(() => fixture.close());
  const thread = await fixture.createThread();
  const events = await Array.fromAsync(fixture.send(thread.id, 'no-such-fixture'));
  assert.equal(text(events), '');
  assert.ok(events.some((e) => e.event === 'done' && e.data.output?.error));
  assert.equal(fixture.mock.getRequests().length, 1, 'fixture failures must not be retried');
  assert.equal(fixture.mock.getRequests()[0].response.status, 503);
  assert.throws(() => fixture.assertProviderRequests(), /Unmatched provider request/);
});
