// Simple in-memory rate limits, so a leaked client key (or a bug in the app) can't run up the
// ElevenLabs or OpenAI bill. Two kinds:
//   • per client and route: at most N requests in any 60-second window
//   • for the whole server: at most N characters of speech per day (UTC)
// In memory is enough for a single backend process; several processes would need a shared store.

export interface RateLimits {
  carePerMinute: number;
  voiceTokensPerMinute: number;
  speechPerMinute: number;
  speechCharactersPerDay: number;
}

export const DEFAULT_LIMITS: RateLimits = {
  carePerMinute: 30,             // a care turn every 2 s is already far faster than anyone talks
  voiceTokensPerMinute: 6,       // one per voice session; a few more for reconnects
  speechPerMinute: 40,           // one per line Lofer says
  speechCharactersPerDay: 50_000, // ≈ 25 care sessions
};

export function limitsFromEnv(env = process.env): RateLimits {
  const n = (name: string, fallback: number) => (Number(env[name]) > 0 ? Number(env[name]) : fallback);
  return {
    carePerMinute: n('RATE_LIMIT_CARE_PER_MINUTE', DEFAULT_LIMITS.carePerMinute),
    voiceTokensPerMinute: n('RATE_LIMIT_VOICE_TOKENS_PER_MINUTE', DEFAULT_LIMITS.voiceTokensPerMinute),
    speechPerMinute: n('RATE_LIMIT_SPEECH_PER_MINUTE', DEFAULT_LIMITS.speechPerMinute),
    speechCharactersPerDay: n('SPEECH_CHARACTERS_PER_DAY', DEFAULT_LIMITS.speechCharactersPerDay),
  };
}

export class RateLimiter {
  private readonly recent = new Map<string, number[]>();      // "route client" → request times (ms)
  private day = '';
  private charactersToday = 0;

  readonly limits: RateLimits;
  constructor(limits: RateLimits = DEFAULT_LIMITS) { this.limits = limits; }

  /** Records a request and says whether it's within `perMinute` for this route and client. */
  allow(route: string, client: string, perMinute: number, now = Date.now()): boolean {
    const key = `${route} ${client}`;
    const times = (this.recent.get(key) ?? []).filter((t) => now - t < 60_000);
    if (times.length >= perMinute) { this.recent.set(key, times); return false; }
    times.push(now);
    this.recent.set(key, times);
    if (this.recent.size > 10_000) this.prune(now);               // keep memory bounded
    return true;
  }

  /** Spends speech characters from today's budget. False (and nothing spent) if it would go over. */
  spendSpeechCharacters(count: number, now = new Date()): boolean {
    const today = now.toISOString().slice(0, 10);
    if (today !== this.day) { this.day = today; this.charactersToday = 0; }
    if (this.charactersToday + count > this.limits.speechCharactersPerDay) return false;
    this.charactersToday += count;
    return true;
  }

  private prune(now: number) {
    for (const [key, times] of this.recent) if (times.every((t) => now - t >= 60_000)) this.recent.delete(key);
  }
}
