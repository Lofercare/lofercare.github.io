// Turns the translation spreadsheet (docs/website-text-for-translation.csv) into the Chinese
// dictionary the website uses (src/i18n/zh.json).
//
//   node scripts/build-zh.mjs
//
// Rows are looked up by their ID number (the data-i18n="001" attributes in the HTML). A few
// rows hold a sentence that has a link or bold part inside it on the page, so they are split
// into pieces here (the "x-..." and "150a/150b" keys).
import { readFileSync, writeFileSync } from 'node:fs';

const CSV = new URL('../../docs/website-text-for-translation.csv', import.meta.url);
const OUT = new URL('../src/i18n/zh.json', import.meta.url);

/** A small CSV reader that handles quotes, commas and line breaks inside quotes. */
function parseCsv(text) {
  const rows = [];
  let row = [], field = '', inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') inQuotes = false;
      else field += c;
    } else if (c === '"') inQuotes = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++;
      row.push(field); rows.push(row); row = []; field = '';
    } else field += c;
  }
  if (field || row.length) { row.push(field); rows.push(row); }
  return rows;
}

const text = readFileSync(CSV, 'utf8').replace(/^﻿/, '');
const [header, ...rows] = parseCsv(text);
const col = (name) => header.findIndex((h) => h.startsWith(name));
const [ID, EN, ZH] = [col('ID'), col('English'), col('Chinese')];

const zh = {};
const problems = [];
for (const r of rows) {
  if (!r[ID]) continue;
  const value = (r[ZH] ?? '').trim();
  if (!value) { problems.push(`${r[ID]}: no Chinese yet (${r[EN].slice(0, 40)})`); continue; }
  zh[r[ID]] = value;
}

// ── Rows split into pieces (they hold a link, bold text or several lines on the page) ──
const need = (id) => zh[id] ?? (problems.push(`${id}: needed to build the split pieces`), '');
const footer = need('126');                                  // "Lofer 正在开发中。© Lofer · 隐私政策"
zh['x-dev'] = footer.split('©')[0].trim();
zh['x-privacy'] = footer.split('·').pop().trim();
const sentences = (s) => s.match(/[^。]+。?/g) ?? [s];
zh['150a'] = sentences(need('150'))[0];                      // "...与你联系。"
zh['150b'] = sentences(need('150')).slice(1).join('');       // "请阅读我们的隐私政策。"
zh['153a'] = sentences(need('153'))[0];
zh['153b'] = sentences(need('153')).slice(1).join('');
const contact = need('310').split(/<br\s*\/?>/);             // Lofer / controllers / location / email
zh['x-controllers'] = contact[1]?.trim() ?? '';
zh['x-location'] = contact[2]?.trim() ?? '';
zh['x-email'] = (contact[3] ?? '').split('：')[0].trim() + '：';

// ── Small pieces that were not in the spreadsheet (please review) ──
zh['x-lang'] = '语言';
zh['x-step2'] = '第 2 步，共 2 步 · 选填';
zh['x-name-long'] = '姓名请控制在 100 个字符以内。';
zh['x-email-empty'] = '请输入你的邮箱地址。';

writeFileSync(OUT, JSON.stringify(zh, null, 1) + '\n');
console.log(`wrote ${Object.keys(zh).length} entries to src/i18n/zh.json`);
if (problems.length) { console.error('\nProblems:\n  ' + problems.join('\n  ')); process.exit(1); }
