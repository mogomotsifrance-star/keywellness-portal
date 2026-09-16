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
    check('68 the bank DSR rows are kept on the basis banks actually use',
      /35% DSR \(bank\)/.test(out.cap), out.cap.slice(0, 160));
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
    check('70 no bank DSR capacity is quoted on a take-home ratio',
      !/35% DSR \(bank\)/.test(out.cap), out.cap.slice(0, 200));
    check('71 the NBFIRA 30%-of-net cap, which IS a net rule, is kept',
      /NBFIRA/.test(out.cap), out.cap.slice(0, 200));
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
               savings: t.savingsAmt, group: t.savingsGroupAmt, needs: t.needsAmt,
               body: document.body.textContent };
    }, PAYSLIP_BUDGET.budgets[thisMonth]);
    check('95 the payslip block is not added to income',
      out.income === 11000, String(out.income));
    check('96 nor to expenses — deducted money was never theirs to allocate',
      out.expenses === 10200,
      `housing+food+transport+debt_min+emfund+retirement+invest+goals+debt_extra=10200, got ${out.expenses}`);
    check('97 monthly_savings counts saving, not extra debt repayment',
      out.savings === 1700, `emfund+retirement+invest+goals=1700, got ${out.savings}`);
    check('98 while the 50/30/20 chart keeps the group, so no chart moves',
      out.group === 2100, `+debt_extra 400 = 2100, got ${out.group}`);
    check('99 the block explains why it is worth filling in',
      /come off before your pay reaches you/.test(out.body), '(reason line missing)');
    check('100 and the income line asks for the bank figure, not the payslip one',
      /bank statement, not your payslip/.test(out.body), '(hint missing)');
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
    /* The reconciliation is arithmetic, offered once the member has given us
       enough to do it — and it is never an error. */
    const { page } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: BARE_BUDGET } });
    const bare = await page.evaluate(() =>
      document.getElementById('payslipReconcile')?.textContent.trim() || '');
    check('103 with nothing entered it says nothing about reconciliation',
      bare === '', bare.slice(0, 120));
    await page.close();
  }
  {
    const { page } = await open(browser, 'budget_planner.html',
      { profile: { id: UID }, tools: { budget_planner: PAYSLIP_BUDGET } });
    const rec = await page.evaluate(() => {
      const el = document.getElementById('payslipReconcile');
      return { text: el?.textContent.replace(/\s+/g, ' ').trim() || '',
               html: el?.innerHTML || '' };
    });
    /* gross 16000 − (2800+900+750+3000+100 = 7550) = 8450, vs net pay 11000 */
    check('104 with the block complete it shows the sum, both sides named',
      /8,450/.test(rec.text) && /11,000/.test(rec.text), rec.text.slice(0, 200));
    check('105 and states the difference without calling it a mistake',
      /2,550/.test(rec.text) && /worth a look rather than a correction/.test(rec.text),
      rec.text.slice(0, 260));
    check('106 it is never styled as an error',
      !/alert|advice-card warn|advice-card alert/.test(rec.html), rec.html.slice(0, 160));
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

  await browser.close();
  console.log(`\n  ${pass} passed, ${fail} failed.`);
  process.exit(fail ? 1 : 0);
})();
