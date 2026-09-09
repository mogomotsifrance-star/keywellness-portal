/* Key Wellness — headless checks for the Debt Rehab Plan view on the
   advisor portal's Report tab (the third switch option).

   Loads the real advisor.html in Chromium with a stubbed Supabase client
   and drives it the way an advisor would: open Olorato, go to Report,
   switch to Debt Rehab Plan, confirm the actions and levers, generate,
   edit a line, untick an action, mark final, regenerate.

   The Edge Function is stubbed — with the REAL compute-rehab.ts +
   report-rehab.ts (bundled by esbuild into the page as window.__DRP), so
   the figures on screen are the figures production would produce from the
   same record. Only the model call is replaced, by the deterministic
   fallback narrative — exactly what production does when the model is
   unavailable.

   Prereq:  npx esbuild tests/drp-entry.ts --bundle --format=iife \
              --global-name=__DRP --outfile=tests/.drp-browser.js
            (run-rehab.sh does this)
   Usage:   node tests/smoke-rehab.js
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
const DRP_BUNDLE = fs.readFileSync(path.resolve(__dirname, '.drp-browser.js'), 'utf8');
const SHOT = process.env.SCREENSHOTS;
const shot = async (page, name) => { if (SHOT) await page.screenshot({ path: path.join(SHOT, name + '.png'), fullPage: true }); };

const ME = '11111111-1111-4111-8111-111111111111';
const CLIENT_ID = 'a7c2f9e0-5b1d-4c3e-9f80-2d6e4b1a7c55';

/* Olorato, as advisor_clients.assessment holds her — the spec §7 worked
   example reconstructed (FNB rate blank, as on the live record). Her
   organisation runs NO advance programme, so the AR view is absent and the
   Debt Rehab Plan is offered purely on the DSR band (44.72% → strained). */
const OLORATO = {
  id: CLIENT_ID, first_name: 'Olorato', last_name: 'Maliko', email: '', phone: '',
  org_id: 'org-sedimosa', org_name: 'Sedimosa', org_unit_id: null, unit_label: null,
  no_org: false, offers_advances: false,
  advisor_id: 'adv-france', is_mine: true, created_at: '2026-08-20T08:00:00Z', updated_at: '2026-09-01T09:00:00Z',
  assessment: {
    personal:{ name:'Olorato', surname:'Maliko', employer:'Sedimosa', maritalStatus:'Married', regime:'Out of Community', age:'38' },
    kids:[{},{}],
    income:{ monthlySalary:4000, otherDeductions:0, spouseIncome:0, rentals:0, businessIncome:8300, dividends:0 },
    liabilities:[
      {item:'Personal Loan', institution:'FNB', loanAmount:'250000', interestRate:'', balance:'210000', monthlyInstalment:'5500', fixed:true},
      {item:'Mortgage Loan', institution:'', loanAmount:'0', interestRate:'', balance:'0', monthlyInstalment:'0', fixed:true},
      {item:'Credit Card', institution:'', loanAmount:'0', interestRate:'', balance:'0', monthlyInstalment:'0', fixed:true},
      {item:'Car Loan', institution:'', loanAmount:'0', interestRate:'', balance:'0', monthlyInstalment:'0', fixed:true},
      {item:'Other', institution:'Motshelo', loanAmount:'16000', interestRate:'30% monthly', balance:'16000', monthlyInstalment:'0'},
      {item:'Other', institution:'Mother', loanAmount:'7000', interestRate:'25% monthly', balance:'7000', monthlyInstalment:'0'},
    ],
    assets:[ {name:'AUDI A3', value:100000, status:'Personal Use', size:'', monthlyIncome:0, potentialIncome:0} ],
    savings:[], risk:[], businesses:[],
    budget:{ housing:4000, food:2400, transport:1000, entertain:1200, emfund:2400, misc:4850 }, budgetOtherCustom:[],
    lifeVision:{}, notes:{ income:'', expense:'', debt:'Failed forex investment funded by motshelo.', lifestyle:'', general:'BNO Fashions income has been declining since May.' },
    consultationNotes:[], documents:[]
  }
};
const AR_CTX = { version:1, status:'final', decision:'Proceed with Conditional Approval', tier:'AMBER', advance_amount:23000, term_months:24, generated_at:'2026-08-28T09:00:00Z', debt_rehab_on:true };

