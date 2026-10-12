// English / Chinese switching for the whole site (landing page, privacy page and the waitlist form).
//
// How it works
//   * The English text stays in the HTML. Every translatable element carries a number from the
//     translation spreadsheet:  <h2 data-i18n="105">…</h2>   or, for an attribute,  data-i18n-alt="130".
//   * The Chinese comes from src/i18n/zh.json (made from the spreadsheet by scripts/build-zh.mjs).
//     It is only downloaded when Chinese is wanted, so English visitors never load it.
//   * The language is decided by ?lang=zh / ?lang=en in the address, else by the browser's
//     language. Nothing is stored on the visitor's device, and internal links carry ?lang along.
//   * Code that builds its own text (the waitlist form) asks t("169", "English text").
const SUPPORTED = ['en', 'zh'];
const SELECTOR = '[data-i18n],[data-i18n-alt],[data-i18n-aria-label],[data-i18n-content],[data-i18n-title]';
const ATTRS = ['alt', 'aria-label', 'content', 'title'];

let language = 'en';
let dictionary = {};
const originals = new WeakMap();   // element -> its English text and attributes, remembered the first time we translate it
const linkHrefs = new WeakMap();   // internal link -> its original href

export const getLanguage = () => language;

/** The text for `id` in the current language, or `english` if there isn't a translation. */
export function t(id, english) {
  return language === 'zh' && dictionary[id] ? dictionary[id] : english;   // (an empty entry = not translated yet)
}

function detect() {
  const asked = new URLSearchParams(window.location.search).get('lang');
  if (SUPPORTED.includes(asked)) return asked;
  const browser = (navigator.languages?.[0] ?? navigator.language ?? '').toLowerCase();
  return browser.startsWith('zh') ? 'zh' : 'en';
}

async function loadDictionary() {
  if (Object.keys(dictionary).length) return;
  try {
    dictionary = (await import('./zh.json')).default;
  } catch {
    dictionary = {};   // couldn't load: stay in English rather than show blanks
  }
}

/** Puts one element into the current language. */
export function translateElement(el) {
  const memory = originals.get(el) ?? { text: undefined, attrs: {} };
  originals.set(el, memory);

  const id = el.dataset.i18n;
  if (id !== undefined) {
    if (memory.text === undefined) memory.text = el.innerHTML;   // keep the English the first time
    const zh = (language === 'zh' && dictionary[id]) || undefined;
    if (zh === undefined) { if (el.innerHTML !== memory.text) el.innerHTML = memory.text; }
    else if (zh.includes('<')) el.innerHTML = zh;                // only our own <br /> lives in the dictionary
    else el.textContent = zh;
  }
  for (const name of ATTRS) {
    const key = el.getAttribute(`data-i18n-${name}`);
    if (key === null) continue;
    if (!(name in memory.attrs)) memory.attrs[name] = el.getAttribute(name) ?? '';
    const zh = (language === 'zh' && dictionary[key]) || undefined;
    el.setAttribute(name, zh ?? memory.attrs[name]);
  }
}

/** Puts everything under `root` into the current language, and updates the toggle and links. */
export function applyLanguage(root = document) {
  if (root.matches?.(SELECTOR)) translateElement(root);
  root.querySelectorAll(SELECTOR).forEach(translateElement);

  document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
  document.querySelectorAll('[data-lang]').forEach((button) => {
    const on = button.dataset.lang === language;
    button.setAttribute('aria-pressed', String(on));
    button.classList.toggle('is-active', on);
  });
  // Internal links keep the chosen language, so the privacy page opens in the same language.
  root.querySelectorAll?.('[data-lang-link]').forEach((link) => {
    if (!linkHrefs.has(link)) linkHrefs.set(link, link.getAttribute('href'));
    const url = new URL(linkHrefs.get(link), window.location.href);
    url.searchParams.set('lang', language);
    link.setAttribute('href', url.pathname + url.search + url.hash);
  });
}

/** Switches language, updates the address (so the page can be shared) and tells the rest of the page. */
export async function setLanguage(next) {
  if (!SUPPORTED.includes(next)) return;
  language = next;
  if (next === 'zh') await loadDictionary();
  if (language !== next) return;                                // clicked again while loading
  applyLanguage(document);
  const url = new URL(window.location.href);
  url.searchParams.set('lang', next);
  window.history.replaceState(null, '', url.pathname + url.search + url.hash);
  document.dispatchEvent(new CustomEvent('lofer:langchange', { detail: { language: next } }));
}

/** Call once at start-up. */
export async function initI18n() {
  language = detect();
  if (language === 'zh') await loadDictionary();
  applyLanguage(document);
  document.querySelectorAll('[data-lang]').forEach((button) => {
    button.addEventListener('click', () => setLanguage(button.dataset.lang));
  });
  document.dispatchEvent(new CustomEvent('lofer:langchange', { detail: { language } }));
}
