// The email-preferences page that personal links in Lofer's emails open:
//   https://<website>/unsubscribe/#t=<personal code>
// The code is after "#", so it never reaches a web server's logs. This page reads it, removes it
// from the address bar and history, and does NOTHING until a button is pressed (email security
// scanners open links automatically; they must not be able to unsubscribe or delete anyone).
import './fonts.js';
import './styles.css';
import { logoMarkSvg } from './logo.js';
import { unsubscribeByLink, leaveWaitlistByLink, WaitlistError } from './waitlist/api.js';
import { linkToken } from './waitlist/validate.js';

document.querySelectorAll('[data-logo-mark]').forEach((slot) => { slot.innerHTML = logoMarkSvg('logo-mark'); });
document.querySelector('[data-year]').textContent = new Date().getFullYear();

const token = linkToken(window.location.hash);
if (window.location.hash) history.replaceState(null, '', window.location.pathname);   // don't leave the code behind

const sections = [...document.querySelectorAll('[data-prefs]')];
const errorBox = document.querySelector('[data-prefs-error]');
function show(name) {
  for (const s of sections) s.hidden = s.dataset.prefs !== name;
  errorBox.hidden = true;
}

const ERRORS = {
  invalid_link: "This link has expired or isn't valid. Please write to loferprivacy@gmail.com and we'll do it for you.",
  rate_limited: 'Lots of requests right now. Please try again in a minute.',
  network: "We couldn't connect. Please check your connection and try again.",
  timeout: 'That took too long. Please try again.',
};

async function run(button, action, doneSection) {
  const label = button.textContent;
  button.disabled = true;
  button.textContent = 'One moment…';
  try {
    await action(token);
    show(doneSection);
  } catch (error) {
    const code = error instanceof WaitlistError ? error.code : 'server';
    errorBox.textContent = ERRORS[code] ?? 'Something went wrong. Please try again, or write to loferprivacy@gmail.com.';
    errorBox.hidden = false;
  } finally {
    button.disabled = false;
    button.textContent = label;
  }
}

document.querySelectorAll('[data-prefs-action]').forEach((button) => {
  button.addEventListener('click', () => {
    switch (button.dataset.prefsAction) {
      case 'unsubscribe': return run(button, unsubscribeByLink, 'done-unsubscribe');
      case 'leave-ask': return show('confirm');
      case 'back': return show('choose');
      case 'leave': return run(button, leaveWaitlistByLink, 'done-leave');
    }
  });
});

show(token ? 'choose' : 'nolink');
