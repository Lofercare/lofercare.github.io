// Checks the privacy page has everything the policy says it should.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../privacy/index.html', import.meta.url), 'utf8');
const index = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const modal = readFileSync(new URL('../src/waitlist/modal.js', import.meta.url), 'utf8');

test('all 14 sections are present, in order', () => {
  const headings = [...html.matchAll(/<h2[^>]*>(.*?)<\/h2>/g)].map((m) => m[1]);
  assert.equal(headings.length, 14);
  headings.forEach((text, i) => assert.ok(text.startsWith(`${i + 1}. `), `section ${i + 1}: "${text}"`));
});

test('date, controllers and contact are correct', () => {
  assert.match(html, /Last updated: 9 October 2026/);
  assert.match(html, /Zuyi Gong and Leyi Jiang/);
  assert.match(html, /unincorporated project based in the United Kingdom/);
  assert.match(html, /Supabase/);
  assert.match(html, /GitHub Pages \(provided by GitHub\): Hosting and delivering our website\./);
  const emails = [...html.matchAll(/loferprivacy@gmail\.com/g)];
  assert.ok(emails.length >= 8);
  assert.doesNotMatch(html, /loferprivacy@gmail\.com[^"<]/);   // never a typo'd variant
});

test('the policy is linked from the footer and from the waitlist', () => {
  assert.match(index, /<footer[\s\S]*href="\.\/privacy\/"[\s\S]*Privacy Policy/);
  assert.match(modal, /href="\$\{PRIVACY_URL\}" target="_blank" rel="noopener"[^>]*>Read our Privacy Policy\./);
  assert.match(modal, /PRIVACY_URL = `\$\{import\.meta\.env\.BASE_URL\}privacy\/`/);
});

test('the marketing checkbox starts unticked and the privacy policy is not a consent checkbox', () => {
  const checkbox = modal.match(/<input type="checkbox"[^>]*>/)[0];
  assert.doesNotMatch(checkbox, /checked/);
  assert.equal([...modal.matchAll(/type="checkbox"/g)].length, 1);
  assert.match(modal, /You can unsubscribe from marketing emails at any time\. Your waitlist registration won't be affected\./);
});
