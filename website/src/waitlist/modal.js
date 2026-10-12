// The two-step waitlist, in a modal that any "Join the waitlist" button can open.
//
//   Step 1  name + email  -> saved straight away. This is the registration.
//   Step 2  optional answers + optional marketing consent -> can be skipped.
//   Done    "You're on the list."
//
// The person is on the waitlist as soon as Step 1 is saved. Nothing here ever shows
// "you're on the list" for a Step 1 that did not save.
import { joinWaitlist, updateWaitlist, WaitlistError } from './api.js';
import { nameError, emailError } from './validate.js';
import { INTERESTS, PRICE_RANGES, CONSENT_VERSION, CONSENT_WORDING, CONSENT_VERSION_ZH, CONSENT_WORDING_ZH } from './config.js';
import { t, getLanguage, applyLanguage, translateElement } from '../i18n/i18n.js';

const options = (list) => list.map(([value, label, id]) => `<option value="${value}" data-i18n="${id}">${label}</option>`).join('');

// The privacy policy opens in a new tab, so nothing typed here is lost.
const PRIVACY_URL = `${import.meta.env.BASE_URL}privacy/`;

const TEMPLATE = `
<dialog class="wl" aria-labelledby="wl-title-1">
  <div class="wl__panel">
    <button class="wl__close" type="button" aria-label="Close" data-i18n-aria-label="143" data-wl-close>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>
    </button>

    <div class="wl__progress" data-wl-progress>
      <span class="wl__bars" aria-hidden="true"><i class="is-on" data-wl-bar="1"></i><i data-wl-bar="2"></i></span>
      <p class="wl__stepname" data-wl-stepname aria-live="polite">Step 1 of 2</p><!-- (set in show(): "Step 1 of 2" / "Step 2 of 2 · Optional") -->
    </div>

    <!-- STEP 1 -->
    <section class="wl__step" data-wl-step="1">
      <h2 class="wl__title" id="wl-title-1" tabindex="-1" data-i18n="145">Be the first to experience Lofer.</h2>
      <p class="wl__sub" data-i18n="146">Personalised body care, made accessible.<br />Join our waitlist for early access.</p>
      <form class="wl__form" novalidate data-wl-form="1">
        <div class="wl__field">
          <label for="wl-name" data-i18n="147">Name</label>
          <input id="wl-name" name="name" type="text" autocomplete="name" maxlength="100" required aria-describedby="wl-name-err" />
          <p class="wl__fielderr" id="wl-name-err" data-wl-err="name" hidden></p>
        </div>
        <div class="wl__field">
          <label for="wl-email" data-i18n="148">Email address</label>
          <input id="wl-email" name="email" type="email" inputmode="email" autocomplete="email" maxlength="254" required aria-describedby="wl-email-err" />
          <p class="wl__fielderr" id="wl-email-err" data-wl-err="email" hidden></p>
        </div>
        <!-- A trap for bots: people never see or fill this. -->
        <!-- (Named and labelled so browser autofill has no reason to fill it.) -->
        <div class="wl__hp" aria-hidden="true"><label>Leave this empty <input name="lofer_hp" type="text" tabindex="-1" autocomplete="off" /></label></div>
        <p class="wl__error" role="alert" data-wl-error="1" hidden></p>
        <button class="button wl__submit" type="submit" data-wl-submit="1" data-i18n="149">Join the Waitlist</button>
        <p class="wl__status" role="status" data-wl-status="1"></p>
        <p class="wl__note"><span data-i18n="150a">We'll use your information to manage your waitlist registration and contact you about early access. </span><a href="${PRIVACY_URL}" target="_blank" rel="noopener" data-lang-link data-i18n="150b">Read our Privacy Policy.</a></p>
      </form>
    </section>

    <!-- STEP 2 -->
    <section class="wl__step" data-wl-step="2" hidden>
      <p class="wl__joined"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg> <span data-i18n="151">You're on the waitlist.</span></p>
      <h2 class="wl__title" id="wl-title-2" tabindex="-1" data-i18n="152">Help us build Lofer for you.</h2>
      <p class="wl__sub"><span data-i18n="153a">A couple of quick questions to help shape what we build next. </span><strong data-i18n="153b">Both are optional.</strong></p>
      <form class="wl__form" novalidate data-wl-form="2">
        <div class="wl__field">
          <label for="wl-interest" data-i18n="154">What interests you most about Lofer?</label>
          <select id="wl-interest" name="interest"><option value="" data-i18n="155">Choose an option</option>${options(INTERESTS)}</select>
        </div>
        <div class="wl__field">
          <label for="wl-price" data-i18n="156">How much would you be willing to pay for a Lofer starter kit (6 intelligent body-care patches)?</label>
          <select id="wl-price" name="price" aria-describedby="wl-price-help"><option value="" data-i18n="157">Choose an option</option>${options(PRICE_RANGES)}</select>
          <p class="wl__help" id="wl-price-help" data-i18n="158">Assume a one-time purchase of the hardware. Any optional subscription would be separate.</p>
        </div>
        <div class="wl__consent">
          <label class="wl__check">
            <input type="checkbox" name="consent" />
            <span data-wl-consent-text>${CONSENT_WORDING}</span>
          </label>
          <p class="wl__help" data-i18n="160">You can unsubscribe from marketing emails at any time. Your waitlist registration won't be affected.</p>
        </div>
        <p class="wl__error" role="alert" data-wl-error="2" hidden></p>
        <div class="wl__actions">
          <button class="button wl__submit" type="submit" data-wl-submit="2" data-i18n="161">Submit</button>
          <button class="wl__skip" type="button" data-wl-skip data-i18n="162">Skip for now</button>
        </div>
        <p class="wl__status" role="status" data-wl-status="2"></p>
      </form>
    </section>

    <!-- DONE -->
    <section class="wl__step wl__step--done" data-wl-step="done" hidden>
      <span class="wl__tick" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></span>
      <h2 class="wl__title" id="wl-title-done" tabindex="-1" data-i18n="163">You're on the list.</h2>
      <p class="wl__sub" data-i18n="164">We'll be in touch when Lofer is ready.<br />Thanks for being part of the beginning.</p>
      <button class="button wl__submit" type="button" data-wl-close data-i18n="165">Back to Lofer</button>
    </section>
  </div>
</dialog>`;

