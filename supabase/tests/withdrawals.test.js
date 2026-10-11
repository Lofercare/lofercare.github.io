// Tests for 20261011000000_waitlist_withdrawals.sql: marketing withdrawals and the "do not email"
// list. Both migrations run in order in a real Postgres engine (PGlite), on top of entries made
// with the first migration only, as on the live project. Run: npm test
import { test, before, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { CONSENT_VERSION } from '../../website/src/waitlist/config.js';

const FIRST = readFileSync(new URL('../migrations/20261010000000_waitlist.sql', import.meta.url), 'utf8');
const SECOND = readFileSync(new URL('../migrations/20261011000000_waitlist_withdrawals.sql', import.meta.url), 'utf8');
const hash = (email) => createHash('sha256').update(email.trim().toLowerCase()).digest('hex');

let db;
const asAnon = async (fn) => { await db.exec('set role anon'); try { return await fn(); } finally { await db.exec('reset role'); } };
const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const join = (name, email) => asAnon(async () => (await one('select public.join_waitlist($1, $2) as r', [name, email])).r);
const answer = (token, consent) => asAnon(async () => (await one('select public.update_waitlist($1, null, null, $2, $3) as r', [token, consent, CONSENT_VERSION])).r);
const entry = (email) => one('select * from public.waitlist_entries where email_normalised = $1', [email]);
const audience = async () => (await db.query('select email from public.marketing_audience()')).rows.map((r) => r.email);
const withdraw = async (email) => (await one('select public.withdraw_marketing_consent($1) as r', [email])).r;
const remove = async (email) => (await one('select public.remove_from_waitlist($1) as r', [email])).r;

before(async () => {
  db = new PGlite();
  await db.waitReady;
  await db.exec(`create role anon nologin; create role authenticated nologin; grant usage on schema public to anon, authenticated;`);
  await db.exec(FIRST);
  // Entries that exist before the upgrade, like the live waitlist today.
  await db.exec('delete from public.waitlist_attempts');
  await answer((await join('Early Yes', 'early.yes@example.com')).token, true);
  await answer((await join('Early No', 'early.no@example.com')).token, false);
  await db.exec(SECOND);
});
beforeEach(async () => { await db.exec('delete from public.waitlist_attempts'); });

test('1. the upgrade keeps existing entries valid and unchanged', async () => {
  const yes = await entry('early.yes@example.com');
  assert.equal(yes.marketing_consent, true);
  assert.equal(yes.marketing_consent_withdrawn_at, null);
  const no = await entry('early.no@example.com');
  assert.equal(no.marketing_consent, false);
  assert.deepEqual(await audience(), ['early.yes@example.com']);
});

test('2. withdrawing keeps the consent evidence and records when', async () => {
  const before_ = await entry('early.yes@example.com');
  assert.equal(await withdraw('  EARLY.yes@Example.com '), 'withdrawn');      // any capitalisation or spacing
  const after = await entry('early.yes@example.com');
  assert.equal(after.marketing_consent, false);
  assert.ok(after.marketing_consent_withdrawn_at, 'withdrawal time recorded');
  assert.deepEqual(after.marketing_consent_timestamp, before_.marketing_consent_timestamp, 'original consent time kept');
  assert.equal(after.marketing_consent_version, before_.marketing_consent_version);
  assert.equal(after.marketing_consent_wording, before_.marketing_consent_wording);
  assert.ok(!(await audience()).includes('early.yes@example.com'));
  assert.equal(await withdraw('early.yes@example.com'), 'not_consented', 'doing it twice is harmless');
});

test('3. the "do not email" list keeps a hash, never the address', async () => {
  const rows = (await db.query('select * from public.waitlist_suppressions')).rows;
  const row = rows.find((r) => r.email_hash === hash('early.yes@example.com'));
  assert.equal(row.reason, 'unsubscribed');
  assert.ok(!JSON.stringify(rows).includes('@'), 'no email address stored');
});

test('4. unsubscribing someone who never opted in, or who is not on the list, still suppresses them', async () => {
  assert.equal(await withdraw('early.no@example.com'), 'not_consented');
  assert.equal(await withdraw('stranger@example.com'), 'not_on_list');
  const hashes = (await db.query('select email_hash from public.waitlist_suppressions')).rows.map((r) => r.email_hash);
  assert.ok(hashes.includes(hash('stranger@example.com')));
});

test('5. leaving the waitlist deletes the entry and keeps only the hash', async () => {
  const { token } = await join('Leaver', 'leaver@example.com');
  await answer(token, true);
  assert.ok((await audience()).includes('leaver@example.com'));
  assert.equal(await remove('Leaver@Example.com'), 'removed');
  assert.equal(await entry('leaver@example.com'), undefined, 'name, email, answers and consent record are gone');
  const s = await one('select reason from public.waitlist_suppressions where email_hash = $1', [hash('leaver@example.com')]);
  assert.equal(s.reason, 'removed');
  assert.ok(!(await audience()).includes('leaver@example.com'));
  assert.equal(await remove('leaver@example.com'), 'not_on_list');
});

test('6. a suppression after someone consents always wins; a fresh tick after it counts again', async () => {
  // Removed earlier (test 5), then signs up again and freshly ticks the box: new, explicit consent.
  await new Promise((resolve) => setTimeout(resolve, 15));   // never the same instant in real life
  const { token } = await join('Leaver Again', 'leaver@example.com');
  await answer(token, true);
  assert.ok((await audience()).includes('leaver@example.com'), 'fresh consent after the suppression');
  // Unsubscribes again: out of the audience.
  await withdraw('leaver@example.com');
  assert.ok(!(await audience()).includes('leaver@example.com'));
});

test('7. signing up again without ticking the box never puts a suppressed person back', async () => {
  await remove('quiet@example.com');                       // asked to be left alone before ever joining
  const { token } = await join('Quiet', 'quiet@example.com');
  await answer(token, false);
  assert.ok(!(await audience()).includes('quiet@example.com'));
});

test('8. the table rule rejects inconsistent consent records', async () => {
  await assert.rejects(db.query(`update public.waitlist_entries set marketing_consent_withdrawn_at = now()
                                 where email_normalised = 'early.no@example.com'`), /consent_fields_agree/,
    'cannot record a withdrawal for someone who never consented');
  await assert.rejects(db.query(`update public.waitlist_entries set marketing_consent = true
                                 where email_normalised = 'early.yes@example.com'`), /consent_fields_agree/,
    'cannot switch consent back on without a fresh consent record');
});

test('9. the website (public key) can use none of this', async () => {
  for (const sql of [
    `select public.withdraw_marketing_consent('early.no@example.com')`,
    `select public.remove_from_waitlist('early.no@example.com')`,
    `select * from public.marketing_audience()`,
    `select * from public.waitlist_suppressions`,
    `select public.waitlist_email_hash('a@example.com')`,
    `select public.waitlist_suppress('a@example.com', 'removed')`,
  ]) {
    await assert.rejects(asAnon(() => db.query(sql)), /permission denied/, sql);
  }
  // …and the two functions it does use still work.
  const { token } = await join('Still Works', 'works@example.com');
  assert.equal((await answer(token, false)).ok, true);
});
