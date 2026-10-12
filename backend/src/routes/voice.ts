// Voice routes. Speech only: these never see Care Intelligence and never decide anything.
//   POST /api/voice/token   → { token, expiresInSeconds }   single-use speech-to-text token
//   POST /api/voice/speech  { text } → streamed audio (16-bit mono PCM, rate in X-Sample-Rate)
import { once } from 'node:events';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { z } from 'zod';
import type { RateLimiter } from '../security/rateLimit.ts';
import { VoiceProviderError, type VoiceProvider } from '../voice/VoiceProvider.ts';
import { readJson, sendJson } from './http.ts';

/** Lofer's lines are short; anything longer is a bug or abuse, and costs money to say. */
export const MAX_SPEECH_CHARACTERS = 500;
const SpeechRequest = z.object({ text: z.string().trim().min(1).max(MAX_SPEECH_CHARACTERS) }).strict();

// One line per request with no personal details: never the text itself (it's about the user's body).
const log = (line: string) => { if (process.env.NODE_ENV !== 'test') console.log(line); };

/** Why the speech service failed, safe to log: our own error messages never contain the key. */
const reason = (error: unknown) => (error instanceof VoiceProviderError ? error.message : 'unexpected error');

export async function voiceTokenRoute(res: ServerResponse, voice: VoiceProvider) {
  try {
    sendJson(res, 200, await voice.createTranscriptionToken());
    log('[voice] token → 200');
  } catch (error) {
    sendJson(res, 502, { error: 'Speech service unavailable' });
    log(`[voice] token → 502 (${reason(error)})`);
  }
}

export async function speechRoute(req: IncomingMessage, res: ServerResponse, voice: VoiceProvider, limiter: RateLimiter) {
  const body = await readJson(req);
  if (!body.ok) return sendJson(res, body.status, { error: body.error });
  const parsed = SpeechRequest.safeParse(body.value);
  if (!parsed.success) return sendJson(res, 400, { error: `Expected { text } with 1–${MAX_SPEECH_CHARACTERS} characters` });
  const { text } = parsed.data;
  if (!limiter.spendSpeechCharacters(text.length)) return sendJson(res, 429, { error: 'Daily speech budget used up' });

  // If the app hangs up (Lofer was interrupted, or a newer line replaced this one), stop generating.
  const abort = new AbortController();
  res.on('close', () => { if (!res.writableFinished) abort.abort(); });

  let speech;
  try {
    speech = await voice.synthesize(text, abort.signal);
  } catch (error) {
    if (abort.signal.aborted) return;
    log(`[voice] speech ${text.length} chars → 502 (${reason(error)})`);
    return sendJson(res, 502, { error: 'Speech service unavailable' });
  }
  res.writeHead(200, { 'Content-Type': 'audio/pcm', 'X-Audio-Format': 'pcm_s16le', 'X-Sample-Rate': String(speech.sampleRate), 'Cache-Control': 'no-store' });
  try {
    for await (const chunk of speech.chunks) {
      if (abort.signal.aborted) break;
      if (!res.write(chunk)) await once(res, 'drain');
    }
    res.end();
    log(`[voice] speech ${text.length} chars → 200${abort.signal.aborted ? ' (interrupted)' : ''}`);
  } catch {
    res.destroy();                                   // the stream broke mid-way: the app treats it as an error
  }
}
