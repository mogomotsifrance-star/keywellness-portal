/* Key Wellness — headless checks for prefill and defaults (P0-5).

   The rule this enforces, across five tool pages:

     A FIELD IS EITHER PREFILLED FROM THE MEMBER'S OWN FIGURE, WITH A VISIBLE
     SOURCE LINE, OR IT IS EMPTY. Never an invented number.

   Why that needs a test rather than a careful read: an invented default does
   not look wrong. Goal Planner opened at P15,000 and Retirement at P15,000 /
   P50,000 / P3,000, age 30, retiring at 65 — all plausible, all somebody
   else's. They persisted into saved tool data and the dashboard snapshot the
   moment the member touched any field, so "62% retirement readiness" was
   computed and stored for a salary the member does not earn (audit F8).

   Also asserted: a source line never names the Budget Planner unless a budget
   actually exists (audit F7), and the two dead prefill blocks stay dead.

   Usage:  node tests/smoke-prefill.js
*/
const { chromium } = require('playwright');
const path = require('path');
const url = require('url');
const fs = require('fs');

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name); }
  else    { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}

const REPO = path.resolve(__dirname, '..');
const pageUrl = f => url.pathToFileURL(path.join(REPO, f)).href;
const UID = 'u1';
const thisMonth = new Date().toISOString().slice(0, 7);

const BUDGET = {
  currentKey: thisMonth,
  budgets: { [thisMonth]: {
    income: [{ id: 1, label: 'Salary (take-home)', amount: 11000 }, { id: 2, label: 'Side work', amount: 1000 }],
    /* Real category ids from EXPENSE_GROUPS. Needs = housing + food + transport
       + debt_min = 8100; savings = emfund 500; total = 8600. */
    expenses: { housing: 4000, food: 1500, transport: 800, debt_min: 1800, emfund: 500 },
  } },
};

const CDN_NOISE = /jsdelivr|cdnjs|Chart|jspdf|autotable/i;

function installStub(page, { profile = null, tools = {} } = {}) {
  return page.addInitScript(({ profile, tools, uid }) => {
    try { Object.keys(localStorage).filter(k => /^kw_|^budget_planner/.test(k)).forEach(k => localStorage.removeItem(k)); } catch (_) {}
    window.__updates = [];
    window.__profile = profile;
    const toolRow = (t) => (tools[t] ? { data: tools[t] } : null);
    let _lastTool = null;
    const chain = (table, op, payload) => {
      const settle = () => Promise.resolve({ data: [], error: null });
      const c = {
        eq: (col, val) => { if (table === 'tool_data' && col === 'tool') _lastTool = val; return c; },
        in: () => c, or: () => c, order: () => c, limit: () => c, select: () => c,
        maybeSingle: async () => ({
          data: table === 'profiles' ? window.__profile : table === 'tool_data' ? toolRow(_lastTool) : null,
          error: null }),
        single: async () => ({ data: null, error: null }),
        then: (r, j) => settle().then(r, j),
        catch: (fn) => settle().catch(fn),
        finally: (fn) => settle().finally(fn),
      };
      if (table === 'profiles' && (op === 'update' || op === 'upsert')) window.__updates.push(payload);
      return c;
    };
    const fake = {
      from: (t) => ({ select: () => chain(t, 'select'), insert: (p) => chain(t, 'insert', p),
                      update: (p) => chain(t, 'update', p), upsert: (p) => chain(t, 'upsert', p),
                      delete: () => chain(t, 'delete') }),
      rpc: async () => ({ data: null, error: null }),
      auth: {
        getSession: async () => ({ data: { session: { user: { id: uid, email: 'm@example.com' } } } }),
        getUser: async () => ({ data: { user: { id: uid, email: 'm@example.com' } }, error: null }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      },
    };
    window.supabase = { createClient: () => fake };
  }, { profile, tools, uid: UID });
}

async function open(browser, file, fixture) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => { if (!CDN_NOISE.test(String(e))) errors.push(String(e)); });
  await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
  await installStub(page, fixture);
  await page.goto(pageUrl(file));
  await page.waitForTimeout(1400);
  return { page, errors };
}

const valOf = (page, id) => page.evaluate(i => document.getElementById(i)?.value ?? null, id);

