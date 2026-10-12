// Entry point for the landing page: wires up the 3D device, the logo,
// the Lofer Loop diagram, the exploded build view and scroll reveals.
import './fonts.js';
import './styles.css';
import { logoMarkSvg } from './logo.js';
import { startLoop } from './loop.js';
import { startBuild } from './build.js';
import { startTiling } from './tiling.js';
import { initWaitlist } from './waitlist/modal.js';
import { initI18n } from './i18n/i18n.js';

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/** The real tile as a flat picture (used when 3D isn't available). BASE_URL keeps the path right on GitHub Pages. */
function deviceImage(className) {
  return `<img class="${className}" src="${import.meta.env.BASE_URL}renders/tile-top.webp" width="900" height="900" alt="" />`;
}

// ── The hero device ──
// three.js is large (~150 KB zipped), so it's loaded separately: the words
// appear straight away and the device fades in once the 3D code arrives.
const stage = document.querySelector('[data-device-stage]');
function showFallback() {
  // No WebGL (old browser, or it's switched off): show a picture of the tile instead.
  stage.classList.add('hero__stage--fallback');
  stage.innerHTML = deviceImage('hero__fallback');
}
import('./device3d.js')
  .then(({ mountDevice }) => {
    if (mountDevice(stage, { reducedMotion })) stage.classList.add('is-ready');
    else showFallback();
  })
  .catch(showFallback);

// ── Logo marks (in the nav and on the Lofer card) ──
document.querySelectorAll('[data-logo-mark]').forEach((slot) => {
  slot.innerHTML = logoMarkSvg('logo-mark');
});

// ── The closed-loop diagram ──
startLoop({ reducedMotion });

// ── Inside Lofer: the exploded view ──
startBuild({ reducedMotion });

// ── The tiling background: a cluster of tiles that regroups as you scroll ──
startTiling({ reducedMotion });

// ── Fade sections in as they scroll into view ──
const revealItems = document.querySelectorAll('.reveal');
if (reducedMotion) {
  revealItems.forEach((item) => item.classList.add('is-visible'));
} else {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          observer.unobserve(entry.target); // only animate once
        }
      }
    },
    { threshold: 0.2 },
  );
  revealItems.forEach((item) => observer.observe(item));
}

// ── Language (English / 中文) ──
initI18n();

// ── Waitlist ──
// Every [data-waitlist-open] button opens the two-step form (src/waitlist/modal.js).
initWaitlist();

document.querySelector('[data-year]').textContent = new Date().getFullYear();
