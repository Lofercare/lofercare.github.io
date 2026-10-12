// A voice provider for tests and offline work: a fake token and silent audio.
// No network, no key, no cost.
import type { SynthesizedSpeech, TranscriptionToken, VoiceProvider } from './VoiceProvider.ts';

export class MockVoiceProvider implements VoiceProvider {
  readonly name = 'mock';

  async createTranscriptionToken(): Promise<TranscriptionToken> {
    return { token: 'mock-single-use-token', expiresInSeconds: 15 * 60 };
  }

  async synthesize(text: string): Promise<SynthesizedSpeech> {
    // Silence, about as long as the line would take to say (60 ms per character, at most 3 s).
    const sampleRate = 24_000;
    const seconds = Math.min(3, text.length * 0.06);
    const bytes = Math.round(seconds * sampleRate) * 2;
    async function* chunks() { yield new Uint8Array(bytes); }
    return { sampleRate, chunks: chunks() };
  }
}