(async () => {
  const browser = await chromium.launch();

  /* ── 1. No invented figure survives in the markup ─────────────── */
  {
    /* Read as source, not through a browser: this is the cheapest possible
       guard and it catches a default being pasted back in. */
    const goal = fs.readFileSync(path.join(REPO, 'goal_planner.html'), 'utf8');
    const ret  = fs.readFileSync(path.join(REPO, 'retirement_calculator.html'), 'utf8');
    check('1  Goal Planner no longer ships a P15,000 income', !/id="monthlyIncome"[^>]*value="15,000\.00"/.test(goal));
    check('2  nor as the load-time fallback', !/data\.settings\.income\s*\|\|\s*'15,000\.00'/.test(goal));
    check('3  Retirement no longer ships a P15,000 salary', !/id="monthlySalary"[^>]*value="15,000\.00"/.test(ret));
    check('4  nor P50,000 of savings', !/id="currentSavings"[^>]*value="50,000\.00"/.test(ret));
    check('5  nor a P3,000 contribution', !/id="monthlyContrib"[^>]*value="3,000\.00"/.test(ret));
    check('6  nor an age of 30', !/id="currentAge"[^>]*value="30"/.test(ret));
    check('7  nor a retirement age of 65', !/id="retirementAge"[^>]*value="65"/.test(ret));
    /* The three that stay are assumptions about the world, not about this
       member — and they now say so. */
    check('8  life expectancy is kept and labelled an assumption',
      /id="lifeExpectancy"[^>]*value="75"/.test(ret) && /<strong>Assumption<\/strong>[^<]*Botswana life-expectancy/.test(ret));
    check('9  the replacement rate too', /id="replacementRate"[^>]*value="70"/.test(ret) &&
      /<strong>Assumption<\/strong>[^<]*standard 70%/.test(ret));
    check('10 and the growth and inflation rates',
      (ret.match(/<strong>Assumption<\/strong>/g) || []).length >= 4,
      String((ret.match(/<strong>Assumption<\/strong>/g) || []).length));

    /* The dead blocks stay dead. */
    const loan = fs.readFileSync(path.join(REPO, 'loan_calculator.html'), 'utf8');
    const rvb  = fs.readFileSync(path.join(REPO, 'rent_vs_buy.html'), 'utf8');
    const deadGone = (src) =>
      !/monthlyGross/.test(src) &&                                   // the id list it sprayed values at
      !/getElementById\('income-prefill-notice'\)/.test(src) &&      // the notice it revealed
      !/id="income-prefill-notice"/.test(src) &&                     // which this page never had
      !/select\('monthly_income'\)/.test(src);                       // and the query it ran to do it
    check('11 the dead prefill block is gone from Loan Calculator', deadGone(loan));
    check('12 and from Rent vs Buy', deadGone(rvb));
  }

  /* ── 2. Goal Planner: empty without a profile, prefilled with one ── */
  {
    const { page, errors } = await open(browser, 'goal_planner.html', { profile: { id: UID } });
    check('13 with no profile figure the income field is empty', (await valOf(page, 'monthlyIncome')) === '');
    check('14 and no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }
  {
    const { page } = await open(browser, 'goal_planner.html', {
      profile: { id: UID, net_income: 11000, monthly_income: 12000, fin_updated_at: '2026-09-01T00:00:00Z' },
      tools: { budget_planner: BUDGET },
    });
    check('15 net_income is preferred over monthly_income',
      (await valOf(page, 'monthlyIncome')) === '11,000.00', await valOf(page, 'monthlyIncome'));
    const hint = await page.evaluate(() => document.getElementById('monthlyIncomeHint')?.textContent || '');
    check('16 and the field says where the figure came from', /Pre-filled from your budget/.test(hint), hint);
    await page.close();
  }
  {
    /* fin_updated_at set but NO budget saved: the honest answer is "profile". */
    const { page } = await open(browser, 'goal_planner.html', {
      profile: { id: UID, net_income: 9000, fin_updated_at: '2026-09-01T00:00:00Z' },
    });
    const hint = await page.evaluate(() => document.getElementById('monthlyIncomeHint')?.textContent || '');
    check('17 with no budget saved it never claims the budget as the source',
      /Pre-filled from your profile/.test(hint) && !/budget/.test(hint), hint);
    await page.close();
  }

  /* ── 3. Retirement: no substituted ages, and no projection without them ── */
  {
    const { page, errors } = await open(browser, 'retirement_calculator.html', { profile: { id: UID } });
    check('18 current age opens empty, not 30', (await valOf(page, 'currentAge')) === '');
    check('19 retirement age opens empty, not 65', (await valOf(page, 'retirementAge')) === '');
    check('20 salary opens empty', (await valOf(page, 'monthlySalary')) === '');

    /* The defect this replaces: touching any field ran calculate() with 30/65
       substituted and stored a readiness percentage for a member who had given
       no ages at all. */
    const gated = await page.evaluate(() => {
      window.calculate();
      const gate = document.getElementById('ret-needs-input');
      return {
        shown: !!gate && getComputedStyle(gate).display !== 'none',
        text: gate?.textContent || '',
        results: getComputedStyle(document.getElementById('resultsSection')).display,
        snap: window._retLastSnap,
      };
    });
    check('21 calculating with nothing entered produces no projection',
      gated.results === 'none' && gated.snap === null, JSON.stringify({ r: gated.results, s: gated.snap }));
    check('22 and says which figures it still needs',
      gated.shown && /your age/.test(gated.text) && /retire/.test(gated.text) && /salary/.test(gated.text),
      gated.text);
    check('23 no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }
  {
    const { page } = await open(browser, 'retirement_calculator.html', {
      profile: { id: UID, age: 34, gross_income: 18000, total_savings: 40000, monthly_savings: 2000,
                 fin_updated_at: '2026-09-01T00:00:00Z' },
      tools: { budget_planner: BUDGET },
    });
    check('24 age is prefilled from the profile', (await valOf(page, 'currentAge')) === '34');
    const hint = await page.evaluate(() => document.getElementById('currentAgeHint')?.textContent || '');
    check('25 and says so', /From your profile/.test(hint), hint);
    check('26 salary is prefilled from the shared figure',
      (await valOf(page, 'monthlySalary')) === '18,000.00', await valOf(page, 'monthlySalary'));
    const notice = await page.evaluate(() => {
      const n = document.getElementById('income-prefill-notice');
      return { text: n?.textContent || '', shown: !!n && getComputedStyle(n).display !== 'none' };
    });
    check('27 the notice names the real source, not a hardcoded "Budget Planner"',
      notice.shown && /Pre-filled from your budget/.test(notice.text), JSON.stringify(notice));

    /* Retirement age is the member's own decision and is still not filled in,
       so there is still nothing to project. */
    const still = await page.evaluate(() => {
      window.calculate();
      return { results: getComputedStyle(document.getElementById('resultsSection')).display,
               text: document.getElementById('ret-needs-input')?.textContent || '' };
    });
    check('28 a prefilled age is not a retirement age — still gated',
      still.results === 'none' && /retire/.test(still.text) && !/your age/.test(still.text), still.text);

    const done = await page.evaluate(() => {
      document.getElementById('retirementAge').value = '60';
      window.calculate();
      return { results: getComputedStyle(document.getElementById('resultsSection')).display,
               gate: getComputedStyle(document.getElementById('ret-needs-input')).display };
    });
    check('29 and once it is given, the projection runs',
      done.results !== 'none' && done.gate === 'none', JSON.stringify(done));
    await page.close();
  }

  /* ── 4. Budget: asks before writing, and writes the two new columns ── */
  {
    const { page, errors } = await open(browser, 'budget_planner.html', {
      profile: { id: UID }, tools: { budget_planner: BUDGET },
    });
    const before = await page.evaluate(() => window.__updates.length);
    const modal = await page.evaluate(async () => {
      window.save();
      await new Promise(r => setTimeout(r, 250));
      const m = document.getElementById('kw-profile-modal');
      return { open: !!m, text: m?.textContent || '',
               focused: document.activeElement?.id || '',
               writes: window.__updates.length };
    });
    check('30 saving no longer writes to the profile silently',
      modal.writes === before, `${before} → ${modal.writes}`);
    check('31 it asks first', modal.open === true);
    check('32 with Yes as the default answer', modal.focused === 'kwp-yes', modal.focused);
    check('33 and explains what saying yes fills in',
      /debt-to-income/.test(modal.text) && /emergency fund/.test(modal.text), modal.text.slice(0, 160));

    const written = await page.evaluate(async () => {
      document.getElementById('kwp-yes').click();
      await new Promise(r => setTimeout(r, 250));
      return window.__updates[window.__updates.length - 1] || {};
    });
    check('34 answering yes writes monthly income and expenses as before',
      written.monthly_income === 12000 && written.monthly_expenses === 8600,
      JSON.stringify(written));   // 12000 income; 4000+1500+800+1800+500 expenses
    check('35 plus net_income, from the "Salary (take-home)" row only',
      written.net_income === 11000, JSON.stringify(written.net_income));
    check('36 plus essential_expenses, from the Needs group only',
      written.essential_expenses === 8100, JSON.stringify(written.essential_expenses));
    check('37 no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }
  {
    const { page } = await open(browser, 'budget_planner.html', {
      profile: { id: UID }, tools: { budget_planner: BUDGET },
    });
    const declined = await page.evaluate(async () => {
      window.save();
      await new Promise(r => setTimeout(r, 250));
      document.getElementById('kwp-no').click();
      await new Promise(r => setTimeout(r, 250));
      return window.__updates.length;
    });
    check('38 declining writes nothing to the profile', declined === 0, String(declined));
    await page.close();
  }

  /* ── 5. DTI: the seeded row names its real source ─────────────── */
  {
    const { page, errors } = await open(browser, 'dti_calculator.html', {
      profile: { id: UID, gross_income: 12000, monthly_debt: 900, fin_updated_at: '2026-09-01T00:00:00Z' },
      tools: { budget_planner: BUDGET },
    });
    const seeded = await page.evaluate(() => ({
      names: [...document.querySelectorAll('.debt-row-name')].map(n => n.textContent.trim()),
      notice: document.getElementById('income-prefill-notice')?.textContent || '',
    }));
    check('39 the seeded row is no longer "from assessment"',
      !seeded.names.some(n => /from assessment/i.test(n)), JSON.stringify(seeded.names));
    check('40 it is named for the budget, which is where the figure came from',
      seeded.names.some(n => /Minimum debt payments \(from your budget\)/.test(n)), JSON.stringify(seeded.names));
    check('41 and the notice agrees', /from your budget/.test(seeded.notice), seeded.notice);
    check('42 no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }
  {
    /* No budget: fall back to the profile figure, and say "profile". */
    const { page } = await open(browser, 'dti_calculator.html', {
      profile: { id: UID, gross_income: 12000, monthly_debt: 900, fin_updated_at: '2026-09-01T00:00:00Z' },
    });
    const seeded = await page.evaluate(() => ({
      names: [...document.querySelectorAll('.debt-row-name')].map(n => n.textContent.trim()),
      notice: document.getElementById('income-prefill-notice')?.textContent || '',
    }));
    check('43 without a budget the row falls back to the profile figure',
      seeded.names.some(n => /Minimum debt payments \(from your profile\)/.test(n)), JSON.stringify(seeded.names));
    check('44 and nothing claims the budget', !/budget/i.test(seeded.notice), seeded.notice);
    await page.close();
  }

  /* ── 6. "I have no debts" (added in P0-4, verified here) ──────── */
  {
    const { page } = await open(browser, 'dti_calculator.html', { profile: { id: UID } });
    const on = await page.evaluate(() => {
      window.toggleNoDebts();
      return { flag: localStorage.getItem('kw_no_debts'),
               label: document.getElementById('noDebtsBtn')?.textContent.trim(),
               note: getComputedStyle(document.getElementById('noDebtsNote')).display };
    });
    check('45 the button records "no debts"', on.flag === 'true' && on.note !== 'none', JSON.stringify(on));
    check('46 and offers the way back', /I do have debts/.test(on.label), on.label);

    /* Drive the real form rather than reaching into module state — this is the
       path a member takes, and it is the path that must clear the flag. */
    const off = await page.evaluate(async () => {
      document.getElementById('debtName').value = 'Car loan';
      document.getElementById('debtAmount').value = '1,200.00';
      window.addDebt();
      await new Promise(r => setTimeout(r, 100));
      return { flag: localStorage.getItem('kw_no_debts'),
               rows: document.querySelectorAll('.debt-row').length,
               label: document.getElementById('noDebtsBtn')?.textContent.trim() };
    });
    check('47 adding a debt clears the flag rather than leaving it lying',
      off.rows > 0 && off.flag === null && /I have no debts/.test(off.label), JSON.stringify(off));
    await page.close();
  }

  await browser.close();
  console.log(`\n  ${pass} passed, ${fail} failed.`);
  process.exit(fail ? 1 : 0);
})();
