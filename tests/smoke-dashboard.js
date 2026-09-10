/* Key Wellness — headless checks for the dashboard first-week state (P0-4).

   What this guards:

     · the score gate. A wellness score out of 100 is shown only once the four
       sources it depends on exist — EXCEPT for a member assessed before P0-3,
       whose figures were given inside the assessment and whose score must not
       vanish. That exception has NO expiry: an old assessment is dated, not
       false, and a score is not taken away from someone who went quiet. What it
       gets instead is its date on the gauge and a live budget nudge. It must
       still not apply to a habits-only row. Four ways to get this wrong;
     · the two-nudge rule. The strip used to carry up to nine at once, ordered
       by the order they happened to be written;
     · an absent figure reads "not yet", never a dash in a warning colour. A red
       "—" states a problem about something the member has not been asked for;
     · "I have no debts" completes the debts source, so a debt-free member's
       picture can reach 6 of 6 instead of being nudged forever.

   Usage:  node tests/smoke-dashboard.js
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
const daysAgo = n => new Date(Date.now() - n * 86400000).toISOString();
const thisMonth = new Date().toISOString().slice(0, 7);

/* A budget the dashboard will accept as "saved this month". */
const BUDGET = {
  currentKey: thisMonth,
  budgets: { [thisMonth]: { income: [{ name: 'Salary', amount: 12000 }],
                            expenses: { rent: 4000, food: 2000, debt_min: 1500, emfund: 500 } } },
};
const EF = { user_id: UID, target_months: 6, current_savings: 9000, monthly: 6000, contribution: 400 };
const DTI = { debts: [{ id: 1, name: 'Car loan', amount: 1500, balance: 60000 }], grossSalary: '12,000', otherIncome: '0' };
const NW = { assets: [{ name: 'Car', amt: 50000 }], liabilities: [] };
const RET = { snapshot: { readinessPct: 55, retireAge: 60, yrsToRetire: 25, currentAge: 35 }, inputs: {} };

/* A habits-only assessment row (P0-3 shape) and a pre-change one. */
const habitsRow = (age = 1) => ({ id: 'a1', user_id: UID, score: 61,
  cat_scores: { income: 66, savings: 33, emergency: 25, debt: 100, retirement: 0, insurance: 50, goals: 60, spending: 70, _insCount: 3 },
  answers: { _habits_only: true, incomeStability: 2, savingsHabit: 1, debtMgmt: 3 }, created_at: daysAgo(age) });
const legacyRow = (age = 1) => ({ id: 'a0', user_id: UID, score: 58,
  cat_scores: { income: 60, savings: 50, emergency: 40, debt: 70, retirement: 45, insurance: 55, goals: 60, spending: 65, _insCount: 4 },
  answers: { incomeStability: 2, savingsHabit: 2, debtMgmt: 2 }, created_at: daysAgo(age) });

