// Chooses the voice provider from the environment (VOICE_PROVIDER).
//   off         no voice routes (they answer 503). The default.
//   mock        fake token + silent audio (tests, offline)
//   elevenlabs  ElevenLabs speech-to-text + text-to-speech (needs ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID)
import type { VoiceProvider } from './VoiceProvider.ts';
import { ElevenLabsVoiceProvider } from './elevenlabs.ts';
import { MockVoiceProvider } from './mock.ts';

export function createVoiceProvider(name = process.env.VOICE_PROVIDER ?? 'off'): VoiceProvider | undefined {
  switch (name) {
    case 'off':
      return undefined;
    case 'mock':
      return new MockVoiceProvider();
    case 'elevenlabs': {
      const apiKey = process.env.ELEVENLABS_API_KEY, voiceId = process.env.ELEVENLABS_VOICE_ID;
      if (!apiKey || !voiceId) throw new Error('VOICE_PROVIDER=elevenlabs needs ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID in backend/.env');
      return new ElevenLabsVoiceProvider({ apiKey, voiceId, ttsModel: process.env.ELEVENLABS_TTS_MODEL || undefined });
    }
    default:
      throw new Error(`Voice provider "${name}" isn't implemented. Use VOICE_PROVIDER=off, mock or elevenlabs.`);
  }
}