// What to tell people when something goes wrong. Step 1 errors always say they are NOT yet on the list;
// Step 2 errors always say they ARE.
const STEP1_IDS = { invalid_email: '166', invalid_name: '167', rate_limited: '168', network: '169', timeout: '170', unavailable: '171', server: '172' };
const STEP2_IDS = { invalid_token: '173', rate_limited: '174', network: '175', timeout: '176', server: '177' };
const step1Error = (code) => { const key = STEP1_ERRORS[code] ? code : 'server'; return t(STEP1_IDS[key], STEP1_ERRORS[key]); };
const step2Error = (code) => { const key = STEP2_ERRORS[code] ? code : 'server'; return t(STEP2_IDS[key], STEP2_ERRORS[key]); };
// The browser-side checks (validate.js) give English messages; these are their translations.
const VALIDATION_IDS = {
  'Please enter your name.': '167',
  'Please enter your email address.': 'x-email-empty',
  'Please enter a valid email address.': '166',
};
const tv = (message) => (VALIDATION_IDS[message] ? t(VALIDATION_IDS[message], message) : message.startsWith('Please keep your name') ? t('x-name-long', message) : message);

const STEP1_ERRORS = {
  invalid_email: 'Please enter a valid email address.',
  invalid_name: 'Please enter your name.',
  rate_limited: "We're getting a lot of sign-ups right now. Please try again in a few minutes. You're not on the list yet.",
  network: "We couldn't reach the waitlist. Please check your connection and try again. You're not on the list yet.",
  timeout: "That's taking longer than expected. Please try again. You're not on the list yet.",
  unavailable: "The waitlist isn't available right now. Please try again later. You're not on the list yet.",
  server: "Something went wrong on our side, and your sign-up wasn't saved. Please try again in a moment.",
};
const STEP2_ERRORS = {
  invalid_token: "We couldn't save these answers. If you've signed up with this email before, your original sign-up and answers stay as they were, and you're on the waitlist either way. You can skip this step.",
  rate_limited: "We couldn't save your answers just now, but you're still on the waitlist. Please try again in a few minutes, or skip.",
  network: "We couldn't save your answers (the connection dropped), but you're still on the waitlist. You can try again or skip.",
  timeout: "Saving your answers is taking longer than expected, but you're still on the waitlist. You can try again or skip.",
  server: "We couldn't save your answers, but you're still on the waitlist. You can try again or skip.",
};

