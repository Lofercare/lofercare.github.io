// Runs one Care Intelligence turn: validate the request, ask the provider, validate the
// answer. A provider answer that doesn't match the schema is NEVER passed on: the app gets
// an error and uses its on-device fallback instead. No care logic lives here.
import { CareRequest, CareIntelligenceResponse, SCHEMA_VERSION } from '../schemas/care.ts';
import type { CareIntelligenceProvider } from '../providers/CareIntelligenceProvider.ts';

export type CareResult =
  | { status: 200; body: CareIntelligenceResponse }
  | { status: 400 | 502 | 504; body: { error: string; details?: unknown } };

/** How long a provider gets per turn (an LLM needs longer than the mock). */
export const PROVIDER_TIMEOUT_MS = Number(process.env.CARE_PROVIDER_TIMEOUT_MS ?? 20_000);

export async function handleCareRequest(raw: unknown, provider: CareIntelligenceProvider): Promise<CareResult> {
  const parsed = CareRequest.safeParse(raw);
  if (!parsed.success) {
    return { status: 400, body: { error: 'Invalid CareRequest', details: parsed.error.issues.slice(0, 10) } };
  }
  const request = parsed.data;

  let answer: unknown;
  try {
    answer = await withTimeout(provider.respond(request), PROVIDER_TIMEOUT_MS);
  } catch (error) {
    if (error instanceof TimeoutError) return { status: 504, body: { error: 'Care provider timed out' } };
    return { status: 502, body: { error: 'Care provider failed' } };
  }

  const checked = CareIntelligenceResponse.safeParse(answer);
  if (!checked.success) {
    return { status: 502, body: { error: 'Care provider returned an invalid response', details: checked.error.issues.slice(0, 10) } };
  }
  if (checked.data.requestId !== request.requestId || checked.data.schemaVersion !== SCHEMA_VERSION) {
    return { status: 502, body: { error: 'Care provider answered a different request' } };
  }
  return { status: 200, body: checked.data };
}

class TimeoutError extends Error {}
function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new TimeoutError()), ms);
    p.then((v) => { clearTimeout(timer); resolve(v); }, (e) => { clearTimeout(timer); reject(e); });
  });
}
