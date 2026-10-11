// Talks to the waitlist database functions in Supabase (see supabase/README.md).
// Only the PUBLISHABLE key is used here. It can call exactly four functions and nothing else:
// the two sign-up steps, and the two personal-link actions on the email-preferences page.
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, CONSENT_VERSION } from './config.js';

/** An error the screens know how to explain. `code` is one of the names below. */
export class WaitlistError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

// Codes the database sends back (see the migration), passed through as they are.
const KNOWN_CODES = ['invalid_email', 'invalid_name', 'rate_limited', 'invalid_token', 'invalid_answer', 'invalid_consent_version', 'invalid_link'];

async function call(fn, body, timeoutMs = 20000) {
  if (!SUPABASE_URL || !SUPABASE_PUBLISHABLE_KEY) throw new WaitlistError('unavailable');

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response;
  try {
    response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: SUPABASE_PUBLISHABLE_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch (error) {
    throw new WaitlistError(error?.name === 'AbortError' ? 'timeout' : 'network');
  } finally {
    clearTimeout(timer);
  }

  if (response.ok) return response.json();
  if (response.status === 429) throw new WaitlistError('rate_limited');
  let code = 'server';
  try {
    const message = String((await response.json())?.message ?? '');
    if (KNOWN_CODES.includes(message)) code = message;
  } catch { /* not JSON: stay with 'server' */ }
  throw new WaitlistError(code);
}

/** Step 1. Resolves to the token needed for Step 2. */
export async function joinWaitlist({ name, email }) {
  const result = await call('join_waitlist', { p_name: name.trim(), p_email: email.trim() });
  if (!result?.ok || typeof result.token !== 'string') throw new WaitlistError('server');
  return { token: result.token };
}

/** Step 2 (optional). `interest` and `price` may be empty. */
export async function updateWaitlist({ token, interest, price, consent }) {
  const result = await call('update_waitlist', {
    p_token: token,
    p_interest: interest || null,
    p_price: price || null,
    p_consent: Boolean(consent),
    p_consent_version: CONSENT_VERSION,
  });
  if (!result?.ok) throw new WaitlistError('server');
}

/** From a personal email link: stop marketing emails (stays on the waitlist). */
export async function unsubscribeByLink(token) {
  const result = await call('unsubscribe_by_link', { p_token: token });
  if (!result?.ok) throw new WaitlistError('server');
}

/** From a personal email link: leave the waitlist (deletes the entry). */
export async function leaveWaitlistByLink(token) {
  const result = await call('leave_waitlist_by_link', { p_token: token });
  if (!result?.ok) throw new WaitlistError('server');
}
