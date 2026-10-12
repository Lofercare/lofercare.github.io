// The privacy page: no 3D, no tiling, no motion. It reuses the site's styles and logo.
import './styles.css';
import { logoMarkSvg } from './logo.js';
import { initI18n } from './i18n/i18n.js';

document.querySelectorAll('[data-logo-mark]').forEach((slot) => {
  slot.innerHTML = logoMarkSvg('logo-mark');
});
document.querySelector('[data-year]').textContent = new Date().getFullYear();

initI18n();   // English / 中文
