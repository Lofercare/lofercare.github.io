// ElevenLabs, used ONLY for speech-to-text (Scribe v2 Realtime) and text-to-speech (Flash).
// No ElevenLabs agent, agent LLM, custom LLM or agent tools: Lofer runs its own conversation.
//
// The permanent API key stays here on the server. The app gets:
//   • a single-use speech-to-text token (expires after 15 minutes, consumed on first use)
//   • synthesized audio, streamed through this backend (the app never talks to text-to-speech directly)
import { VoiceProviderError, type SynthesizedSpeech, type TranscriptionToken, type VoiceProvider } from './VoiceProvider.ts';

const API = 'https://api.elevenlabs.io';
export const DEFAULT_TTS_MODEL = 'eleven_flash_v2_5';   // ElevenLabs' lowest-latency text-to-speech model
const TTS_SAMPLE_RATE = 24_000;                         // pcm_24000: clear speech, small enough to stream

export interface ElevenLabsOptions {
  apiKey: string;
  voiceId: string;
  ttsModel?: string;
  fetch?: typeof fetch;                                 // tests pass a fake
}

export class ElevenLabsVoiceProvider implements VoiceProvider {
  readonly name = 'elevenlabs';
  readonly ttsModel: string;
  private readonly apiKey: string;
  private readonly voiceId: string;
  private readonly fetch: typeof fetch;

  constructor(options: ElevenLabsOptions) {
    this.apiKey = options.apiKey;
    this.voiceId = options.voiceId;
    this.ttsModel = options.ttsModel || DEFAULT_TTS_MODEL;
    this.fetch = options.fetch ?? fetch;
  }

  async createTranscriptionToken(): Promise<TranscriptionToken> {
    const res = await this.call(`${API}/v1/single-use-token/realtime_scribe`, { method: 'POST', signal: AbortSignal.timeout(10_000) });
    const body = (await res.json().catch(() => null)) as { token?: unknown } | null;
    if (typeof body?.token !== 'string' || !body.token) throw new VoiceProviderError('Speech-to-text token missing from the response');
    return { token: body.token, expiresInSeconds: 15 * 60 };
  }

  async synthesize(text: string, signal: AbortSignal): Promise<SynthesizedSpeech> {
    const url = `${API}/v1/text-to-speech/${encodeURIComponent(this.voiceId)}/stream?output_format=pcm_${TTS_SAMPLE_RATE}`;
    const res = await this.call(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, model_id: this.ttsModel }),
      signal,
    });
    if (!res.body) throw new VoiceProviderError('Text-to-speech returned no audio');
    return { sampleRate: TTS_SAMPLE_RATE, chunks: res.body as unknown as AsyncIterable<Uint8Array> };
  }

  /** One authenticated request. The key goes in a header (never the URL) and never into an error message. */
  private async call(url: string, init: RequestInit): Promise<Response> {
    let res: Response;
    try {
      res = await this.fetch(url, { ...init, headers: { ...(init.headers as Record<string, string>), 'xi-api-key': this.apiKey } });
    } catch (error) {
      if ((error as Error)?.name === 'AbortError') throw error;
      throw new VoiceProviderError('Speech service unreachable');
    }
    if (!res.ok) throw new VoiceProviderError(`Speech service answered ${res.status}`);
    return res;
  }
}
