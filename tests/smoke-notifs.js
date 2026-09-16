/* Key Wellness — headless checks for the notification panel's smart nudges.

   What this guards:

     · the panel's entries read `state` (loaded from Supabase at login), not the
       localStorage caches individual tool pages happen to write. That was the
       whole defect: an entry stayed live after the member had done the thing,
       because the cache is written on another page, or not at all, or the
       member is signed in on a second device;
     · the habits-check entry carries P0-3 wording. "Take the 8-dimension
       wellness assessment to see your score" was wrong twice over — it is a
       habits check now, and P0-4 means no score follows it;
     · thresholds match the dashboard nudge ladder. The re-check ask was 30 days
       here and 90 there, so the panel asked two months early;
     · the stress ask waits for a budget, as the ladder does. On a member's
       first morning it is a demand with nothing behind it.

   Usage:  node tests/smoke-notifs.js
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

const BUDGET = {
  currentKey: thisMonth,
  budgets: { [thisMonth]: { income: [{ name: 'Salary', amount: 12000 }],
                            expenses: { housing: 4000, food: 2000, debt_min: 1500, emfund: 500 } } },
};
/* A fund with a monthly figure and under three months of cover. */
const EF_THIN = { user_id: UID, target_months: 6, current_savings: 3000, monthly: 6000, contribution: 400 };
/* A fund the member started but never told us the size of. months-of-cover is
   unknowable here, so the panel must say nothing rather than "0.0 months". */
const EF_NO_MONTHLY = { user_id: UID, target_months: 6, current_savings: 3000, monthly: 0, contribution: 0 };

const assessRow = (age = 1) => ({ id: 'a1', user_id: UID, score: 61,
  cat_scores: { income: 66, savings: 33, emergency: 25, debt: 100, retirement: 0, insurance: 50, goals: 60, spending: 70, _insCount: 3 },
  answers: { _habits_only: true, incomeStability: 2, savingsHabit: 1, debtMgmt: 3 },
  created_at: daysAgo(age) });

const CDN_NOISE = /cdn\.jsdelivr|Failed to fetch|NetworkError|supabase/i;

