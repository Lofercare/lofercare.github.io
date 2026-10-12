// Voice routes, client authentication and rate limits, over HTTP. Offline: the ElevenLabs
// provider is tested with a fake fetch, so no key and no network are needed.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { createApp, type AppOptions } from '../src/app.ts';
import { MockCareIntelligenceProvider } from '../src/providers/mock/MockCareIntelligenceProvider.ts';
import { DEFAULT_LIMITS, RateLimiter } from '../src/security/rateLimit.ts';
import { ElevenLabsVoiceProvider } from '../src/voice/elevenlabs.ts';
import { MockVoiceProvider } from '../src/voice/mock.ts';
import { createVoiceProvider } from '../src/voice/index.ts';
import { request, TENNIS } from './helpers.ts';

const KEY = 'test-client-key';
const servers: ReturnType<typeof createApp>[] = [];
after(() => servers.forEach((s) => s.close()));

async function serve(options: AppOptions) {
  const server = createApp(new MockCareIntelligenceProvider(), options);
  servers.push(server);
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address() as AddressInfo;
  return (path: string, body?: unknown, key: string | null = KEY) => fetch(`http://127.0.0.1:${port}${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { 'Content-Type': 'application/json', ...(key ? { Authorization: `Bearer ${key}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

// MARK: authentication

test('with a client key, care and voice routes need it; health stays open', async () => {
  const call = await serve({ voice: new MockVoiceProvider(), clientKey: KEY });
  assert.equal((await call('/api/health', undefined, null)).status, 200);
  assert.equal((await call('/api/care', request({ text: TENNIS }), null)).status, 401);
  assert.equal((await call('/api/care', request({ text: TENNIS }), 'wrong-key')).status, 401);
  assert.equal((await call('/api/voice/token', {}, null)).status, 401);
  assert.equal((await call('/api/voice/speech', { text: 'Hello' }, null)).status, 401);
  assert.equal((await call('/api/care', request({ text: TENNIS }))).status, 200);
  assert.equal((await call('/api/voice/token', {})).status, 200);
});

// MARK: voice routes

test('health reports the voice provider', async () => {
  const call = await serve({ voice: new MockVoiceProvider() });
  assert.equal((await (await call('/api/health')).json()).voice, 'mock');
});

test('a single-use speech-to-text token is issued', async () => {
  const call = await serve({ voice: new MockVoiceProvider(), clientKey: KEY });
  const res = await call('/api/voice/token', {});
  assert.deepEqual(await res.json(), { token: 'mock-single-use-token', expiresInSeconds: 900 });
});

test('speech streams 16-bit PCM with its sample rate', async () => {
  const call = await serve({ voice: new MockVoiceProvider(), clientKey: KEY });
  const res = await call('/api/voice/speech', { text: 'Show me where it is bothering you.' });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'audio/pcm');
  assert.equal(res.headers.get('x-sample-rate'), '24000');
  const bytes = (await res.arrayBuffer()).byteLength;
  assert.ok(bytes > 0 && bytes % 2 === 0, 'whole 16-bit samples');
});

test('speech text is validated', async () => {
  const call = await serve({ voice: new MockVoiceProvider(), clientKey: KEY });
  assert.equal((await call('/api/voice/speech', { text: '   ' })).status, 400);
  assert.equal((await call('/api/voice/speech', { text: 'x'.repeat(501) })).status, 400);
  assert.equal((await call('/api/voice/speech', { text: 'Hi', voice: 'someone-else' })).status, 400, 'no extra fields (e.g. choosing another voice)');
});

test('voice routes answer 503 when voice is off', async () => {
  const call = await serve({});
  assert.equal((await call('/api/voice/token', {})).status, 503);
  assert.equal((await call('/api/voice/speech', { text: 'Hi' })).status, 503);
});

// MARK: rate limits

test('per-client rate limits return 429', async () => {
  const call = await serve({ voice: new MockVoiceProvider(), clientKey: KEY, limits: { ...DEFAULT_LIMITS, voiceTokensPerMinute: 2 } });
  assert.equal((await call('/api/voice/token', {})).status, 200);
  assert.equal((await call('/api/voice/token', {})).status, 200);
  assert.equal((await call('/api/voice/token', {})).status, 429);
});

test('the daily speech budget is enforced', async () => {
  const call = await serve({ voice: new MockVoiceProvider(), clientKey: KEY, limits: { ...DEFAULT_LIMITS, speechCharactersPerDay: 10 } });
  assert.equal((await call('/api/voice/speech', { text: 'Hello.' })).status, 200);       // 6 characters
  assert.equal((await call('/api/voice/speech', { text: 'Hello.' })).status, 429);       // would make 12
});

test('the rate limiter forgets requests older than a minute', () => {
  const limiter = new RateLimiter();
  assert.ok(limiter.allow('care', 'a', 1, 0));
  assert.ok(!limiter.allow('care', 'a', 1, 30_000));
  assert.ok(limiter.allow('care', 'b', 1, 30_000), 'per client');
  assert.ok(limiter.allow('care', 'a', 1, 61_000));
});

// MARK: the ElevenLabs provider (fake fetch)

const SECRET = 'sk_secret_never_leaks';
function fakeFetch(respond: (url: string, init: RequestInit) => Response) {
  const calls: { url: string; init: RequestInit }[] = [];
  const f = (async (url: string | URL, init: RequestInit = {}) => { calls.push({ url: String(url), init }); return respond(String(url), init); }) as typeof fetch;
  return { f, calls };
}

test('ElevenLabs: the token comes from the single-use token endpoint, key in a header only', async () => {
  const { f, calls } = fakeFetch(() => Response.json({ token: 'sutkn_123' }));
  const provider = new ElevenLabsVoiceProvider({ apiKey: SECRET, voiceId: 'voice-1', fetch: f });
  assert.deepEqual(await provider.createTranscriptionToken(), { token: 'sutkn_123', expiresInSeconds: 900 });
  assert.equal(calls[0].url, 'https://api.elevenlabs.io/v1/single-use-token/realtime_scribe');
  assert.equal(calls[0].init.method, 'POST');
  assert.equal((calls[0].init.headers as Record<string, string>)['xi-api-key'], SECRET);
  assert.ok(!calls[0].url.includes(SECRET));
});

test('ElevenLabs: speech uses the configured voice, Flash and PCM', async () => {
  const { f, calls } = fakeFetch(() => new Response(new Uint8Array([1, 0, 2, 0])));
  const provider = new ElevenLabsVoiceProvider({ apiKey: SECRET, voiceId: 'voice-1', fetch: f });
  const speech = await provider.synthesize('Paused.', new AbortController().signal);
  assert.equal(speech.sampleRate, 24000);
  assert.equal(calls[0].url, 'https://api.elevenlabs.io/v1/text-to-speech/voice-1/stream?output_format=pcm_24000');
  assert.deepEqual(JSON.parse(String(calls[0].init.body)), { text: 'Paused.', model_id: 'eleven_flash_v2_5' });
});

test('ElevenLabs failures become a 502 that never contains the key', async () => {
  const { f } = fakeFetch(() => new Response(`invalid key ${SECRET}`, { status: 401 }));
  const call = await serve({ voice: new ElevenLabsVoiceProvider({ apiKey: SECRET, voiceId: 'v', fetch: f }), clientKey: KEY });
  for (const res of [await call('/api/voice/token', {}), await call('/api/voice/speech', { text: 'Hi' })]) {
    assert.equal(res.status, 502);
    assert.ok(!(await res.text()).includes(SECRET));
  }
});

test('VOICE_PROVIDER=elevenlabs refuses to start without its settings', () => {
  const saved = { ...process.env };
  delete process.env.ELEVENLABS_API_KEY;
  try { assert.throws(() => createVoiceProvider('elevenlabs'), /ELEVENLABS_API_KEY/); }
  finally { Object.assign(process.env, saved); }
  assert.equal(createVoiceProvider('off'), undefined);
});
