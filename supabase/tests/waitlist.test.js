// Tests for the waitlist database. They run the real migration in a real Postgres engine
// (PGlite) and call the functions as the `anon` role, which is what the website's
// publishable key uses. Run: npm test
import { test, before, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PGlite } from '@electric-sql/pglite';
import { CONSENT_VERSION, CONSENT_WORDING, CONSENT_VERSION_ZH, CONSENT_WORDING_ZH, INTERESTS, PRICE_RANGES } from '../../website/src/waitlist/config.js';

// Every migration, in order, exactly as they would be run in the Supabase SQL editor.
const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url);
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(new URL(f, MIGRATIONS_DIR), 'utf8')).join('\n');

/** A fresh database with the migration applied and the two Supabase roles in place. */
async function freshDb(dataDir) {
  const db = dataDir ? new PGlite(dataDir) : new PGlite();
  await db.waitReady;
  const existing = await db.query(`select 1 from pg_roles where rolname = 'anon'`);
  if (existing.rows.length === 0) {
    await db.exec(`create role anon nologin; create role authenticated nologin;
                   grant usage on schema public to anon, authenticated;`);
    await db.exec(MIGRATION);
  }
  return db;
}

/** Runs `fn` as the public (anon) role, the same as the website. */
async function asAnon(db, fn) {
  await db.exec('set role anon');
  try { return await fn(); } finally { await db.exec('reset role'); }
}

const join_ = (db, name, email) =>
  asAnon(db, async () => (await db.query('select public.join_waitlist($1, $2) as r', [name, email])).rows[0].r);
const update_ = (db, token, interest, price, consent, version = CONSENT_VERSION) =>
  asAnon(db, async () => (await db.query('select public.update_waitlist($1, $2, $3, $4, $5) as r', [token, interest, price, consent, version])).rows[0].r);
const rows = async (db) => (await db.query('select * from public.waitlist_entries order by created_at')).rows;

let db;
before(async () => { db = await freshDb(); });
// The flood throttle (40 calls a minute) would trip over a long test run, so start each test with a clean count.
beforeEach(async () => { await db.exec('delete from public.waitlist_attempts'); });

test('1. a valid signup is saved and returns a token', async () => {
  const r = await join_(db, 'Ada Lovelace', 'ada@example.com');
  assert.equal(r.ok, true);
  assert.equal(r.token.length, 64);
  const [row] = await rows(db);
  assert.equal(row.name, 'Ada Lovelace');
  assert.equal(row.email_normalised, 'ada@example.com');
  assert.equal(row.marketing_consent, false);           // 8/10. off unless ticked
  assert.equal(row.marketing_consent_timestamp, null);
  assert.equal(row.interest_category, null);
  assert.notEqual(row.update_token_hash, r.token);       // only a hash is stored
});

test('2. an invalid email is rejected', async () => {
  for (const bad of ['', 'nope', 'a@b', '@x.com', 'a b@c.com', 'x@y .com', null]) {
    await assert.rejects(join_(db, 'Ada', bad), /invalid_email/, `should reject ${JSON.stringify(bad)}`);
  }
  await assert.rejects(join_(db, 'Ada', 'a'.repeat(250) + '@example.com'), /invalid_email/);
});

test('3. a missing or oversized name is rejected', async () => {
  await assert.rejects(join_(db, '', 'x@example.com'), /invalid_name/);
  await assert.rejects(join_(db, '   ', 'x@example.com'), /invalid_name/);
  await assert.rejects(join_(db, null, 'x@example.com'), /invalid_name/);
  await assert.rejects(join_(db, 'n'.repeat(101), 'x@example.com'), /invalid_name/);
});

test('4 + 16. duplicates (any capitalisation or spacing) do not create a second entry, and look identical', async () => {
  const before_ = (await rows(db)).length;
  const again = await join_(db, 'Someone Else', '  ADA@Example.COM ');
  assert.equal(again.ok, true);
  assert.equal(again.token.length, 64);                  // same shape as a real signup: no email enumeration
  assert.equal((await rows(db)).length, before_);
  const ada = (await rows(db)).find((r) => r.email_normalised === 'ada@example.com');
  assert.equal(ada.name, 'Ada Lovelace');                // the original is untouched
});

test('5 + 6. Step 2 updates the same record, once', async () => {
  const { token } = await join_(db, 'Grace Hopper', 'grace@example.com');
  const before_ = (await rows(db)).length;
  await update_(db, token, 'sports_recovery', '150_199', false);
  const all = await rows(db);
  assert.equal(all.length, before_);
  const row = all.find((r) => r.email_normalised === 'grace@example.com');
  assert.equal(row.interest_category, 'sports_recovery');
  assert.equal(row.price_range, '150_199');
  assert.equal(row.update_token_hash, null);
  await assert.rejects(update_(db, token, 'other_curious', 'under_100', false), /invalid_token/); // the token works once
});

test('7. skipping Step 2 keeps the signup', async () => {
  await join_(db, 'Skipper', 'skip@example.com');
  const row = (await rows(db)).find((r) => r.email_normalised === 'skip@example.com');
  assert.ok(row);
  assert.equal(row.interest_category, null);
  assert.equal(row.price_range, null);
  assert.equal(row.marketing_consent, false);
});

test('9. ticking the box records consent, time, version and the exact wording', async () => {
  const { token } = await join_(db, 'Consenter', 'yes@example.com');
  const t0 = Date.now();
  await update_(db, token, null, null, true);
  const row = (await rows(db)).find((r) => r.email_normalised === 'yes@example.com');
  assert.equal(row.marketing_consent, true);
  assert.equal(row.marketing_consent_version, CONSENT_VERSION);
  assert.equal(row.marketing_consent_wording, CONSENT_WORDING);
  assert.ok(Math.abs(new Date(row.marketing_consent_timestamp).getTime() - t0) < 60_000);
});