function installStub(page, f) {
  return page.addInitScript(({ f, uid }) => {
    try {
      localStorage.setItem('kw_session_trust', JSON.stringify({ uid, ts: Date.now() }));
      ['kw_consent_accepted','kw_profile','kw_snapshot','kw_assessment_result',
       'kw_no_debts','kw_notifs','kw_notifs_dismissed','kw_goals',
       'kw_ef_cache','kw_bookings','financial_stress_v1'].forEach(k => localStorage.removeItem(k));
      localStorage.setItem('kw_welcome_seen', 'true');
      /* The stale caches the panel used to trust. Every fixture seeds them with
         the OPPOSITE of the truth in `state`, so a check can only pass if the
         entry is reading state — the point of the fix. */
      if (f.staleCaches) {
        localStorage.setItem('kw_assessment_result', JSON.stringify({ score: 61, date: new Date().toISOString() }));
        localStorage.setItem('kw_ef_cache', JSON.stringify({ months: 0 }));
        localStorage.setItem('kw_bookings', JSON.stringify([{ id: 'b-cached' }]));
        localStorage.setItem('financial_stress_v1', JSON.stringify([{ score: 3 }]));
      }
    } catch (_) {}

    const toolRows = Object.entries(f.tools || {}).map(([tool, data]) => ({ tool, data }));
    const lists = {
      assessments: f.assessments || [], checkins: [], stress_logs: f.stress || [],
      bookings: f.bookings || [], reward_thresholds: [], tool_data: toolRows,
      notifications: [], content_progress: [], content_items: [],
    };
    const singles = {
      profiles: f.profile, badges: { earned_badge_ids: [] },
      my_points: { total: 0 }, emergency_fund: f.ef || null,
    };
    const chain = (table) => {
      const settle = () => Promise.resolve({ data: lists[table] ?? [], error: null, count: 0 });
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

/* Renders index.html and reads the notification panel. The panel is populated by
   loadNotifications() at startup, so it does not need opening to be read. */
async function panel(browser, fixture) {
  const f = { profile: { id: UID, onboarded: true, first_name: 'Neo', consent_accepted: true, welcome_seen: true },
              staleCaches: true, ...fixture };
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
    const el = document.getElementById('notifList');
    return { text: el ? el.textContent : '', html: el ? el.innerHTML : '' };
  });
  return { page, view, errors };
}

(async () => {
  const browser = await chromium.launch();

  /* ── 1. Brand-new member: no assessment row ──────────────────── */
  {
    const { page, view, errors } = await panel(browser, { assessments: [] });
    check('1  the habits check is offered', /Habits check/.test(view.text), view.text.slice(0, 200));
    check('2  and the stale 8-dimension copy is gone',
      !/8-dimension/.test(view.text) && !/Complete Your Assessment/.test(view.text), view.text.slice(0, 200));
    check('3  it does not promise a score, which P0-4 gates',
      !/to see your score/.test(view.text), view.text.slice(0, 200));
    check('4  no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ── 2. The bug reported: it persisted after completion ──────── */
  {
    const { page, view } = await panel(browser, { assessments: [assessRow(1)] });
    check('5  once an assessments row exists the entry is gone',
      !/Habits check/.test(view.text), view.text.slice(0, 200));
    check('6  and a recent row is not asked to be re-checked either',
      !/Re-check your habits/.test(view.text), view.text.slice(0, 200));
    await page.close();
  }
  {
    /* 60 days: past the old 30-day threshold, inside the dashboard's 90. The
       panel used to ask here while the dashboard did not. */
    const { page, view } = await panel(browser, { assessments: [assessRow(60)] });
    check('7  at 60 days it still does not ask — the ladder waits for 90',
      !/Re-check your habits/.test(view.text) && !/Habits check/.test(view.text), view.text.slice(0, 200));
    await page.close();
  }
  {
    const { page, view } = await panel(browser, { assessments: [assessRow(120)] });
    check('8  past 90 days it asks for a re-check',
      /Re-check your habits/.test(view.text), view.text.slice(0, 200));
    check('9  and names the age rather than a bare "Now"',
      /120 days ago/.test(view.text), view.text.slice(0, 250));
    await page.close();
  }

  /* ── 3. Emergency fund reads the row, not kw_ef_cache ────────── */
  {
    /* No fund at all. The stale cache claims 0 months, which used to fire an
       "Alert" about a fund the member has never opened. */
    const { page, view } = await panel(browser, { assessments: [assessRow(1)], ef: null });
    check('10 no fund means no alert, whatever the stale cache says',
      !/Emergency Fund Alert/.test(view.text), view.text.slice(0, 200));
    await page.close();
  }
  {
    const { page, view } = await panel(browser, { assessments: [assessRow(1)], ef: EF_THIN });
    check('11 a thin fund does raise the alert', /Emergency Fund Alert/.test(view.text), view.text.slice(0, 250));
    check('12 with months computed from the row (0.5), not the cache (0.0)',
      /0\.5 months saved/.test(view.text), view.text.slice(0, 300));
    await page.close();
  }
  {
    const { page, view } = await panel(browser, { assessments: [assessRow(1)], ef: EF_NO_MONTHLY });
    check('13 a fund with no monthly figure states nothing about months of cover',
      !/months saved/.test(view.text), view.text.slice(0, 250));
    await page.close();
  }

  /* ── 4. Stress waits for a budget, like the ladder ───────────── */
  {
    const { page, view } = await panel(browser, { assessments: [assessRow(1)] });
    check('14 no budget yet, so no stress ask on the first morning',
      !/Stress check-in/.test(view.text), view.text.slice(0, 250));
    await page.close();
  }
  {
    const { page, view } = await panel(browser, {
      assessments: [assessRow(1)], tools: { budget_planner: BUDGET }, stress: [] });
    check('15 with a budget saved and no log, it asks',
      /Stress check-in/.test(view.text), view.text.slice(0, 250));
    check('16 in the dashboard ladder\'s words',
      /how is money feeling this fortnight/.test(view.text), view.text.slice(0, 300));
    await page.close();
  }
  {
    const { page, view } = await panel(browser, {
      assessments: [assessRow(1)], tools: { budget_planner: BUDGET },
      stress: [{ created_at: daysAgo(2), level: 3, tags: [], notes: '' }] });
    check('17 and stops once a log exists in the table',
      !/Stress check-in/.test(view.text), view.text.slice(0, 250));
    await page.close();
  }

  /* ── 5. Booking reads state.bookings ─────────────────────────── */
  {
    const { page, view } = await panel(browser, { assessments: [assessRow(1)], bookings: [] });
    check('18 no bookings, so the coaching ask stands',
      /Book a Coaching Session/.test(view.text), view.text.slice(0, 250));
    await page.close();
  }
  {
    const { page, view } = await panel(browser, {
      assessments: [assessRow(1)],
      bookings: [{ id: 'b1', status: 'pending', service: 'coaching', created_at: daysAgo(1) }] });
    check('19 a real booking stops it, where the cache never did',
      !/Book a Coaching Session/.test(view.text), view.text.slice(0, 250));
    await page.close();
  }

  /* ── 6. A member who has done everything sees an empty panel ─── */
  {
    const { page, view, errors } = await panel(browser, {
      assessments: [assessRow(1)],
      tools: { budget_planner: BUDGET },
      ef: { user_id: UID, target_months: 6, current_savings: 30000, monthly: 6000, contribution: 400 },
      stress: [{ created_at: daysAgo(2), level: 3, tags: [], notes: '' }],
      /* Pending, not confirmed: a CONFIRMED booking legitimately produces its own
         "Booking confirmed" notice, which is information, not a demand. */
      bookings: [{ id: 'b1', status: 'pending', service: 'coaching', created_at: daysAgo(1) }],
    });
    check('20 nothing is left to demand', /caught up/.test(view.text), view.text.slice(0, 250));
    check('21 no uncaught errors on a complete panel', errors.length === 0, errors.join(' | '));
    await page.close();
  }

  await browser.close();
  console.log(`\n  ${pass} passed, ${fail} failed.`);
  process.exit(fail ? 1 : 0);
})();
