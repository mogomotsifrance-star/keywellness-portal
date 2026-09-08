/* Key Wellness — headless checks for the first session (P0-1).

   There was no coverage of onboarding at all before this, on the largest and
   least-protected file in the repo, while P0-1 rewrote exactly that path. The
   things asserted here are the ones a regression would silently undo:

     · no modal fires on sign-in (four used to);
     · the wizard is two screens, and neither asks for a company, a department
       or a Pula amount;
     · consent is recorded BEFORE the member is allowed past screen 1, and
       finishing the wizard does not un-record it (saveUser() writes a whitelist
       with `consent_accepted ?? false`, so replacing state.user wholesale in
       finishOnboarding would quietly reset a compliance record — it did in an
       earlier draft of this change);
     · `onboarded` is the only gate, so the name modal can no longer skip the
       wizard the way it did before (audit F1).

   Usage:  node tests/smoke-onboarding.js
*/
const { chromium } = require('playwright');
const path = require('path');
const url = require('url');

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name); }
  else    { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}

const INDEX = url.pathToFileURL(path.resolve(__dirname, '..', 'index.html')).href;
const UID = 'u1';

/* The stub every page in this repo needs. index.html loads supabase-js from
   jsdelivr; if the CDN is reachable the real library OVERWRITES this stub, the
   page builds a real client against production, and every assertion afterwards
   is meaningless. See the same note in smoke-account.js. */
function installStub(page, profile) {
  return page.addInitScript(({ profile, uid }) => {
    // Trust the session so index.html does not stop at the password wall.
    try {
      localStorage.setItem('kw_session_trust', JSON.stringify({ uid, ts: Date.now() }));
      localStorage.removeItem('kw_consent_accepted');
      localStorage.removeItem('kw_welcome_seen');
      localStorage.removeItem('kw_profile');
    } catch (_) {}

    window.__writes = [];          // every profiles write, in order
    window.__navigations = [];     // openTool() targets, intercepted below
    window.__profile = profile;

    const rows = (table) => {
      if (table === 'profiles') return window.__profile;
      return null;
    };
    // Fixtures for the dashboard cases carry an assessment row, so those cases
    // stay about the welcome card rather than about the empty state. Cases that
    // deliberately have none (the P0-2 group) pass no __assessments.
    const lists = (table) => {
      if (table === 'assessments') return window.__profile?.__assessments || [];
      return [];
    };
    const chain = (table, op, payload) => {
      const c = {
        eq: () => c, in: () => c, or: () => c, order: () => c, limit: () => c,
        select: () => c,
        maybeSingle: async () => ({ data: rows(table), error: null }),
        single: async () => {
          if (table === 'profiles' && op === 'upsert') {
            window.__profile = { ...(window.__profile || {}), ...payload };
            return { data: window.__profile, error: null };
          }
          return { data: rows(table), error: null };
        },
        then: (res) => res({ data: table === 'profiles' ? null : lists(table), error: null })
      };
      if (table === 'profiles' && (op === 'upsert' || op === 'update')) {
        window.__writes.push({ op, payload });
        if (op === 'update') window.__profile = { ...(window.__profile || {}), ...payload };
      }
      return c;
    };
    const fake = {
      from: (t) => ({
        select: () => chain(t, 'select'),
        insert: (p) => chain(t, 'insert', p),
        update: (p) => chain(t, 'update', p),
        upsert: (p) => chain(t, 'upsert', p),
        delete: () => chain(t, 'delete'),
      }),
      rpc: async () => ({ data: null, error: null }),
      auth: {
        getSession: async () => ({ data: { session: { user: { id: uid, email: 'new@example.com' } } } }),
        getUser: async () => ({ data: { user: { id: uid, email: 'new@example.com' } } }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
        updateUser: async () => ({ error: null }),
        signOut: async () => ({ error: null }),
      }
    };
    window.supabase = { createClient: () => fake };

    // openTool() sets location.href. Record it instead of leaving the page.
    window.addEventListener('DOMContentLoaded', () => {
      const orig = window.openTool;
      window.openTool = (f) => { window.__navigations.push(f); };
      void orig;
    });
  }, { profile, uid: UID });
}

async function boot(browser, profile) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
  await installStub(page, profile);
  await page.goto(INDEX);
  await page.waitForFunction(() => !!window.state && window.state.user !== undefined, null, { timeout: 10000 })
    .catch(() => {});
  await page.waitForTimeout(1500);   // long enough for the old 700/800 ms modal timers
  return { page, errors };
}

const NEW_MEMBER = { id: UID, onboarded: false, first_name: null, consent_accepted: false };

