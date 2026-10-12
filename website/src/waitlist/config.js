// Settings and wording for the waitlist. Plain data, so tests can read it too.

// Where the waitlist database lives. Both values are PUBLIC by design (the publishable key can
// only call the two waitlist functions; see supabase/README.md). They come from the build
// environment: website/.env.local on your machine, repository variables on GitHub.
export const SUPABASE_URL = (import.meta.env?.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
export const SUPABASE_PUBLISHABLE_KEY = import.meta.env?.VITE_SUPABASE_PUBLISHABLE_KEY ?? '';

// The marketing checkbox wording, and its version, per language. The database keeps a copy of each
// version (table waitlist_consent_texts) and stamps it on the entry when someone ticks the box, so what
// they agreed to is on record. If you change the wording, add a new version in the database too.
// A test checks these match the database setup and the translation spreadsheet.
export const CONSENT_VERSION = 'marketing-v1';
export const CONSENT_WORDING = "I'd like to receive occasional product news, updates and offers from Lofer by email.";
export const CONSENT_VERSION_ZH = 'marketing-v1-zh';
export const CONSENT_WORDING_ZH = '我希望通过邮件偶尔收到 Lofer 的产品消息、更新与优惠。';

// Step 2 choices: [stored value, English label, translation number]. Only the label is translated;
// the stored value stays the same in every language.
export const INTERESTS = [
  ['sports_recovery', 'Sports recovery', '184'],
  ['everyday_tension', 'Everyday muscle tension', '185'],
  ['preventive_care', 'Preventive body care', '186'],
  ['at_home_convenience', 'Convenient at-home care', '187'],
  ['ai_personalised', 'Personalised, AI-powered care', '188'],
  ['exploring_technology', 'Exploring new technology', '189'],
  ['other_curious', 'Other / Just curious', '190'],
];

export const PRICE_RANGES = [
  ['under_100', 'Under £100', '191'],
  ['100_149', '£100–£149', '192'],
  ['150_199', '£150–£199', '193'],
  ['200_249', '£200–£249', '194'],
  ['250_299', '£250–£299', '195'],
  ['300_399', '£300–£399', '196'],
  ['400_plus', '£400+', '197'],
  ['not_sure', 'Not sure yet', '198'],
];