function stub(page) {
  return page.addInitScript(({ OLORATO, ME, DRP_BUNDLE, AR_CTX }) => {
    (0, eval)(DRP_BUNDLE);
    window.__rpc = [];
    window.__plans = [];             // what debt_rehab_plans holds
    window.__invocations = [];
    window.__arRows = [];            // advance_recommendations rows the AR-flag lookup sees

    const chainFor = (t) => {
      const rows = t === 'advance_recommendations' ? window.__arRows.slice() : [];
      const chain = {
        eq: () => chain, is: () => chain, in: () => chain, or: () => chain, order: () => chain, limit: () => chain,
        maybeSingle: async () => ({ data: t === 'profiles' ? { id: ME } : (rows[0] || null), error: null }),
        single: async () => ({ data: null, error: null }),
        update: () => chain,
        then: (res) => res({ data: rows, error: null })
      };
      return chain;
    };
    const fake = {
      from: (t) => ({ select: () => chainFor(t), insert: () => chainFor(t), update: () => chainFor(t), delete: () => chainFor(t) }),
      rpc: async (fn, args) => {
        window.__rpc.push({ fn, args: JSON.parse(JSON.stringify(args || null)) });
        if (fn === 'advisor_me') return { data: { id: 'adv-france', full_name: 'France Mogomotsi', email: 'france@keywealth.co.bw', is_team_lead: false }, error: null };
        if (fn === 'advisor_clients_list') return { data: [OLORATO], error: null };
        if (fn === 'advisor_client_notes') return { data: [], error: null };
        if (fn === 'advisor_note_counts') return { data: [], error: null };
        if (fn === 'advisor_pending_responses') return { data: [], error: null };
        if (fn === 'debt_rehab_plan_list') return { data: window.__plans.slice().sort((a,b)=>b.version-a.version), error: null };
        if (fn === 'debt_rehab_plan_update') {
          const r = window.__plans.find(x => x.id === args.p_id);
          if (r) { r.content = args.p_content; r.actions = args.p_actions; }
          return { data: null, error: null };
        }
        if (fn === 'debt_rehab_plan_finalise') {
          const r = window.__plans.find(x => x.id === args.p_id);
          if (r) { r.status = 'final'; r.finalised_at = '2026-09-03T10:00:00Z'; }
          return { data: null, error: null };
        }
        if (fn === 'debt_rehab_plan_discard') {
          window.__plans = window.__plans.filter(x => x.id !== args.p_id);
          return { data: null, error: null };
        }
        return { data: [], error: null };
      },
      functions: {
        invoke: async (name, { body }) => {
          window.__invocations.push({ name, body: JSON.parse(JSON.stringify(body)) });
          if (name !== 'debt-rehab-plan') return { data: null, error: { message: 'unknown function' } };
          if (window.__fnFail) return { data: null, error: { message: 'boom', context: { json: async () => ({ ok:false, message: 'Today\'s generation allowance for your account is used up. Try again tomorrow.' }) } } };
          const a = OLORATO.assessment;
          const prep = { ...(body.prep || {}), plan_date: '2026-09-03', lending_norm_pct: 35 };
          const notes = [a.notes.debt, a.notes.general];
          const computed = __DRP.computeRehab(a, prep, { rehab_context: AR_CTX, advisor_notes: notes });
          const suggestions = __DRP.liveLiabilities(a).map(({ index, raw }) => ({ index, item: raw.item, institution: raw.institution, ...__DRP.suggestAction(raw, computed.income.total_monthly_income, 35) }));
          const levers = computed.levers.assets.map(l => ({ asset_index: l.asset_index, name: l.name, value: l.value, on: l.on }));
          if (body.mode === 'preview') return { data: { ok: true, mode: 'preview', computed, suggestions, levers, consultant: 'France Mogomotsi', rehab_context: AR_CTX }, error: null };
          const narrative = __DRP.fallbackNarrative(computed);
          const content = __DRP.buildContent(computed, { consultant: 'France Mogomotsi', consultation_date: prep.consultation_date || '2026-09-01', plan_date: '2026-09-03', notes: { diagnostics: { debt: a.notes.debt, general: a.notes.general }, timeline: [] } }, narrative);
          const row = { id: 'plan-' + (window.__plans.length + 1), client_id: body.client_id, version: window.__plans.length + 1,
                        status: 'draft', input: { prep, rehab_context: AR_CTX }, computed, narrative: { source: 'fallback' }, content, actions: __DRP.checkableActions(computed, narrative),
                        model: null, narrative_source: 'fallback', generated_at: '2026-09-03T09:30:00Z', finalised_at: null };
          window.__plans.push(row);
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
  }, { OLORATO, ME, DRP_BUNDLE, AR_CTX });
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

  /* ── 1. Reach the view ─────────────────────────────────── */
  await page.evaluate((id) => { openClient(id); switchTab('report'); }, CLIENT_ID);
  await page.waitForTimeout(300);
  check('1  Report tab offers PFA + Debt Rehab Plan (no Advance Recommendation: the employer runs no programme)',
    await page.evaluate(() => { const b = Array.from(document.querySelectorAll('.ar-switch button')).map(x => x.textContent.trim());
      return b.length === 2 && b[0] === 'Personal Financial Assessment' && b[1] === 'Debt Rehab Plan'; }));
  check('2  the Personal Financial Assessment still renders unchanged underneath',
    (await txt()).includes('Personal Financial Assessment') && (await txt()).includes('Net Worth'));

  await page.click('.ar-switch button:has-text("Debt Rehab Plan")');
  await page.waitForTimeout(900);

  /* ── 2. Prepare ────────────────────────────────────────── */
  check('3  with no plan yet, Prepare opens with the three live liabilities (blank template rows dropped)',
    await page.evaluate(() => document.querySelectorAll('.drp-prep tbody tr').length === 3));
  check('4  actions pre-filled: FNB Renegotiate, motshelo + mother Consolidate',
    await page.evaluate(() => Array.from(document.querySelectorAll('.drp-prep .ar-seg button.on')).map(b => b.className.split(' ')[0]).join(',')) === 'RENEGOTIATE,CONSOLIDATE,CONSOLIDATE');
  const live = await page.evaluate(() => document.querySelector('.ar-live').innerText);
  check('5  live figures match the worked example: DSR 44.72%, Phase 1 44.72% – 52.51%, Phase 2 35.00% – 42.79%, shortfall headline',
    /44\.72%/.test(live) && /44\.72% – 52\.51%/.test(live) && /35\.00% – 42\.79%/.test(live) && /shortfall P 3,550\.00/.test(live) && /9,050\.00/.test(live), live.replace(/\s+/g,' '));
  check('6  the AUDI is listed as an asset lever and ticked by default',
    await page.evaluate(() => { const li = document.querySelector('.drp-levers li'); return !!li && /AUDI A3/.test(li.innerText) && li.querySelector('input').checked; }));
  check('7  FNB (rate blank) asks for a remaining term because it cannot be derived; the outcome column shows the P 4,305.00 cap',
    await page.evaluate(() => { const tr = document.querySelector('.drp-prep tbody tr'); return /Remaining term/.test(tr.innerText) && /4,305\.00/.test(tr.innerText); }));
  await shot(page, '1-prepare');

  await page.evaluate(() => drpPrepSet(1, 'action', 'RETAIN'));
  await page.waitForTimeout(600);
  check('8  changing an action re-computes live: headline becomes 1 renegotiate · 1 consolidate · 1 retain',
    /1 renegotiate · 1 consolidate · 1 retain/.test(await page.evaluate(() => document.querySelector('.ar-live').innerText)));
  await page.evaluate(() => drpPrepSet(1, 'action', 'CONSOLIDATE'));
  await page.waitForTimeout(600);
  await page.evaluate(() => { document.querySelector('.drp-levers input').click(); });
  await page.waitForTimeout(600);
  const inv0 = await page.evaluate(() => window.__invocations[window.__invocations.length - 1].body);
  check('9  unticking the AUDI lever is sent as levers[{asset_index:0,on:false}] on the next preview',
    inv0.mode === 'preview' && inv0.prep.levers.length === 1 && inv0.prep.levers[0].on === false);
  await page.evaluate(() => { document.querySelector('.drp-levers input').click(); });
  await page.waitForTimeout(600);
  await page.evaluate(() => drpPrepField('extension_months', '36'));
  await page.waitForTimeout(600);
  check('10 the term-extension field is sent through (36 months)',
    await page.evaluate(() => window.__invocations[window.__invocations.length - 1].body.prep.extension_months === 36));
  await page.evaluate(() => drpPrepField('extension_months', '24'));
  await page.waitForTimeout(600);

  /* ── 3. Generate ───────────────────────────────────────── */
  await page.click('button:has-text("Generate Debt Rehab Plan")');
  await page.waitForTimeout(700);
  const inv = await page.evaluate(() => window.__invocations.filter(i => i.body.mode === 'generate'));
  check('11 generate calls the Edge Function once with three confirmed actions, the lever and 24 months',
    inv.length === 1 && inv[0].body.prep.liabilities.length === 3 && inv[0].body.prep.liabilities[0].action === 'RENEGOTIATE'
      && inv[0].body.prep.levers.length === 1 && inv[0].body.prep.levers[0].on === true && inv[0].body.prep.extension_months === 24);
  const doc = await page.evaluate(() => document.querySelector('#drp-doc') && document.querySelector('#drp-doc').innerText);
  check('12 the plan renders with the INTERNAL header and the ten numbered sections in order',
    !!doc && /CONFIDENTIAL — INTERNAL DEBT REHAB PLAN \(Key Wellness use only — not for distribution to employer or employee\)/.test(doc)
      && ['01','02','03','04','05','06','07','08','09','10'].every(n => doc.includes(n))
      && doc.indexOf('Client & Enrollment') < doc.indexOf('Root Causes') && doc.indexOf('Root Causes') < doc.indexOf('Financial Position Snapshot')
      && doc.indexOf('Debt-by-Debt Actions') < doc.indexOf('Budget Correction') && doc.indexOf('Budget Correction') < doc.indexOf('Income & Asset Levers')
      && doc.indexOf('Phased Recovery Plan') < doc.indexOf('Review Triggers') && doc.indexOf('Review Triggers') < doc.indexOf('Next Scheduled Review')
      && doc.indexOf('Next Scheduled Review') < doc.indexOf('Consultant Notes'));
  check('13 enrollment: Olorato Maliko, Sedimosa, France Mogomotsi, trigger = Debt Rehab on AR v1, tier AMBER — DSR 44.72%',
    /Olorato Maliko/.test(doc) && /Sedimosa/.test(doc) && /France Mogomotsi/.test(doc) && /Advance Recommendation v1/.test(doc) && /AMBER — DSR 44\.72%/.test(doc));
  check('14 debt table: FNB RENEGOTIATE with the P 4,305.00 cap; motshelo + mother CONSOLIDATE settled by the AR v1 advance',
    await page.evaluate(() => { const t = document.querySelectorAll('#drp-doc .ar-tbl')[0].innerText;
      return /RENEGOTIATE/.test(t) && /Target ≤ P 4,305\.00/.test(t) && (t.match(/CONSOLIDATE/g)||[]).length === 2 && (t.match(/AR v1, 28 Aug 2026/g)||[]).length === 2; }));
  check('15 budget: four groups, shortfall P 3,550.00 as the urgent line, all-in gap P 9,050.00, cuts 1,250 / 2,300',
    await page.evaluate(() => { const t = document.querySelectorAll('#drp-doc .ar-tbl')[1].innerText; const sec = document.querySelectorAll('#drp-doc .ar-sec')[4].innerText;
      return t.split('\n').filter(l => /^(Needs|Wants|Savings|Other)/.test(l)).length === 4 && /P 1,250\.00/.test(t) && /P 2,300\.00/.test(t)
        && /Shortfall: P 15,850\.00 budgeted against P 12,300\.00 income = P 3,550\.00 a month — the most urgent item/.test(sec) && /P 9,050\.00/.test(sec); }));
  check('16 three phases with computed bands and a Phase 3 target of 35.00%',
    await page.evaluate(() => { const ph = Array.from(document.querySelectorAll('.drp-phase .band')).map(x => x.innerText);
      return ph.length === 3 && /44\.72% – 52\.51%/.test(ph[0]) && /35\.00% – 42\.79%/.test(ph[1]) && /Target ≤ 35\.00%/.test(ph[2]); }));
  check('17 checkable actions: Phase 1 lists the AUDI sale and the FNB conversation; the lever list has the AUDI; five triggers',
    await page.evaluate(() => { const p1 = document.querySelectorAll('.drp-phase')[0].innerText; const lists = document.querySelectorAll('#drp-doc .ar-cond');
      const triggers = document.querySelectorAll('#drp-doc .ar-sec')[7].querySelectorAll('.ar-cond li').length;
      return /Initiate the sale of AUDI A3/.test(p1) && /term-extension conversation with FNB/.test(p1) && lists.length >= 5 && triggers === 5; }));
  check('18 data gaps are printed, not hidden: FNB rate and savings',
    await page.evaluate(() => { const g = document.querySelector('#drp-doc .ar-gaps'); return !!g && /Interest rate not captured for Personal Loan – FNB/.test(g.innerText) && /Savings and investments not captured/.test(g.innerText); }));
  check('19 the fallback-prose warning shows when the model did not write the text',
    /Fallback prose/.test(await page.evaluate(() => document.querySelector('.ar-bar').innerText)));
  check('20 consultant notes are carried verbatim and labelled as the consultant\'s',
    /carried verbatim from the record/.test(doc) && /Failed forex investment funded by motshelo/.test(doc));
  await shot(page, '2-draft');

  /* ── 4. Edit ───────────────────────────────────────────── */
  const b = page.locator('[data-drp="sections.root_causes.bullets.0"]');
  await b.click();
  await page.keyboard.press('End');
  await page.keyboard.type(' Advisor added this.');
  await page.waitForTimeout(1200);
  const upd = await page.evaluate(() => window.__rpc.filter(r => r.fn === 'debt_rehab_plan_update'));
  check('21 typing into a root-cause bullet saves through debt_rehab_plan_update with the edited text',
    upd.length >= 1 && /Advisor added this\./.test(upd[upd.length-1].args.p_content.sections.root_causes.bullets[0]));
  await page.evaluate(() => { document.querySelectorAll('.drp-phase')[0].querySelector('.ar-cond input').click(); });
  await page.waitForTimeout(1200);
  const upd2 = await page.evaluate(() => window.__rpc.filter(r => r.fn === 'debt_rehab_plan_update'));
  check('22 unticking a Phase 1 action saves it off and strikes it through on screen',
    upd2[upd2.length-1].args.p_actions.find(a => a.group === 'phase1').on === false
      && await page.evaluate(() => document.querySelectorAll('.drp-phase')[0].querySelector('.ar-cond li').classList.contains('off')));

  /* ── 5. Print CSS ─────────────────────────────────────── */
  await page.emulateMedia({ media: 'print' });
  await shot(page, '3-print');
  check('23 in print: the unticked action disappears, toolbar/switch/hero are hidden, the INTERNAL header stays',
    await page.evaluate(() => {
      const off = document.querySelectorAll('.drp-phase')[0].querySelector('.ar-cond li');
      return getComputedStyle(off).display === 'none' && getComputedStyle(document.querySelector('.ar-bar')).display === 'none'
        && getComputedStyle(document.querySelector('.ar-switch')).display === 'none'
        && getComputedStyle(document.querySelector('.drp-head')).display !== 'none'
        && (!document.querySelector('.client-hero') || getComputedStyle(document.querySelector('.client-hero')).display === 'none');
    }));
  await page.emulateMedia({ media: 'screen' });

  /* ── 6. Finalise ──────────────────────────────────────── */
  await page.click('button:has-text("Mark final")');
  await page.waitForTimeout(200);
  check('24 Mark final asks for confirmation before locking',
    await page.evaluate(() => /Confirm — mark final/.test(document.querySelector('.ar-bar').innerText) && window.__rpc.filter(r => r.fn === 'debt_rehab_plan_finalise').length === 0));
  await page.click('button:has-text("Confirm — mark final")');
  await page.waitForTimeout(600);
  check('25 after confirming, the row is final, the badge says Final, nothing is editable',
    await page.evaluate(() => window.__rpc.some(r => r.fn === 'debt_rehab_plan_finalise')
      && /Final/.test(document.querySelector('.ar-status').textContent)
      && document.querySelectorAll('#drp-doc [contenteditable="true"]').length === 0
      && document.querySelectorAll('#drp-doc input[type=checkbox]').length === 0));
  check('26 a final plan offers Regenerate and Print, but no Mark final or Discard',
    await page.evaluate(() => { const t = document.querySelector('.ar-bar').innerText; return /Regenerate/.test(t) && /Print/.test(t) && !/Mark final/.test(t) && !/Discard/.test(t); }));

  /* ── 7. Regenerate → v2 ───────────────────────────────── */
  await page.click('button:has-text("Regenerate")');
  await page.waitForTimeout(800);
  check('27 Regenerate reopens Prepare seeded from v1 (same three actions, 24 months, AUDI ticked)',
    await page.evaluate(() => document.querySelectorAll('.drp-prep').length === 1
      && document.querySelector('.drp-prep .ar-fields input[type=number]').value === '24'
      && Array.from(document.querySelectorAll('.drp-prep .ar-seg button.on')).map(b => b.className.split(' ')[0]).join(',') === 'RENEGOTIATE,CONSOLIDATE,CONSOLIDATE'
      && document.querySelector('.drp-levers input').checked));
  await page.click('button:has-text("Generate Debt Rehab Plan")');
  await page.waitForTimeout(700);
  check('28 v2 is a fresh draft; the picker lists v2 and v1 (final)',
    await page.evaluate(() => { const o = Array.from(document.querySelectorAll('.ar-select option')).map(x => x.textContent); return o.length === 2 && /v2 · Draft/.test(o[0]) && /v1 · Final/.test(o[1]); }));

  /* ── 8. Error path ────────────────────────────────────── */
  await page.evaluate(() => { window.__fnFail = true; drpRegenerate(); });
  await page.waitForTimeout(800);
  check('29 a refused call surfaces the server\'s message instead of a blank screen',
    /generation allowance/.test(await txt()));
  await page.evaluate(() => { window.__fnFail = false; });

  /* ── 9. The offer rule ───────────────────────────────── */
  const reportTabHtml = async () => {
    await page.evaluate(() => { reportView = 'pfa'; switchTab('report'); });
    await page.waitForTimeout(400);
    return page.evaluate(() => document.getElementById('page-content').innerHTML);
  };
  await page.evaluate((id) => { const c = clients.find(x => x.id === id); c.income.monthlySalary = 80000; DRP.arFlag = {}; window.__arRows = []; }, CLIENT_ID);
  check('30 a client within the norm with no Debt Rehab flag on file is not offered the view',
    !/Debt Rehab Plan<\/button>/.test(await reportTabHtml()));
  await page.evaluate(() => { DRP.arFlag = {}; window.__arRows = [{ conditions: [{ key: 'debt_rehab', on: true, group: 'condition' }] }]; });
  const html31 = await reportTabHtml();
  check('31 …but when the latest Advance Recommendation has Debt Rehab on, the view appears once that lookup returns',
    /Debt Rehab Plan<\/button>/.test(html31));
  await page.evaluate((id) => { const c = clients.find(x => x.id === id); c.income.monthlySalary = 4000; DRP.arFlag = {}; window.__arRows = []; }, CLIENT_ID);
  check('32 a strained DSR band alone offers the view, with no Advance Recommendation and no advance programme',
    /Debt Rehab Plan<\/button>/.test(await reportTabHtml()) && !/Advance Recommendation<\/button>/.test(await reportTabHtml()));

  check('33 no JavaScript errors during the whole run', errors.length === 0, errors.join(' | '));

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
