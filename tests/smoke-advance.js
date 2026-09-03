/* Key Wellness — headless checks for the Advance Recommendation view
   on the advisor portal's Report tab.

   Loads the real advisor.html in Chromium with a stubbed Supabase client
   and drives it the way an advisor would: open Tumelo, go to Report,
   switch to Advance Recommendation, confirm the classification, generate,
   edit a line, untick a condition, mark final, print.

   The Edge Function is stubbed too — but not with canned JSON. The stub
   runs the REAL compute.ts + report.ts (bundled by esbuild into the page
   as window.__AR), so the figures on screen are the figures production
   would produce from the same record. Only the model call is replaced,
   by the deterministic fallback narrative — which is exactly what
   production does when the model is unavailable.

   Prereq:  npx esbuild tests/ar-entry.ts --bundle --format=iife \
              --global-name=__AR --outfile=tests/.ar-browser.js
            (run-advance.sh does this)
   Usage:   node tests/smoke-advance.js
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
const AR_BUNDLE = fs.readFileSync(path.resolve(__dirname, '.ar-browser.js'), 'utf8');

/* SCREENSHOTS=<dir> saves prepare / draft / print captures for a design review. */
const SHOT = process.env.SCREENSHOTS;
const shot = async (page, name, opts) => { if (SHOT) await page.screenshot({ path: path.join(SHOT, name + '.png'), fullPage: true, ...(opts||{}) }); };

const ME = '11111111-1111-4111-8111-111111111111';
const CLIENT_ID = 'f460e2df-bd48-42aa-9976-f481a955b2c2';

/* Tumelo, as advisor_clients.assessment holds her, linked to an organisation
   that runs an advance programme. The org link — not the typed Employer —
   is what opens the Advance Recommendation view. */
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
    assets:[], savings:[], risk:[], businesses:[], budget:{}, budgetOtherCustom:[],
    lifeVision:{}, notes:{ income:'', expense:'', debt:'', lifestyle:'', general:'' }, consultationNotes:[], documents:[]
  }
};