export function initWaitlist() {
  const wrapper = document.createElement('div');
  wrapper.innerHTML = TEMPLATE.trim();
  const dialog = wrapper.firstElementChild;
  document.body.append(dialog);
  const $ = (selector) => dialog.querySelector(selector);

  const state = { step: 1, token: null, decoy: false };
  const steps = { 1: $('[data-wl-step="1"]'), 2: $('[data-wl-step="2"]'), done: $('[data-wl-step="done"]') };
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ── Language ──
  const renderStepName = () => {
    $('[data-wl-stepname]').textContent = state.step === 2 ? t('x-step2', 'Step 2 of 2 · Optional') : t('144', 'Step 1 of 2');
  };
  const renderConsentText = () => {
    $('[data-wl-consent-text]').textContent = getLanguage() === 'zh' ? CONSENT_WORDING_ZH : CONSENT_WORDING;
  };
  function onLanguageChange() {
    applyLanguage(dialog);
    renderConsentText();
    renderStepName();
    // The box is cleared, so a "yes" is always given to the wording the person is looking at.
    dialog.querySelector('[name=consent]').checked = false;
    dialog.querySelectorAll('[data-wl-error], [data-wl-err]').forEach((box) => { box.textContent = ''; box.hidden = true; });
  }
  document.addEventListener('lofer:langchange', onLanguageChange);

  function show(step) {
    state.step = step;
    for (const [key, el] of Object.entries(steps)) el.hidden = String(step) !== key;
    $('[data-wl-progress]').hidden = step === 'done';
    renderStepName();
    $('[data-wl-bar="2"]').classList.toggle('is-on', step === 2);
    const heading = $(`#wl-title-${step}`);
    dialog.setAttribute('aria-labelledby', heading.id);
    if (!reducedMotion) {
      steps[step].classList.remove('is-entering');
      void steps[step].offsetWidth;   // restart the entrance animation
      steps[step].classList.add('is-entering');
    }
    // Move keyboard focus to the new step so screen readers announce it.
    (step === 1 ? $('#wl-name') : heading).focus({ preventScroll: true });
  }

  function setError(box, message) {
    box.textContent = message;
    box.hidden = !message;
  }
  function setBusy(button, statusEl, busy, label, slowLabel) {
    button.disabled = busy;
    button.classList.toggle('is-busy', busy);
    if (busy) button.textContent = label;
    else translateElement(button);          // back to the button's own words, in the current language
    statusEl.textContent = '';
    if (busy) return setTimeout(() => { statusEl.textContent = slowLabel; }, 6000);   // a slow network: say so
    return null;
  }

  // ── Step 1 ──
  $('[data-wl-form="1"]').addEventListener('submit', async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const name = form.elements.name.value;
    const email = form.elements.email.value;

    const problems = { name: nameError(name), email: emailError(email) };
    for (const key of ['name', 'email']) {
      const box = $(`[data-wl-err="${key}"]`);
      setError(box, problems[key] ? tv(problems[key]) : '');
      form.elements[key].setAttribute('aria-invalid', problems[key] ? 'true' : 'false');
    }
    setError($('[data-wl-error="1"]'), '');
    if (problems.name || problems.email) {
      form.elements[problems.name ? 'name' : 'email'].focus();
      return;
    }

    // Bots fill the hidden field. Look like success, send nothing.
    if (form.elements.lofer_hp.value) {
      state.decoy = true;
      show(2);
      return;
    }

    const button = $('[data-wl-submit="1"]');
    const slow = setBusy(button, $('[data-wl-status="1"]'), true, t('178', 'Joining…'), t('179', 'Still working… this is taking a little longer than usual.'));
    try {
      const { token } = await joinWaitlist({ name, email });
      state.token = token;
      clearTimeout(slow);
      // A short, calm confirmation on the button, then on to Step 2.
      button.disabled = true;
      button.classList.remove('is-busy');
      button.textContent = t('180', "You're on the list ✓");
      await new Promise((resolve) => setTimeout(resolve, reducedMotion ? 0 : 900));
      translateElement(button);
      button.disabled = false;
      show(2);
    } catch (error) {
      clearTimeout(slow);
      setBusy(button, $('[data-wl-status="1"]'), false);
      const code = error instanceof WaitlistError ? error.code : 'server';
      if (code === 'invalid_email') setError($('[data-wl-err="email"]'), step1Error('invalid_email'));
      else if (code === 'invalid_name') setError($('[data-wl-err="name"]'), step1Error('invalid_name'));
      else setError($('[data-wl-error="1"]'), step1Error(code));
    }
  });

  // ── Step 2 ──
  async function finish() { show('done'); }

  $('[data-wl-form="2"]').addEventListener('submit', async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const answers = { interest: form.elements.interest.value, price: form.elements.price.value, consent: form.elements.consent.checked };
    setError($('[data-wl-error="2"]'), '');

    // Nothing answered and the box left unticked: there is nothing to save.
    if (!answers.interest && !answers.price && !answers.consent) return finish();
    if (state.decoy) return finish();

    const button = $('[data-wl-submit="2"]');
    const slow = setBusy(button, $('[data-wl-status="2"]'), true, t('181', 'Saving…'), t('182', 'Still saving… your place on the waitlist is safe.'));
    try {
      // The consent version is the wording in the language they are looking at right now.
      await updateWaitlist({ token: state.token, ...answers, consentVersion: getLanguage() === 'zh' ? CONSENT_VERSION_ZH : CONSENT_VERSION });
      clearTimeout(slow);
      setBusy(button, $('[data-wl-status="2"]'), false);
      await finish();
    } catch (error) {
      clearTimeout(slow);
      setBusy(button, $('[data-wl-status="2"]'), false);
      // Step 1 is already saved, so this never undoes the registration.
      const code = error instanceof WaitlistError ? error.code : 'server';
      setError($('[data-wl-error="2"]'), step2Error(code));
    }
  });
  $('[data-wl-skip]').addEventListener('click', finish);

  // ── Opening and closing ──
  function open() {
    if (!dialog.open) {
      dialog.showModal();
      document.documentElement.classList.add('wl-open');
    }
    show(state.step);   // pick up where they left off (closing mid-way never loses the registration)
  }
  function close() { dialog.close(); }
  dialog.addEventListener('close', () => document.documentElement.classList.remove('wl-open'));
  dialog.addEventListener('click', (event) => { if (event.target === dialog) close(); });   // click on the dimmed backdrop
  dialog.querySelectorAll('[data-wl-close]').forEach((button) => button.addEventListener('click', close));

  onLanguageChange();   // start in the current language

  document.querySelectorAll('[data-waitlist-open]').forEach((trigger) => {
    trigger.addEventListener('click', (event) => { event.preventDefault(); open(); });
  });
}
