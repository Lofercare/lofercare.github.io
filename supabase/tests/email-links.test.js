// Tests for 20261012000000_waitlist_email_links.sql: the personal links in emails (unsubscribe from
// marketing / leave the waitlist). All three migrations run in order in a real Postgres engine
// (PGlite); the link actions are called as the website's public (anon) role. Run: npm test
import { test, before, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { CONSENT_VERSION } from '../../website/src/waitlist/config.js';

const migration = (f) => readFileSync(new URL(`../migrations/${f}`, import.meta.url), 'utf8');
const sha = (s) => createHash('sha256').update(s).digest('hex');

let db;
const asAnon = async (fn) => { await db.exec('set role anon'); try { return await fn(); } finally { await db.exec('reset role'); } };
const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const join = (name, email) => asAnon(async () => (await one('select public.join_waitlist($1, $2) as r', [name, email])).r);
const answer = (token, consent) => asAnon(async () => (await one('select public.update_waitlist($1, null, null, $2, $3) as r', [token, consent, CONSENT_VERSION])).r);
const signUp = async (name, email, consent) => { await answer((await join(name, email)).token, consent); };
const entry = (email) => one('select * from public.waitlist_entries where email_normalised = $1', [email]);
const linksFor = async (fn) => Object.fromEntries((await db.query(`select email, link_token from public.${fn}()`)).rows.map((r) => [r.email, r.link_token]));
const unsubscribe = (token) => asAnon(async () => (await one('select public.unsubscribe_by_link($1) as r', [token])).r);
const leave = (token) => asAnon(async () => (await one('select public.leave_waitlist_by_link($1) as r', [token])).r);
// The test database's clock is coarse; at the same instant a suppression wins (by design), so wait a moment.
const tick = () => new Promise((resolve) => setTimeout(resolve, 15));
const suppression = (email) => one('select reason from public.waitlist_suppressions where email_hash = $1', [sha(email)]);

before(async () => {
  db = new PGlite();
  await db.waitReady;
  await db.exec(`create role anon nologin; create role authenticated nologin; grant usage on schema public to anon, authenticated;`);
  for (const f of ['20261010000000_waitlist.sql', '20261011000000_waitlist_withdrawals.sql', '20261012000000_waitlist_email_links.sql']) {
    await db.exec(migration(f));
  }
});
beforeEach(async () => { await db.exec('delete from public.waitlist_attempts'); });

test('1. marketing exports only opted-in people; service exports everyone; each gets a fresh link', async () => {
  await signUp('Opted In', 'in@example.com', true);
  await signUp('Not Opted', 'out@example.com', false);
  const marketing = await linksFor('marketing_audience_with_links');
  assert.deepEqual(Object.keys(marketing), ['in@example.com']);
  const service = await linksFor('waitlist_contacts_with_links');
  assert.deepEqual(Object.keys(service).sort(), ['in@example.com', 'out@example.com']);
  for (const t of [...Object.values(marketing), ...Object.values(service)]) assert.match(t, /^[0-9a-f]{64}$/);
  assert.notEqual(marketing['in@example.com'], service['in@example.com'], 'a new token per export');
  const stored = (await db.query('select token_hash from public.waitlist_link_tokens')).rows.map((r) => r.token_hash);
  assert.ok(!stored.includes(marketing['in@example.com']), 'only the hash is stored');
  assert.ok(stored.includes(sha(marketing['in@example.com'])));
});

test('2. the unsubscribe link stops marketing, keeps them on the waitlist and keeps the consent evidence', async () => {
  await signUp('Unsub', 'unsub@example.com', true);
  const token = (await linksFor('marketing_audience_with_links'))['unsub@example.com'];
  assert.deepEqual(await unsubscribe(token), { ok: true });
  const e = await entry('unsub@example.com');
  assert.equal(e.marketing_consent, false);
  assert.ok(e.marketing_consent_withdrawn_at);
  assert.ok(e.marketing_consent_timestamp, 'evidence kept');
  assert.equal((await suppression('unsub@example.com')).reason, 'unsubscribed');
  assert.ok(!Object.keys(await linksFor('marketing_audience_with_links')).includes('unsub@example.com'));
  assert.deepEqual(await unsubscribe(token), { ok: true }, 'clicking twice is fine');
});

test('3. the leave link deletes the entry; the same link works for both actions', async () => {
  await signUp('Leaver', 'leaver@example.com', true);
  const token = (await linksFor('marketing_audience_with_links'))['leaver@example.com'];
  await unsubscribe(token);
  assert.deepEqual(await leave(token), { ok: true });
  assert.equal(await entry('leaver@example.com'), undefined);
  assert.equal((await suppression('leaver@example.com')).reason, 'removed');
});

test('4. a link still works after the entry is gone (a late click never fails)', async () => {
  await signUp('Late', 'late@example.com', false);
  const token = (await linksFor('waitlist_contacts_with_links'))['late@example.com'];
  await db.query(`select public.remove_from_waitlist('late@example.com')`);
  assert.deepEqual(await unsubscribe(token), { ok: true });
  assert.deepEqual(await leave(token), { ok: true });
});

test('5. made-up, malformed or expired links are refused', async () => {
  for (const bad of ['', 'abc', 'g'.repeat(64), 'a'.repeat(64), null]) {
    await assert.rejects(unsubscribe(bad), /invalid_link/, JSON.stringify(bad));
    await assert.rejects(leave(bad), /invalid_link/, JSON.stringify(bad));
  }
  await signUp('Old Link', 'old@example.com', false);
  const token = (await linksFor('waitlist_contacts_with_links'))['old@example.com'];
  await db.query(`update public.waitlist_link_tokens set created_at = now() - interval '401 days' where token_hash = $1`, [sha(token)]);
  await assert.rejects(unsubscribe(token), /invalid_link/);
  assert.ok(await entry('old@example.com'), 'nothing happened');
});

test('6. unsubscribing again after a fresh opt-in always wins', async () => {
  await signUp('Again', 'again@example.com', true);
  await unsubscribe((await linksFor('marketing_audience_with_links'))['again@example.com']);
  await db.query(`select public.remove_from_waitlist('again@example.com')`);
  await tick();                                                     // a real re-sign-up is never in the same instant
  await signUp('Again', 'again@example.com', true);                 // fresh, explicit consent
  const token = (await linksFor('marketing_audience_with_links'))['again@example.com'];
  assert.ok(token, 'fresh consent puts them back');
  await unsubscribe(token);
  assert.ok(!Object.keys(await linksFor('marketing_audience_with_links')).includes('again@example.com'));
});

test('7. the owner by-address actions still work (same code as the links)', async () => {
  await signUp('By Address', 'byaddress@example.com', true);
  assert.equal((await one(`select public.withdraw_marketing_consent(' ByAddress@Example.com ') as r`)).r, 'withdrawn');
  assert.equal((await one(`select public.withdraw_marketing_consent('byaddress@example.com') as r`)).r, 'not_consented');
  assert.equal((await one(`select public.remove_from_waitlist('byaddress@example.com') as r`)).r, 'removed');
  assert.equal((await one(`select public.remove_from_waitlist('byaddress@example.com') as r`)).r, 'not_on_list');
});

test('8. new sign-ups record the current privacy policy', async () => {
  await signUp('Policy', 'policy@example.com', false);
  assert.equal((await entry('policy@example.com')).privacy_notice_version, 'policy-2026-10-11');
});

test('9. retention: 12 months after sign-up; old link tokens go too', async () => {
  await signUp('Ancient', 'ancient@example.com', false);
  await db.query(`update public.waitlist_entries set created_at = now() - interval '13 months' where email_normalised = 'ancient@example.com'`);
  await db.query(`update public.waitlist_link_tokens set created_at = now() - interval '401 days'`);
  assert.equal((await one(`select public.purge_waitlist(interval '12 months') as n`)).n, 1);
  assert.equal(await entry('ancient@example.com'), undefined);
  assert.equal((await one('select count(*)::int as n from public.waitlist_link_tokens')).n, 0);
});

test('10. the website (public key) can use only the two link actions', async () => {
  for (const sql of [
    'select * from public.marketing_audience_with_links()',
    'select * from public.waitlist_contacts_with_links()',
    `select public.waitlist_new_link_token('a@example.com')`,
    `select public.waitlist_withdraw_by_hash('${'a'.repeat(64)}')`,
    `select public.waitlist_remove_by_hash('${'a'.repeat(64)}')`,
    `select public.waitlist_link_email_hash('${'a'.repeat(64)}')`,
    'select * from public.waitlist_link_tokens',
    `select public.purge_waitlist(interval '1 day')`,
  ]) {
    await assert.rejects(asAnon(() => db.query(sql)), /permission denied/, sql);
  }
});
