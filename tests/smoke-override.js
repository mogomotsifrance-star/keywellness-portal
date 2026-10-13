/* Key Wellness — headless checks for the advisor's advance figure and the
   internal notes on the Advance Recommendation view (13 Oct 2026).

   Loads the real advisor.html with a stubbed Supabase client. The stubbed
   Edge Function runs the REAL compute.ts + report.ts (bundled as
   window.__AR, as smoke-advance.js does) and passes the active override in,
   exactly as index.ts does. The stubbed RPCs mirror the rules of
   supabase_advance_override.sql (cap, sum, notes); the database itself is
   tested by the rolled-back live trial recorded in BUILD-NOTES.

   Also proves a report WITHOUT an override renders byte-identically to the
   advisor.html at git HEAD (pass OLD_ADVISOR=<path> to compare).

   Prereq:  the bundle from tests/run-advance.sh (tests/.ar-browser.js)
   Usage:   node tests/smoke-override.js
*/
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name); }
  else    { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}

const ADVISOR_HTML = 'file://' + path.resolve(__dirname, '..', 'advisor.html');
const OLD_ADVISOR = process.env.OLD_ADVISOR ? 'file://' + path.resolve(process.env.OLD_ADVISOR) : null;
const AR_BUNDLE = fs.readFileSync(path.resolve(__dirname, '.ar-browser.js'), 'utf8');
const SHOT = process.env.SCREENSHOTS;

const ME = '11111111-1111-4111-8111-111111111111';
const CLIENT_ID = 'f460e2df-bd48-42aa-9976-f481a955b2c2';
const TUMELO = {
  id: CLIENT_ID, first_name: 'Tumelo', last_name: 'Kgamayane', email: '', phone: '',
  org_id: 'org-hollard', org_name: 'Hollard', org_unit_id: null, unit_label: null,
  no_org: false, offers_advances: true,
  advisor_id: 'adv-france', is_mine: true, created_at: '2026-08-28T08:00:00Z', updated_at: '2026-08-28T09:00:00Z',
  assessment: {
    personal:{ name:'Tumelo', surname:'Kgamayane', employer:'Hollard', maritalStatus:'Married', regime:'In Community of Property', age:'41' },
    kids:[],
    income:{ monthlySalary:44782.61, otherDeductions:10929.88, spouseIncome:0, rentals:0, businessIncome:0, dividends:0 },
    liabilities:[
      {item:'Personal Loan', institution:'Stanbic Bank Botswana', loanAmount:'550000', interestRate:'12', balance:'433020.45', monthlyInstalment:'9075.98', fixed:true},
      {item:'Mortgage Loan', institution:'', loanAmount:'0', interestRate:'', balance:'0', monthlyInstalment:'0', fixed:true},
      {item:'Credit Card', institution:'', loanAmount:'0', interestRate:'', balance:'0', monthlyInstalment:'0', fixed:true},
      {item:'Car Loan', institution:'', loanAmount:'0', interestRate:'', balance:'0', monthlyInstalment:'0', fixed:true},
      {item:'Other', institution:'Express Credit', loanAmount:'50000', interestRate:'25', balance:'25000', monthlyInstalment:'2200'},
      {item:'Other', institution:'Close Friends Microlender', loanAmount:'10000', interestRate:'25', balance:'3600', monthlyInstalment:'0'},
      {item:'Other', institution:'Motshelo', loanAmount:'1500', interestRate:'30', balance:'2300', monthlyInstalment:'0'},
      {item:'Other', institution:'Motshelo 2', loanAmount:'2000', interestRate:'', balance:'2450', monthlyInstalment:'0'},
      {item:'Other', institution:'Motshelo', loanAmount:'10000', interestRate:'', balance:'3500', monthlyInstalment:'0'},
      {item:'Other', institution:'', loanAmount:'0', interestRate:'', balance:'0', monthlyInstalment:'0'},
    ],
    budget:{}, documents:[]
  }
};
const INTERNAL_NOTE = 'Employee showed the school fee invoice in session; not for HR';

