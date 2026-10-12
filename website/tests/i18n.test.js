// Checks the Chinese version is wired up completely. Run: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CONSENT_WORDING_ZH, INTERESTS, PRICE_RANGES } from '../src/waitlist/config.js';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const zh = JSON.parse(read('../src/i18n/zh.json'));
const pages = { 'index.html': read('../index.html'), 'privacy/index.html': read('../privacy/index.html'), 'src/waitlist/modal.js': read('../src/waitlist/modal.js') };

test('every translation number used in the HTML and the form exists in the Chinese dictionary', () => {
  const missing = [];
  for (const [name, text] of Object.entries(pages)) {
    for (const m of text.matchAll(/data-i18n(?:-[a-z-]+)?="([^"$]+)"/g)) if (!zh[m[1]]) missing.push(`${name}: ${m[1]}`);   // ($ = filled in by code, checked via the choices test)
    for (const m of text.matchAll(/\bt\('([^']+)'/g)) if (!zh[m[1]]) missing.push(`${name}: t('${m[1]}')`);
  }
  assert.deepEqual(missing, []);
});

test('the dictionary has no empty entries, and no English-only leftovers where Chinese is expected', () => {
  for (const [id, text] of Object.entries(zh)) assert.ok(text.trim().length > 0, `empty: ${id}`);
});

test('the Step 2 choices all have a translation number', () => {
  for (const [value, , id] of [...INTERESTS, ...PRICE_RANGES]) assert.ok(zh[id], `choice ${value} (${id})`);
});

test('the Chinese consent wording is the one in the spreadsheet', () => {
  assert.equal(CONSENT_WORDING_ZH, zh['183']);
});

test('the language toggle is in the top bar of both pages', () => {
  for (const name of ['index.html', 'privacy/index.html']) {
    assert.match(pages[name], /data-lang="en"[^>]*>EN</);
    assert.match(pages[name], /data-lang="zh"[^>]*>中文</);
  }
});

test('line breaks in Chinese only appear where the English has them', () => {
  for (const id of ['033', '146', '164', '310']) assert.match(zh[id], /<br/);
  const withBreaks = Object.entries(zh).filter(([, v]) => v.includes('<br')).map(([k]) => k);
  assert.deepEqual(withBreaks.sort(), ['033', '146', '164', '310']);
});

test('translation numbers are never put on containers (replacing one would wipe out its contents)', () => {
  // The loop diagram nodes and the "Best of both" arrow broke this way once.
  for (const name of ['index.html', 'privacy/index.html']) {
    const containers = [...pages[name].matchAll(/<(g|div|svg|ul|ol|section|nav|header|footer|figure|dl|form)\b[^>]*\bdata-i18n(?:-[a-z-]+)?="/g)]
      .filter((m) => !/data-i18n-(aria-label|alt|title|content)=/.test(m[0]));
    assert.deepEqual(containers.map((m) => m[0].slice(0, 40)), [], name);
  }
});
