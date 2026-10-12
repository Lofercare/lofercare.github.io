// POST /api/care end to end over HTTP, including failures and provider swapping.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp } from '../src/app.ts';
import { MockCareIntelligenceProvider } from '../src/providers/mock/MockCareIntelligenceProvider.ts';
import type { CareIntelligenceProvider } from '../src/providers/CareIntelligenceProvider.ts';
import { CareIntelligenceResponse, type CareRequest } from '../src/schemas/care.ts';
import { createProvider } from '../src/providers/index.ts';
import { request, TENNIS } from './helpers.ts';

const servers: ReturnType<typeof createApp>[] = [];
after(() => servers.forEach((s) => s.close()));
async function serve(provider: CareIntelligenceProvider) {
  const server = createApp(provider);
  servers.push(server);
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address() as AddressInfo;
  return (path: string, body?: unknown, raw?: string) => fetch(`http://127.0.0.1:${port}${path}`, body === undefined && raw === undefined
    ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: raw ?? JSON.stringify(body) });
}

test('health reports the provider', async () => {
  const call = await serve(new MockCareIntelligenceProvider());
  const res = await call('/api/health');
  assert.deepEqual(await res.json(), { ok: true, provider: 'mock', voice: 'off', schemaVersion: 1 });
});

test('a valid request gets a schema-valid structured response', async () => {
  const call = await serve(new MockCareIntelligenceProvider());
  const req = request({ text: TENNIS, expectedField: 'story' });
  const res = await call('/api/care', req);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.ok(CareIntelligenceResponse.safeParse(body).success);
  assert.equal(body.requestId, req.requestId);
});

test('bad input is rejected with 400', async () => {
  const call = await serve(new MockCareIntelligenceProvider());
  assert.equal((await call('/api/care', undefined, '{not json')).status, 400);
  assert.equal((await call('/api/care', { hello: 'world' })).status, 400);
  assert.equal((await call('/api/care', { ...request({ text: 'hi' }), schemaVersion: 99 })).status, 400);
});

test('a provider that fails, or answers badly, never reaches the app', async () => {
  const failing: CareIntelligenceProvider = { name: 'failing', respond: async () => { throw new Error('boom'); } };
  assert.equal((await (await serve(failing))('/api/care', request({ text: 'hi' }))).status, 502);

  // A provider trying to slip in a device command (extra field) is rejected by the strict schema.
  const sneaky: CareIntelligenceProvider = { name: 'sneaky', respond: async (r) => ({ ...(await new MockCareIntelligenceProvider().respond(r)), deviceCommand: { ems: 5 } }) as never };
  assert.equal((await (await serve(sneaky))('/api/care', request({ text: TENNIS }))).status, 502);

  const wrongId: CareIntelligenceProvider = { name: 'stale', respond: async (r) => ({ ...(await new MockCareIntelligenceProvider().respond(r)), requestId: 'other' }) };
  assert.equal((await (await serve(wrongId))('/api/care', request({ text: TENNIS }))).status, 502);
});

test('providers are swappable behind the same interface', async () => {
  // A stand-in for a future LLM provider: same interface, same validated output.
  const future: CareIntelligenceProvider = {
    name: 'future-llm',
    respond: async (r: CareRequest) => ({ ...(await new MockCareIntelligenceProvider().respond(r)), provider: 'future-llm' }),
  };
  const res = await (await serve(future))('/api/care', request({ text: TENNIS }));
  assert.equal(res.status, 200);
  assert.equal((await res.json()).provider, 'future-llm');
  assert.throws(() => createProvider('anthropic'), /isn't implemented/, 'only configured providers exist');
});