function stub(page) {
  return page.addInitScript(({ TUMELO, ME, AR_BUNDLE }) => {
    (0, eval)(AR_BUNDLE);
    const A = TUMELO.assessment;
    const pf = v => { const n = parseFloat(String(v == null ? '' : v).replace(/[,P\s]/g, '')); return isFinite(n) ? n : 0; };
    const r2 = n => Math.round(n * 100) / 100;
    const P = n => Number(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    window.__rpc = []; window.__invocations = [];
    window.__overrides = []; window.__notes = []; window.__latestFinal = null; window.__noGross = false;
    let seq = 0; const now = () => new Date(Date.UTC(2026, 9, 13, 8, 0, seq++)).toISOString();

    const gen = (version) => {
      const ov = window.__overrides.find(o => o.is_active);
      const override = ov ? { id: ov.id, amount: ov.advisor_amount, justification: ov.justification, allocations: ov.allocations } : null;
      const computed = __AR.compute(A, { recommendation_date: '2026-10-13', consultant_name: 'France Mogomotsi', override });
      const content = __AR.buildContent(computed, { consultant: 'France Mogomotsi', consultation_date: '2026-10-13', recommendation_date: '2026-10-13' }, __AR.fallbackNarrative(computed));
      const conditions = [...computed.conditions.map(c => ({ ...c, group: 'condition' })), ...computed.support_plan.map(c => ({ ...c, group: 'support' })), ...computed.follow_up.map(c => ({ ...c, group: 'follow_up' }))];
      return { id: 'rep-' + version, client_id: TUMELO.id, version, status: 'draft', input: { prep: {} }, computed, narrative: { source: 'fallback' }, content, conditions,
               model: null, narrative_source: 'fallback', generated_at: '2026-10-13T09:00:00Z', finalised_at: null, consent_id: null };
    };
    window.__reports = [gen(1)];

    const getPayload = () => {
      const gross = window.__noGross ? 0 : pf(A.income.monthlySalary);
      const act = window.__overrides.find(o => o.is_active) || null;
      return {
        gross_monthly_salary: gross > 0 ? gross : null, cap: gross > 0 ? r2(gross * 4) : null,
        liabilities: A.liabilities.map((l, i) => ({ liability_index: i, lender: (l.institution || '').trim() || l.item, balance: r2(pf(l.balance)), instalment: r2(pf(l.monthlyInstalment)) })).filter(x => x.balance > 0),
        active: act ? { ...act, allocations: act.allocations.map(a => ({ kind: a.kind, liability_index: a.liability_index, lender: a.lender, outstanding_balance: a.outstanding_balance, other_purpose: a.purpose, amount: a.amount })) } : null,
        history: window.__overrides.slice().reverse().map(o => ({ id: o.id, advisor_amount: o.advisor_amount, is_active: o.is_active, created_at: o.created_at, deactivated_at: o.deactivated_at })),
        notes: window.__notes.slice().reverse(),
        latest_final: window.__latestFinal,
      };
    };
    const err = m => ({ data: null, error: { message: m } });

    const chainFor = (t) => {
      const rows = t === 'advance_recommendations' ? window.__reports.slice().sort((a, b) => b.version - a.version) : [];
      const chain = { eq: () => chain, is: () => chain, in: () => chain, or: () => chain, order: () => chain, limit: () => chain,
        maybeSingle: async () => ({ data: t === 'profiles' ? { id: ME } : null, error: null }), single: async () => ({ data: null, error: null }),
        update: () => chain, then: (res) => res({ data: rows, error: null }) };
      return chain;
    };
    const fake = {
      from: (t) => ({ select: () => chainFor(t), insert: () => chainFor(t), update: () => chainFor(t), delete: () => chainFor(t) }),
      rpc: async (fn, args) => {
        window.__rpc.push({ fn, args: JSON.parse(JSON.stringify(args || null)) });
        if (fn === 'advisor_me') return { data: { id: 'adv-france', full_name: 'France Mogomotsi', email: 'france@keywealth.co.bw', is_team_lead: false }, error: null };
        if (fn === 'advisor_clients_list') return { data: [TUMELO], error: null };
        if (fn === 'advance_override_get') return { data: getPayload(), error: null };
        if (fn === 'advance_override_save') {
          const g = getPayload();
          if (!g.gross_monthly_salary) return err('GROSS_SALARY_REQUIRED: record the gross monthly salary on the Income tab before setting an advance');
          if (window.__forceCap || args.p_amount > g.cap) return err('ABOVE_CAP: the advance cannot exceed P ' + P(g.cap) + ' (4 x gross monthly salary)');
          const sum = r2(args.p_allocations.reduce((s, a) => s + a.amount, 0));
          if (sum !== args.p_amount) return err('the use-of-funds lines add up to P ' + P(sum) + ', not the P ' + P(args.p_amount) + ' advance');
          const prev = window.__overrides.find(o => o.is_active);
          const rep = window.__reports.find(r => r.id === args.p_source_recommendation_id);
          const system = rep.computed.override ? rep.computed.override.system_amount : (rep.computed.advance ? rep.computed.advance.amount : 0);
          if (prev) { prev.is_active = false; prev.deactivated_at = now(); }
          const o = { id: 'ovr-' + (window.__overrides.length + 1), advisor_amount: args.p_amount, justification: args.p_justification, system_amount: system,
            cap_amount: g.cap, is_active: true, created_at: now(), deactivated_at: null,
            allocations: args.p_allocations.map(a => a.kind === 'liability'
              ? { kind: 'liability', liability_index: a.liability_index, lender: (A.liabilities[a.liability_index].institution || '').trim() || A.liabilities[a.liability_index].item, outstanding_balance: pf(A.liabilities[a.liability_index].balance), purpose: null, amount: a.amount }
              : { kind: 'other', liability_index: null, lender: null, outstanding_balance: null, purpose: a.purpose, amount: a.amount }) };
          window.__overrides.push(o);
          window.__notes.push({ id: 'n' + window.__notes.length, kind: 'system', author: 'France Mogomotsi', created_at: now(),
            body: `Advance changed from P ${P(prev ? prev.advisor_amount : system)}${prev ? ' (previous advisor figure)' : ' (portal calculation)'} to P ${P(args.p_amount)}. Cap P ${P(g.cap)} (4 x gross monthly salary of P ${P(g.gross_monthly_salary)}). Saved by France Mogomotsi.` });
          return { data: o, error: null };
        }
        if (fn === 'advance_override_remove') {
          const prev = window.__overrides.find(o => o.is_active);
          if (!prev) return err('there is no advisor figure to remove');
          prev.is_active = false; prev.deactivated_at = now();
          window.__notes.push({ id: 'n' + window.__notes.length, kind: 'system', author: 'France Mogomotsi', created_at: now(),
            body: `Advisor figure of P ${P(prev.advisor_amount)} removed by France Mogomotsi. The report reverts to the portal calculation. Reason: ${args.p_reason}` });
          return { data: null, error: null };
        }
        if (fn === 'advance_internal_note_add') {
          const n = { id: 'n' + window.__notes.length, kind: 'advisor', author: 'France Mogomotsi', created_at: now(), body: args.p_body };
          window.__notes.push(n); return { data: n, error: null };
        }
        return { data: [], error: null };
      },
      functions: {
        invoke: async (name, { body }) => {
          window.__invocations.push({ name, body: JSON.parse(JSON.stringify(body)) });
          const ov = window.__overrides.find(o => o.is_active);
          const override = ov ? { id: ov.id, amount: ov.advisor_amount, justification: ov.justification, allocations: ov.allocations } : null;
          const computed = __AR.compute(A, { ...(body.prep || {}), override, recommendation_date: '2026-10-13', consultant_name: 'France Mogomotsi' });
          const suggestions = __AR.liveLiabilities(A).map(({ index, raw }) => ({ index, item: raw.item, institution: raw.institution, ...__AR.suggestClassification(raw) }));
          if (body.mode === 'preview') return { data: { ok: true, mode: 'preview', computed, suggestions, consultant: 'France Mogomotsi' }, error: null };
          const row = gen(window.__reports.length + 1);
          window.__reports.push(row);
          return { data: { ok: true, mode: 'generate', report: row, narrative_source: 'fallback' }, error: null };
        }
      },
      auth: {
        getSession: async () => ({ data: { session: { user: { id: ME, email: 'france@keywealth.co.bw' } } } }),
        getUser: async () => ({ data: { user: { id: ME, email: 'france@keywealth.co.bw' } } }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
        signOut: async () => ({ error: null })
      }
    };
    window.supabase = { createClient: () => fake };
  }, { TUMELO, ME, AR_BUNDLE });
}

async function openAR(page, url) {
  await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
  await page.route('**fonts.googleapis.com/**', r => r.abort());
  await stub(page);
  await page.goto(url);
  await page.waitForTimeout(1200);
  await page.evaluate((id) => { openClient(id); switchTab('report'); }, CLIENT_ID);
  await page.waitForTimeout(300);
  await page.click('.ar-switch button:has-text("Advance Recommendation")');
  await page.waitForTimeout(900);
}

(async () => {
  const browser = await chromium.launch(process.env.PW_CHROMIUM ? { executablePath: process.env.PW_CHROMIUM } : {});
  const page = await browser.newPage();
  await page.setViewportSize({ width: 1440, height: 1000 });
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  await openAR(page, ADVISOR_HTML);

  const docText = () => page.evaluate(() => (document.getElementById('ar-doc') || {}).innerText || '');
  const panelText = () => page.evaluate(() => (document.querySelector('.ovr') || {}).innerText || '');

  /* ── 0. No override: the report is the report it was ── */
  const docV1 = await page.evaluate(() => arRenderDoc(arSelected()));
  if (OLD_ADVISOR) {
    const old = await browser.newPage();
    old.on('pageerror', e => errors.push('old: ' + String(e)));
    await openAR(old, OLD_ADVISOR);
    const docOld = await old.evaluate(() => arRenderDoc(arSelected()));
    check('0  report without an override: arRenderDoc output byte-identical to git HEAD', docOld === docV1, `old ${docOld.length} vs new ${docV1.length}`);
    await old.close();
  } else console.log('SKIP  0  (set OLD_ADVISOR to compare against git HEAD)');

  /* ── 1. Panel and figures strip ── */
  const p1 = await panelText();
  check('1  panel beside the report: portal P 36,850.00, cap P 179,130.44, current = portal',
    /Portal calculation\s*P 36,850\.00/.test(p1) && /Cap \(4 × gross\)\s*P 179,130\.44/.test(p1) && /Current recommended advance\s*P 36,850\.00/.test(p1), p1.slice(0, 300));
  check('2  internal notes are labelled internal and permanent',
    p1.includes('Internal. Not shown on the report or to the employer.') && p1.includes('cannot be edited or deleted'));
  check('3  panel is not printed and not inside the report document',
    await page.evaluate(() => document.querySelector('.ovr').classList.contains('no-print') && !document.querySelector('#ar-doc .ovr')));
  check('4  helper under the justification says it goes on the report', p1.includes('This appears on the report sent to the employer.'));

  /* ── 2. Above the cap ── */
  await page.fill('#ovr-amount', '200000');
  await page.waitForTimeout(100);
  check('5  above the cap: Save disabled with "Cannot exceed P 179,130.44 (4 × gross monthly salary)"',
    await page.evaluate(() => document.getElementById('ovr-save').disabled) && (await panelText()).includes('Cannot exceed P 179,130.44 (4 × gross monthly salary)'));

  /* ── 3. Fill the form; mismatch blocks ── */
  await page.fill('#ovr-amount', '55000');
  await page.fill('#ovr-just', 'School fees for two children are due in January — the employee asked for help with them.');
  await page.selectOption('.ovr-tbl tbody tr:nth-child(1) select', '4');
  await page.waitForTimeout(100);
  await page.fill('.ovr-tbl tbody tr:nth-child(1) .ovr-amt', '25000');
  await page.click('.ovr-link'); await page.waitForTimeout(100);
  await page.selectOption('.ovr-tbl tbody tr:nth-child(2) select', '5'); await page.waitForTimeout(100);
  await page.fill('.ovr-tbl tbody tr:nth-child(2) .ovr-amt', '3600');
  await page.click('.ovr-link'); await page.waitForTimeout(100);
  await page.selectOption('.ovr-tbl tbody tr:nth-child(3) select', 'other'); await page.waitForTimeout(100);
  await page.fill('.ovr-tbl tbody tr:nth-child(3) .ovr-purpose', 'School fees, January 2027');
  await page.fill('.ovr-tbl tbody tr:nth-child(3) .ovr-amt', '20000');
  await page.waitForTimeout(100);
  const mm = await panelText();
  check('6  allocation mismatch blocks Save and says by how much',
    await page.evaluate(() => document.getElementById('ovr-save').disabled) && mm.includes('P 6,400.00 still to allocate') && mm.includes('Use of funds adds up to P 48,600.00, not P 55,000.00.'), mm.slice(-600));
  check('7  liability lines show the lender and outstanding balance',
    mm.includes('P 25,000.00') && await page.evaluate(() => document.querySelector('.ovr-tbl tbody tr:nth-child(1) select').selectedOptions[0].textContent.includes('Express Credit')));
  await page.fill('.ovr-tbl tbody tr:nth-child(3) .ovr-amt', '26400');
  await page.waitForTimeout(100);
  const ok = await panelText();
  check('8  matched: Save enabled, repayment preview P 2,291.67 per month over 24 months, headroom shown',
    !(await page.evaluate(() => document.getElementById('ovr-save').disabled)) && ok.includes('P 2,291.67 per month over 24 months, no interest') && ok.includes('Headroom P 124,130.44'), ok.slice(0, 900));
  if (SHOT) await page.screenshot({ path: path.join(SHOT, 'override-form.png'), fullPage: true });

  /* ── 4. Save ── */
  await page.click('#ovr-save');
  await page.waitForTimeout(400);
  const saveCall = await page.evaluate(() => window.__rpc.filter(r => r.fn === 'advance_override_save').pop());
  check('9  save sends amount, justification, the report on screen and three lines',
    saveCall && saveCall.args.p_amount === 55000 && saveCall.args.p_source_recommendation_id === 'rep-1' && saveCall.args.p_allocations.length === 3
      && saveCall.args.p_allocations[0].liability_index === 4 && saveCall.args.p_allocations[2].purpose === 'School fees, January 2027', JSON.stringify(saveCall && saveCall.args));
  const ps = await panelText();
  check('10 the system note shows at once in the history',
    ps.includes('Advance changed from P 36,850.00 (portal calculation) to P 55,000.00') && await page.evaluate(() => !!document.querySelector('.ovr-notes li.sys')));
  check('11 figures strip: current P 55,000.00 marked "Advisor set"', /Current recommended advance\s*P 55,000\.00\s*Advisor set/i.test(ps), ps.slice(0, 400));
  check('12 v1 (portal figure) can no longer be marked final, and the panel says why',
    ps.includes('was generated before the current advance figure of P 55,000.00') && await page.evaluate(() => {
      const b = Array.from(document.querySelectorAll('.ar-bar button')).find(x => x.textContent.trim() === 'Mark final');
      return b && b.disabled && /current advance figure/.test(b.title); }));

  /* ── 5. Internal note ── */
  await page.fill('.ovr textarea[placeholder="Add a note"]', INTERNAL_NOTE);
  await page.click('.ovr button:has-text("Add note")');
  await page.waitForTimeout(300);
  check('13 an advisor note is added, newest first, with author and time, not marked System',
    await page.evaluate((t) => { const li = document.querySelector('.ovr-notes li'); return li && !li.classList.contains('sys') && li.innerText.includes(t) && /France Mogomotsi · \d/.test(li.innerText); }, INTERNAL_NOTE));

  /* ── 6. Generate on the advisor's figure ── */
  await page.click('.ovr-stale button');
  await page.waitForTimeout(900);
  const genBtn = await page.$('button:has-text("Generate Advance Recommendation")') || await page.$('.ar-prep button.btn-primary');
  if (genBtn) await genBtn.click();
  await page.waitForTimeout(1200);
  const v2 = await page.evaluate(() => { const r = arSelected(); return r && { version: r.version, ovr: !!(r.computed && r.computed.override) }; });
  check('14 a new version is generated on the advisor figure', v2 && v2.version === 2 && v2.ovr, JSON.stringify(v2));
  const d2 = await docText();
  check('15 report shows Recommended Amount P 55,000.00 and the advisor section with the justification',
    /Recommended Amount\s*P 55,000\.00/.test(d2) && /ADVISOR'S RECOMMENDATION/i.test(d2) && d2.includes('School fees for two children are due in January, the employee asked for help with them.'), d2.slice(0, 1500));
  check('16 repayment: P 2,291.67 per month over 24 months, no interest',
    d2.includes('P 2,291.67 per month over 24 months, no interest'));
  const uf = await page.evaluate(() => Array.from(document.querySelectorAll('#ar-doc .ar-adv tbody tr')).map(tr => Array.from(tr.cells).map(td => td.innerText.trim())));
  check('17 use-of-funds table: lender lines with balances, the Other line, total equal to the advance',
    JSON.stringify(uf) === JSON.stringify([
      ['Express Credit', 'P 25,000.00', 'P 25,000.00'], ['Close Friends Microlender', 'P 3,600.00', 'P 3,600.00'],
      ['School fees, January 2027', '', 'P 26,400.00'], ['Total', '', 'P 55,000.00']]), JSON.stringify(uf));
  check('18 the portal figure, the cap and the words override/amended appear nowhere in the report',
    !d2.includes('36,850') && !d2.includes('179,130') && !/overrid|amended/i.test(d2));
  check('19 no internal note text in the report (grep for the note)', !d2.includes(INTERNAL_NOTE) && !d2.includes('Advance changed from'));
  check('20 no em dash, en dash or double hyphen in the advisor section',
    await page.evaluate(() => !/[–—]|--/.test(document.querySelector('#ar-doc .ar-adv').innerText)));
  check('21 debt table: Express Credit settled by the advance; DSR after recomputed (25.38%)',
    /Express Credit[^\n]*Settled by advance/.test(d2) && d2.includes('25.38%'), '');
  check('22 v2 matches the active figure: no stale warning', !(await panelText()).includes('was generated before'));
  if (SHOT) await page.screenshot({ path: path.join(SHOT, 'override-report.png'), fullPage: true });

  /* ── 7. Print ── */
  await page.emulateMedia({ media: 'print' });
  check('23 print: the panel is hidden, the report is not',
    await page.evaluate(() => getComputedStyle(document.querySelector('.ovr')).display === 'none' && getComputedStyle(document.getElementById('ar-doc')).display !== 'none'));
  await page.emulateMedia({ media: 'screen' });

  /* ── 8. Amended after marking final ── */
  await page.evaluate(() => { window.__latestFinal = { id: 'rep-0', version: 0, finalised_at: '2026-10-12T10:00:00Z' }; });
  await page.evaluate(async () => { await arLoadOverride(); arRender(); });
  const am = await panelText();
  check('24 override saved after a final: advisor screen says "Amended after marking final on 12 Oct 2026"',
    am.includes('Amended after marking final on') && am.includes('send it to the employer again'), am.slice(0, 300));
  check('25 ...and the report itself never says amended', !/amended/i.test(await docText()));
  await page.evaluate(() => { window.__latestFinal = null; });

  /* ── 9. Server errors are readable ── */
  await page.evaluate(() => { window.__forceCap = true; });
  await page.evaluate(() => { AR.ovrForm.amount = '55000'; arRender(); });
  await page.click('#ovr-save'); await page.waitForTimeout(300);
  check('26 a server ABOVE_CAP refusal reads as a sentence, without the code',
    (await panelText()).includes('The advance cannot exceed P 179,130.44 (4 x gross monthly salary).') && !(await panelText()).includes('ABOVE_CAP'));
  await page.evaluate(() => { window.__forceCap = false; window.__noGross = true; });
  await page.click('#ovr-save'); await page.waitForTimeout(300);
  const ng = await panelText();
  check('27 GROSS_SALARY_REQUIRED: plain message and a link to the Income tab',
    ng.includes('Record the gross monthly salary on the Income tab') && await page.evaluate(() => Array.from(document.querySelectorAll('.ovr button')).some(b => b.textContent.trim() === 'Go to Income')));
  await page.evaluate(async () => { await arLoadOverride(); arRender(); });
  check('28 with no gross salary recorded, Save is disabled before any call',
    await page.evaluate(() => document.getElementById('ovr-save').disabled) && (await panelText()).includes('Gross salary not recorded'));
  await page.evaluate(async () => { window.__noGross = false; await arLoadOverride(); AR.ovrErr=''; arRender(); });

  /* ── 10. Remove ── */
  await page.click('.ovr button:has-text("Remove advisor figure")');
  await page.waitForTimeout(100);
  await page.click('.ovr button:has-text("Confirm remove")');
  await page.waitForTimeout(200);
  check('29 remove needs a reason', (await panelText()).includes('Give a short reason'));
  await page.fill('#ovr-reason', 'Employee withdrew the school fee request.');
  await page.click('.ovr button:has-text("Confirm remove")');
  await page.waitForTimeout(400);
  const rm = await panelText();
  check('30 removed: figures strip back to the portal calculation, removal logged with the reason',
    /Current recommended advance\s*P 36,850\.00/.test(rm) && !/Advisor set/i.test(rm) && rm.includes('Reason: Employee withdrew the school fee request.'), rm.slice(0, 500));
  check('31 v2 (advisor figure) now needs regenerating before it can be final', rm.includes('advisor figure that has since been removed'));
  check('32 nothing from the panel reaches the client record a linked member can read',
    await page.evaluate(() => !/justification|School fees|Employee showed/i.test(JSON.stringify(assessmentPayload(clients.find(c => c.id === currentClientId))))));

  /* ── 11. Narrow screen: the panel stacks under the report ── */
  await page.setViewportSize({ width: 390, height: 900 });
  await page.waitForTimeout(200);
  check('33 narrow screen: the panel sits below the report, not beside it',
    await page.evaluate(() => { const d = document.getElementById('ar-doc').getBoundingClientRect(), o = document.querySelector('.ovr').getBoundingClientRect(); return o.top >= d.bottom - 1; }));

  check('34 zero JS errors', errors.length === 0, errors.join(' | '));
  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
