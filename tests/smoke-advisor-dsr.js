/* Key Wellness — headless checks for the 4 Oct 2026 advisor changes:
   DSR on gross salary with the 40/50/60 bands (Batch 2), the Liabilities
   page's Outstanding balance / Loan term / totals (Batch 3), the Budget
   totals (Batch 4) and the Personal Financial Assessment additions
   (Batch 6).

   Loads the real advisor.html in Chromium with a stubbed Supabase client.
   Every client here is synthetic: nothing reads or writes real data.

   Usage:   node tests/smoke-advisor-dsr.js
*/
const { chromium } = require('playwright');
const path = require('path');

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name); }
  else    { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}

const ADVISOR_HTML = 'file://' + path.resolve(__dirname, '..', 'advisor.html');
const ME = '22222222-2222-4222-8222-222222222222';

const base = (id, first, assessment) => ({
  id, first_name: first, last_name: 'Test', email: '', phone: '',
  org_id: null, org_name: null, org_unit_id: null, unit_label: null, no_org: true, offers_advances: false,
  advisor_id: 'adv-test', is_mine: true, created_at: '2026-10-01T08:00:00Z', updated_at: '2026-10-01T09:00:00Z',
  assessment: Object.assign({
    personal:{ name:first, surname:'Test', employer:'', maritalStatus:'Single', age:'35' },
    kids:[], assets:[], savings:[], risk:[], businesses:[], budget:{}, budgetOtherCustom:[],
    lifeVision:{}, notes:{ income:'', expense:'', debt:'', lifestyle:'', general:'' }, consultationNotes:[], documents:[]
  }, assessment)
});

/* Gross 15,000 and P 6,750 of instalments: DSR 45.00%, Manageable on the new
   bands (it was Over-indebted at 45% on the old ones). One debt is an old
   row with a 0 balance and no term, as every row saved before 4 Oct is. */
const A = base('c-aaaa', 'Amantle', {
  income:{ monthlySalary:15000, otherDeductions:0, spouseIncome:0, rentals:0, businessIncome:0, dividends:0 },
  liabilities:[
    {item:'Personal Loan', institution:'Stanbic Bank Botswana', loanAmount:100000, interestRate:'14%', balance:80000, monthlyInstalment:3750, fixed:true},
    {item:'Mortgage Loan', institution:'', loanAmount:0, interestRate:'', balance:0, monthlyInstalment:0, fixed:true},
    {item:'Credit Card', institution:'', loanAmount:0, interestRate:'', balance:0, monthlyInstalment:0, fixed:true},
    {item:'Car Loan', institution:'', loanAmount:0, interestRate:'', balance:0, monthlyInstalment:0, fixed:true},
    {item:'Other', institution:'Kgalagadi Micro Cash', loanAmount:40000, interestRate:'30%', balance:0, monthlyInstalment:3000, fixed:false},
  ],
  budget:{ housing:4000, food:3000, transport:2000, debt_min:6000, emfund:1000, retirement:1000 },
});
/* Budget check from the brief: income 20,000, living 9,000, debt 6,000,
   savings 2,000 → total expenses 17,000, net income 3,000. Income is all
   business income so the Batch 4 figures do not depend on PAYE. */
const B = base('c-bbbb', 'Boitumelo', {
  income:{ monthlySalary:0, otherDeductions:0, spouseIncome:0, rentals:0, businessIncome:20000, dividends:0 },
  liabilities:[ {item:'Personal Loan', institution:'', loanAmount:0, interestRate:'', balance:0, monthlyInstalment:0, fixed:true} ],
  budget:{ housing:5000, food:2500, misc:1000, transport:500, debt_min:4000, debt_extra:2000, emfund:1500, motshelo:500 },
});