(async () => {
  const browser = await chromium.launch();

  /* ── 1. Nothing pops up, and the wizard is what a new member gets ── */
  {
    const { page, errors } = await boot(browser, NEW_MEMBER);

    const modals = await page.evaluate(() => {
      const vis = id => {
        const el = document.getElementById(id);
        if (!el) return false;
        const cs = getComputedStyle(el);
        return cs.display !== 'none' && cs.visibility !== 'hidden' && el.offsetParent !== null;
      };
      return { name: vis('name-modal'), consent: vis('consent-modal'), gender: vis('gender-modal'),
               company: vis('company-modal'), department: vis('department-modal'),
               welcome: document.getElementById('welcome-modal')?.classList.contains('visible') || false };
    });
    check('1  the name pop-up does not fire on sign-in', modals.name === false);
    check('2  the consent pop-up does not fire on sign-in', modals.consent === false);
    check('3  the gender pop-up does not fire on sign-in', modals.gender === false);
    check('4  the company and department backfills do not fire',
      modals.company === false && modals.department === false);
    check('5  the welcome video does not open itself', modals.welcome === false);

    const body = await page.evaluate(() => document.getElementById('page-content').textContent);
    check('6  a member who is not onboarded lands on "Before you start"',
      /Before you start/.test(body), body.slice(0, 120));
    check('7  step 1 of 2, not step 1 of 6', /Step 1 of 2/.test(body));

    /* The three lines the audit specified, in the member's language. */
    check('8  it says what will be asked, who sees it, and what we never do',
      /What we will ask/.test(body) && /Who can see it/.test(body) && /What we never do/.test(body));
    check('9  it names the five-or-more rule rather than "authorised advisors"',
      /groups of five or more/i.test(body) && /never your name/i.test(body));
    check('10 it says data is never sold or shared with lenders',
      /never sell/i.test(body) && /lenders/i.test(body));

    /* Continue is gated on the tick, and consent is not written before it. */
    const beforeTick = await page.evaluate(() => ({
      disabled: document.getElementById('w-next')?.disabled,
      writes: window.__writes.length,
    }));
    check('11 Continue is disabled until "I understand" is ticked', beforeTick.disabled === true);
    check('12 nothing is written to profiles before the member ticks it', beforeTick.writes === 0);

    /* The full statement is the real one, read from #consent-statement. */
    await page.click('button:has-text("Read the full Data Protection statement")');
    const expanded = await page.evaluate(() => document.getElementById('page-content').textContent);
    check('13 the full statement expands inline, not in a modal',
      /Secure Storage/.test(expanded) && /Botswana Data Protection/.test(expanded));
    check('14 the expanded text is the same one the consent modal holds',
      expanded.includes('Purpose Limitation'));

    await page.click('button:has-text("Hide the full Data Protection statement")');
    const collapsed = await page.evaluate(() => document.getElementById('page-content').textContent);
    check('15 and collapses again', !/Secure Storage/.test(collapsed));

    /* Tick → Continue records consent before advancing. */
    await page.check('#onb-consent');
    await page.click('#w-next');
    await page.waitForTimeout(400);

    const afterConsent = await page.evaluate(() => ({
      writes: window.__writes,
      ls: localStorage.getItem('kw_consent_accepted'),
      text: document.getElementById('page-content').textContent,
    }));
    const consentWrite = afterConsent.writes.find(w => w.payload && w.payload.consent_accepted === true);
    check('16 ticking records consent_accepted on the server', !!consentWrite);
    check('17 with a consent_date', !!(consentWrite && consentWrite.payload.consent_date));
    check('18 and only then sets the localStorage fast-path', afterConsent.ls === 'true');
    check('19 the member advances to "About you"', /About you/.test(afterConsent.text));

    /* ── Screen 2: one screen, no company, no department, no Pula ── */
    const about = await page.evaluate(() => {
      const el = document.getElementById('page-content');
      const ids = [...el.querySelectorAll('input,button')].map(n => n.id).filter(Boolean);
      return {
        text: el.textContent,
        ids,
        moneyInputs: [...el.querySelectorAll('input')].filter(i => i.inputMode === 'decimal').length,
        prefixes: el.querySelectorAll('.input-prefix').length,
        genderSelected: [...el.querySelectorAll('#onb-gender .choice-btn')]
          .filter(b => b.classList.contains('selected')).map(b => b.dataset.g),
      };
    });
    check('20 first name, age, last name and gender are all on one screen',
      about.ids.includes('onb-first') && about.ids.includes('onb-age') &&
      about.ids.includes('onb-last') && /Gender/.test(about.text));
    check('21 employment and goals are on it too',
      /employment status/i.test(about.text) && /want to work on/i.test(about.text));
    check('22 no company picker', !/Which company/i.test(about.text));
    check('23 no department step', !/department/i.test(about.text));
    check('24 no Pula amount is asked anywhere in the wizard',
      about.moneyInputs === 0 && about.prefixes === 0);
    check('25 gender is optional and pre-set to "Prefer not to say"',
      /\(optional\)/.test(about.text) && about.genderSelected.length === 1 &&
      about.genderSelected[0] === 'prefer_not_to_say', JSON.stringify(about.genderSelected));
    check('26 and says why it is asked, as a group measure',
      /only ever as a group/i.test(about.text));

    /* Validation: Finish with nothing filled in must not save. */
    const writesBefore = await page.evaluate(() => window.__writes.length);
    await page.click('#w-next');
    await page.waitForTimeout(200);
    const blocked = await page.evaluate(() => ({
      writes: window.__writes.length,
      errs: ['onb-name-err','onb-age-err','onb-emp-err','onb-goals-err']
        .map(id => getComputedStyle(document.getElementById(id)).display !== 'none'),
      navs: window.__navigations.length,
    }));
    check('27 Finish with an empty form saves nothing', blocked.writes === writesBefore);
    check('28 and flags all four required answers at once',
      blocked.errs.every(Boolean), JSON.stringify(blocked.errs));
    check('29 and does not open the assessment', blocked.navs === 0);

    /* Age outside 18–80 is rejected. */
    await page.fill('#onb-first', 'Kagiso');
    await page.fill('#onb-age', '12');
    await page.click('.choice-btn:has-text("Self-employed")');
    await page.click('.choice-btn:has-text("Build savings")');
    await page.click('#w-next');
    await page.waitForTimeout(200);
    const badAge = await page.evaluate(() => ({
      shown: getComputedStyle(document.getElementById('onb-age-err')).display !== 'none',
      navs: window.__navigations.length,
    }));
    check('30 an age under 18 is rejected', badAge.shown === true && badAge.navs === 0);

    /* A good form finishes. */
    await page.fill('#onb-age', '34');
    await page.click('#w-next');
    await page.waitForTimeout(600);

    const done = await page.evaluate(() => ({
      writes: window.__writes,
      profile: window.__profile,
      navs: window.__navigations,
    }));
    const upserts = done.writes.filter(w => w.op === 'upsert');
    const last = upserts[upserts.length - 1];
    check('31 finishing marks the member onboarded', last && last.payload.onboarded === true);
    check('32 and saves the answers it asked for',
      last && last.payload.first_name === 'Kagiso' && last.payload.age === 34 &&
      last.payload.employment === 'Self-employed' &&
      Array.isArray(last.payload.goals) && last.payload.goals.includes('Build savings'),
      JSON.stringify(last && last.payload));
    /* The regression this file exists for. */
    check('33 and does NOT un-record the consent taken on screen 1',
      last && last.payload.consent_accepted === true,
      'consent_accepted=' + JSON.stringify(last && last.payload.consent_accepted));
    check('34 gender is persisted separately (it is not in saveUser\'s whitelist)',
      done.writes.some(w => w.op === 'update' && w.payload.gender === 'prefer_not_to_say'));
    check('35 nothing writes org_unit_id or department_id',
      !done.writes.some(w => 'org_unit_id' in w.payload || 'department_id' in w.payload));
    check('36 and the member goes straight to the habits check',
      done.navs.includes('wellness_assessment.html'), JSON.stringify(done.navs));

    check('37 no uncaught JavaScript errors through the whole first session',
      errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ── 1b. The same guard, for a member with no profiles row yet ──
     loadAllData leaves state.user null when the row has not materialised, so
     recordConsent takes its second branch. If that branch does not seed
     state.user, finishOnboarding's upsert defaults consent_accepted back to
     false and the compliance record is lost — the other half of check 33. */
  {
    const { page } = await boot(browser, null);
    const started = await page.evaluate(() => /Before you start/.test(document.getElementById('page-content').textContent));
    check('37a a member with no profiles row still gets the wizard', started === true);

    await page.check('#onb-consent');
    await page.click('#w-next');
    await page.waitForTimeout(400);
    await page.fill('#onb-first', 'Neo');
    await page.fill('#onb-age', '29');
    await page.click('.choice-btn:has-text("Student")');
    await page.click('.choice-btn:has-text("Pay off debt")');
    await page.click('#w-next');
    await page.waitForTimeout(600);

    const last = await page.evaluate(() => {
      const u = window.__writes.filter(w => w.op === 'upsert');
      return u[u.length - 1]?.payload || null;
    });
    check('37b and finishing does not reset the consent it just recorded',
      !!last && last.consent_accepted === true && !!last.consent_date,
      JSON.stringify(last && { c: last.consent_accepted, d: last.consent_date }));
    await page.close();
  }

  /* ── 2. The F1 gate: a name is not onboarding ────────────────── */
  {
    const { page } = await boot(browser, {
      id: UID, onboarded: false, first_name: 'Existing', consent_accepted: true,
    });
    const text = await page.evaluate(() => document.getElementById('page-content').textContent);
    check('38 a member with a name but onboarded=false still sees the wizard once',
      /Before you start/.test(text), text.slice(0, 120));
    await page.close();
  }
  {
    const { page } = await boot(browser, {
      id: UID, onboarded: true, first_name: 'Existing', consent_accepted: true,
    });
    const text = await page.evaluate(() => document.getElementById('page-content').textContent);
    check('39 an onboarded member is not sent back through it',
      !/Before you start/.test(text));
    await page.close();
  }

  /* ── 2b. P0-2: no route is locked behind a first assessment ────
     An onboarded member with NO assessments row. Every one of these views used
     to render "One quick step first" with dead navigation. */
  {
    const ONBOARDED_NO_ASSESSMENT = {
      id: UID, onboarded: true, first_name: 'Neo', consent_accepted: true, welcome_seen: true,
    };
    const { page, errors } = await boot(browser, ONBOARDED_NO_ASSESSMENT);

    const dash = await page.evaluate(() => document.getElementById('page-content').textContent);
    check('40 a member with no assessment is not held on "One quick step first"',
      !/One quick step first/.test(dash), dash.slice(0, 120));
    check('41 they get the dashboard itself', /Financial Hub|Your picture/.test(dash), dash.slice(0, 160));

    /* Every member route renders, not just the dashboard. */
    const views = ['learn', 'tools', 'booking', 'emergency', 'progress', 'badges', 'profile', 'my-bookings', 'checkin'];
    const blocked = [];
    for (const v of views) {
      await page.evaluate(view => { window.location.hash = view; }, v);
      await page.waitForTimeout(250);
      const t = await page.evaluate(() => document.getElementById('page-content').textContent.trim());
      if (/One quick step first/.test(t) || t.length === 0) blocked.push(v + (t.length === 0 ? ' (empty)' : ' (locked)'));
    }
    check('42 and every other member route renders too', blocked.length === 0, blocked.join(', '));

    check('43 renderFirstAssessmentLock no longer exists',
      await page.evaluate(() => typeof window.renderFirstAssessmentLock === 'undefined'));
    check('44 no uncaught errors walking the portal without an assessment',
      errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ── 3. The welcome video is a card, not a gate ──────────────── */
  {
    const { page } = await boot(browser, {
      id: UID, onboarded: true, first_name: 'Existing', consent_accepted: true, welcome_seen: false,
      __assessments: [{ id: 'a1', user_id: UID, score: 62, cat_scores: {}, answers: {}, created_at: new Date().toISOString() }],
    });
    await page.waitForTimeout(600);
    const card = await page.evaluate(() => document.getElementById('page-content').textContent);
    check('45 the dashboard offers the welcome video as a dismissible card',
      /Watch the 2-minute welcome from the team/.test(card));

    /* Opening it shows a close control immediately — it used to be withheld
       until the video ended, which is what made it a gate. */
    await page.click('button:has-text("Watch")');
    await page.waitForTimeout(300);
    const open = await page.evaluate(() => ({
      visible: document.getElementById('welcome-modal').classList.contains('visible'),
      closeShown: getComputedStyle(document.getElementById('welcome-start-wrap')).display !== 'none',
      label: document.querySelector('#welcome-start-wrap button')?.textContent.trim(),
    }));
    check('46 the video modal opens with its close button already there',
      open.visible === true && open.closeShown === true);
    check('47 and the button closes rather than launching the assessment',
      open.label === 'Close', open.label);

    await page.click('#welcome-start-wrap button');
    await page.waitForTimeout(500);
    const afterClose = await page.evaluate(() => ({
      navs: window.__navigations.length,
      ls: localStorage.getItem('kw_welcome_seen'),
      card: document.getElementById('page-content').textContent,
    }));
    check('48 closing it opens nothing', afterClose.navs === 0);
    check('49 remembers it was seen', afterClose.ls === 'true');
    check('50 and the card is gone', !/Watch the 2-minute welcome/.test(afterClose.card));
    await page.close();
  }
  {
    const { page } = await boot(browser, {
      id: UID, onboarded: true, first_name: 'Existing', consent_accepted: true, welcome_seen: false,
      __assessments: [{ id: 'a1', user_id: UID, score: 62, cat_scores: {}, answers: {}, created_at: new Date().toISOString() }],
    });
    await page.waitForTimeout(600);
    await page.click('button:has-text("Dismiss")');
    await page.waitForTimeout(500);
    const dismissed = await page.evaluate(() => ({
      ls: localStorage.getItem('kw_welcome_seen'),
      card: document.getElementById('page-content').textContent,
    }));
    check('51 Dismiss retires the card without watching', dismissed.ls === 'true' &&
      !/Watch the 2-minute welcome/.test(dismissed.card));
    await page.close();
  }

  await browser.close();
  console.log(`\n  ${pass} passed, ${fail} failed.`);
  process.exit(fail ? 1 : 0);
})();
