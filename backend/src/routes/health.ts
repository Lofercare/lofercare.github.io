// GET /api/health: is the backend up, and which providers are answering?
import type { ServerResponse } from 'node:http';
import type { CareIntelligenceProvider } from '../providers/CareIntelligenceProvider.ts';
import { SCHEMA_VERSION } from '../schemas/care.ts';
import type { VoiceProvider } from '../voice/VoiceProvider.ts';
import { sendJson } from './http.ts';

export function healthRoute(res: ServerResponse, provider: CareIntelligenceProvider, voice?: VoiceProvider) {
  sendJson(res, 200, { ok: true, provider: provider.name, voice: voice?.name ?? 'off', schemaVersion: SCHEMA_VERSION });
}