function installStub(page, f) {
  return page.addInitScript(({ f, uid }) => {
    try {
      localStorage.setItem('kw_session_trust', JSON.stringify({ uid, ts: Date.now() }));
      ['kw_consent_accepted','kw_welcome_seen','kw_profile','kw_snapshot',
       'kw_assessment_result','kw_no_debts'].forEach(k => localStorage.removeItem(k));
      localStorage.setItem('kw_welcome_seen', 'true');   // keep the welcome card out of the way
      if (f.noDebts) localStorage.setItem('kw_no_debts', 'true');
      if (f.startingPoint) localStorage.setItem('kw_assessment_result',
        JSON.stringify({ score: 61, habitsOnly: true, date: new Date().toISOString(), startingPoint: f.startingPoint }));
    } catch (_) {}

    const toolRows = Object.entries(f.tools || {}).map(([tool, data]) => ({ tool, data }));
    const lists = {
      assessments: f.assessments || [], checkins: [], stress_logs: f.stress || [],
      bookings: [], reward_thresholds: [], tool_data: toolRows, notifications: [],
    };
    const singles = {
      profiles: f.profile, badges: { earned_badge_ids: [] },
      my_points: { total: 0 }, emergency_fund: f.ef || null,
    };
    /* The real Supabase builder is a thenable that also has .catch — index.html
       uses `.update(...).eq(...).then(...).catch(...)` in persistLiveWellness.
       A `then` that returns a plain value leaves `.catch` undefined and the
       dashboard dies with "Cannot read properties of undefined". */
    const chain = (table) => {
      const settle = () => Promise.resolve({ data: lists[table] ?? [], error: null });
      const c = {
        eq: () => c, in: () => c, or: () => c, order: () => c, limit: () => c, select: () => c,
        maybeSingle: async () => ({ data: singles[table] ?? null, error: null }),
        single: async () => ({ data: singles[table] ?? null, error: null }),
        then: (res, rej) => settle().then(res, rej),
        catch: (fn) => settle().catch(fn),
        finally: (fn) => settle().finally(fn),
      };
      return c;
    };
    const fake = {
      from: (t) => ({ select: () => chain(t), insert: () => chain(t), update: () => chain(t),
                      upsert: () => chain(t), delete: () => chain(t) }),
      rpc: async () => ({ data: null, error: null }),
      auth: {
        getSession: async () => ({ data: { session: { user: { id: uid, email: 'm@example.com' } } } }),
        getUser: async () => ({ data: { user: { id: uid, email: 'm@example.com' } }, error: null }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      },
    };
    window.supabase = { createClient: () => fake };
  }, { f, uid: UID });
}

const CDN_NOISE = /jsdelivr|cdnjs|Chart|vimeo/i;

async function dash(browser, fixture) {
  const f = { profile: { id: UID, onboarded: true, first_name: 'Neo', consent_accepted: true, welcome_seen: true },
              ...fixture };
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => { if (!CDN_NOISE.test(String(e))) errors.push(String(e)); });
  await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
  await installStub(page, f);
  await page.goto(INDEX);
  await page.waitForFunction(() => !!document.getElementById('page-content')?.textContent.trim(),
    null, { timeout: 10000 }).catch(() => {});
  await page.waitForTimeout(1200);
  const view = await page.evaluate(() => {
    const el = document.getElementById('page-content');
    const cards = [...el.querySelectorAll('.hub-card')].map(c => ({
      lbl: c.querySelector('.hub-lbl')?.textContent || '',
      val: c.querySelector('.hub-val')?.textContent || '',
      cls: c.className,
    }));
    return {
      text: el.textContent,
      html: el.innerHTML,
      cards,
      gauge: !!el.querySelector('svg path[d*="A 78 78"]'),
      actions: el.querySelectorAll('.next-action').length,
    };
  });
  return { page, view, errors };
}

/* index.html tags the strip #kw-nudge-strip and each row data-kw-nudge="<id>".
   Reading those rather than inferring from div nesting keeps this suite from
   breaking on a purely visual change to the strip. */
async function nudgeIds(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll('#kw-nudge-strip [data-kw-nudge]')].map(n => n.dataset.kwNudge));
}

