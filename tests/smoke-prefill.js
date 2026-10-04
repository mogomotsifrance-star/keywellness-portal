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
   actually exists (audit F7), the two dead prefill blocks stay dead, and the
   P0-6 "who sees this" line is present, muted and correctly worded on each of
   the five screens that ask for money (audit F5).

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
    window.__toolWrites = [];
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
      if (table === 'tool_data' && (op === 'update' || op === 'upsert')) window.__toolWrites.push(payload);
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

/* dti_calculator keeps `debts` in module scope, so a fixture cannot assign it.
   Add one the way a member does: fill the form, press Add. */
const addDebtVia = (page, name, amount) => page.evaluate(({ name, amount }) => {
  document.getElementById('debtName').value    = name;
  document.getElementById('debtAmount').value  = String(amount);
  document.getElementById('debtBalance').value = '0';
  window.addDebt();
}, { name, amount });

/* KWProfile.confirm() is a real overlay. Answer it so the next action is not
   reading a page with a modal still up. */
const dismissProfileModal = async (page) => {
  await page.waitForTimeout(300);
  await page.evaluate(() => document.getElementById('kwp-no')?.click());
  await page.waitForTimeout(150);
};

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

  /* ── 7. P0-6: the "who sees this" line, at the field ──────────
     The audit's point (F5, §8) is that this is where a member's "who is using
     my data" question is actually answered — beside the field, when it is
     asked, not in 380 words before they have seen anything. Two wordings: the
     money tools say what the employer sees, the debt tools also rule out a
     lender, because "will this reach a bank" is the specific fear there. */
  {
    const STAYS = /Stays in your account\. Your employer only ever sees averages across 5 or more colleagues\./;
    const COACH = /Only you and, if you choose, your coach\. Never your employer, never a lender\./;

    const seen = {};
    for (const [file, re, label] of [
      ['budget_planner.html', STAYS, 'Budget Planner'],
      ['net_worth_tracker.html', STAYS, 'Net Worth'],
      ['dti_calculator.html', COACH, 'DTI'],
      ['debt_management_planner.html', COACH, 'Debt Planner'],
    ]) {
      const { page } = await open(browser, file, { profile: { id: UID } });
      const got = await page.evaluate(() => {
        const el = document.querySelector('.kw-trust');
        if (!el) return null;
        const cs = getComputedStyle(el);
        return { text: el.textContent.trim(), size: parseFloat(cs.fontSize),
                 visible: cs.display !== 'none' && el.offsetParent !== null,
                 icons: /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u.test(el.textContent) };
      });
      seen[label] = got;
      await page.close();
    }
    check('48 the Budget Planner carries the employer-averages line',
      STAYS.test(seen['Budget Planner']?.text || ''), JSON.stringify(seen['Budget Planner']));
    check('49 so does Net Worth', STAYS.test(seen['Net Worth']?.text || ''), JSON.stringify(seen['Net Worth']));
    check('50 DTI carries the coach-and-never-a-lender line',
      COACH.test(seen['DTI']?.text || ''), JSON.stringify(seen['DTI']));
    check('51 so does the Debt Planner', COACH.test(seen['Debt Planner']?.text || ''), JSON.stringify(seen['Debt Planner']));
    check('52 each is visible, muted and carries no icon',
      Object.values(seen).every(g => g && g.visible && g.size <= 12 && !g.icons),
      JSON.stringify(Object.entries(seen).map(([k, v]) => [k, v && { s: v.size, v: v.visible, i: v.icons }])));
    /* The debt tools must not carry the softer wording: on a debt register the
       lender question is the one being asked. */
    check('53 the debt tools do not use the money-tool wording',
      !STAYS.test(seen['DTI']?.text || '') && !STAYS.test(seen['Debt Planner']?.text || ''));
  }
  {
    /* The fifth place is a view inside index.html, not its own page. */
    const fs2 = require('fs');
    const idx = fs2.readFileSync(path.join(REPO, 'index.html'), 'utf8');
    check('54 the Emergency Fund view carries it too',
      /class="kw-trust">Stays in your account\. Your employer only ever sees averages across 5 or more colleagues\./.test(idx));
    check('55 and index.html defines the shared style rather than inlining it',
      /^\.kw-trust\{/m.test(idx));
  }

  /* ── 8. A1: the DTI basis ──────────────────────────────────────
     The budget captures take-home only, so a member who arrives here from it
     has gross = 0. This used to end in alert('Please enter your monthly
     income.') — a demand for a figure they had already given. */
  {
    /* Take-home only, one debt. */
    const { page, errors } = await open(browser, 'dti_calculator.html', {
      profile: { id: UID, net_income: 10000, monthly_debt: 2000, fin_updated_at: '2026-09-01T00:00:00Z' },
      tools: { budget_planner: BUDGET },
    });
    const out = await page.evaluate(() => {
      document.getElementById('grossSalary').value = '0';
      document.getElementById('otherIncome').value = '0';
      document.getElementById('netSalary').value   = '10000';
      window.calculate();
      const vis = id => { const e = document.getElementById(id); return !!e && getComputedStyle(e).display !== 'none'; };
      return { results: vis('resultsSection'),
               gauge: document.getElementById('gaugePct')?.textContent || '',
               /* strip is written synchronously; gaugePct animates */
               ratio: (document.getElementById('summaryStrip')?.textContent.match(/(\d+\.\d)%/) || [])[1] || '',
               desc:  document.getElementById('gaugeDesc')?.textContent || '',
               strip: document.getElementById('summaryStrip')?.textContent || '',
               advice: document.getElementById('adviceCard')?.textContent || '',
               notice: vis('dti-calc-notice'),
               snap: JSON.parse(localStorage.getItem('kw_snapshot') || '{}').dti || null };
    });
    check('56 a take-home-only member gets a ratio instead of an alert',
      out.results === true && out.ratio !== '', JSON.stringify({ r: out.results, ratio: out.ratio }));
    check('57 the result says which pay it is on',
      /on take-home pay/.test(out.strip) || /on take-home pay/.test(out.advice),
      out.strip.slice(0, 120) + ' | ' + out.advice.slice(0, 120));
    check('58 and names gross as what would give the lender view',
      /gross salary \(before PAYE\)/.test(out.advice), out.advice.slice(0, 200));
    check('59 the gauge does not call take-home pay gross income',
      !/gross income/i.test(out.desc), out.desc);
    /* The seeded row takes the budget's debt_min (1800), not profiles.monthly_debt
       (2000) — P0-5's preference, asserted by checks 39-41. 1800/10000 = 18.0%. */
    check('60 the ratio is debt over take-home (1800/10000), on no other basis',
      out.ratio === '18.0', out.ratio);
    check('61 the basis is recorded in kw_snapshot for the dashboard',
      out.snap && out.snap.basis === 'take_home', JSON.stringify(out.snap));
    check('62 no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }
  {
    /* Neither figure: name what is missing, in the page. */
    const { page } = await open(browser, 'dti_calculator.html', { profile: { id: UID } });
    const out = await page.evaluate(() => {
      let alerted = false;
      window.alert = () => { alerted = true; };
      ['grossSalary','otherIncome','netSalary'].forEach(i => document.getElementById(i).value = '0');
      window.calculate();
      const el = document.getElementById('dti-calc-notice');
      return { alerted, shown: !!el && getComputedStyle(el).display !== 'none',
               text: el?.textContent || '',
               results: getComputedStyle(document.getElementById('resultsSection')).display !== 'none' };
    });
    check('63 with no income at all it says so in the page, not in an alert',
      out.shown === true && out.alerted === false, JSON.stringify(out));
    check('64 and names both figures that would unblock it',
      /gross salary/i.test(out.text) && /take-home/i.test(out.text), out.text);
    check('65 no results are drawn from nothing', out.results === false, String(out.results));
    await page.close();
  }
  {
    /* Gross present: the existing lender-basis path is untouched. */
    const { page } = await open(browser, 'dti_calculator.html', { profile: { id: UID } });
    await addDebtVia(page, 'Car', 4000);
    const out = await page.evaluate(() => {
      document.getElementById('grossSalary').value = '20000';
      document.getElementById('otherIncome').value = '0';
      document.getElementById('netSalary').value   = '15000';
      window.calculate();
      const _strip = document.getElementById('summaryStrip')?.textContent || '';
      return { ratio: (_strip.match(/(\d+\.\d)%/) || [])[1] || '',
               desc:  document.getElementById('gaugeDesc')?.textContent || '',
               strip: _strip,
               cap:   document.getElementById('capacityRows')?.textContent || '',
               snap:  JSON.parse(localStorage.getItem('kw_snapshot') || '{}').dti || null };
    });
    check('66 with gross present the ratio is still on gross (4000/20000)',
      out.ratio === '20.0' && /gross income/.test(out.desc), out.ratio + ' | ' + out.desc);
    check('67 the strip still says Gross Monthly Income',
      /Gross Monthly Income/.test(out.strip) && !/on take-home pay/.test(out.strip), out.strip.slice(0, 120));
    // 4 Oct 2026: room is measured against the wellbeing benchmark and the
    // over-indebtedness line from js/dsr-bands.js, not bank thresholds.
    check('68 on gross, the room rows measure against the 40% target and the 60% line',
      /40% wellbeing target/.test(out.cap) && /60% overindebtedness line/.test(out.cap), out.cap.slice(0, 160));
    check('69 and the basis records gross', out.snap && out.snap.basis === 'gross', JSON.stringify(out.snap));
    await page.close();
  }
  {
    /* The gross-basis benchmark must not be applied to a take-home figure. */
    const { page } = await open(browser, 'dti_calculator.html', { profile: { id: UID } });
    await addDebtVia(page, 'Car', 4000);
    const out = await page.evaluate(() => {
      document.getElementById('grossSalary').value = '0';
      document.getElementById('otherIncome').value = '0';
      document.getElementById('netSalary').value   = '10000';
      window.calculate();
      return { cap: document.getElementById('capacityRows')?.textContent || '',
               advice: document.getElementById('adviceCard')?.textContent || '',
               rows: document.getElementById('breakdownRows')?.textContent || '' };
    });
    check('70 no room is quoted on a take-home ratio (it would understate it)',
      !/wellbeing target/.test(out.cap), out.cap.slice(0, 200));
    check('71 and the unverified NBFIRA claim is gone (removed 4 Oct 2026)',
      !/NBFIRA/.test(out.cap), out.cap.slice(0, 200));
    check('72 the headline is not repeated as a separate "DTI on net" row',
      !/DTI on net/.test(out.rows), out.rows.slice(0, 200));
    check('73 and nothing promises what a lender will decide',
      !/lenders will/i.test(out.advice) && !/qualify for most loans/i.test(out.advice), out.advice.slice(0, 200));
    await page.close();
  }

  /* Nothing writes a DTI ratio to profiles — asserted rather than changed. */
  {
    const fs3 = require('fs');
    const dti = fs3.readFileSync(path.join(REPO, 'dti_calculator.html'), 'utf8');
    check('74 no DTI ratio is written to the shared profile on any basis',
      !/\b(dti_pct|dti_ratio|debt_to_income)\b/.test(dti),
      (dti.match(/\b(dti_pct|dti_ratio|debt_to_income)\b/g) || []).join(' '));
  }

  /* ── 9. A2: a source line names the source that supplied the figure ── */
  {
    /* The generic banner and the specific one must not stack. */
    const { page, errors } = await open(browser, 'dti_calculator.html', {
      profile: { id: UID, net_income: 11000, monthly_debt: 900, fin_updated_at: '2026-09-01T00:00:00Z' },
      tools: { budget_planner: BUDGET },
    });
    const out = await page.evaluate(() => {
      const gen = document.getElementById('kw-profile-notice');
      const spec = document.getElementById('income-prefill-notice');
      const vis = el => !!el && getComputedStyle(el).display !== 'none';
      return { generic: vis(gen), specific: vis(spec),
               specificText: spec?.textContent || '' };
    });
    check('75 the vague "from your profile" banner is gone from DTI',
      out.generic === false, 'generic notice still shown');
    check('76 the specific notice is the one that shows',
      out.specific === true && /from your budget/.test(out.specificText), out.specificText);
    check('77 no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }
  {
    /* The other three pages keep the generic banner — only DTI opts out. */
    const { page } = await open(browser, 'retirement_calculator.html', {
      profile: { id: UID, gross_income: 18000, fin_updated_at: '2026-09-01T00:00:00Z' },
    });
    const still = await page.evaluate(() => !!document.getElementById('kw-profile-notice'));
    check('78 opting out is per-page, not a global removal', still === true, String(still));
    await page.close();
  }
  {
    /* Budget Planner's seeded-income hint named the assessment for every
       member, whether or not they had ever done one. */
    const { page } = await open(browser, 'budget_planner.html', {
      profile: { id: UID, net_income: 11000, fin_updated_at: '2026-09-01T00:00:00Z' },
    });
    const hint = await page.evaluate(() => document.getElementById('incomeRows')?.textContent || '');
    check('79 the seeded-income hint no longer claims the assessment',
      !/from your assessment/.test(hint), hint.slice(-140));
    check('80 it names the profile, which is where net_income came from',
      !/Prefilled/.test(hint) || /from your profile/.test(hint), hint.slice(-140));
    await page.close();
  }

  /* Source-level sweep: the phrase must not survive anywhere in the tools. */
  {
    const fs4 = require('fs');
    const TOOLS = ['budget_planner.html','dti_calculator.html','retirement_calculator.html',
                   'investment_calculator.html','goal_planner.html','net_worth_tracker.html',
                   'affordability_calculator.html','rent_vs_buy.html','loan_calculator.html',
                   'expense_tracker.html','debt_management_planner.html'];
    /* Strip HTML and JS comments first: a comment explaining why a wrong source
       line was removed is not itself a wrong source line. */
    const speech = f => fs4.readFileSync(path.join(REPO, f), 'utf8')
      .replace(/<!--[\s\S]*?-->/g, '')
      .replace(/^\s*\/\/.*$/gm, '')
      .replace(/\/\*[\s\S]*?\*\//g, '');
    const offenders = TOOLS.filter(f => /from your assessment/.test(speech(f)));
    check('81 no tool page says "from your assessment"', offenders.length === 0, offenders.join(', '));
    const bad = TOOLS.filter(f => /from your Budget Planner/.test(speech(f)));
    check('82 nor "from your Budget Planner"', bad.length === 0, bad.join(', '));
  }

  /* ── 8. Accepting a prefilled figure is an answer ──────────────────────────

     The path that had no save at all. A member arrives at DTI from their
     budget and the page is already complete: the debt row is seeded from
     `debt_min`, take-home is seeded from the budget's salary row. They read
     it, agree with it, and press Calculate. They have touched NOTHING, so
     add/remove never fires — and saving only ever fired on add/remove.

     So: no tool_data row, no dti_basis, no monthly_debt prompt, and the
     dashboard's Debts source never flips. The score gate could not be met by
     this route however many times they pressed the button.

     These fixtures add no debt. That is the point — the seeding is the page's
     own, and accepting it is the member's answer. */
  const seeded = (browser) => open(browser, 'dti_calculator.html', {
    profile: { id: UID, net_income: 11000 },
    tools: { budget_planner: BUDGET },
  });

  {
    const { page, errors } = await seeded(browser);
    const before = await page.evaluate(() => ({
      debt: document.getElementById('debtList')?.textContent || '',
      net:  document.getElementById('netSalary')?.value || '',
      writes: window.__toolWrites.length,
    }));
    check('83 the page arrives seeded from the budget, with nothing saved yet',
      /1,800/.test(before.debt) && /11,000/.test(before.net) && before.writes === 0,
      JSON.stringify(before).slice(0, 200));

    await page.evaluate(() => window.calculate());
    await page.waitForTimeout(400);
    const out = await page.evaluate(() => ({
      results: document.getElementById('resultsSection')?.classList.contains('visible') || false,
      toolWrites: window.__toolWrites.slice(),
      modalText: document.getElementById('kw-profile-modal')?.textContent || '',
    }));

    check('84 Calculate alone writes the tool record',
      out.toolWrites.some(w => w.tool === 'dti_calculator'),
      JSON.stringify(out.toolWrites).slice(0, 200));
    check('85 carrying the debt the member accepted without editing',
      out.toolWrites.some(w => (w.data?.debts || []).some(d => Number(d.amount) === 1800)),
      JSON.stringify(out.toolWrites[0]?.data?.debts || null));
    check('86 and the basis it was computed on, so nothing downstream guesses',
      out.toolWrites.some(w => w.data?.dti_basis === 'take_home'),
      JSON.stringify(out.toolWrites.map(w => w.data?.dti_basis)));
    check('87 the monthly_debt offer reaches the member on this path',
      /profile/i.test(out.modalText), out.modalText.slice(0, 160) || '(no modal)');
    check('88 the results still render', out.results === true, String(out.results));
    check('89 no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }
  {
    /* Accepting the offer writes the column the dashboard and the HR
       indicators read — and pressing Calculate again does not re-ask. */
    const { page } = await seeded(browser);
    await page.evaluate(() => window.calculate());
    await page.waitForTimeout(400);
    await page.evaluate(() => document.getElementById('kwp-yes')?.click());
    await page.waitForTimeout(300);
    const wrote = await page.evaluate(() => window.__updates.slice());
    await page.evaluate(() => window.calculate());
    await page.waitForTimeout(400);
    const again = await page.evaluate(() => !!document.getElementById('kw-profile-modal'));

    check('90 accepting writes monthly_debt as the budget figure',
      wrote.some(w => Number(w.monthly_debt) === 1800), JSON.stringify(wrote));
    check('91 and a second Calculate does not ask the same question twice',
      again === false, 'modal re-opened for an unchanged total');
    await page.close();
  }
  {
    /* Declining is an answer too. Re-asking because they did not answer the
       way we hoped is worse than not asking. */
    const { page } = await seeded(browser);
    await page.evaluate(() => window.calculate());
    await page.waitForTimeout(400);
    await page.evaluate(() => document.getElementById('kwp-no')?.click());
    await page.waitForTimeout(300);
    await page.evaluate(() => window.calculate());
    await page.waitForTimeout(400);
    const out = await page.evaluate(() => ({
      modal: !!document.getElementById('kw-profile-modal'),
      updates: window.__updates.slice(),
      writes: window.__toolWrites.length,
    }));
    check('92 declining is remembered — Calculate does not ask again',
      out.modal === false, 'modal re-opened after the member declined');
    check('93 and nothing was written to the profile behind their back',
      !out.updates.some(w => 'monthly_debt' in w), JSON.stringify(out.updates));
    check('94 while the tool record is still saved, which is not theirs to decline',
      out.writes >= 2, String(out.writes));
    await page.close();
  }
  {
    /* Batch 6b (4 Oct 2026). A member who repays a loan straight off the
       salary: budget debt_min 1,800, payslip loans 3,000, and the budget
       wrote monthly_debt = 4,800. Seeding debt_min alone made this page's
       total 1,800, so Calculate offered to "update" monthly_debt DOWN to
       1,800, and a yes erased the salary-deducted loan from every report. */
    const { page, errors } = await open(browser, 'dti_calculator.html', {
      profile: { id: UID, net_income: 11000, monthly_debt: 4800, payslip_loan_deductions: 3000 },
      tools: { budget_planner: BUDGET },
    });
    const list = await page.evaluate(() => document.getElementById('debtList')?.textContent || '');
    check('6b.1 the salary-deducted loan is seeded as its own row beside the budget line',
      /1,800/.test(list) && /3,000/.test(list) && /deducted from your salary/.test(list), list.slice(0, 200));
    await page.evaluate(() => window.calculate());
    await page.waitForTimeout(400);
    const out = await page.evaluate(() => ({
      modal: !!document.getElementById('kw-profile-modal'),
      modalText: document.getElementById('kw-profile-modal')?.textContent || '',
      debts: (window.__toolWrites.find(w => w.tool === 'dti_calculator')?.data?.debts || []).map(d => Number(d.amount)),
    }));
    check('6b.2 the total matches monthly_debt (4,800), so no one is offered a lower figure',
      out.debts.reduce((a, b) => a + b, 0) === 4800 && !/monthly debt|4,800|1,800/i.test(out.modalText),
      JSON.stringify(out));
    check('6b.3 no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ── 9. Phase C: the figures that come off pay before it arrives ──────────

     The budget asked only for what lands in the member's account, so
     everything deducted at source was invisible — most damagingly a loan
     repaid straight off the salary, which made a member with real debt read as
     having none and gave them a clean DTI.

     The block is OPTIONAL and must stay outside every total: it describes
     money the member never had the chance to allocate, so budgeting it would
     double-count it against the pay they actually received. */
  const PAYSLIP_BUDGET = {
    currentKey: thisMonth,
    budgets: { [thisMonth]: {
      income: [{ id: 1, label: 'Paid into your bank account each month (net pay)', amount: 11000 }],
      expenses: { housing: 4000, food: 1500, transport: 800, debt_min: 1800,
                  emfund: 500, retirement: 700, invest: 300, goals: 200, debt_extra: 400 },
      payslip: { gross: 16000, paye: 2800, pension: 900, medical: 750, loans: 3000, other: 100 },
    } },
  };
  /* The same budget with the payslip block untouched. */
  const BARE_BUDGET = JSON.parse(JSON.stringify(PAYSLIP_BUDGET));
  delete BARE_BUDGET.budgets[thisMonth].payslip;

  {
    const { page, errors } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: PAYSLIP_BUDGET } });
    /* budget_planner keeps `budgets` and `currentKey` in module scope (a plain
       <script>, so `function` declarations reach window but `let`/`const` do
       not). calcTotals IS a function declaration, so hand it the budget. */
    const out = await page.evaluate((b) => {
      const t = window.calcTotals(b);
      return { income: t.totalIncome, expenses: t.totalExpenses,
               savings: t.savingsAmt, group: t.barSaveAmt, needs: t.needsAmt,
               body: document.body.textContent };
    }, PAYSLIP_BUDGET.budgets[thisMonth]);
    check('95 the payslip block is not added to income',
      out.income === 11000, String(out.income));
    check('96 nor to expenses — deducted money was never theirs to allocate',
      out.expenses === 10200,
      `housing+food+transport+debt_min+emfund+retirement+invest+goals+debt_extra=10200, got ${out.expenses}`);
    check('97 monthly_savings counts saving, not extra debt repayment',
      out.savings === 1700, `emfund+retirement+invest+goals=1700, got ${out.savings}`);
    /* Phase D retired savingsGroupAmt: the third bar is now the `save` BUCKET,
       which still carries debt_extra — and is labelled "Savings & extra debt
       repayment" so the member can see why it differs from the Savings Rate. */
    check('98 the third bar still carries extra debt repayment',
      out.group === 2100, `+debt_extra 400 = 2100, got ${out.group}`);
    check('99 the block explains why it is worth filling in',
      /come off before your pay reaches you/.test(out.body), '(reason line missing)');
    /* D.3 rewrite. Before: the page said "bank statement, not your payslip"
       under the income list. Now: the net row's own hint says what reaches the
       bank, and that the payslip above fills it, and sits under that row. */
    const netHint = await page.evaluate(() =>
      document.getElementById('incrow_1')?.textContent.replace(/\s+/g, ' ') || '');
    check('100 and the net-pay row asks for what reaches the bank, filled from the payslip',
      netHint.includes('what reaches your bank account each month. Filled in from your payslip above when you enter it.'),
      netHint.slice(0, 200));
    check('101 no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }
  {
    /* No numeric defaults. An untouched field is empty, and stays out of the
       profile patch entirely rather than writing 0 — a zero the member did not
       type is a figure we were never given. */
    const { page } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: BARE_BUDGET } });
    const vals = await page.evaluate(() => {
      window.togglePayslip();
      return ['gross','paye','pension','medical','loans','other']
        .map(id => document.getElementById('ps_' + id)?.value ?? '(missing)');
    });
    check('102 every payslip field opens empty, with no placeholder figure',
      vals.every(v => v === ''), JSON.stringify(vals));
    await page.close();
  }
  {
    /* D.3 rewrite of 103-106. Before: a separate reconcile note under the
       payslip block (#payslipReconcile) stated gross less deductions against
       the net line and called the gap "worth a look rather than a correction".
       Now: the comparison lives under the net row itself, and only for a
       figure the member typed: "Your payslip works out to {left}. Use that
       figure". Still arithmetic, still never an error. */
    const { page } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: BARE_BUDGET } });
    const bare = await page.evaluate(() =>
      document.getElementById('st_inc_1')?.textContent.trim() ?? null);
    check('103 with nothing entered the net row says nothing about the payslip',
      bare === '', String(bare).slice(0, 120));
    await page.close();
  }
  {
    const { page } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: PAYSLIP_BUDGET } });
    const rec = await page.evaluate(() => {
      const el = document.getElementById('st_inc_1');
      return { text: el?.textContent.replace(/\s+/g, ' ').trim() || '',
               html: el?.innerHTML || '',
               color: el ? getComputedStyle(el).color : '',
               net: document.getElementById('inc_amt_1')?.value || '',
               link: !!document.getElementById('netUsePayslip') };
    });
    /* gross 16000 - (2800+900+750+3000+100 = 7550) = 8450, vs a typed 11000 */
    check('104 with the block complete the typed net row shows what the payslip works out to',
      /Your payslip works out to P 8,450\.00\./.test(rec.text) && /11,000/.test(rec.net),
      `${rec.text.slice(0, 160)} | net ${rec.net}`);
    check('105 and offers it as a choice, never calls the typed figure a mistake',
      rec.link && /Use that figure/.test(rec.text) && !/mistake|wrong|error|incorrect/i.test(rec.text),
      rec.text.slice(0, 200));
    check('106 it is never styled as an error',
      rec.html !== '' && !/alert|warn|var\(--red\)/.test(rec.html) && rec.color !== 'rgb(192, 57, 43)',
      `${rec.html.slice(0, 160)} | ${rec.color}`);
    await page.close();
  }
  {
    /* What the budget now hands on. This is the whole point of the block. */
    const { page } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: PAYSLIP_BUDGET } });
    const patch = await page.evaluate(async () => {
      window._kwProfileSnapshot = {};
      /* Do NOT await the sync: it blocks on KWProfile.confirm(), which only
         resolves when the modal is clicked — and the click is below. */
      const done = window.kwSyncProfileFromBudget();
      await new Promise(r => setTimeout(r, 300));
      document.getElementById('kwp-yes')?.click();
      await done;
      await new Promise(r => setTimeout(r, 250));
      return window.__updates[window.__updates.length - 1] || null;
    });
    check('107 monthly_debt counts the loan taken before the member is paid',
      patch && Number(patch.monthly_debt) === 4800,
      `debt_min 1800 + payslip loans 3000 = 4800, got ${patch && patch.monthly_debt}`);
    check('108 gross_income finally has a writer that is not a calculator',
      patch && Number(patch.gross_income) === 16000, JSON.stringify(patch?.gross_income));
    check('109 the payslip figures are stored as their own facts',
      patch && Number(patch.payslip_pension) === 900 && Number(patch.payslip_medical) === 750
        && Number(patch.payslip_paye) === 2800 && Number(patch.payslip_loan_deductions) === 3000,
      JSON.stringify(patch));
    check('110 retirement_contribution is the voluntary allocation alone',
      patch && Number(patch.retirement_contribution) === 700,
      `budget retirement category 700, got ${patch && patch.retirement_contribution}`);
    check('111 and monthly_savings excludes debt_extra',
      patch && Number(patch.monthly_savings) === 1700, JSON.stringify(patch?.monthly_savings));
    await page.close();
  }
  {
    /* An untouched payslip block writes none of those columns — not zeros. */
    const { page } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: BARE_BUDGET } });
    const patch = await page.evaluate(async () => {
      window._kwProfileSnapshot = {};
      /* Do NOT await the sync: it blocks on KWProfile.confirm(), which only
         resolves when the modal is clicked — and the click is below. */
      const done = window.kwSyncProfileFromBudget();
      await new Promise(r => setTimeout(r, 300));
      document.getElementById('kwp-yes')?.click();
      await done;
      await new Promise(r => setTimeout(r, 250));
      return window.__updates[window.__updates.length - 1] || null;
    });
    check('112 an untouched payslip block writes no payslip column at all',
      patch && !('gross_income' in patch) && !('payslip_paye' in patch)
        && !('payslip_pension' in patch) && !('payslip_loan_deductions' in patch),
      JSON.stringify(patch));
    check('113 monthly_debt is then the budget line alone',
      patch && Number(patch.monthly_debt) === 1800, JSON.stringify(patch?.monthly_debt));
    await page.close();
  }
  {
    /* Budgets saved before Phase C carry the OLD income label. Matching only
       the new wording would stop writing net_income for them, silently, with
       the tool still appearing to work. 29 live profiles. */
    const LEGACY = JSON.parse(JSON.stringify(BARE_BUDGET));
    LEGACY.budgets[thisMonth].income = [
      { id: 1, label: 'Salary (take-home)', amount: 11000 },
      { id: 2, label: 'Side work', amount: 1400 },
    ];
    const { page } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: LEGACY } });
    const patch = await page.evaluate(async () => {
      window._kwProfileSnapshot = {};
      /* Do NOT await the sync: it blocks on KWProfile.confirm(), which only
         resolves when the modal is clicked — and the click is below. */
      const done = window.kwSyncProfileFromBudget();
      await new Promise(r => setTimeout(r, 300));
      document.getElementById('kwp-yes')?.click();
      await done;
      await new Promise(r => setTimeout(r, 250));
      return window.__updates[window.__updates.length - 1] || null;
    });
    check('114 a pre-Phase-C budget still has its net pay recognised',
      patch && Number(patch.net_income) === 11000, JSON.stringify(patch?.net_income));
    check('115 and income beyond that row becomes other_income',
      patch && Number(patch.other_income) === 1400, JSON.stringify(patch?.other_income));
    await page.close();
  }
  {
    /* Retirement stops offering the member their emergency fund back as a
       retirement contribution, and names the two real sources. */
    const { page } = await open(browser, 'retirement_calculator.html', {
      profile: { id: UID, retirement_contribution: 700, payslip_pension: 900,
                 monthly_savings: 1700, gross_income: 16000, payslip_paye: 2800 } });
    const out = await page.evaluate(() => ({
      contrib: document.getElementById('monthlyContrib')?.value || '',
      hint:    document.getElementById('monthlyContribHint')?.textContent || '',
      gross:   document.getElementById('monthlySalary')?.value || '',
    }));
    check('116 the contribution is what goes to retirement, not all savings',
      /1,600/.test(out.contrib), `700 + 900 = 1600, got "${out.contrib}" (monthly_savings is 1700)`);
    check('117 and it names both places the figure came from',
      /from your budget/.test(out.hint) && /from your payslip/.test(out.hint), out.hint);
    check('118 gross arrives from the payslip block', /16,?000/.test(out.gross), out.gross);
    await page.close();
  }
  {
    /* Nothing is invented when we hold neither figure. */
    const { page } = await open(browser, 'retirement_calculator.html',
      { profile: { id: UID, monthly_savings: 1700 } });
    const contrib = await page.evaluate(() =>
      document.getElementById('monthlyContrib')?.value || '');
    check('119 with no retirement figure it asks rather than guessing from savings',
      contrib === '', `expected empty, got "${contrib}"`);
    await page.close();
  }
  {
    /* DTI and Affordability stop asking for gross, and say where it came from. */
    for (const [file, label] of [['dti_calculator.html', '120'], ['affordability_calculator.html', '121']]) {
      const { page } = await open(browser, file,
        { profile: { id: UID, gross_income: 16000, payslip_paye: 2800, net_income: 11000 } });
      const out = await page.evaluate(() => ({
        gross: document.getElementById('grossSalary')?.value || '',
        hint:  document.getElementById('grossSalaryHint')?.textContent || '',
      }));
      check(`${label} ${file.replace('_calculator.html','')} no longer has to ask for gross`,
        /16,?000/.test(out.gross), out.gross);
      check(`${label}b and says it came from the payslip`,
        /from your payslip/.test(out.hint), out.hint);
      await page.close();
    }
  }
  {
    /* The dead end, on the one tool that still had it. Affordability needs only
       income, and income is prefilled — so a member could open it, agree, press
       Calculate, and leave no trace. */
    const { page, errors } = await open(browser, 'affordability_calculator.html',
      { profile: { id: UID, gross_income: 16000, net_income: 11000, monthly_expenses: 8400 } });
    const out = await page.evaluate(async () => {
      window.__toolWrites = [];
      document.getElementById('deposit').value = '50000';
      window.calculate();
      await new Promise(r => setTimeout(r, 900));
      return { writes: window.__toolWrites.slice(),
               shown: document.getElementById('results')?.classList.contains('show') || false };
    });
    check('122 Calculate alone writes the affordability tool record',
      out.writes.some(w => w.tool === 'affordability'),
      JSON.stringify(out.writes).slice(0, 200));
    check('123 and the results still render', out.shown === true, String(out.shown));
    check('124 no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }
  {
    /* The other three were never dead ends — they cannot reach a result
       without an input event. These pin that, so a future prefill of loan
       amount or home price cannot quietly recreate the defect. */
    const cases = [
      ['loan_calculator.html',  'loan_calc',  () => {
        document.getElementById('loanAmount').value   = '200000';
        document.getElementById('interestRate').value = '11';
        document.getElementById('loanTerm').value     = '5';
      }],
      ['rent_vs_buy.html',      'rent_vs_buy', () => {
        document.getElementById('homePrice').value   = '800000';
        document.getElementById('monthlyRent').value = '6000';
      }],
    ];
    let n = 125;
    for (const [file, tool, fill] of cases) {
      const { page } = await open(browser, file, { profile: { id: UID, monthly_income: 11000 } });
      /* Chart.js is a blocked CDN in this harness, and these two draw one. The
         save path is what is under test, not the chart. */
      await page.evaluate(() => {
        if (!window.Chart) window.Chart = function(){ return { destroy(){}, update(){}, data:{}, options:{} }; };
      });
      const wrote = await page.evaluate(async (fillSrc) => {
        window.__toolWrites = [];
        // eslint-disable-next-line no-new-func
        new Function(fillSrc)();
        document.querySelectorAll('input[id]').forEach(el =>
          el.dispatchEvent(new Event('input', { bubbles: true })));
        window.calculate();
        await new Promise(r => setTimeout(r, 900));
        return window.__toolWrites.slice();
      }, '(' + fill.toString() + ')()');
      check(`${n} ${file.replace('.html','')} records the run it was given`,
        wrote.some(w => w.tool === tool), JSON.stringify(wrote).slice(0, 160));
      n++;
      await page.close();
    }
  }

  /* ── 10. Phase D: the Botswana category model ─────────────────────────────

     Spec: docs/phase-d-category-model.md (APPROVED 16 Sep 2026).

     The bars used to read the GROUP, so the Other group — Giving,
     Miscellaneous and every custom line — was in the expense total and in no
     bar, and the three bars never added up to what the member spends. They now
     read BUCKET, and a line we have not been told about stays visibly
     uncounted rather than being guessed into one. */
  const D = (over) => ({
    currentKey: thisMonth,
    budgets: { [thisMonth]: Object.assign({
      income: [{ id: 1, label: 'Paid into your bank account each month (net pay)', amount: 12000 }],
      expenses: {}, actuals: {}, customCats: [], tags: {},
    }, over) },
  });
  const totalsOf = (page, bm) => page.evaluate(b => {
    const t = window.calcTotals(b);
    return { income:t.totalIncome, expenses:t.totalExpenses, needs:t.needsAmt,
             wants:t.wantsAmt, bar:t.barSaveAmt, savings:t.savingsAmt,
             untagged:t.untaggedAmt };
  }, bm);

  {
    /* Everything tagged: the bars account for every thebe of spending. */
    const bm = D({ expenses: { housing:4000, food:1500, dining:600, emfund:500,
                               debt_extra:300, gifts:400, misc:200, custom_1:250 },
                   tags: { gifts:'need', misc:'want' },
                   customCats: [{ id:'custom_1', name:'Burial society', tag:'save' }] }).budgets[thisMonth];
    const { page } = await open(browser, 'budget_planner.html', { profile: { id: UID } });
    const t = await totalsOf(page, bm);
    check('129 with every line tagged, the bars account for all spending',
      t.needs + t.wants + t.bar === t.expenses,
      `needs ${t.needs} + wants ${t.wants} + bar ${t.bar} = ${t.needs+t.wants+t.bar}, expenses ${t.expenses}`);
    check('130 nothing is left uncounted', t.untagged === 0, String(t.untagged));
    check('131 a line tagged Need is in the Needs bar',
      t.needs === 5900, `housing+food+gifts(need) = 5900, got ${t.needs}`);
    check('132 a custom line tagged Saving is saving',
      t.savings === 750, `emfund 500 + custom 250 = 750, got ${t.savings}`);
    await page.close();
  }
  {
    /* Untagged: in the total, in no bar, and never guessed into one. */
    const bm = D({ expenses: { housing:4000, gifts:400, custom_1:250 },
                   customCats: [{ id:'custom_1', name:'Society', tag:null }] }).budgets[thisMonth];
    const { page } = await open(browser, 'budget_planner.html', { profile: { id: UID } });
    const t = await totalsOf(page, bm);
    check('133 an untagged line is in the expense total',
      t.expenses === 4650, String(t.expenses));
    check('134 and in none of the three bars',
      t.needs === 4000 && t.wants === 0 && t.bar === 0,
      `needs ${t.needs} wants ${t.wants} bar ${t.bar}`);
    check('135 the shortfall is reported rather than hidden',
      t.untagged === 650, `gifts 400 + custom 250 = 650, got ${t.untagged}`);
    check('136 an untagged line is never counted as saving',
      t.savings === 0, String(t.savings));
    await page.close();
  }
  {
    /* moraka and motshelo — the two the model moved. */
    const bm = D({ expenses: { moraka:900, motshelo:600, emfund:400, debt_extra:300 } }).budgets[thisMonth];
    const { page } = await open(browser, 'budget_planner.html', { profile: { id: UID } });
    const t = await totalsOf(page, bm);
    check('137 farm costs are a Need, not saving',
      t.needs === 900, `moraka in Needs, got ${t.needs}`);
    check('138 and are absent from the savings figure',
      t.savings === 1000, `emfund 400 + motshelo 600 = 1000, got ${t.savings}`);
    check('139 a money motshelo IS saving',
      t.savings === 1000 && t.bar === 1300,
      `savings ${t.savings}, bar (incl debt_extra 300) ${t.bar}`);
    check('140 extra debt repayment is in the bar and not in savings',
      t.bar - t.savings === 300, `bar ${t.bar} - savings ${t.savings}`);
    await page.close();
  }
  {
    /* The page renders moraka under Needs with its amount intact — an existing
       budget must not lose a thebe when the category changes group. */
    const { page } = await open(browser, 'budget_planner.html', {
      profile: { id: UID },
      tools: { budget_planner: D({ expenses: { moraka: 900 } }) } });
    const view = await page.evaluate(() => {
      const groups = [...document.querySelectorAll('.cat-group')].map(g => ({
        name: g.querySelector('.cat-group-name')?.textContent || '',
        text: g.textContent,
      }));
      return { needs: groups.find(g => /Needs/.test(g.name))?.text || '',
               savings: groups.find(g => /Savings/.test(g.name))?.text || '',
               amount: document.getElementById('exp_moraka')?.value || '' };
    });
    check('141 farm costs render under Needs',
      /Farm costs \(moraka & masimo\)/.test(view.needs), view.needs.slice(0, 120));
    check('142 and no longer under Savings',
      !/Farm costs/.test(view.savings), view.savings.slice(0, 120));
    check('143 with the amount the member already had',
      /900/.test(view.amount), view.amount);
    await page.close();
  }
  {
    /* The three-way question: once, on save, not mid-entry, and back again
       after a dismissal. */
    const { page } = await open(browser, 'budget_planner.html', {
      profile: { id: UID }, tools: { budget_planner: D({}) } });
    const mid = await page.evaluate(() => {
      const el = document.getElementById('exp_gifts');
      el.value = '400';
      el.dispatchEvent(new Event('input', { bubbles: true }));
      return !!document.getElementById('kw-bucket-modal');
    });
    check('144 the question does not fire while the member is typing',
      mid === false, 'modal opened mid-entry');

    await page.waitForTimeout(900);
    const asked = await page.evaluate(() => {
      const m = document.getElementById('kw-bucket-modal');
      return { open: !!m, text: m ? m.textContent.replace(/\s+/g,' ') : '' };
    });
    check('145 it fires once the save lands',
      asked.open === true, 'no modal after autosave');
    check('146 with the approved wording',
      /Is this a need, a want, or saving\?/.test(asked.text), asked.text.slice(0, 120));
    check('147 and the three approved descriptions',
      /you could not stop paying it this month/.test(asked.text)
      && /you choose it, and could pause it/.test(asked.text)
      && /the money is still yours afterwards/.test(asked.text), asked.text.slice(0, 300));

    /* Dismissed: untagged, and asked again on the next save. */
    await page.evaluate(() => document.getElementById('kwb-skip').click());
    await page.waitForTimeout(200);
    const afterSkip = await page.evaluate(() => ({
      modal: !!document.getElementById('kw-bucket-modal'),
      tagged: !!(window.__lastSavedTags || {}).gifts,
    }));
    check('148 dismissing leaves the line untagged', afterSkip.tagged === false, 'a tag was stored');

    const reasked = await page.evaluate(async () => {
      const el = document.getElementById('exp_misc');
      el.value = '100';
      el.dispatchEvent(new Event('input', { bubbles: true }));
      await new Promise(r => setTimeout(r, 900));
      return !!document.getElementById('kw-bucket-modal');
    });
    check('149 and the question comes back on the next save, never dropped',
      reasked === true, 'the question was dropped for good');
    await page.close();
  }
  {
    /* Answering it once is enough — it is not asked again for that line. */
    const { page } = await open(browser, 'budget_planner.html', {
      profile: { id: UID }, tools: { budget_planner: D({}) } });
    await page.evaluate(() => {
      const el = document.getElementById('exp_gifts');
      el.value = '400';
      el.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await page.waitForTimeout(900);
    await page.evaluate(() => document.getElementById('kwb-need')?.click());
    await page.waitForTimeout(500);
    const again = await page.evaluate(async () => {
      const el = document.getElementById('exp_gifts');
      el.value = '450';
      el.dispatchEvent(new Event('input', { bubbles: true }));
      await new Promise(r => setTimeout(r, 900));
      return { modal: !!document.getElementById('kw-bucket-modal'),
               body: document.body.textContent };
    });
    check('150 once answered, the same line is not asked again',
      again.modal === false, 'asked twice for one line');
    check('151 and the page says how it is counted',
      /Counted as Need/.test(again.body), '(no counted-as chip)');
    await page.close();
  }
  {
    /* The deficit sentence. Wants big enough to close the gap: name that one
       line. Never a Need, Giving, family support, contributions or a custom. */
    const { page } = await open(browser, 'budget_planner.html', {
      profile: { id: UID },
      tools: { budget_planner: D({
        income: [{ id:1, label:'Paid into your bank account each month (net pay)', amount:10000 }],
        expenses: { housing:5000, family_support:2000, gifts:800, travel:3000, dining:400 },
      }) } });
    const adv = await page.evaluate(() =>
      document.getElementById('adviceList')?.textContent.replace(/\s+/g,' ') || '');
    check('152 the deficit states the shortfall in Pula',
      /1,200\.00 short this month/.test(adv), adv.slice(0, 220));
    check('153 and names the one Want line that could close it',
      /Travel & holidays/.test(adv) && /3,000\.00/.test(adv), adv.slice(0, 260));
    check('154 it never tells them to cut a Need, Giving or family support',
      !/(cut|reduce|trim)[^.]{0,60}(Housing|Family support|Giving|Contributions)/i.test(adv),
      adv.slice(0, 300));
    check('155 the blanket "review subscriptions, dining" line is gone',
      !/Review subscriptions, dining, and entertainment/.test(adv), '(old sentence present)');
    await page.close();
  }
  {
    /* Wants smaller than the gap: say it sits in fixed costs, name no line,
       offer a coach. */
    const { page } = await open(browser, 'budget_planner.html', {
      profile: { id: UID },
      tools: { budget_planner: D({
        income: [{ id:1, label:'Paid into your bank account each month (net pay)', amount:10000 }],
        expenses: { housing:6000, family_support:3000, debt_min:2000, dining:200 },
      }) } });
    const adv = await page.evaluate(() =>
      document.getElementById('adviceList')?.textContent.replace(/\s+/g,' ') || '');
    check('156 when Wants cannot cover the gap it says so',
      /larger than everything flexible/.test(adv), adv.slice(0, 260));
    check('157 names no line at all',
      !/Housing|Family support|Dining out|Minimum debt/.test(adv.split('short this month')[1]?.split('.')[0] || ''),
      adv.slice(0, 260));
    check('158 and offers a coach', /Key Wellness coach/.test(adv), adv.slice(0, 260));
    await page.close();
  }
  {
    /* The advice a member reads about the lines we never criticise. */
    const { page } = await open(browser, 'budget_planner.html', {
      profile: { id: UID },
      tools: { budget_planner: D({
        expenses: { family_support:1500, contributions:400, gifts:300,
                    motshelo:600, motshelo_goods:350, moraka:700, helper:900 },
        tags: { gifts:'need' } }) } });
    const adv = await page.evaluate(() =>
      document.getElementById('adviceList')?.textContent.replace(/\s+/g,' ') || '');
    const VERBATIM = [
      'It is an obligation, and it is counted as one — not as spending to cut.',
      'When a month passes without one, that amount can move to savings.',
      'For most people this is a commitment, not a luxury, and the budget treats it that way.',
      'That is saving, and it is counted as saving.',
      'It is groceries paid in advance, so it counts as food, not as saving.',
      'The herd and the land may be assets; keeping them is a cost, and it is counted as one.',
      'Employing someone is a wage they depend on. It belongs in Needs, not Wants.',
    ];
    const missing = VERBATIM.filter(v => !adv.includes(v));
    check('159 every approved advice sentence appears verbatim',
      missing.length === 0, missing.join(' || ').slice(0, 300));
    await page.close();
  }
  {
    /* Hints, verbatim, on the page. */
    const { page } = await open(browser, 'budget_planner.html', { profile: { id: UID } });
    const body = await page.evaluate(() => document.body.textContent.replace(/\s+/g,' '));
    const HINTS = [
      'feed, herding, vet, dipping, seed, ploughing, fuel to the farm. Not the value of the herd or the land.',
      'your monthly contribution to a groceries or toiletries motshelo',
      'what you set aside for funerals, weddings, baby showers and workplace collections. Most months something comes up.',
      'tithe or church giving, and gifts you give. Money to family goes under Family support.',
      'your monthly contribution to the group. Enter the payout under Income when it arrives.',
    ];
    const missing = HINTS.filter(h => !body.includes(h));
    check('160 every approved hint appears verbatim', missing.length === 0,
      missing.join(' || ').slice(0, 300));
    check('161 the third bar is relabelled',
      /Savings & extra debt repayment/.test(body), '(bar label not found)');
    await page.close();
  }
  {
    /* Recognised income rows. */
    const { page } = await open(browser, 'budget_planner.html', {
      profile: { id: UID }, tools: { budget_planner: D({}) } });
    const out = await page.evaluate(async () => {
      window.addIncomeRow('farm_income');
      await new Promise(r => setTimeout(r, 200));
      /* Scope to the income container: the payslip block reuses .income-row
         for its grid layout, so an unscoped query picks up those too. */
      const row = [...document.querySelectorAll('#incomeRows .income-row')].pop();
      const inp = row.querySelector('input.mono');
      inp.value = '4500';
      inp.dispatchEvent(new Event('input', { bubbles: true }));
      await new Promise(r => setTimeout(r, 900));
      return { label: row.querySelector('.label-input')?.value || '',
               hint: row.textContent,
               adv: document.getElementById('adviceList')?.textContent.replace(/\s+/g,' ') || '' };
    });
    check('162 farm income is a named row', out.label === 'Farm income', out.label);
    check('163 with its approved hint',
      /Not what the herd is worth/.test(out.hint), out.hint.slice(0, 160));
    check('164 and a month containing it is not treated as a new normal',
      /a bonus month rather than a salary/.test(out.adv), out.adv.slice(0, 240));
    await page.close();
  }
  {
    /* Goal types. */
    const { page } = await open(browser, 'goal_planner.html', { profile: { id: UID } });
    const out = await page.evaluate(async () => {
      document.querySelector('[data-type="livestock"]').click();
      await new Promise(r => setTimeout(r, 150));
      document.getElementById('goalHead').value = '5';
      document.getElementById('goalHead').dispatchEvent(new Event('input', { bubbles: true }));
      document.getElementById('goalPerHead').value = '6000';
      document.getElementById('goalPerHead').dispatchEvent(new Event('input', { bubbles: true }));
      await new Promise(r => setTimeout(r, 150));
      return { target: document.getElementById('goalTarget').value,
               calc: document.getElementById('livestockCalc').textContent,
               copy: document.getElementById('goalTypeCopy').textContent,
               body: document.body.textContent };
    });
    check('165 livestock computes the target from head x price',
      /30,000/.test(out.target), out.target);
    check('166 and shows the working', /5 × P 6,000\.00/.test(out.calc), out.calc);
    check('167 with the approved copy',
      out.copy.includes('Once bought, the animals move to your assets, and their upkeep moves to Farm costs.'),
      out.copy.slice(0, 200));
    check('168 bogadi is offered as a goal type',
      /Bogadi/.test(out.body), '(bogadi button missing)');
    await page.close();
  }
  {
    /* A provision the month did not use is good news, never a scold. */
    const { page } = await open(browser, 'budget_planner.html', {
      profile: { id: UID },
      tools: { budget_planner: D({
        expenses: { contributions: 500, housing: 4000 },
        actuals:  { contributions: 200 } }) } });
    const adv = await page.evaluate(() =>
      document.getElementById('adviceList')?.textContent.replace(/\s+/g,' ') || '');
    check('169 an unused provision is reported as money still theirs',
      /300\.00 is still yours/.test(adv), adv.slice(0, 260));
    check('170 and never as overspending',
      !/over budget|overspen/i.test(adv.split('still yours')[0] || ''), adv.slice(0, 260));
    await page.close();
  }

  /* ── 11. Phase D.3: payslip first, calm lines, no double counting ────────

     Decided 25 Sep 2026. The payslip card comes first and what is left after
     its deductions FILLS the net-pay row's amount, which stays the one home
     for that figure. Hints show only while the member is in a line. Four
     lines warn, in words only, when a payslip figure could be typed twice. */
  const NET = 'Paid into your bank account each month (net pay)';
  const D3 = (over) => ({
    currentKey: thisMonth,
    budgets: { [thisMonth]: Object.assign({
      income: [{ id: 1, label: NET, amount: 0 }],
      expenses: {}, actuals: {}, customCats: [], tags: {},
    }, over) },
  });
  /* Type the way a member does: focus, the page's own select-on-focus, keys. */
  const typeInto = async (page, id, text) => {
    await page.focus('#' + id);
    await page.evaluate(i => document.getElementById(i).select(), id);
    await page.keyboard.type(text);
  };
  const netState = page => page.evaluate(() => {
    const b = budgets[currentKey];
    const r = b.income[0];
    const el = document.getElementById('inc_amt_' + r.id);
    return { amount: r.amount, src: r.src ?? null, value: el?.value ?? null,
             readOnly: !!el?.readOnly, total: calcTotals(b).totalIncome,
             state: document.getElementById('st_inc_' + r.id)?.textContent.replace(/\s+/g, ' ').trim() || '' };
  });
  const visible = (page, id) => page.evaluate(i => {
    const el = document.getElementById(i);
    return !!el && el.checkVisibility();
  }, id);

  {
    const { page, errors } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: D3({}) } });
    const order = await page.evaluate(() => {
      const ps = document.getElementById('payslipCard'), inc = document.getElementById('incomeCard');
      return !!(ps && inc && (ps.compareDocumentPosition(inc) & Node.DOCUMENT_POSITION_FOLLOWING));
    });
    check('171 the payslip card renders above the Income card', order === true, String(order));
    check('172 on a first budget the payslip card opens by default',
      await visible(page, 'ps_gross'), 'payslip body collapsed');
    check('173 with the one line under its title, always visible',
      await page.evaluate(() => document.getElementById('payslipLead')?.textContent.trim()) ===
        'Start with your payslip. What is left after deductions becomes your income below.', '');

    /* Open it regardless, so what follows tests the typing and not 172 again. */
    await page.evaluate(() => { if (document.getElementById('payslipBody').hidden) togglePayslip(); });
    /* Gross alone is not take-home pay, so it does not calculate. */
    await typeInto(page, 'ps_gross', '10000');
    await page.waitForTimeout(100);
    let n = await netState(page);
    const calcGross = await page.evaluate(() =>
      typeof payslipCalc === 'function' ? payslipCalc(budgets[currentKey]) : 'no calculator');
    check('174 gross alone does not calculate',
      calcGross === null && n.amount === 0 && n.src !== 'payslip' && n.value === '',
      JSON.stringify({ calcGross, n }));

    /* Gross 10,000 + PAYE 1,200 + pension 500, all without leaving the card. */
    await page.keyboard.press('Tab');
    await page.keyboard.type('1200');
    await page.keyboard.press('Tab');
    await page.keyboard.type('500');
    await page.waitForTimeout(900);          // autosave fired at least once
    n = await netState(page);
    check('175 gross less PAYE and pension fills the net row with 8,300',
      n.amount === 8300 && n.value === '8,300.00', JSON.stringify(n));
    check('176 marked as from the payslip, and read-only', n.src === 'payslip' && n.readOnly, JSON.stringify(n));
    check('177 totalIncome reads it, because it is the same one home', n.total === 8300, String(n.total));
    check('178 and the net row says where it came from, with a way to adjust',
      n.state.includes('Worked out from your payslip: P 10,000.00 less P 1,700.00 in deductions.')
        && n.state.includes('Check it matches the net pay on your payslip. Adjust'), n.state);
    const modalWhileTyping = await page.evaluate(() => !!document.getElementById('kw-profile-modal'));
    check('179 typing gross then PAYE without leaving the card never opens the profile prompt',
      modalWhileTyping === false, 'prompt opened mid-entry');

    /* Leaving the card puts the question, once, with the finished figure. */
    await page.focus('#exp_housing');
    await page.waitForTimeout(500);
    const asked = await page.evaluate(() => !!document.getElementById('kw-profile-modal'));
    check('180 the prompt waits until focus leaves the card, then is offered',
      modalWhileTyping === false && asked, `while typing ${modalWhileTyping}, after leaving ${asked}`);
    await page.evaluate(() => document.getElementById('kwp-yes')?.click());
    await page.waitForTimeout(300);
    const patch = await page.evaluate(() => window.__updates[window.__updates.length - 1] || null);
    check('181 and the synced net_income is the worked-out 8,300, with no uncaught errors',
      patch && Number(patch.net_income) === 8300 && errors.length === 0,
      JSON.stringify(patch && patch.net_income) + ' ' + errors.join(' | '));
    await page.close();
  }
  {
    /* Adjust, a later payslip change, then back to the payslip figure. */
    const { page } = await open(browser, 'budget_planner.html', { profile: { id: UID },
      tools: { budget_planner: D3({ payslip: { gross: 10000, paye: 1200, pension: 500 },
        income: [{ id: 1, label: NET, amount: 8300, src: 'payslip' }] }) } });
    await page.evaluate(() => document.getElementById('netAdjust')?.click());
    await page.waitForTimeout(100);
    let n = await netState(page);
    check('183 Adjust makes the figure the member\'s own, and editable',
      n.src === 'typed' && !n.readOnly && n.amount === 8300, JSON.stringify(n));
    await typeInto(page, 'inc_amt_1', '8000');
    await typeInto(page, 'ps_paye', '1300');
    await page.waitForTimeout(700);
    n = await netState(page);
    check('184 a later payslip change leaves the typed figure alone',
      n.amount === 8000 && n.src === 'typed', JSON.stringify(n));
    check('185 and says what the payslip works out to, as a choice',
      n.state === 'Your payslip works out to P 8,200.00. Use that figure', n.state);
    await typeInto(page, 'ps_paye', '1200');
    await page.waitForTimeout(700);
    await page.evaluate(() => document.getElementById('netUsePayslip')?.click());
    await page.waitForTimeout(100);
    n = await netState(page);
    check('186 "Use that figure" restores 8,300 from the payslip',
      n.amount === 8300 && n.src === 'payslip' && n.readOnly, JSON.stringify(n));
    /* Clearing gross keeps the last figure and hands it to the member. */
    await typeInto(page, 'ps_gross', '');
    await page.keyboard.press('Backspace');
    await page.waitForTimeout(100);
    n = await netState(page);
    check('187 clearing gross never drops income to zero; the figure becomes typed',
      n.amount === 8300 && n.src === 'typed' && !n.readOnly, JSON.stringify(n));
    await page.close();
  }
  {
    /* A budget saved before D.3: typed net, payslip figures that differ. */
    const { page } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: PAYSLIP_BUDGET } });
    let n = await netState(page);
    check('188 an existing budget loads with its typed net untouched, offered the payslip figure, not given it',
      n.amount === 11000 && n.value === '11,000.00' && !n.readOnly && n.src === null
        && n.state === 'Your payslip works out to P 8,450.00. Use that figure', JSON.stringify(n));
    await typeInto(page, 'ps_other', '150');
    await page.waitForTimeout(100);
    n = await netState(page);
    /* other 100 -> 150: 16000 - 7600 = 8400 */
    check('189 and a payslip edit still never overwrites it, only updates the offer',
      n.amount === 11000 && n.state === 'Your payslip works out to P 8,400.00. Use that figure', JSON.stringify(n));
    await page.close();
  }
  {
    /* Payslip figures in no total and no bar, even while they fill the net row. */
    const { page } = await open(browser, 'budget_planner.html', { profile: { id: UID },
      tools: { budget_planner: D3({ expenses: { housing: 3000, dining: 400, emfund: 300 } }) } });
    await typeInto(page, 'ps_gross', '10000');
    await typeInto(page, 'ps_paye', '1200');
    await typeInto(page, 'ps_pension', '500');
    await typeInto(page, 'ps_medical', '400');
    await typeInto(page, 'ps_loans', '900');
    await page.waitForTimeout(100);
    const t = await page.evaluate(() => {
      const x = calcTotals(budgets[currentKey]);
      return { income: x.totalIncome, expenses: x.totalExpenses, needs: x.needsAmt,
               wants: x.wantsAmt, bar: x.barSaveAmt, savings: x.savingsAmt };
    });
    check('190 payslip figures appear in no total and no bar',
      t.income === 7000 && t.expenses === 3700 && t.needs === 3000 && t.wants === 400
        && t.bar === 300 && t.savings === 300, JSON.stringify(t));
    await page.close();
  }
  {
    /* Copy to next month. */
    const { page } = await open(browser, 'budget_planner.html', { profile: { id: UID },
      tools: { budget_planner: D3({ payslip: { gross: 10000, paye: 1200, pension: 500 }, fs_mode: 'varies',
        income: [{ id: 1, label: NET, amount: 8300, src: 'payslip' }],
        expenses: { family_support: 600 } }) } });
    const next = await page.evaluate(() => {
      const [y, m] = currentKey.split('-').map(Number);
      const d = new Date(y, m, 1);
      const key = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0');
      const from = currentKey;
      openNewMonthModal();
      document.getElementById('newMonthInput').value = key;
      document.getElementById('copyFromSel').value = from;
      confirmNewMonth();
      const b = budgets[key];
      return { payslip: b.payslip, fs: b.fs_mode, src: b.income[0].src, amount: b.income[0].amount };
    });
    await dismissProfileModal(page);
    check('191 copying a month carries the payslip, family support mode and the net row\'s src',
      next.payslip && next.payslip.gross === 10000 && next.payslip.pension === 500
        && next.fs === 'varies' && next.src === 'payslip' && next.amount === 8300, JSON.stringify(next));
    await page.close();
  }
  {
    /* Guidance shows on focus, one line at a time. */
    const { page } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: D3({}) } });
    const shown = () => page.evaluate(() =>
      [...document.querySelectorAll('.kw-guide')].filter(e => e.checkVisibility()).map(e => e.id));
    const idle = await shown();
    const total = await page.evaluate(() => document.querySelectorAll('.kw-guide').length);
    check('192 with no line focused, no hint or first-budget prompt is visible',
      idle.length === 0 && total > 20, `visible: ${idle.join(',')} of ${total}`);
    const y0 = await page.evaluate(() => document.getElementById('exp_housing').getBoundingClientRect().top + window.scrollY);
    await page.focus('#exp_housing');
    const y1 = await page.evaluate(() => document.getElementById('exp_housing').getBoundingClientRect().top + window.scrollY);
    const onFocus = await shown();
    check('193 focusing the Housing amount shows Housing\'s hint and no other line\'s',
      onFocus.includes('g_housing') && onFocus.every(id => /_housing$/.test(id)), onFocus.join(','));
    check('194 on a first budget its prompt shows too, and only on focus',
      onFocus.includes('gp_housing'), onFocus.join(','));
    check('195 showing the hint does not move the input being typed in',
      onFocus.includes('g_housing') && Math.abs(y1 - y0) < 0.5, `${y0} -> ${y1}, shown ${onFocus.join(',')}`);
    const dby = await page.evaluate(() => document.getElementById('exp_housing').getAttribute('aria-describedby') || '');
    check('196 the hidden hint stays tied to its input for screen readers',
      dby.split(' ').includes('g_housing') && dby.split(' ').includes('gp_housing'), dby);
    await page.focus('#ps_loans');
    const ps = await shown();
    check('197 payslip-row hints follow the same rule',
      ps.length === 1 && ps[0] === 'g_ps_loans', ps.join(','));
    await page.focus('#inc_amt_1');
    const net = await shown();
    check('198 the net-pay hint sits under the net row and shows on focus',
      net.length === 1 && net[0] === 'g_inc_1'
        && await page.evaluate(() => document.getElementById('incrow_1').contains(document.getElementById('g_inc_1'))),
      net.join(','));
    /* State stays visible: the Fixed/Varies switch, with nothing focused. */
    await page.evaluate(() => document.activeElement && document.activeElement.blur());
    const fsHint = await page.evaluate(() => { const e = document.getElementById('g_family_support');
      return e ? e.checkVisibility() : 'missing'; });
    check('199 state and controls stay visible while that line\'s guidance is hidden',
      await visible(page, 'fs_fixed') && fsHint === false, `switch / hint: ${fsHint}`);
    /* "No payslip?" collapses the card and goes to the net amount. */
    await page.evaluate(() => document.getElementById('payslipSkip')?.click());
    const skip = await page.evaluate(() => ({ hidden: document.getElementById('payslipBody')?.hidden,
      focus: document.activeElement && document.activeElement.id }));
    check('200 "No payslip, or not to hand?" collapses the card and focuses the net amount',
      skip.hidden === true && skip.focus === 'inc_amt_1', JSON.stringify(skip));
    await page.close();
  }
  {
    /* A returning member who never entered a payslip figure: collapsed. */
    const two = D3({});
    two.budgets['2020-01'] = JSON.parse(JSON.stringify(two.budgets[thisMonth]));
    const { page } = await open(browser, 'budget_planner.html', { profile: { id: UID }, tools: { budget_planner: two } });
    const st = await page.evaluate(() => ({ hidden: document.getElementById('payslipBody').hidden,
      lead: !!document.getElementById('payslipLead')?.checkVisibility() }));
    check('201 a returning member with no payslip figure sees it collapsed to its title and one line',
      st.hidden === true && st.lead === true, JSON.stringify(st));
    await page.close();
  }
  {
    /* The four double-counting warnings. */
    const WARN = {
      debt_min:   { ps: 'loans',   amt: 'P 3,000.00', lines: [
        'Your payslip already takes P 3,000.00 in loan repayments.',
        'Only add loans here that you pay from your bank account.',
        'Adding a payslip loan again would count it twice.'] },
      retirement: { ps: 'pension', amt: 'P 900.00', lines: [
        'P 900.00 already goes to your pension through your payslip.',
        'Add only what you pay on top by choice, such as a retirement annuity.',
        'Adding the payslip amount here would count it twice.'] },
      health:     { ps: 'medical', amt: 'P 750.00', lines: [
        'Your medical aid of P 750.00 comes off your payslip.',
        'Add only medical costs you pay yourself, like gap payments or pharmacy.'] },
      insurance:  { ps: 'other',   amt: '', lines: [
        'Some cover, like funeral policies, may already come off your payslip.',
        'Only add policies you pay from your bank account.'] },
    };
    const FIG = { loans: 3000, pension: 900, medical: 750, other: 100 };
    for (const [cat, w] of Object.entries(WARN)) {
      const { page } = await open(browser, 'budget_planner.html', { profile: { id: UID },
        tools: { budget_planner: D3({ payslip: { gross: 16000, [w.ps]: 0 } }) } });
      const warnText = () => page.evaluate(c => {
        const el = document.querySelector('#psw_' + c + ' .kw-warn');
        return { text: el ? el.innerText.split('\n').map(x => x.trim()).filter(Boolean) : null,
                 shown: !!el && el.checkVisibility() };
      }, cat);
      await page.focus('#exp_' + cat);
      const zero = await warnText();
      await typeInto(page, 'ps_' + w.ps, String(FIG[w.ps]));
      await page.focus('#exp_' + cat);
      const focused = await warnText();
      await page.evaluate(() => document.activeElement.blur());
      const idleEmpty = await warnText();
      await typeInto(page, 'exp_' + cat, '200');
      await page.evaluate(() => document.activeElement.blur());
      const idleFig = await warnText();
      await dismissProfileModal(page);
      check(`202 ${cat}: the warning appears only once the payslip ${w.ps} figure is above zero, verbatim`,
        zero.text === null && focused.shown && JSON.stringify(focused.text) === JSON.stringify(w.lines),
        JSON.stringify({ zero: zero.text, focused: focused.text }));
      check(`203 ${cat}: hidden when out of the line and the line is empty, shown once it has a figure`,
        !idleEmpty.shown && idleFig.shown, `${idleEmpty.shown} / ${idleFig.shown}`);
      check(`204 ${cat}: muted, never red`,
        await page.evaluate(c => { const el = document.querySelector('#psw_' + c + ' .kw-warn');
          if (!el) return false;
          const ref = document.createElement('span'); ref.style.color = 'var(--muted)'; document.body.appendChild(ref);
          const muted = getComputedStyle(ref).color; ref.remove();
          return getComputedStyle(el).color === muted; }, cat), '');
      await page.close();
    }
  }
  {
    /* No new member-facing string carries an em dash, en dash or "--". */
    const { page } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: D3({}) } });
    const strs = await page.evaluate(() => {
      const out = [];
      if (typeof KW_D3_COPY === 'undefined') return out;
      Object.values(KW_D3_COPY).forEach(v => out.push(typeof v === 'function' ? v('P 1.00', 'P 2.00') : v));
      Object.values(KW_PAYSLIP_WARN).forEach(w => out.push(...w.lines('P 1.00')));
      if (typeof KW_D3_COPY === 'undefined') return out;
      out.push(document.getElementById('payslipLead').textContent.trim(),
               document.getElementById('payslipSkip').textContent.trim());
      return out;
    });
    const bad = strs.filter(x => /[—–]|--/.test(x));
    check('205 no new member-facing string contains an em dash, en dash or "--"',
      strs.length >= 15 && bad.length === 0, bad.join(' || ') || `only ${strs.length} strings`);
    await page.close();
  }

  /* ── 12. The budget fits a phone (decided 4 Oct 2026) ──────────────────────

     At 390px the page was 480px wide: the expense rows' fixed columns set a
     minimum the whole column could not shrink below, and Budgeted / Actual
     showed three characters. Under 560px rows now stack. Desktop is untouched,
     and section 12 pins its geometry to what dev rendered. */
  const PHONE = {
    currentKey: thisMonth,
    budgets: { [thisMonth]: {
      income: [{ id: 1, label: NET, amount: 11250, src: 'payslip' },
               { id: 2, label: 'Farm income', amount: 800, srcId: 'farm_income' }],
      payslip: { gross: 16000, paye: 2800, pension: 900, medical: 750, loans: 300, other: 100 },
      fs_mode: 'varies',
      expenses: { housing: 12500, food: 1500, family_support: 700, contributions: 300, debt_min: 900,
                  retirement: 500, health: 200, insurance: 150, dining: 400, custom_1: 250, gifts: 200 },
      actuals: { housing: 12500, food: 1700 },
      customCats: [{ id: 'custom_1', name: 'Burial society', tag: 'save' }], tags: { gifts: 'need' }, collapsed: {},
    } },
  };
  const openVW = async (vw, fx = PHONE) => {
    const page = await browser.newPage({ viewport: { width: vw, height: 800 } });
    await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
    await installStub(page, { profile: { id: UID }, tools: { budget_planner: fx } });
    await page.goto(pageUrl('budget_planner.html'));
    await page.waitForTimeout(1400);
    return page;
  };
  for (const vw of [390, 360]) {
    const page = await openVW(vw);
    const r = await page.evaluate(() => ({
      sw: document.documentElement.scrollWidth, vw: document.documentElement.clientWidth,
      groups: [...document.querySelectorAll('.cat-group-body')].length,
      warns: [...document.querySelectorAll('.kw-warn')].filter(e => e.checkVisibility()).length,
    }));
    check(`206 at ${vw}px the page does not scroll sideways, every group open and warnings showing`,
      r.sw <= r.vw && r.groups === 4 && r.warns === 4, JSON.stringify(r));
    await page.close();
  }
  {
    const page = await openVW(390);
    const small = await page.evaluate(() =>
      [...document.querySelectorAll('#mainContent input, #mainContent textarea')].filter(e => e.checkVisibility())
        .filter(e => e.getBoundingClientRect().height < 44 || parseFloat(getComputedStyle(e).fontSize) < 16)
        .map(e => `${e.id} ${Math.round(e.getBoundingClientRect().height)}px/${getComputedStyle(e).fontSize}`));
    check('207 at 390px every budget input is at least 44px tall with at least 16px text',
      small.length === 0, small.slice(0, 6).join(', '));
    const taps = await page.evaluate(() => {
      const ids = ['fs_fixed', 'fs_varies', 'payslipToggle', 'payslipSkip', 'netAdjust'];
      const els = ids.map(id => document.getElementById(id))
        .concat([...document.querySelectorAll('.del-btn, .kw-tap')].filter(e => e.checkVisibility()));
      return els.filter(e => !e || e.getBoundingClientRect().height < 44)
        .map(e => e ? `${e.id || e.textContent.trim()} ${Math.round(e.getBoundingClientRect().height)}px` : 'missing');
    });
    check('208 Fixed/Varies, Adjust, the tag links, Delete, Show/Hide and "No payslip?" are 44px targets',
      taps.length === 0, taps.join(', '));
    const overlapsOf = pg => pg.evaluate(() => {
      const I = [...document.querySelectorAll('#mainContent input, #mainContent textarea, #mainContent select, #mainContent button, #mainContent a[href], #mainContent [onclick]')]
        .filter(e => e.checkVisibility() && !e.closest('#monthPills'));
      const out = [];
      for (let i = 0; i < I.length; i++) for (let j = i + 1; j < I.length; j++) {
        const a = I[i], b = I[j];
        if (a.contains(b) || b.contains(a)) continue;
        const p = a.getBoundingClientRect(), q = b.getBoundingClientRect();
        const w = Math.min(p.right, q.right) - Math.max(p.left, q.left);
        const h = Math.min(p.bottom, q.bottom) - Math.max(p.top, q.top);
        if (w > 0.5 && h > 0.5) out.push(`${a.id || a.textContent.trim().slice(0, 14)} x ${b.id || b.textContent.trim().slice(0, 14)}`);
      }
      return { n: I.length, out };
    });
    /* Twice: once with Adjust on the net row, once with "Use that figure"
       (a typed net that differs from the payslip). Both sit beside the tag
       "change" links and the Delete targets, which is where overlaps would be. */
    const typed = JSON.parse(JSON.stringify(PHONE));
    typed.budgets[thisMonth].income[0] = { id: 1, label: NET, amount: 11000, src: 'typed' };
    const page2 = await openVW(390, typed);
    const useLink = await page2.evaluate(() => !!document.getElementById('netUsePayslip')?.checkVisibility());
    const o1 = await overlapsOf(page), o2 = await overlapsOf(page2);
    await page2.close();
    check('209 at 390px the 44px tap targets are in place and no two interactive elements\' tap boxes intersect',
      taps.length === 0 && useLink && o1.n > 60 && o1.out.length === 0 && o2.out.length === 0,
      `targets: ${taps.join(', ') || 'ok'}; ${o1.n} elements; ${o1.out.concat(o2.out).slice(0, 5).join(' | ')}`);
    /* Labels: Budgeted, Actual and Variance, the header's own words. */
    const lbl = await page.evaluate(() => [...document.querySelectorAll('#exprow_housing .bva-lbl')]
      .filter(e => e.checkVisibility()).map(e => e.textContent.trim()));
    check('210 on a phone each amount is labelled Budgeted, Actual and Variance',
      JSON.stringify(lbl) === JSON.stringify(['Budgeted', 'Actual', 'Variance']), JSON.stringify(lbl));
    /* D.3 still holds on a phone: guidance opens BELOW the amounts, and the
       field being typed in does not move. */
    const g = await page.evaluate(async () => {
      const inp = document.getElementById('exp_debt_min');
      const y0 = inp.getBoundingClientRect().top + scrollY;
      inp.focus();
      await new Promise(r => setTimeout(r, 50));
      const y1 = inp.getBoundingClientRect().top + scrollY;
      const act = document.getElementById('act_debt_min').getBoundingClientRect().bottom + scrollY;
      const tops = ['g_debt_min', 'gp_debt_min'].map(id => document.getElementById(id))
        .concat([document.querySelector('#psw_debt_min .kw-warn')])
        .map(e => e && e.checkVisibility() ? e.getBoundingClientRect().top + scrollY : null);
      return { y0, y1, act, tops };
    });
    check('211 on a phone, hints, prompt and warning open under the amounts without moving the field',
      Math.abs(g.y1 - g.y0) < 0.5 && g.tops.every(t => t !== null && t >= g.act), JSON.stringify(g));
    await page.close();
  }
  {
    const page = await openVW(360);
    const fit = await page.evaluate(() => ['exp_housing', 'act_housing'].map(id => {
      const e = document.getElementById(id), w = e.closest('.iw').getBoundingClientRect();
      return { id, value: e.value, pre: e.closest('.iw').querySelector('.iw-pre').textContent.trim(),
               clipped: e.scrollWidth > e.clientWidth, inView: w.left >= 0 && w.right <= document.documentElement.clientWidth };
    }));
    check('212 at 360px Budgeted and Actual each show "P 12,500.00" in full',
      fit.every(f => f.pre === 'P' && f.value === '12,500.00' && !f.clipped && f.inView), JSON.stringify(fit));
    await page.close();
  }
  {
    /* Desktop: the geometry dev rendered at 1280px, pinned (captured from dev
       at 6a947f6 with this fixture, before the phone work). */
    const DEV = {"cols":"274px 108px 108px 96px 32px","incCols":"450px 160px 32px",
      "housing":{"row":[0,0,650,36],"exp":[309,1,80,34],"act":[425,1,80,34],"v":[514,0,96,36]},
      "family_support":{"row":[0,0,650,55],"exp":[309,1,80,34],"act":[425,1,80,34],"v":[514,0,96,36]},
      "custom_1":{"row":[0,0,650,50],"exp":[309,1,80,34],"act":[425,1,80,34],"v":[514,0,96,36]},
      "debt_min":{"row":[0,0,650,113],"exp":[309,1,80,34],"act":[425,1,80,34],"v":[514,0,96,36]},
      "inc":{"row":[0,0,658,36],"lbl":[1,1,197,33],"amt":[485,1,132,34]},
      "ps":{"row":[0,0,658,36],"amt":[485,1,132,34]}};
    const fx = JSON.parse(JSON.stringify(PHONE));
    fx.budgets[thisMonth].payslip.loans = 300;
    fx.budgets[thisMonth].expenses.housing = 4000;
    fx.budgets[thisMonth].actuals.housing = 4000;
    const page = await openVW(1280, fx);
    const got = await page.evaluate(() => {
      const rel = (id, rowId) => { const e = document.getElementById(id)?.closest(id.startsWith('var_') ? '.bva-var' : '*'),
        r = document.getElementById(rowId); if (!e || !r) return null;
        const a = e.getBoundingClientRect(), b = r.getBoundingClientRect();
        return [Math.round(a.left - b.left), Math.round(a.top - b.top), Math.round(a.width), Math.round(a.height)]; };
      const out = { cols: getComputedStyle(document.querySelector('.bva-row')).gridTemplateColumns,
                    incCols: getComputedStyle(document.querySelector('.income-row')).gridTemplateColumns };
      for (const c of ['housing', 'family_support', 'custom_1', 'debt_min']) { const row = 'exprow_' + c;
        out[c] = { row: rel(row, row), exp: rel('exp_' + c, row), act: rel('act_' + c, row), v: rel('var_' + c, row) }; }
      out.inc = { row: rel('incrow_2', 'incrow_2'), lbl: rel('inc_lbl_2', 'incrow_2'), amt: rel('inc_amt_2', 'incrow_2') };
      out.ps = { row: rel('psrow_gross', 'psrow_gross'), amt: rel('ps_gross', 'psrow_gross') };
      return out; });
    const lblHidden = await page.evaluate(() => { const l = [...document.querySelectorAll('#exprow_housing .bva-lbl')];
      return l.length === 3 && l.every(e => !e.checkVisibility()); });
    /* The geometry half passes on dev by construction (it is dev's own
       geometry); the phone labels make the check as a whole fail there. */
    check('213 at 1280px the row grids are unchanged from dev, and the phone labels are present but not shown',
      JSON.stringify(got) === JSON.stringify(DEV) && lblHidden, `labels hidden: ${lblHidden}; ` + JSON.stringify(got).slice(0, 260));
    await page.close();
  }

  await browser.close();
  console.log(`\n  ${pass} passed, ${fail} failed.`);
  process.exit(fail ? 1 : 0);
})();
