// The Lofer backend as an http.Server, with the providers passed in (so tests can swap them).
import { createServer, type IncomingMessage, type Server } from 'node:http';
import type { CareIntelligenceProvider } from './providers/CareIntelligenceProvider.ts';
import { careRoute } from './routes/care.ts';
import { healthRoute } from './routes/health.ts';
import { sendJson } from './routes/http.ts';
import { speechRoute, voiceTokenRoute } from './routes/voice.ts';
import { isAuthorized } from './security/clientAuth.ts';
import { DEFAULT_LIMITS, RateLimiter, type RateLimits } from './security/rateLimit.ts';
import type { VoiceProvider } from './voice/VoiceProvider.ts';

export interface AppOptions {
  /** Speech-to-text tokens + text-to-speech. Without one, the voice routes answer 503. */
  voice?: VoiceProvider;
  /** When set, every /api/* route except /api/health needs "Authorization: Bearer <clientKey>". */
  clientKey?: string;
  limits?: RateLimits;
}

export function createApp(provider: CareIntelligenceProvider, options: AppOptions = {}): Server {
  const limiter = new RateLimiter(options.limits ?? DEFAULT_LIMITS);
  const { voice, clientKey } = options;
  return createServer(async (req, res) => {
    try {
      const path = (req.url ?? '/').split('?')[0];
      if (req.method === 'GET' && path === '/api/health') return healthRoute(res, provider, voice);
      if (!isAuthorized(req, clientKey)) return sendJson(res, 401, { error: 'Unauthorized' });

      const client = clientAddress(req);
      const tooMany = () => sendJson(res, 429, { error: 'Too many requests. Try again in a minute.' });
      if (req.method === 'POST' && path === '/api/care') {
        if (!limiter.allow('care', client, limiter.limits.carePerMinute)) return tooMany();
        return await careRoute(req, res, provider);
      }
      if (req.method === 'POST' && (path === '/api/voice/token' || path === '/api/voice/speech')) {
        if (!voice) return sendJson(res, 503, { error: 'Voice is off on this server (VOICE_PROVIDER)' });
        if (path === '/api/voice/token') {
          if (!limiter.allow('voice-token', client, limiter.limits.voiceTokensPerMinute)) return tooMany();
          return await voiceTokenRoute(res, voice);
        }
        if (!limiter.allow('speech', client, limiter.limits.speechPerMinute)) return tooMany();
        return await speechRoute(req, res, voice, limiter);
      }
      sendJson(res, 404, { error: 'Not found' });
    } catch {
      if (!res.headersSent) sendJson(res, 500, { error: 'Internal error' });
      else res.destroy();
    }
  });
}

/** Rate limits are per network address. (Behind a proxy this would read the proxy's header instead.) */
function clientAddress(req: IncomingMessage): string {
  return req.socket.remoteAddress ?? 'unknown';
}
