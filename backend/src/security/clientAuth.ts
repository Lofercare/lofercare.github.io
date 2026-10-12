// Who may call the backend. When LOFER_CLIENT_KEY is set, every /api/* route except
// /api/health needs "Authorization: Bearer <LOFER_CLIENT_KEY>".
//
// This is a shared app key: good for development and TestFlight, but anyone who unpacks the
// app can find it. Before a public release, replace it with Apple App Attest (per-device proof
// that the request comes from a genuine copy of Lofer). See docs/PHASE-4-VOICE.md.
import { createHash, timingSafeEqual } from 'node:crypto';
import type { IncomingMessage } from 'node:http';

export function isAuthorized(req: IncomingMessage, clientKey: string | undefined): boolean {
  if (!clientKey) return true;                       // no key configured: local development only
  const header = req.headers.authorization ?? '';
  const presented = header.startsWith('Bearer ') ? header.slice(7) : '';
  // Compare hashes in constant time, so the response time doesn't leak how much of the key matched.
  const digest = (s: string) => createHash('sha256').update(s).digest();
  return timingSafeEqual(digest(presented), digest(clientKey));
}
