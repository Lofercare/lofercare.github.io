// What Lofer needs from a speech service: ears (speech-to-text) and a mouth (text-to-speech).
// No conversation, no LLM, no decisions: the app's own Care Intelligence, InvestigationEngine
// and SafetyValidator decide what Lofer says. A voice provider only turns text into audio and
// gives the app a short-lived credential to stream the microphone for transcription.

export interface TranscriptionToken {
  /** Single use, short-lived. The app connects to the speech-to-text WebSocket with it. */
  token: string;
  expiresInSeconds: number;
}

export interface SynthesizedSpeech {
  /** Raw 16-bit little-endian mono PCM at this sample rate, streamed as it's generated. */
  sampleRate: number;
  chunks: AsyncIterable<Uint8Array>;
}

export interface VoiceProvider {
  readonly name: string;
  createTranscriptionToken(): Promise<TranscriptionToken>;
  /** `signal` aborts generation when the app stops listening (an interruption, or a newer line). */
  synthesize(text: string, signal: AbortSignal): Promise<SynthesizedSpeech>;
}

/** A failure talking to the speech service. The message never contains credentials. */
export class VoiceProviderError extends Error {}
