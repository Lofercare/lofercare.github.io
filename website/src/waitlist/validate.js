// Checks run in the browser before anything is sent. The database checks everything again.

export const NAME_MAX = 100;
export const EMAIL_MAX = 254;

/** Returns an error message, or '' if the name is fine. */
export function nameError(value) {
  const name = String(value ?? '').trim();
  if (!name) return 'Please enter your name.';
  if (name.length > NAME_MAX) return `Please keep your name under ${NAME_MAX} characters.`;
  return '';
}

/** Returns an error message, or '' if the email looks valid. Same rule as the database. */
export function emailError(value) {
  const email = String(value ?? '').trim();
  if (!email) return 'Please enter your email address.';
  if (email.length > EMAIL_MAX || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return 'Please enter a valid email address.';
  return '';
}

/** The personal code from an email link's "#t=…", or '' if it's missing or malformed. */
export function linkToken(hash) {
  const token = new URLSearchParams(String(hash ?? '').replace(/^#/, '')).get('t') ?? '';
  return /^[0-9a-f]{64}$/.test(token) ? token : '';
}