(async () => {
  const browser = await chromium.launch();

  /* ── 1. Brand-new member: nothing done ───────────────────────── */
  {
    const { page, view, errors } = await dash(browser, { assessments: [] });
    check('1  the gauge is not shown before the score is earned', view.gauge === false);
    check('2  the slot reads "Your picture — 0 of 6"', /Your picture — 0 of 6/.test(view.text), view.text.slice(0, 140));
    check('3  all six sources are listed as a checklist',
      ['Habits check','Budget','Emergency fund','Debts','Net worth','Retirement']
        .every(l => view.text.includes(l)));
    check('4  and each unmet one reads "not yet"',
      (view.text.match(/not yet/g) || []).length >= 6, String((view.text.match(/not yet/g) || []).length));
    check('5  no wellness score is printed anywhere', !/\d+\/100/.test(view.text),
      (view.text.match(/\d+\/100/g) || []).join(' '));

    const titles = await nudgeIds(page);
    check('6  at most two nudges are live, and at least one', titles.length >= 1 && titles.length <= 2, JSON.stringify(titles));
    check('7  and the first is the habits check', titles[0] === 'habits', JSON.stringify(titles));
    check('8  the second is the budget', titles[1] === 'budget', JSON.stringify(titles));
    check('9  the strip is headed by a next step, not "Action Required"',
      /Your next step/.test(view.text) && !/Action Required/.test(view.text));
    check('10 "What To Do Next" is capped at three', view.actions <= 3, String(view.actions));
    check('11 and does not also demand the assessment nudge 1 is asking for',
      !/Complete your wellness assessment/.test(view.text));
    check('12 no empty hub card shows a dash', !view.cards.some(c => c.val === '—'),
      JSON.stringify(view.cards.filter(c => c.val === '—')));
    check('13 nor a red or orange colour for an absence',
      !view.cards.some(c => c.val === 'not yet' && /\b(red|orange)\b/.test(c.cls)),
      JSON.stringify(view.cards.filter(c => c.val === 'not yet' && /\b(red|orange)\b/.test(c.cls))));
    check('14 no uncaught errors on an empty dashboard', errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ── 2. The starting point stands in for the score ───────────── */
  {
    const { page, view } = await dash(browser, {
      assessments: [habitsRow(1)],
      startingPoint: ['From your answers, two things stand out: you save what is left rather than saving first, and a surprise bill would be hard to absorb right now.',
                      'Moving even a small amount on payday, before anything else, is the single habit that changes this.'],
    });
    check('15 one source done reads "1 of 6"', /Your picture — 1 of 6/.test(view.text), view.text.slice(0, 140));
    check('16 the habits check no longer appears as a next step',
      !(await nudgeIds(page)).includes('habits'));
    check('17 the written starting point fills the gauge slot',
      /Your starting point/.test(view.text) && /save what is left rather than saving first/.test(view.text),
      view.text.slice(0, 200));
    check('18 still no score', view.gauge === false && !/\d+\/100/.test(view.text));
    await page.close();
  }

  /* ── 3. The score gate opens on the fourth source ────────────── */
  {
    const { view } = await dash(browser, {
      assessments: [habitsRow(1)], ef: EF,
      tools: { budget_planner: BUDGET },
    });
    check('19 habits + budget + EF is three of six — still no score',
      /Your picture — 3 of 6/.test(view.text) && view.gauge === false, view.text.slice(0, 140));
  }
  {
    const { view } = await dash(browser, {
      assessments: [habitsRow(1)], ef: EF,
      tools: { budget_planner: BUDGET, dti_calculator: DTI },
    });
    check('20 adding debts opens the gate and the gauge appears', view.gauge === true);
    check('21 and a score out of 100 is now shown', /\d+\/100/.test(view.text),
      view.text.slice(0, 160));
  }

  /* ── 4. "I have no debts" is an answer ───────────────────────── */
  {
    /* Gate still shut (no EF), so the checklist is on screen and the debts row
       can be read directly. */
    const { page, view } = await dash(browser, {
      assessments: [habitsRow(1)], noDebts: true, tools: { budget_planner: BUDGET },
    });
    check('22 "no debts" counts the debts source as done',
      /Your picture — 3 of 6/.test(view.text), view.text.slice(0, 160));
    check('23 the member is no longer nudged to list debts',
      !(await nudgeIds(page)).includes('debts'));
    await page.close();
  }
  {
    const { view } = await dash(browser, {
      assessments: [habitsRow(1)], ef: EF, noDebts: true, tools: { budget_planner: BUDGET },
    });
    check('24 and it opens the score gate without any debt register',
      view.gauge === true && /\d+\/100/.test(view.text), view.text.slice(0, 160));
  }

  /* ── 5. The grandfather rule ──────────────────────────────────
     It has no expiry. A score earned from figures the member typed into the old
     assessment stays theirs; what it carries is a date, so they can judge its
     age themselves, and a budget nudge, so refreshing it is one click. */
  {
    const { page, view } = await dash(browser, { assessments: [legacyRow(10)] });
    check('25 a pre-change assessment keeps its score with no other source',
      view.gauge === true && /\d+\/100/.test(view.text), view.text.slice(0, 160));
    check('25b and the score is shown with the date it came from',
      /from your assessment on \d{1,2} [A-Z][a-z]+/.test(view.text),
      view.text.slice(0, 200));
    const titles = await nudgeIds(page);
    check('25c with the budget nudge still live beside it',
      titles.includes('budget'), JSON.stringify(titles));
    await page.close();
  }
  {
    /* The case the 90-day rule used to break: two years dormant. The score is
       still the last true thing the member told us, so it stays — dated. */
    const { page, view } = await dash(browser, { assessments: [legacyRow(730)] });
    check('26 and it never expires, however old the assessment is',
      view.gauge === true && /\d+\/100/.test(view.text), view.text.slice(0, 160));
    check('26b a date from an earlier year carries its year',
      /from your assessment on \d{1,2} [A-Z][a-z]+ \d{4}/.test(view.text),
      view.text.slice(0, 200));
    const titles = await nudgeIds(page);
    check('26c the budget nudge is live here too',
      titles.includes('budget'), JSON.stringify(titles));
    await page.close();
  }
  {
    /* Dimensions are not backfilled by the grandfather rule: a source the member
       has never given still reads "not yet" in the hub, not a number or a dash. */
    const { view } = await dash(browser, { assessments: [legacyRow(120)] });
    const empties = view.cards.filter(c => c.val === 'not yet').map(c => c.lbl);
    check('26d dimensions with no data still read "not yet"',
      empties.length >= 3 && !view.cards.some(c => c.val === '—'),
      JSON.stringify(view.cards.map(c => c.lbl + '=' + c.val)));
  }
  {
    /* Once the four sources are in, the score stands on its own and the date
       line would be telling the member to refresh what they just refreshed. */
    const { view } = await dash(browser, {
      assessments: [legacyRow(120)], ef: EF,
      tools: { budget_planner: BUDGET, dti_calculator: DTI },
    });
    check('26e once the sources are in, the score drops the "from your assessment" line',
      view.gauge === true && !/from your assessment on/.test(view.text),
      view.text.slice(0, 200));
  }
  {
    const { view } = await dash(browser, { assessments: [habitsRow(10)] });
    check('27 and a habits-only row never grandfathers, however recent',
      view.gauge === false && /Your picture — 1 of 6/.test(view.text), view.text.slice(0, 140));
  }
  {
    const { view } = await dash(browser, { assessments: [habitsRow(400)] });
    check('27b nor an old one — age was never what made a row count',
      view.gauge === false && /Your picture/.test(view.text), view.text.slice(0, 140));
  }

  /* ── 6. A full picture ───────────────────────────────────────── */
  {
    const { page, view, errors } = await dash(browser, {
      assessments: [habitsRow(1)], ef: EF,
      tools: { budget_planner: BUDGET, dti_calculator: DTI, net_worth_tracker: NW, retirement: RET,
               /* stress is nudge 7, not one of the six sources — a complete
                  picture with no log still legitimately asks for one, so the
                  fixture supplies it to reach a genuinely empty ladder. */
               financial_stress_tracker: { entries: [{ score: 4, date: daysAgo(2) }] } },
    });
    check('28 six of six shows the score', view.gauge === true);
    const titles = await nudgeIds(page);
    check('29 and the ladder has nothing left to ask', titles.length === 0, JSON.stringify(titles));
    check('30 the strip still shows one "done" line for momentum',
      /done\. That fills in the tools/.test(view.text));
    check('31 no uncaught errors on a complete dashboard', errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ── 7. Nudge ordering and the folded employment rule ────────── */
  {
    const { page } = await dash(browser, {
      assessments: [habitsRow(1)], tools: { budget_planner: BUDGET },
    });
    const titles = await nudgeIds(page);
    check('32 with habits and budget done, the emergency fund comes next',
      titles[0] === 'emergency', JSON.stringify(titles));
    await page.close();
  }
  {
    const { page, view } = await dash(browser, {
      profile: { id: UID, onboarded: true, first_name: 'Neo', consent_accepted: true,
                 welcome_seen: true, employment: 'Self-employed' },
      assessments: [habitsRow(1)], tools: { budget_planner: BUDGET },
    });
    check('33 self-employed folds a 6-month target into the EF ask, not a nudge of its own',
      /variable income we aim for 6 months/.test(view.text), view.text.slice(0, 200));
    const titles = await nudgeIds(page);
    check('34 and there is still no separate employment nudge',
      titles.length <= 2 && !/Retirement Annuity|provisional tax/.test(view.text), JSON.stringify(titles));
    await page.close();
  }

  /* ── 8. The insurance re-take nudge is gone ──────────────────── */
  {
    const { page, view } = await dash(browser, {
      assessments: [{ ...habitsRow(1), cat_scores: { ...habitsRow(1).cat_scores, _insCount: undefined } }],
    });
    check('35 no nudge asks the member to re-take the assessment for insurance',
      !/Check your insurance coverage/.test(view.text) && !/Re-take the assessment/i.test(view.text));
    const titles = await nudgeIds(page);
    check('36 the ladder is still capped at two', titles.length <= 2, JSON.stringify(titles));
    await page.close();
  }

  await browser.close();
  console.log(`\n  ${pass} passed, ${fail} failed.`);
  process.exit(fail ? 1 : 0);
})();