function stub(page) {
  return page.addInitScript(({ TUMELO, ME, AR_BUNDLE }) => {
    // Real compute + report modules, in the page.
    (0, eval)(AR_BUNDLE);
    window.__rpc = [];
    window.__reports = [];          // what advance_recommendations holds
    window.__invocations = [];

    const chainFor = (t) => {
      const rows = t === 'advance_recommendations' ? window.__reports.slice().sort((a,b)=>b.version-a.version) : [];
      const chain = {
        eq: () => chain, is: () => chain, in: () => chain, or: () => chain, order: () => chain, limit: () => chain,
        maybeSingle: async () => ({ data: t === 'profiles' ? { id: ME } : null, error: null }),
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
        if (fn === 'advisor_clients_list') return { data: [TUMELO], error: null };
        if (fn === 'advisor_client_notes') return { data: [], error: null };
        if (fn === 'advisor_note_counts') return { data: [], error: null };
        if (fn === 'advisor_pending_responses') return { data: [], error: null };
        if (fn === 'advance_recommendation_update') {
          const r = window.__reports.find(x => x.id === args.p_id);
          if (r) { r.content = args.p_content; r.conditions = args.p_conditions; }
          return { data: null, error: null };
        }
        if (fn === 'advance_recommendation_finalise') {
          const r = window.__reports.find(x => x.id === args.p_id);
          if (r) { r.status = 'final'; r.finalised_at = '2026-08-31T10:00:00Z'; }
          return { data: null, error: null };
        }
        if (fn === 'advance_recommendation_discard') {
          window.__reports = window.__reports.filter(x => x.id !== args.p_id);
          return { data: null, error: null };
        }
        return { data: [], error: null };
      },
      functions: {
        invoke: async (name, { body }) => {
          window.__invocations.push({ name, body: JSON.parse(JSON.stringify(body)) });
          if (name !== 'advance-recommendation') return { data: null, error: { message: 'unknown function' } };
          if (window.__fnFail) return { data: null, error: { message: 'boom', context: { json: async () => ({ ok:false, message: 'Today\'s generation allowance for your account is used up. Try again tomorrow.' }) } } };
          const a = TUMELO.assessment;
          const prep = body.prep || {};
          const computed = __AR.compute(a, { ...prep, recommendation_date: '2026-08-31', consultant_name: 'France Mogomotsi' });
          const suggestions = __AR.liveLiabilities(a).map(({ index, raw }) => ({ index, item: raw.item, institution: raw.institution, ...__AR.suggestClassification(raw) }));
          if (body.mode === 'preview') return { data: { ok: true, mode: 'preview', computed, suggestions, consultant: 'France Mogomotsi' }, error: null };
          const narrative = __AR.fallbackNarrative(computed);
          const content = __AR.buildContent(computed, { consultant: 'France Mogomotsi', consultation_date: prep.consultation_date || '2026-08-28', recommendation_date: '2026-08-31' }, narrative);
          const conditions = [
            ...computed.conditions.map(c => ({ ...c, group: 'condition' })),
            ...computed.support_plan.map(c => ({ ...c, group: 'support' })),
            ...computed.follow_up.map(c => ({ ...c, group: 'follow_up' })),
          ];
          const row = { id: 'rep-' + (window.__reports.length + 1), client_id: body.client_id, version: window.__reports.length + 1,
                        status: 'draft', input: { prep }, computed, narrative: { source: 'fallback' }, content, conditions,
                        model: null, narrative_source: 'fallback', generated_at: '2026-08-31T09:30:00Z', finalised_at: null };
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
  check('1  Report tab shows the two-view switch, PFA first',
    await page.evaluate(() => document.querySelectorAll('.ar-switch button').length === 2
      && document.querySelector('.ar-switch button.active').textContent.includes('Personal Financial')));
  check('2  the Personal Financial Assessment still renders unchanged underneath',
    (await txt()).includes('Personal Financial Assessment') && (await txt()).includes('Net Worth'));

  await page.click('.ar-switch button:nth-child(2)');
  await page.waitForTimeout(900);

  /* ── 2. Prepare ────────────────────────────────────────── */
  check('3  with no report yet, the Prepare screen opens and shows the six live liabilities (blank template rows dropped)',
    await page.evaluate(() => document.querySelectorAll('.ar-prep tbody tr').length === 6));
  check('4  auto-classification: Stanbic formal, the other five informal',
    await page.evaluate(() => Array.from(document.querySelectorAll('.ar-prep .ar-seg button.on')).map(b => b.className.includes('informal') ? 'I' : 'F').join('')) === 'FIIIII');
  const live = await page.evaluate(() => document.querySelector('.ar-live').innerText);
  check('5  live figures match the worked example: 45.43% → 42.75%, P 36,850.00, AMBER',
    /45\.43%/.test(live) && /42\.75%/.test(live) && /36,850\.00/.test(live) && /AMBER/.test(live), live.replace(/\s+/g,' '));
  check('6  rates that were not captured say so, not 0%',
    await page.evaluate(() => Array.from(document.querySelectorAll('.ar-prep tbody tr')).filter(tr => /Not captured/.test(tr.innerText)).length === 2));

  await shot(page, '1-prepare');
  // Reclassify Express Credit as formal → nothing replaces its P 2,200 instalment, DSR after must rise.
  await page.evaluate(() => arPrepSet(1, 'classification', 'formal'));
  await page.waitForTimeout(600);
  const live2 = await page.evaluate(() => document.querySelector('.ar-live').innerText);
  check('7  changing a classification re-computes live (advance drops to P 11,850.00, DSR after rises to 47.42%)',
    /11,850\.00/.test(live2) && /47\.42%/.test(live2) && /RED/.test(live2), live2.replace(/\s+/g,' '));
  await page.evaluate(() => arPrepSet(1, 'classification', 'informal'));
  await page.waitForTimeout(600);

  // Term change
  await page.evaluate(() => arPrepField('term_months', '12'));
  await page.waitForTimeout(600);
  const live3 = await page.evaluate(() => document.querySelector('.ar-live').innerText);
  check('8  a 12-month term halves the horizon: instalment P 3,070.83, DSR after 48.94% → RED',
    /3,070\.83/.test(live3) && /48\.94%/.test(live3) && /RED/.test(live3), live3.replace(/\s+/g,' '));
  await page.evaluate(() => arPrepField('term_months', '24'));
  await page.waitForTimeout(600);

  /* ── 3. Generate ───────────────────────────────────────── */
  await page.click('button:has-text("Generate Advance Recommendation")');
  await page.waitForTimeout(700);
  const inv = await page.evaluate(() => window.__invocations.filter(i => i.body.mode === 'generate'));
  check('9  generate calls the Edge Function once with the confirmed classification and 24 months',
    inv.length === 1 && inv[0].body.prep.term_months === 24 && inv[0].body.prep.liabilities.length === 6
      && inv[0].body.prep.liabilities.filter(l => l.classification === 'informal').length === 5);

  const doc = await page.evaluate(() => document.querySelector('#ar-doc') && document.querySelector('#ar-doc').innerText);
  check('10 the report renders with CONFIDENTIAL and the nine numbered sections in order',
    !!doc && /CONFIDENTIAL/.test(doc) && ['01','02','03','04','05','06','07','08','09'].every(n => doc.includes(n))
      && doc.indexOf('Employee Details') < doc.indexOf('Reasoning') && doc.indexOf('Reasoning') < doc.indexOf('Debt Service Ratio')
      && doc.indexOf('Financial Risk Assessment') < doc.indexOf('Consultant Recommendation')
      && doc.indexOf('Consultant Recommendation') < doc.indexOf('Employee Support Plan'));
  check('11 header table: Hollard, P 36,850.00, 24 months, Salary / Incentive Advance, France Mogomotsi',
    /Hollard/.test(doc) && /P 36,850\.00/.test(doc) && /24 months/.test(doc) && /Salary \/ Incentive Advance/.test(doc) && /France Mogomotsi/.test(doc));
  check('12 DSR table has Before and After columns with 45.43% and 42.75%',
    await page.evaluate(() => { const t = document.querySelectorAll('#ar-doc .ar-tbl')[0].innerText; return /before/i.test(t) && /after advance/i.test(t) && /45\.43%/.test(t) && /42\.75%/.test(t); }));
  check('13 debt position: Stanbic Unchanged, five Settled by advance, a New advance line, "Not captured" for blank rates',
    await page.evaluate(() => { const t = document.querySelectorAll('#ar-doc .ar-tbl')[1].innerText;
      return (t.match(/Settled by advance/g)||[]).length === 5 && /Unchanged/.test(t) && /New advance/.test(t) && (t.match(/Not captured/g)||[]).length === 2; }));
  check('14 risk block is AMBER and the decision line is Proceed with Conditional Approval',
    await page.evaluate(() => document.querySelector('.ar-risk').classList.contains('AMBER') && /Proceed with Conditional Approval/.test(document.querySelector('.ar-dec').textContent)));
  check('15 the three operating conditions are checkboxes, all on by default for this case',
    await page.evaluate(() => { const li = document.querySelectorAll('.ar-sec .ar-cond')[0].querySelectorAll('li'); return li.length === 3 && Array.from(li).every(l => l.querySelector('input').checked); }));
  check('16 data gaps are printed, not hidden: two rates and the missing budget',
    await page.evaluate(() => { const g = document.querySelector('.ar-gaps'); return !!g && /Interest rate not captured/.test(g.innerText) && /budget/.test(g.innerText); }));
  check('17 confidentiality statement is the fixed wording',
    /This report contains only the professional recommendation from the Financial Wellness Consultation/.test(doc));
  check('18 the fallback-prose warning shows when the model did not write the text',
    /Fallback prose/.test(await page.evaluate(() => document.querySelector('.ar-bar').innerText)));

  await shot(page, '2-draft');
  /* ── 4. Edit ───────────────────────────────────────────── */
  const p = page.locator('[data-ar="sections.reasoning.intro"]');
  await p.click();
  await page.keyboard.press('End');
  await page.keyboard.type(' Advisor added this.');
  await page.waitForTimeout(1200);
  const upd = await page.evaluate(() => window.__rpc.filter(r => r.fn === 'advance_recommendation_update'));
  check('19 typing into a paragraph saves through advance_recommendation_update with the edited text',
    upd.length >= 1 && /Advisor added this\./.test(upd[upd.length-1].args.p_content.sections.reasoning.intro));

  await page.evaluate(() => { const li = document.querySelectorAll('.ar-sec .ar-cond')[0].querySelectorAll('li'); li[2].querySelector('input').click(); });
  await page.waitForTimeout(1200);
  const upd2 = await page.evaluate(() => window.__rpc.filter(r => r.fn === 'advance_recommendation_update'));
  check('20 unticking the HR-letter condition saves it off and strikes it through on screen',
    upd2[upd2.length-1].args.p_conditions.find(c => c.key === 'hr_letter_hold').on === false
      && await page.evaluate(() => document.querySelectorAll('.ar-sec .ar-cond')[0].querySelectorAll('li')[2].classList.contains('off')));

  /* ── 5. Print CSS ─────────────────────────────────────── */
  await page.emulateMedia({ media: 'print' });
  await shot(page, '3-print');
  check('21 in print, an unticked condition disappears and the toolbar/switch are hidden',
    await page.evaluate(() => {
      const off = document.querySelectorAll('.ar-sec .ar-cond')[0].querySelectorAll('li')[2];
      return getComputedStyle(off).display === 'none' && getComputedStyle(document.querySelector('.ar-bar')).display === 'none'
        && getComputedStyle(document.querySelector('.ar-switch')).display === 'none';
    }));
  await page.emulateMedia({ media: 'screen' });

  /* ── 6. Finalise ──────────────────────────────────────── */
  await page.click('button:has-text("Mark final")');
  await page.waitForTimeout(200);
  check('22 Mark final asks for confirmation before locking',
    await page.evaluate(() => !!document.querySelector('button') && /Confirm — mark final/.test(document.querySelector('.ar-bar').innerText)) &&
    await page.evaluate(() => window.__rpc.filter(r => r.fn === 'advance_recommendation_finalise').length === 0));
  await page.click('button:has-text("Confirm — mark final")');
  await page.waitForTimeout(600);
  check('23 after confirming, the row is final, the badge says Final, and nothing is editable',
    await page.evaluate(() => window.__rpc.some(r => r.fn === 'advance_recommendation_finalise')
      && /Final/.test(document.querySelector('.ar-status').textContent)
      && document.querySelectorAll('#ar-doc [contenteditable="true"]').length === 0
      && document.querySelectorAll('#ar-doc input[type=checkbox]').length === 0));
  check('24 a final report offers Regenerate and Print, but no Mark final or Discard',
    await page.evaluate(() => { const t = document.querySelector('.ar-bar').innerText; return /Regenerate/.test(t) && /Print/.test(t) && !/Mark final/.test(t) && !/Discard/.test(t); }));

  /* ── 7. Regenerate → v2, and the version picker ───────── */
  await page.click('button:has-text("Regenerate")');
  await page.waitForTimeout(800);
  check('25 Regenerate reopens Prepare seeded from v1 (24 months, five informal)',
    await page.evaluate(() => document.querySelectorAll('.ar-prep').length === 1
      && document.querySelector('.ar-prep input[type=number]').value === '24'
      && document.querySelectorAll('.ar-prep .ar-seg button.on.informal').length === 5));
  await page.click('button:has-text("Generate Advance Recommendation")');
  await page.waitForTimeout(700);
  check('26 v2 is a fresh draft; the picker lists v2 and v1 (final)',
    await page.evaluate(() => { const o = Array.from(document.querySelectorAll('.ar-select option')).map(x => x.textContent); return o.length === 2 && /v2 · Draft/.test(o[0]) && /v1 · Final/.test(o[1]); }));

  /* ── 8. Error path ────────────────────────────────────── */
  await page.evaluate(() => { window.__fnFail = true; arRegenerate(); });
  await page.waitForTimeout(800);
  check('27 a refused call surfaces the server\'s message instead of a blank screen',
    /generation allowance/.test(await txt()));

  /* ── 9. Gating: who may be offered an advance recommendation ─────
     The pill used to render for every client, so a Hollard-headed
     document could be produced for any organisation's employee, or for
     a private client with no programme at all. ── */
  const reportTabHtml = async () => {
    await page.evaluate(() => { reportView = 'pfa'; switchTab('report'); });
    await page.waitForTimeout(250);
    return page.evaluate(() => document.getElementById('page-content').innerHTML);
  };

  await page.evaluate((id) => { const c = clients.find(x => x.id === id);
                                c._org.offersAdvances = false; }, CLIENT_ID);
  check('29 an organisation that runs no advance programme is not offered the view',
    !/Advance Recommendation<\/button>/.test(await reportTabHtml()));

  await page.evaluate((id) => { const c = clients.find(x => x.id === id);
                                c._org.offersAdvances = true; c._org.id = null; c._org.noOrg = true; }, CLIENT_ID);
  check('30 a private client with no organisation is not offered the view',
    !/Advance Recommendation<\/button>/.test(await reportTabHtml()));

  await page.evaluate((id) => { const c = clients.find(x => x.id === id);
                                c._org.id = 'org-hollard'; c._org.noOrg = false; }, CLIENT_ID);
  check('31 the assessment still renders for a client who cannot have an advance',
    /Personal Financial Assessment/.test(await reportTabHtml()));

  check('32 an unlinked client is warned about on the Personal tab, not silently counted',
    await page.evaluate((id) => {
      const c = clients.find(x => x.id === id);
      const saved = { id: c._org.id, noOrg: c._org.noOrg };
      c._org.id = null; c._org.noOrg = false;
      switchTab('personal');
      const hit = /company reporting will not count them/i.test(document.getElementById('page-content').innerHTML);
      c._org.id = saved.id; c._org.noOrg = saved.noOrg;
      return hit;
    }, CLIENT_ID));

  check('28 no JavaScript errors during the whole run', errors.length === 0, errors.join(' | '));

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
