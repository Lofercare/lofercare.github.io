// The privacy page: no 3D, no tiling, no motion. It reuses the site's styles and logo.
import './fonts.js';
import './styles.css';
import { logoMarkSvg } from './logo.js';

document.querySelectorAll('[data-logo-mark]').forEach((slot) => {
  slot.innerHTML = logoMarkSvg('logo-mark');
});
document.querySelector('[data-year]').textContent = new Date().getFullYear();