test('10. leaving the box unticked records no consent', async () => {
  const { token } = await join_(db, 'No Consent', 'no@example.com');
  await update_(db, token, 'everyday_tension', 'not_sure', false);
  const row = (await rows(db)).find((r) => r.email_normalised === 'no@example.com');
  assert.equal(row.marketing_consent, false);
  assert.equal(row.marketing_consent_timestamp, null);
  assert.equal(row.marketing_consent_version, null);
  assert.equal(row.marketing_consent_wording, null);
});

test('consent cannot be recorded against a wording version that does not exist', async () => {
  const { token } = await join_(db, 'Bad Version', 'badver@example.com');
  await assert.rejects(update_(db, token, null, null, true, 'made-up-v9'), /invalid_consent_version/);
});

test('the wording and version in the website match what the database stores', async () => {
  const r = await db.query('select wording from public.waitlist_consent_texts where version = $1', [CONSENT_VERSION]);
  assert.equal(r.rows[0]?.wording, CONSENT_WORDING);
});

test('the Chinese consent wording matches too, and a Chinese sign-up records it', async () => {
  const r = await db.query('select wording from public.waitlist_consent_texts where version = $1', [CONSENT_VERSION_ZH]);
  assert.equal(r.rows[0]?.wording, CONSENT_WORDING_ZH);
  const { token } = await join_(db, '李雷', 'zh-yes@example.com');
  await update_(db, token, null, null, true, CONSENT_VERSION_ZH);
  const row = (await rows(db)).find((x) => x.email_normalised === 'zh-yes@example.com');
  assert.equal(row.marketing_consent_version, CONSENT_VERSION_ZH);
  assert.equal(row.marketing_consent_wording, CONSENT_WORDING_ZH);
  assert.equal(row.name, '李雷');                         // Chinese names are stored as typed
});

test('every choice in the website is accepted, and anything else is refused', async () => {
  for (const [value] of INTERESTS) {
    const { token } = await join_(db, 'Opt', `opt-${value}@example.com`);
    await update_(db, token, value, null, false);
  }
  for (const [value] of PRICE_RANGES) {
    const { token } = await join_(db, 'Opt', `price-${value}@example.com`);
    await update_(db, token, null, value, false);
  }
  const { token } = await join_(db, 'Odd', 'odd@example.com');
  await assert.rejects(update_(db, token, 'hacker_news', null, false), /invalid_answer/);
  await assert.rejects(update_(db, token, null, 'free', false), /invalid_answer/);
});

test('17. updates are refused without the right token', async () => {
  const { token } = await join_(db, 'Victim', 'victim@example.com');
  // wrong, short, empty and decoy tokens
  for (const bad of [null, '', 'abc', 'x'.repeat(64), token.replace(/.$/, token.endsWith('0') ? '1' : '0')]) {
    await assert.rejects(update_(db, bad, 'other_curious', '400_plus', true), /invalid_token/);
  }
  // the decoy token a duplicate signup receives does nothing to the original entry
  const decoy = (await join_(db, 'Attacker', 'victim@example.com')).token;
  await assert.rejects(update_(db, decoy, 'other_curious', '400_plus', true), /invalid_token/);
  const row = (await rows(db)).find((r) => r.email_normalised === 'victim@example.com');
  assert.equal(row.interest_category, null);
  assert.equal(row.marketing_consent, false);
  // an expired token is refused
  await db.exec(`update public.waitlist_entries set update_token_expires_at = now() - interval '1 minute' where email_normalised = 'victim@example.com'`);
  await assert.rejects(update_(db, token, 'other_curious', null, false), /invalid_token/);
});

test('the public key cannot read, change or delete anything directly', async () => {
  for (const sql of [
    'select * from public.waitlist_entries',
    `insert into public.waitlist_entries (name, email, email_normalised) values ('x', 'x@x.com', 'x@x.com')`,
    `update public.waitlist_entries set name = 'x'`,
    'delete from public.waitlist_entries',
    'select * from public.waitlist_consent_texts',
    'select public.purge_waitlist(interval \'0 seconds\')',
    'select public.waitlist_slow_down()',
  ]) {
    await assert.rejects(asAnon(db, () => db.query(sql)), /permission denied/, sql);
  }
});

test('the owner can purge old entries', async () => {
  await db.exec(`update public.waitlist_entries set created_at = now() - interval '2 years' where email_normalised = 'skip@example.com'`);
  const r = await db.query(`select public.purge_waitlist(interval '12 months') as n`);
  assert.equal(r.rows[0].n, 1);
});

test('a flood of calls is slowed down', async () => {
  const flood = await freshDb();
  let limited = false;
  for (let i = 0; i < 60 && !limited; i++) {
    try { await join_(flood, 'Bot', `bot${i}@example.com`); } catch (e) { limited = /rate_limited/.test(String(e.message)); }
  }
  assert.ok(limited, 'expected rate_limited after many calls in a minute');
  await flood.close();
});

test('18. entries are still there after the database is closed and reopened', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'lofer-wl-'));
  try {
    const first = await freshDb(dir);
    const { token } = await join_(first, 'Persisted', 'persist@example.com');
    await update_(first, token, 'preventive_care', '200_249', true);
    await first.close();
    const second = await freshDb(dir);
    const row = (await rows(second)).find((r) => r.email_normalised === 'persist@example.com');
    assert.equal(row.price_range, '200_249');
    assert.equal(row.marketing_consent, true);
    await second.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
