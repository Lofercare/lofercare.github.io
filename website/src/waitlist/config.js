// Settings and wording for the waitlist. Plain data, so tests can read it too.

// Where the waitlist database lives. Both values are PUBLIC by design (the publishable key can
// only call the four waitlist functions; see supabase/README.md). They come from the build
// environment: website/.env.local on your machine, repository variables on GitHub.
export const SUPABASE_URL = (import.meta.env?.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
export const SUPABASE_PUBLISHABLE_KEY = import.meta.env?.VITE_SUPABASE_PUBLISHABLE_KEY ?? '';

// The marketing checkbox wording, and its version. The database keeps a copy of each version
// (table waitlist_consent_texts) and stamps it on the entry when someone ticks the box.
// If you change the wording, add a new version in the database too. A test checks they match.
export const CONSENT_VERSION = 'marketing-v1';
export const CONSENT_WORDING = "I'd like to receive occasional product news, updates and offers from Lofer by email.";

// Step 2 choices: [stored value, label shown].
export const INTERESTS = [
  ['sports_recovery', 'Sports recovery'],
  ['everyday_tension', 'Everyday muscle tension'],
  ['preventive_care', 'Preventive body care'],
  ['at_home_convenience', 'Convenient at-home care'],
  ['ai_personalised', 'Personalised, AI-powered care'],
  ['exploring_technology', 'Exploring new technology'],
  ['other_curious', 'Other / Just curious'],
];

export const PRICE_RANGES = [
  ['under_100', 'Under £100'],
  ['100_149', '£100–£149'],
  ['150_199', '£150–£199'],
  ['200_249', '£200–£249'],
  ['250_299', '£250–£299'],
  ['300_399', '£300–£399'],
  ['400_plus', '£400+'],
  ['not_sure', 'Not sure yet'],
];
