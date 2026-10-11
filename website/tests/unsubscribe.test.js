// The email-preferences page (/unsubscribe/) that personal links in emails open.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { linkToken } from '../src/waitlist/validate.js';

const html = readFileSync(new URL('../unsubscribe/index.html', import.meta.url), 'utf8');
const script = readFileSync(new URL('../src/unsubscribe.js', import.meta.url), 'utf8');
const api = readFileSync(new URL('../src/waitlist/api.js', import.meta.url), 'utf8');
const vite = readFileSync(new URL('../vite.config.js', import.meta.url), 'utf8');
const T = 'a'.repeat(64);

test('the personal code is read from after "#" and must be exactly 64 hex characters', () => {
  assert.equal(linkToken(`#t=${T}`), T);
  assert.equal(linkToken(`t=${T}`), T);
  for (const bad of ['', '#', '#t=', '#t=abc', `#t=${'g'.repeat(64)}`, `#t=${T}x`, `#x=${T}`, undefined]) {
    assert.equal(linkToken(bad), '', String(bad));
  }
});

test('nothing happens on page load: the actions run only from button clicks', () => {
  const calls = [...script.matchAll(/(unsubscribeByLink|leaveWaitlistByLink)\b/g)].map((m) => m.index);
  const clickHandler = script.indexOf("addEventListener('click'");
  assert.ok(clickHandler > 0);
  // Apart from the import line, every use is inside the click handler or the helper it calls.
  const importLine = script.indexOf("from './waitlist/api.js'");
  for (const at of calls) assert.ok(at < importLine || at > script.indexOf('async function run'), `call at ${at}`);
  assert.match(script, /case 'leave-ask': return show\('confirm'\)/, 'leaving asks for confirmation first');
});

test('the code is removed from the address bar, and the page stays out of search engines', () => {
  assert.match(script, /history\.replaceState\(null, '', window\.location\.pathname\)/);
  assert.match(html, /<meta name="robots" content="noindex, nofollow" \/>/);
  assert.match(html, /<meta name="referrer" content="no-referrer" \/>/);
});

test('the page calls only the two link functions, and is part of the build', () => {
  assert.match(api, /call\('unsubscribe_by_link', \{ p_token: token \}\)/);
  assert.match(api, /call\('leave_waitlist_by_link', \{ p_token: token \}\)/);
  assert.match(vite, /unsubscribe: resolve\(import\.meta\.dirname, 'unsubscribe\/index\.html'\)/);
});

test('no page loads fonts from Google', () => {
  for (const page of ['../index.html', '../privacy/index.html', '../unsubscribe/index.html', '../public/hardware/index.html']) {
    assert.doesNotMatch(readFileSync(new URL(page, import.meta.url), 'utf8'), /fonts\.(googleapis|gstatic)\.com/, page);
  }
});