function stub(page) {
  return page.addInitScript(({ CLIENTS, ME }) => {
    window.__updates = [];
    const chainFor = (t, payload) => {
      if (payload !== undefined) window.__updates.push({ table: t, payload: JSON.parse(JSON.stringify(payload)) });
      const chain = {
        eq: () => chain, is: () => chain, in: () => chain, or: () => chain, order: () => chain, limit: () => chain,
        select: () => chain,
        maybeSingle: async () => ({ data: t === 'profiles' ? { id: ME } : null, error: null }),
        single: async () => ({ data: null, error: null }),
        then: (res) => res({ data: [], error: null })
      };
      return chain;
    };
    const fake = {
      from: (t) => ({ select: () => chainFor(t), insert: (p) => chainFor(t, p), update: (p) => chainFor(t, p), delete: () => chainFor(t) }),
      rpc: async (fn) => {
        if (fn === 'advisor_me') return { data: { id: 'adv-test', full_name: 'Test Advisor', email: 'advisor@example.test', is_team_lead: false }, error: null };
        if (fn === 'advisor_clients_list') return { data: CLIENTS, error: null };
        return { data: [], error: null };
      },
      functions: { invoke: async () => ({ data: null, error: { message: 'not used' } }) },
      auth: {
        getSession: async () => ({ data: { session: { user: { id: ME, email: 'advisor@example.test' } } } }),
        getUser: async () => ({ data: { user: { id: ME, email: 'advisor@example.test' } } }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
        signOut: async () => ({ error: null })
      }
    };
    window.supabase = { createClient: () => fake };
  }, { CLIENTS: [A, B], ME });
}

(async () => {
  const browser = await chromium.launch(process.env.PW_CHROMIUM ? { executablePath: process.env.PW_CHROMIUM } : {});
  const page = await browser.newPage();
  await page.setViewportSize({ width: 1440, height: 1000 });
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
  await page.route('**fonts.googleapis.com/**', r => r.abort());
  await stub(page);
  await page.goto(ADVISOR_HTML);
  await page.waitForTimeout(1200);
  const txt = () => page.evaluate(() => document.body.innerText);

  /* ── Batch 2: DSR on gross, new bands, explanation ─────────── */
  check('B2.1 js/dsr-bands.js loaded: 45 manageable, 55 strained, 62 overindebted, 40 / 60 named',
    await page.evaluate(() => KWDsr.band(45) === 'manageable' && KWDsr.band(55) === 'strained' && KWDsr.band(62) === 'over_indebted'
      && KWDsr.band(40) === 'manageable' && KWDsr.band(60) === 'over_indebted' && KWDsr.benchmark === 40 && KWDsr.line === 60));
  check('B2.2 advisor DSR = instalments ÷ own gross salary: 6,750 / 15,000 = 45.00%, Manageable',
    await page.evaluate((id) => { const c = clients.find(x => x.id === id); const t = calcTotals(c); return t.dti === 45 && diagDebt(t).label === 'Manageable'; }, A.id));
  check('B2.3 business income alone gives no DSR, never a 0% that reads healthy',
    await page.evaluate((id) => calcTotals(clients.find(x => x.id === id)).dti === null, B.id));
  await page.evaluate((id) => { openClient(id); switchTab('liabilities'); }, A.id);
  await page.waitForTimeout(300);
  let body = await txt();
  check('B2.4 the at-a-glance DSR reads 45.00% with its band and a "Why two numbers?" explanation',
    /45\.00%/.test(body) && /Debt service ratio \(DSR\) · Manageable/i.test(body) && /Why two numbers\?/.test(body), body.slice(0, 200));
  check('B2.5 the advisor explanation carries the agreed wording',
    await page.evaluate(() => /Healthy below 40% · Manageable 40 to 49\.99% · Strained 50 to 59\.99% · Overindebted 60% and above/.test(KWDsr.advisorText())
      && /60% is the over-indebtedness line used for risk flags\. 40% is the Key Wellness wellbeing benchmark/.test(KWDsr.advisorText())));

  /* ── Batch 3: Liabilities page ─────────────────────────────── */
  const heads = await page.evaluate(() => Array.from(document.querySelectorAll('.rt-liab thead th')).map(th => th.textContent.trim()));
  check('B3.1 columns in order: Item, Institution, Loan amount, Outstanding balance, Loan term (months), Interest, Monthly instalment',
    heads.slice(0, 7).join('|') === 'Item|Institution|Loan amount|Outstanding balance|Loan term (months)|Interest|Monthly instalment', heads.join('|'));
  const rowInputs = (i) => page.evaluate((i) => Array.from(document.querySelectorAll('.rt-liab tbody tr')[i].querySelectorAll('input')).map(x => ({ v: x.value, ph: x.placeholder })), i);
  const old = await rowInputs(4);
  check('B3.2 an old row with a 0 balance and no term shows "Not recorded", not zero',
    old[3].v === '' && old[3].ph === 'Not recorded' && old[4].v === '' && old[4].ph === 'Not recorded', JSON.stringify(old));
  const tmpl = await rowInputs(1);
  check('B3.3 a blank template row (Mortgage) is not shouted at: no "Not recorded"',
    tmpl.every(x => x.ph !== 'Not recorded'), JSON.stringify(tmpl));
  check('B3.4 numbers are right-aligned in tabular figures',
    await page.evaluate(() => { const cs = getComputedStyle(document.querySelectorAll('.rt-liab tbody tr')[0].querySelectorAll('td.rt-num input')[0]); return cs.textAlign === 'right' && /tabular-nums/.test(cs.fontVariantNumeric); }));
  const totals = await page.evaluate(() => document.querySelector('#liab-total').innerText.replace(/\s+/g, ' '));
  check('B3.5 totals row: principal P 140,000.00, outstanding P 80,000.00 (1 not recorded), monthly P 6,750.00',
    /140,000\.00/.test(totals) && /80,000\.00/.test(totals) && /1 not recorded/.test(totals) && /6,750\.00/.test(totals), totals);

  // Edit the old row: outstanding balance above principal, a 36-month term.
  const inputs = (i) => page.locator('.rt-liab tbody tr').nth(i).locator('input');
  await inputs(4).nth(3).fill('45000');
  await inputs(4).nth(4).fill('36');
  await page.waitForTimeout(200);
  body = await txt();
  check('B3.6 an outstanding balance above the loan amount warns but is kept',
    /Above the loan amount/.test(body) && await page.evaluate((id) => clients.find(x => x.id === id).liabilities[4].balance === 45000, A.id));
  check('B3.7 a 36-month term saves as a whole number and reads "36 months (3 yrs)"',
    /36 months \(3 yrs\)/.test(body) && await page.evaluate((id) => clients.find(x => x.id === id).liabilities[4].termMonths === 36, A.id));
  const totals2 = await page.evaluate(() => document.querySelector('#liab-total').innerText.replace(/\s+/g, ' '));
  check('B3.8 the totals follow the typing: outstanding P 125,000.00, none missing',
    /125,000\.00/.test(totals2) && !/not recorded/.test(totals2), totals2);
  await inputs(4).nth(4).fill('0');
  await page.waitForTimeout(150);
  check('B3.9 a term of 0 is refused with a message and the saved term stays 36',
    /Whole months, from 1 to 600/.test(await txt()) && await page.evaluate((id) => clients.find(x => x.id === id).liabilities[4].termMonths === 36, A.id));
  await inputs(4).nth(4).fill('');
  await inputs(4).nth(3).fill('');
  await page.waitForTimeout(150);
  check('B3.10 clearing the balance and term stores null, not 0',
    await page.evaluate((id) => { const r = clients.find(x => x.id === id).liabilities[4]; return r.balance === null && r.termMonths === null; }, A.id));
  await inputs(4).nth(4).fill('24');
  await inputs(4).nth(3).fill('38000');
  await inputs(4).nth(1).fill('  Kgalagadi Micro Cash ');
  await inputs(4).nth(1).dispatchEvent('change');
  await page.waitForTimeout(900);   // past the 700 ms save debounce
  const saved = await page.evaluate(() => { const u = window.__updates.filter(x => x.table === 'advisor_clients').pop(); return u && u.payload.assessment.liabilities[4]; });
  check('B3.11 the save carries termMonths, balance and the trimmed institution, and no transient error flag',
    saved && saved.termMonths === 24 && saved.balance === 38000 && saved.institution === 'Kgalagadi Micro Cash' && !('_termError' in saved), JSON.stringify(saved));
  check('B3.12 Institution suggestions keep the lender list and add institutions already recorded',
    await page.evaluate(() => { const v = Array.from(document.querySelectorAll('#bw-institutions-credit option')).map(o => o.value); return v.includes('Absa Bank Botswana') && v.includes('Kgalagadi Micro Cash'); }));

  /* ── Batch 4: Budget totals ────────────────────────────────── */
  await page.evaluate((id) => { openClient(id); switchTab('budget'); }, B.id);
  await page.waitForTimeout(300);
  let sum = await page.evaluate(() => document.querySelector('#budgetSummary').innerText.replace(/\s+/g, ' '));
  check('B4.1 income 20,000 · living 9,000 · debt 6,000 · savings 2,000 → total expenses 17,000 · net income 3,000',
    /Total income P 20,000\.00/.test(sum) && /Total expenses/.test(sum) && /P 17,000\.00/.test(sum)
      && /Living expenses P 9,000\.00 · Debt repayments P 6,000\.00 · Savings contributions P 2,000\.00/.test(sum)
      && /Net income P 3,000\.00/.test(sum), sum);
  check('B4.2 the three parts add up to the total, and debt_extra is counted once, as debt, never as saving',
    await page.evaluate((id) => { const t = calcTotals(clients.find(x => x.id === id)); return t.budgetLivingAmt + t.budgetDebtAmt + t.budgetSavingsAmt === t.totalExpenses && t.budgetDebtAmt === 6000 && t.budgetSavingsAmt === 2000; }, B.id));
  await page.locator('.cat-row input').first().fill('10000');   // housing 5,000 → 10,000
  await page.waitForTimeout(200);
  sum = await page.evaluate(() => document.querySelector('#budgetSummary').innerText.replace(/\s+/g, ' '));
  check('B4.3 a negative net income reads "Shortfall" with a positive amount and the word, not a minus sign',
    /Shortfall P 2,000\.00 shortfall/i.test(sum) && !/-P|P -/.test(sum), sum);
  check('B4.4 debt is not counted twice: liabilities add nothing to the budget total',
    await page.evaluate((id) => { const t = calcTotals(clients.find(x => x.id === id)); return t.totalExpenses === 22000; }, B.id));
  await page.evaluate((id) => { openClient(id); switchTab('budget'); }, A.id);
  await page.waitForTimeout(300);
  sum = await page.evaluate(() => document.querySelector('#budgetSummary').innerText.replace(/\s+/g, ' '));
  check('B4.5 when the budget debt line (P 6,000.00) and the liabilities instalments (P 6,750.00) differ, both are shown',
    /P 6,000\.00/.test(sum) && /6,750\.00/.test(sum) && /Liabilities tab instalments/.test(sum), sum);

  /* ── Batch 6: Personal Financial Assessment ────────────────── */
  await page.evaluate(() => { switchTab('report'); });
  await page.waitForTimeout(400);
  const doc = await page.evaluate(() => document.querySelector('.report-doc').innerText);
  check('B6.1 the liabilities table has Institution, Principal, Outstanding balance, Loan term and repayment',
    /Principal\s+Outstanding balance\s+Loan term\s+Interest\s+Monthly repayment/i.test(doc), doc.slice(doc.indexOf('Liabilities'), doc.indexOf('Liabilities') + 200));
  check('B6.2 with the term the advisor recorded ("24 months (2 yrs)") and a totals row',
    /24 months \(2 yrs\)/.test(doc) && /Total\s+P 140,000\.00\s+P 118,000\.00/.test(doc), doc.slice(doc.indexOf('Liabilities'), doc.indexOf('Debt Service Ratio')));
  check('B6.3 a missing figure prints "Not recorded", never P 0.00 (Stanbic has no term)',
    /Not recorded/.test(doc.slice(doc.indexOf('Liabilities'), doc.indexOf('Debt Service Ratio'))));
  const dsrSec = doc.slice(doc.indexOf('Debt Service Ratio'), doc.indexOf('Assets'));
  check('B6.4 DSR section: "Your debt repayments take up 45.0% of your gross salary. This is Manageable."',
    /Your debt repayments take up 45\.0% of your gross salary\. This is Manageable\./.test(dsrSec), dsrSec.slice(0, 200));
  check('B6.5 the explanation is printed in full (paper cannot expand a toggle)',
    /Why two numbers\?/.test(dsrSec) && /At 60% or more, debt repayments take so much of your salary/.test(dsrSec) && /below 40%/.test(dsrSec));
  check('B6.6 member copy passes the dash check: no em dash, en dash or double hyphen in the DSR section',
    !/[—–]|--/.test(dsrSec), dsrSec);
  const budSec = doc.slice(doc.indexOf('Personal Budget'), doc.indexOf('Advisory Diagnostic'));
  check('B6.7 budget totals appear in the report, without the advisor-only mismatch note',
    /Total income/.test(budSec) && /Total expenses/.test(budSec) && /Net income|Shortfall/.test(budSec) && !/Check which is right/.test(budSec), budSec.slice(0, 300));

  check('Z  no JavaScript errors during the whole run', errors.length === 0, errors.join(' | '));
  await browser.close();
  console.log(`${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
