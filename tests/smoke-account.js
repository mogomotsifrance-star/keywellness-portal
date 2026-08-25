/* Key Wellness — headless checks for the organisation account file
   (Phase 2: shell, presenting issues, delivery, wellbeing).

   Loads the real admin.html in Chromium with a stubbed Supabase client
   and drives the drill-in the way an admin would: click an organisation,
   read each panel, change the period and the site scope, and switch the
   client-safe view on.

   Four RPCs are stubbed, and each can be made to fail on its own:
     admin_org_indicators       __indFail    Panel 3, admin OR team lead
     org_report_data            __repFail    Panels 1 and 2, admin only
     org_financial_indicators   __finFail    Panel 2, admin only
     advisor_session_breakdown  __adminOnly  Panel 1, admin only

   The fixture is built from the real payload shapes, not from what the
   shapes look like they ought to be. That distinction is the reason this
   file exists: the first version used plain numbers where the SQL returns
   { value, suppressed } cells, and every panel assertion passed while the
   page rendered [object Object] and NaN. See the note above REPORT.

   Usage:  node tests/smoke-account.js
*/
const { chromium } = require('playwright');
const path = require('path');

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name); }
  else    { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}

/* Shapes returned by the HR reporting functions.

   IMPORTANT: org_report_data() does NOT return plain numbers for anything
   that counts people. _suppress_count() and _suppress_rate() both return
   a jsonb object — { value, suppressed } — and reading .value off it
   directly gives [object Object] on the page and NaN in arithmetic. An
   earlier version of this fixture used plain numbers and, as a result,
   asserted nothing about the code path that actually runs in production.
   The cell() helper below builds the real shape, and which fields are
   wrapped is copied from supabase_org_report_data_v4.sql, not guessed.

   cell(n)    a real count            cell(null)  withheld (1 or 2 people)
   cell(0)    genuinely nobody                                             */
const cell = v => ({ value: v, suppressed: v === null });

const REPORT = {
  insufficient_cohort: false, n_employees: 21,
  // registered and bookings_unconfirmed are plain; the four middle steps are wrapped.
  engagement_funnel: { registered: 21, completed_assessment: cell(13), used_tool: cell(null),
                       booked_session: cell(6), attended_session: cell(4), bookings_unconfirmed: 2 },
  // total_booked / total_attended / coverage_pct are plain; mode_split and
  // monthly_trend counts are wrapped.
  sessions: { total_booked: 12, total_attended: 8,
              attendance_confirmation_coverage_pct: 83.3,
              mode_split: { 'In-Person': cell(5), Virtual: cell(3) },
              monthly_trend: [ { month: '2026-07', booked: cell(5), attended: cell(3) },
                               { month: '2026-08', booked: cell(7), attended: cell(5) } ] },
  assessment_categories: {
    debt:      { assessed_count: cell(13), band_under_50: cell(4), band_50_69: cell(5), band_70_plus: cell(4) },
    emergency: { assessed_count: cell(13), band_under_50: cell(7), band_50_69: cell(null), band_70_plus: cell(4) }
  },
  demographics: { age_bands: { '18_29': cell(4), '30_39': cell(9), '40_49': cell(5), '50_plus': cell(3) } },
  learning: { articles_read: cell(6), videos_watched: cell(null), quizzes_passed: cell(3) },
  // participation_rate and attendance_rate are wrapped; the two totals are plain.
  kpi_summary: { participation_rate: cell(62), attendance_rate: cell(66.7),
                 total_reach: 7, total_touchpoints: 40 },
  session_intensity: { '1': cell(4), '2': cell(2), '3_plus': cell(null) },
  client_type_split: { member: cell(6), dependent: cell(null) },
  // program_activities is plain throughout.
  program_activities: { total_activities: 2, total_attendees: 55,
    activities_list: [ { title: 'Budgeting talk', activity_date: '2026-07-14',
                         attendee_count: 30, activity_type: 'education_talk',
                         delivery_mode: 'physical' } ] },
  // attendance_confirmation_pct plain, assessment_completion_pct wrapped.
  data_coverage: { attendance_confirmation_pct: 83.3, assessment_completion_pct: cell(62),
                   statement: 'Figures reflect confirmed portal data as of snapshot date.' }
};

// org_financial_indicators() is the odd one out: it carries its own
// explicit `suppressed` flag on each band and plain medians.
const FIN = {
  eligible: true, assessed_count: 13,
  dti: { reported_count: 10, median: 22.4, bands: [
    { key:'healthy', label:'Healthy (<20%)', count: 4, suppressed:false },
    { key:'over_indebted', label:'Over-indebted (>45%)', count: null, suppressed:true } ] },
  retirement: { median: 48, bands: [ { key:'fair', label:'Fair (55-69)', count: 5, suppressed:false } ] },
  stress:     { reported_count: 5, median: 6, bands: [ { key:'high', label:'High (7-10)', count: 2, suppressed:false } ] }
};

// advisor_session_breakdown() applies NO suppression at all — plain
// numbers throughout, including counts of one and two.
const BREAKDOWN = {
  org_id: 'org-test',
  totals: { total_booked: 12, total_attended: 8, advisor_sourced: 9, self_booked: 3,
            advisor_sourced_pct: 75.0, declined_by_member: 1, awaiting_response: 2 },
  by_advisor: [
    { advisor_id:'a1', advisor_name:'Kealeboga Gaseitsiwe', advisor_active:true,
      booked:7, attended:5, no_show:1, unconfirmed:1, cancelled:0,
      unique_clients:5, attendance_rate:83.3 },
    { advisor_id:'a2', advisor_name:'Retired Advisor', advisor_active:false,
      booked:2, attended:1, no_show:0, unconfirmed:1, cancelled:0,
      unique_clients:2, attendance_rate:100.0 }
  ]
};

const ORGS = [
  { id: 'org-test', name: 'Test Co',  invite_code: 'TEST-1234', is_active: true,
    program_name: 'Financial Wellbeing', member_count: 21, hr_count: 1, unit_count: 0, deletable: false },
  { id: 'org-sed',  name: 'Sedimosa', invite_code: 'S3DI-M185', is_active: true,
    program_name: null, member_count: 8, hr_count: 1, unit_count: 11, deletable: false }
];

const UNITS = [
  { id: 'unit-hq',   name: 'Head Office Co', parent_name: null,            parent_unit_id: null,      is_active: true,  member_count: 8, child_count: 2 },
  { id: 'unit-gabs', name: 'Gaborone',       parent_name: 'Head Office Co', parent_unit_id: 'unit-hq', is_active: true,  member_count: 5, child_count: 0 },
  { id: 'unit-old',  name: 'Lobatse',        parent_name: 'Head Office Co', parent_unit_id: 'unit-hq', is_active: false, member_count: 1, child_count: 0 }
];

function indicators(opts) {
  opts = opts || {};
  const safe = !!opts.client_safe;
  const mk = (key, label, placement, count, base, extra) => Object.assign({
    key: key, label: label, placement: placement,
    definition: label + ' definition', source: 'assessment',
    count: count, base: base,
    pct: base ? Math.round(1000 * count / base) / 10 : null,
    low_base: base < 5,
    movement: null, movement_note: null,
    suppressed: false
  }, extra || {});

  const head = [
    mk('over_indebted',        'Over-indebted',        'row_1', 2, 10,
       { source: 'profile', movement_note: 'No history: this is a current profile value, so it cannot be re-computed as at a past date.' }),
    mk('no_emergency_buffer',  'No emergency buffer',  'row_1', 7, 13,
       { movement: { previous_count: 2, previous_base: 8, previous_pct: 25.0, delta_pct: 28.8 } }),
    mk('living_beyond_means',  'Living beyond means',  'row_1', 2, 13,
       { movement: { previous_count: 4, previous_base: 8, previous_pct: 50.0, delta_pct: -34.6 } }),
    mk('retirement_shortfall', 'Retirement shortfall', 'row_2', 6, 13,
       { movement: { previous_count: 4, previous_base: 8, previous_pct: 50.0, delta_pct: -3.8 } }),
    mk('cover_gap',            'Cover gap',            'row_2', 3, 13, {}),
    mk('not_building_wealth',  'Not building wealth',  'row_2', 8, 13, {})
  ];

  // A deliberately tiny base, so low-base marking and client-safe
  // suppression can both be checked on the same indicator.
  const lib = [
    mk('no_will',                'No will in place',                  'library', 3, 4,
       { source: 'profile', movement_note: 'No history: this is a current profile value, so it cannot be re-computed as at a past date.' }),
    mk('single_income_reliance', 'Reliance on a single income source','library', 5, 13, {}),
    mk('high_financial_stress',  'High financial stress',             'library', 2, 5, {})
  ];

  if (safe) {
    lib.forEach(r => { if (r.low_base) { r.count = null; r.pct = null; r.movement = null; r.suppressed = true; } });
    head.forEach(r => { if (r.low_base) { r.count = null; r.pct = null; r.movement = null; r.suppressed = true; } });
  }

  return {
    org_id: opts.org_id, org_name: 'Test Co',
    unit_id: opts.unit_id || null,
    unit_label: opts.unit_id ? 'Head Office Co — Gaborone' : null,
    period_start: opts.start, period_end: opts.end,
    client_safe: safe, suppressed: false,
    cohort: { registered: opts.unit_id ? 5 : 21, assessed: opts.unit_id ? 3 : 13,
              registered_before: 18, low_base_threshold: 5 },
    headline: head, library: lib,
    note: 'Prevalence among the population each figure can be computed for.'
  };
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));

  /* admin.html loads supabase-js from jsdelivr in <head>. addInitScript runs
     before page scripts, so the stub below is installed first — and then the
     CDN library lands and overwrites window.supabase. The page then builds a
     REAL client, finds no session, and redirects to index.html; every
     assertion after that fails with "window.showTab is not a function".

     That means the suite only passed when the CDN happened to be unreachable.
     Blocking it makes the stub authoritative and the run deterministic on or
     offline. Chart.js is left alone — the account file degrades without it and
     nothing here asserts on a canvas. */
  await page.route('**cdn.jsdelivr.net/npm/@supabase/**', route => route.abort());

  await page.addInitScript(({ orgs, units }) => {
    window.__rpc = [];
    window.__orgs = orgs;
    window.__units = units;
    window.__indicatorFn = null;      // installed from Node below
    const q = () => {
      const chain = {
        eq: () => chain, or: () => chain, order: () => chain, limit: () => chain,
        maybeSingle: async () => ({ data: { email: 'admin@keywellness.co.bw' }, error: null }),
        single: async () => ({ data: null, error: null }),
        then: (res) => res({ data: [], error: null })
      };
      return chain;
    };
    const fakeSb = {
      from: () => ({ select: q, insert: q, update: q, delete: q }),
      rpc: async (fn, args) => {
        window.__rpc.push({ fn: fn, args: args });
        if (fn === 'admin_orgs_overview')   return { data: window.__orgs,  error: null };
        if (fn === 'admin_units_overview')  return { data: window.__units, error: null };
        if (fn === 'admin_org_indicators')  return window.__indFail
          ? { data: null, error: { message: 'function admin_org_indicators does not exist' } }
          : { data: window.__makeIndicators(args), error: null };
        if (fn === 'org_report_data')           return (window.__adminOnly || window.__repFail)
          ? { data: null, error: { message: 'period_end must not be before period_start' } }
          : { data: window.__report, error: null };
        if (fn === 'org_financial_indicators')  return (window.__adminOnly || window.__finFail)
          ? { data: null, error: { message: 'not authorised' } } : { data: window.__fin, error: null };
        if (fn === 'advisor_session_breakdown') return window.__adminOnly
          ? { data: null, error: { message: 'not authorised' } } : { data: window.__breakdown, error: null };
        return { data: [], error: null };
      },
      auth: {
        getSession: async () => ({ data: { session: {
          user: { id: 'admin-1', email: 'admin@keywellness.co.bw' } } } }),
        getUser: async () => ({ data: { user: { id: 'admin-1', email: 'admin@keywellness.co.bw' } } }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
        signOut: async () => ({ error: null })
      }
    };
    window.supabase = { createClient: () => fakeSb };
  }, { orgs: ORGS, units: UNITS });

  await page.addInitScript(({ report, fin, breakdown }) => {
    window.__report = report; window.__fin = fin; window.__breakdown = breakdown;
    window.FIXED_REPORT    = JSON.parse(JSON.stringify(report));
    window.FIXED_FIN       = JSON.parse(JSON.stringify(fin));
    window.FIXED_BREAKDOWN = JSON.parse(JSON.stringify(breakdown));
    window.__adminOnly = false;   // flipped later to simulate a team-lead-only user
    window.__repFail   = false;   // one source failing while the other succeeds
    window.__finFail   = false;
    window.__indFail   = false;
  }, { report: REPORT, fin: FIN, breakdown: BREAKDOWN });

  // The indicator builder lives in Node so the fixture stays in one place.
  await page.addInitScript('window.__makeIndicators = ' + (function (mk) {
    return function (args) {
      return mk({
        org_id: args.p_org_id, start: args.p_start, end: args.p_end,
        unit_id: args.p_unit_id, client_safe: args.p_client_safe
      });
    };
  }).toString() + '(' + indicators.toString() + ');');

  await page.addInitScript(() => { window.__makeIndicatorsOrig = window.__makeIndicators; });
  await page.goto('file://' + path.resolve(__dirname, '..', 'admin.html'));
  await page.waitForTimeout(700);

  // ── Drill in from the organisations list ────────────────────
  await page.evaluate(() => { window.showTab('orgs'); });
  await page.waitForTimeout(400);

  const linkText = await page.evaluate(() => {
    const a = Array.from(document.querySelectorAll('a')).find(x => /openOrgAccount/.test(x.getAttribute('onclick') || ''));
    return a ? a.textContent.trim() : null;
  });
  check('the organisation name is a link into the account file', linkText === 'Test Co', String(linkText));

  await page.evaluate(() => { window.openOrgAccount(0); });
  await page.waitForTimeout(500);

  const body = () => page.evaluate(() => document.getElementById('page-content').innerText);

  let txt = await body();
  check('the account file opens on the chosen organisation', /Test Co/.test(txt));
  check('the header strip shows the cohort', /21/.test(txt) && /registered members/i.test(txt));
  check('and the participation share', /62%/.test(txt), txt.slice(0, 200));

  // ── The six, in two named rows ──────────────────────────────
  check('pressure-now row is present',    /pressure now/i.test(txt));
  check('future-exposure row is present', /future exposure/i.test(txt));
  const tiles = await page.evaluate(() =>
    Array.from(document.querySelectorAll('.card .stat-grid .stat-box')).length);
  check('exactly six headline tiles render', tiles === 6, 'tiles=' + tiles);

  check('a tile shows the share', /53\.8%/.test(txt), 'expected 7 of 13 = 53.8%');
  check('and its denominator, never a bare number', /7 of 13/.test(txt));

  // ── Movement rendering ──────────────────────────────────────
  check('a worsening indicator shows a rise', /▲\s*28\.8 pts/.test(txt), txt.match(/▲[^\n]*/g));
  check('an improving indicator shows a fall', /▼\s*34\.6 pts/.test(txt));
  check('a profile indicator says movement is unavailable rather than showing zero',
    /Movement not available/.test(txt));

  // ── Low base ────────────────────────────────────────────────
  check('a low-base figure is marked, not hidden, on the internal view',
    /low base/i.test(txt) && /No will in place/.test(txt));

  // ── Library table ───────────────────────────────────────────
  check('the library lists the wider set', /wider library/i.test(txt));
  check('the income dimension is relabelled, not called an income problem',
    /Reliance on a single income source/.test(txt) && !/income problem/i.test(txt));

  // ── Period change re-queries ────────────────────────────────
  const beforeCalls = await page.evaluate(() => window.__rpc.filter(r => r.fn === 'admin_org_indicators').length);
  await page.evaluate(() => { acctStart = '2026-01-01'; return window.renderOrgAccount(); });
  await page.waitForTimeout(400);
  const afterCalls = await page.evaluate(() => window.__rpc.filter(r => r.fn === 'admin_org_indicators').length);
  check('changing the period re-queries rather than filtering stale data', afterCalls > beforeCalls);
  const sentStart = await page.evaluate(() => {
    const c = window.__rpc.filter(r => r.fn === 'admin_org_indicators');
    return c[c.length - 1].args.p_start;
  });
  check('and sends the chosen start date', sentStart === '2026-01-01', sentStart);

  // ── Site scoping ────────────────────────────────────────────
  const unitOptions = await page.evaluate(() =>
    Array.from(document.querySelectorAll('select option')).map(o => o.textContent));
  check('the site picker offers the whole organisation first',
    unitOptions[0] === 'Whole organisation', JSON.stringify(unitOptions));
  check('sites read as company — site',
    unitOptions.includes('Head Office Co — Gaborone'), JSON.stringify(unitOptions));
  check('a closed site is still listed, and marked closed',
    unitOptions.some(o => /Lobatse \(closed\)/.test(o)), JSON.stringify(unitOptions));
  check('a company with sites is selectable here (unlike the advisor picker)',
    unitOptions.includes('Head Office Co'), JSON.stringify(unitOptions));

  await page.evaluate(() => { acctUnitId = 'unit-gabs'; return window.renderOrgAccount(); });
  await page.waitForTimeout(400);
  txt = await body();
  check('scoping to a site narrows the cohort shown', /\b5\b/.test(txt) && /Registered members/i.test(txt));
  const sentUnit = await page.evaluate(() => {
    const c = window.__rpc.filter(r => r.fn === 'admin_org_indicators');
    return c[c.length - 1].args.p_unit_id;
  });
  check('and passes the unit to the RPC', sentUnit === 'unit-gabs', String(sentUnit));

  // ── Client-safe ─────────────────────────────────────────────
  await page.evaluate(() => { acctUnitId = ''; acctSafe = true; return window.renderOrgAccount(); });
  await page.waitForTimeout(400);
  txt = await body();
  const sentSafe = await page.evaluate(() => {
    const c = window.__rpc.filter(r => r.fn === 'admin_org_indicators');
    return c[c.length - 1].args.p_client_safe;
  });
  check('the client-safe toggle reaches the RPC', sentSafe === true);
  check('a suppressed indicator says so instead of showing a count',
    /too small to report/i.test(txt));

  // ── The copy summary carries denominators and a warning ─────
  const summary = await page.evaluate(async () => {
    let captured = null;
    navigator.clipboard.writeText = async (t) => { captured = t; };
    acctSafe = false;
    await window.renderOrgAccount();
    await new Promise(r => setTimeout(r, 300));
    window.acctCopySummary();
    await new Promise(r => setTimeout(r, 100));
    return captured;
  });
  check('the copied summary states every denominator',
    /7 of 13/.test(summary || ''), (summary || '').slice(0, 160));
  check('and warns loudly when it is the internal, unsuppressed view',
    /INTERNAL view/.test(summary || ''));

  // ── Back out ────────────────────────────────────────────────
  await page.evaluate(() => window.orgSwitch('orgs'));
  await page.waitForTimeout(400);
  txt = await body();
  check('the back button returns to the organisations list',
    /Add an organisation/.test(txt));

  // Back on the account file — orgSwitch() above left the list showing.
  await page.evaluate(() => { acctPanel = 'issues'; return window.renderOrgAccount(); });
  await page.waitForTimeout(400);

  // ══ PANEL TABS ══════════════════════════════════════════════
  const tabLabels = await page.evaluate(() =>
    Array.from(document.querySelectorAll('button')).map(b => b.textContent.trim())
      .filter(t => /Presenting issues|Delivery|Wellbeing/.test(t)));
  check('all three panels are reachable',
    ['Presenting issues', 'Delivery', 'Wellbeing'].every(l => tabLabels.includes(l)),
    JSON.stringify(tabLabels));
  check('presenting issues is the panel that opens',
    tabLabels[0] === 'Presenting issues', JSON.stringify(tabLabels));

  // ══ PANEL 1 — DELIVERY ══════════════════════════════════════
  await page.evaluate(() => { acctPanel = 'delivery'; return window.renderOrgAccount(); });
  await page.waitForTimeout(400);
  txt = await body();

  check('delivery leads with booked, attended and reach',
    /12/.test(txt) && /sessions booked/i.test(txt)
    && /attended/i.test(txt) && /people reached/i.test(txt));
  check('the attendance rate is computed, not left to the reader',
    /67%/.test(txt), 'expected 8 of 12 = 67%');

  check('advisor-sourced and self-booked are split out',
    /Advisor-sourced[\s\S]{0,40}9 of 12/.test(txt) && /Self-booked[\s\S]{0,40}3 of 12/.test(txt),
    (txt.match(/Advisor-sourced[^\n]*\n?[^\n]*/) || [''])[0]);
  check('and the share is shown, not just the count',
    /9 of 12 · 75%/.test(txt));

  check('the per-advisor table names each advisor',
    /Kealeboga Gaseitsiwe/.test(txt) && /Retired Advisor/.test(txt));
  check('an advisor who has left is marked inactive rather than dropped',
    /inactive/i.test(txt));
  check('the per-advisor caveat says it ignores the site selector',
    /does not narrow to the selected/i.test(txt));

  check('group activity is listed', /Budgeting talk/.test(txt));
  check('and admits the themes are not captured yet',
    /not captured anywhere yet/i.test(txt));

  // The distinction the whole suppression design rests on.
  check('a withheld repeat-visit count renders as a dash, never as zero',
    /Seen three times or more[\s\S]{0,30}— of 7/.test(txt),
    (txt.match(/Seen three times or more[^\n]*\n?[^\n]*/) || [''])[0]);
  check('the suppression mismatch between the panels is stated on the page',
    /can legitimately disagree/i.test(txt));

  // ══ PANEL 2 — WELLBEING ═════════════════════════════════════
  await page.evaluate(() => { acctPanel = 'wellbeing'; return window.renderOrgAccount(); });
  await page.waitForTimeout(400);
  txt = await body();

  check('the engagement funnel runs registered → attended',
    /Registered[\s\S]{0,200}Completed assessment[\s\S]{0,200}Booked a session[\s\S]{0,200}Attended a session/.test(txt));
  check('a withheld funnel step is a dash, not a zero',
    /Used a tool[\s\S]{0,30}— of 21/.test(txt),
    (txt.match(/Used a tool[^\n]*\n?[^\n]*/) || [''])[0]);

  check('the dimension band table renders each assessed dimension',
    /debt/i.test(txt) && /emergency/i.test(txt) && /Under 50/i.test(txt));
  const bandCells = await page.evaluate(() => {
    const tr = Array.from(document.querySelectorAll('tr'))
      .find(r => /emergency/i.test(r.cells[0] ? r.cells[0].textContent : ''));
    return tr ? Array.from(tr.cells).map(c => c.textContent.trim()) : null;
  });
  check('a withheld band in the dimension table is a dash',
    !!bandCells && bandCells[3] === '—', JSON.stringify(bandCells));

  check('age bands are shown', /18–29/.test(txt) && /50\+/.test(txt));
  check('a withheld learning figure is a dash',
    /Watched a video:\s*—/.test(txt), (txt.match(/Watched a video:[^\n]*/) || [''])[0]);

  check('the financial position shows DTI, retirement and stress',
    /Debt-to-income/i.test(txt) && /Retirement readiness/i.test(txt) && /Financial stress/i.test(txt));
  check('with the medians', /22\.4/.test(txt) && /48/.test(txt) && /out of 10/.test(txt));
  check('a suppressed DTI band shows a dash rather than a count',
    /Over-indebted \(>45%\)[\s\S]{0,12}—/.test(txt),
    (txt.match(/Over-indebted[^\n]*\n?[^\n]*/) || [''])[0]);
  check('and the page says these three ignore the period and site selectors',
    /Whole organisation, as it stands today/i.test(txt));

  check('data coverage is stated so the reader can judge the numbers',
    /83\.3%/.test(txt) && /Assessment completion/i.test(txt));

  // ══ THE WRAPPED-CELL CONTRACT ═══════════════════════════════
  // org_report_data() returns { value, suppressed } objects, not numbers.
  // Reading one straight through prints [object Object] and computes NaN,
  // and — the part that matters — makes a withheld count indistinguishable
  // from a real one. Sweep every panel for the symptoms.
  for (const panel of ['delivery', 'wellbeing']) {
    await page.evaluate(p => { acctPanel = p; return window.renderOrgAccount(); }, panel);
    await page.waitForTimeout(350);
    const t = await body();
    const h = await page.evaluate(() => document.getElementById('page-content').innerHTML);
    check(panel + ': no unwrapped cell object reaches the page',
      !/\[object Object\]/.test(t), (t.match(/.{0,40}\[object Object\]/) || [''])[0]);
    check(panel + ': no NaN reaches the page',
      !/NaN/.test(h), (h.match(/.{0,60}NaN.{0,20}/) || [''])[0]);
    check(panel + ': no undefined reaches the page',
      !/\bundefined\b/.test(t), (t.match(/.{0,40}undefined/) || [''])[0]);
  }

  // A zero is a fact and must not borrow the withheld glyph.
  await page.evaluate(() => {
    window.__report = JSON.parse(JSON.stringify(window.__report));
    window.__report.learning.quizzes_passed = { value: 0, suppressed: false };
    acctPanel = 'wellbeing';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(350);
  txt = await body();
  check('a genuine zero renders as 0, not as the withheld dash',
    /Passed a quiz:\s*0\b/.test(txt), (txt.match(/Passed a quiz:[^\n]*/) || [''])[0]);

  // ══ CLIENT-SAFE MUST REACH THE UNSUPPRESSED SOURCE TOO ══════
  // advisor_session_breakdown() suppresses nothing of its own, so the
  // client-safe view has to do it here or the toggle is a false promise.
  await page.evaluate(() => {
    acctSafe = true; acctPanel = 'delivery';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  check('client-safe withholds the per-advisor table, which names staff',
    !/Kealeboga Gaseitsiwe/.test(txt) && /client-safe view/i.test(txt));
  check('and hides a count of one from the unsuppressed source',
    !/Declined by member:\s*1\b/.test(txt),
    (txt.match(/Declined by member:[^\n]*/) || [''])[0]);
  await page.evaluate(() => { acctSafe = false; });

  // ══ A COHORT TOO SMALL TO REPORT ════════════════════════════
  await page.evaluate(() => {
    window.__report = Object.assign({}, window.__report, { insufficient_cohort: true });
    acctPanel = 'wellbeing';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  check('an organisation under the floor says its detail is withheld',
    /withheld/i.test(txt) && /five-member floor/i.test(txt));
  check('but the whole-organisation financial position still renders',
    /Debt-to-income/i.test(txt), txt.slice(0, 300));

  await page.evaluate(() => { acctPanel = 'delivery'; return window.renderOrgAccount(); });
  await page.waitForTimeout(400);
  txt = await body();
  check('delivery withholds the same detail but keeps the advisor breakdown',
    /withheld/i.test(txt) && /Kealeboga Gaseitsiwe/.test(txt));

  await page.evaluate(() => {
    window.__report = Object.assign({}, window.__report, { insufficient_cohort: false });
  });

  // ══ ONE SOURCE FAILING, THE OTHER FINE ══════════════════════
  // The failure mode that reads as a fact: org_report_data() raises
  // (it validates the date range; advisor_session_breakdown() does not),
  // and the panel renders empty tables as though there were no sessions.
  await page.evaluate(() => {
    window.__repFail = true;
    acctPanel = 'delivery';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  check('one source failing is reported as a failure, not as empty data',
    /Engagement detail unavailable/i.test(txt), txt.slice(0, 300));
  check('and the panel keeps the half that did load',
    /Kealeboga Gaseitsiwe/.test(txt));

  await page.evaluate(() => { acctPanel = 'wellbeing'; return window.renderOrgAccount(); });
  await page.waitForTimeout(400);
  txt = await body();
  check('wellbeing keeps the financial position when only the report fails',
    /Debt-to-income/.test(txt) && /unavailable/i.test(txt));

  await page.evaluate(() => {
    window.__repFail = false; window.__finFail = true;
    acctPanel = 'wellbeing';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  check('and never shows an empty financial card under a footnote claiming it agrees',
    /Financial position unavailable/i.test(txt)
    && !/These three ignore the period/.test(txt), txt.slice(0, 300));
  await page.evaluate(() => { window.__finFail = false; });

  // ══ A TEAM LEAD WITHOUT ADMIN ═══════════════════════════════
  // admin_org_indicators() allows the advisory team lead; the two HR
  // reporting functions do not. The page has to degrade, not break.
  await page.evaluate(() => {
    window.__adminOnly = true;
    acctPanel = 'delivery';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  check('a team-lead-only user is told delivery needs admin access',
    /needs admin access/i.test(txt), txt.slice(0, 300));
  check('and is told the gap is a permission, not a claim that nothing happened',
    /not a claim that/i.test(txt));

  await page.evaluate(() => { acctPanel = 'wellbeing'; return window.renderOrgAccount(); });
  await page.waitForTimeout(400);
  txt = await body();
  check('and the same on wellbeing', /needs admin access/i.test(txt));

  await page.evaluate(() => { acctPanel = 'issues'; return window.renderOrgAccount(); });
  await page.waitForTimeout(400);
  txt = await body();
  check('while presenting issues still answers for them',
    /pressure now/i.test(txt) && /53\.8%/.test(txt));

  await page.evaluate(() => { window.__adminOnly = false; });

  // ══ WHAT THE SECOND REVIEW CAUGHT ═══════════════════════════

  // A null median with the unit appended outside the guard read
  // "Median —%" — the same bug acctPct exists to prevent.
  await page.evaluate(() => {
    window.__fin = JSON.parse(JSON.stringify(window.__fin));
    window.__fin.dti.median = null;
    acctPanel = 'wellbeing';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  check('a null median does not render as "Median —%"',
    !/Median —%/.test(txt) && !/Median — out of 10/.test(txt) && /Median —/.test(txt),
    (txt.match(/Median[^\n]*/g) || []).join(' | '));

  // The bands suppress a count of one; the median does not, and on a
  // thin population the median IS that person's own figure.
  await page.evaluate(() => {
    window.__fin = JSON.parse(JSON.stringify(window.__fin));
    window.__fin.dti.median = 71.5;
    window.__fin.dti.reported_count = 2;
    window.__fin.dti.bands = [{ key:'over_indebted', label:'Over-indebted (>45%)',
                                count: null, suppressed: true }];
    acctSafe = true;
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  check('client-safe hides a median computed over one or two people',
    !/71\.5/.test(txt), (txt.match(/Median[^\n]*/g) || []).join(' | '));

  await page.evaluate(() => {
    acctSafe = false;
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(300);
  txt = await body();
  check('but the internal view still shows it',
    /71\.5/.test(txt));

  // The footnote asserted the DTI bands agree with everything else,
  // printed underneath a card showing no bands at all.
  await page.evaluate(() => {
    window.__fin = { eligible: false, assessed_count: 3 };
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  check('an ineligible organisation drops the claim that the bands agree',
    !/These three ignore the period/.test(txt) && /Not enough assessed members/.test(txt));
  check('and points at the panel that can still answer the debt question',
    /has no floor/i.test(txt));
  await page.evaluate(() => { window.__fin = JSON.parse(JSON.stringify(FIXED_FIN)); });

  // ══ CLIENT-SAFE ON THE UNSUPPRESSED HEAD COUNTS ═════════════
  await page.evaluate(() => {
    window.__report = JSON.parse(JSON.stringify(window.__report));
    window.__report.kpi_summary.total_reach = 2;      // plain, never suppressed by the RPC
    window.__breakdown = JSON.parse(JSON.stringify(window.__breakdown));
    window.__breakdown.totals.self_booked = 2;        // half of a two-part split
    acctSafe = true; acctPanel = 'delivery';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  // stat-lbl is text-transform:uppercase, and innerText reflects that.
  check('client-safe hides a reach of two, which the RPC does not suppress',
    !/\b2\b[\s\S]{0,20}People reached/i.test(txt) && /People reached/i.test(txt),
    (txt.match(/[^\n]*People reached[^\n]*/) || [''])[0]);
  check('and does not leak it as a bar denominator',
    !/— of 2/.test(txt), (txt.match(/Seen once[^\n]*\n?[^\n]*/) || [''])[0]);
  check('hiding one half of a split hides the other, or it is a subtraction away',
    !/Self-booked[\s\S]{0,30}\b2 of\b/.test(txt)
    && !/Advisor-sourced[\s\S]{0,30}\b10 of\b/.test(txt),
    (txt.match(/Advisor-sourced[\s\S]{0,60}/) || [''])[0]);
  await page.evaluate(() => { acctSafe = false; });

  // ══ AN INDICATORS FAILURE MUST NOT BE SILENT ════════════════
  // The header tiles are drawn on every tab. Without this, a missing
  // Phase 1 migration reads as an organisation with nobody in it.
  await page.evaluate(() => {
    window.__indFail = true; acctPanel = 'delivery';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  check('an indicators failure is stated on the delivery tab too, not just its own',
    /Cohort figures unavailable/i.test(txt), txt.slice(0, 300));
  check('and says the dashes are a missing call, not a cohort of nobody',
    /not a cohort of nobody/i.test(txt));
  await page.evaluate(() => { window.__indFail = false; });

  // ══ A RENDER FAULT MUST NOT STRAND THE SPINNER ══════════════
  // The try/catch originally wrapped only the header, so a throw while
  // building a panel left "Loading account file…" up for good.
  await page.evaluate(() => {
    window.__report = JSON.parse(JSON.stringify(window.__report));
    window.__report.sessions.monthly_trend = 5;   // .map is not a function
    acctPanel = 'delivery';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(500);
  txt = await body();
  check('a throw while building a panel says so instead of hanging on the spinner',
    /could not be drawn/i.test(txt) && !/Loading account file/.test(txt),
    txt.slice(0, 200));
  await page.evaluate(() => {
    window.__report = JSON.parse(JSON.stringify(FIXED_REPORT));
    acctPanel = 'issues';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);

  // ══ THE COPIED TEXT IS WHAT REACHES A CLIENT REPORT ═════════
  const nullPct = await page.evaluate(async () => {
    let captured = null;
    navigator.clipboard.writeText = async (t) => { captured = t; };
    const orig = window.__makeIndicators;
    window.__makeIndicators = (args) => {
      const d = orig(args);
      d.headline[0].count = 0; d.headline[0].base = 0; d.headline[0].pct = null;
      return d;
    };
    await window.renderOrgAccount();
    await new Promise(r => setTimeout(r, 300));
    window.acctCopySummary();
    await new Promise(r => setTimeout(r, 100));
    window.__makeIndicators = orig;
    return captured;
  });
  check('a rate that cannot be computed is never copied out as "null%"',
    !/null%/.test(nullPct || ''),
    (nullPct || '').split('\n').filter(l => /Over-indebted/.test(l)).join(' | '));
  check('and says why there is no rate instead',
    /nothing to compute it over/.test(nullPct || ''));

  await page.evaluate(() => window.renderOrgAccount());
  await page.waitForTimeout(400);

  // ══ COMPLEMENTARY DISCLOSURE ════════════════════════════════
  // Six of these panels' figures are exact partitions of a total the
  // same page displays. Hiding one part of a partition hides nothing —
  // the reader subtracts. Every one of them has to hide as a set.
  await page.evaluate(() => {
    window.__report = JSON.parse(JSON.stringify(FIXED_REPORT));
    window.__breakdown = JSON.parse(JSON.stringify(FIXED_BREAKDOWN));
    // reach 17 = 10 + 5 + 2, with only the last cell suppressed by SQL.
    window.__report.kpi_summary.total_reach = 17;
    window.__report.session_intensity = { '1': { value: 10, suppressed: false },
                                          '2': { value: 5,  suppressed: false },
                                          '3_plus': { value: null, suppressed: true } };
    // reach 17 = 15 + 2, with the smaller half suppressed.
    window.__report.client_type_split = { member:    { value: 15,   suppressed: false },
                                          dependent: { value: null, suppressed: true } };
    // 13 assessed = 4 + 7 + 2, one band suppressed.
    window.__report.assessment_categories = { debt: {
      assessed_count: { value: 13, suppressed: false },
      band_under_50:  { value: 4,  suppressed: false },
      band_50_69:     { value: 7,  suppressed: false },
      band_70_plus:   { value: null, suppressed: true } } };
    // 20 attendees = 10 + 8 + 2, the last activity below the line.
    window.__report.program_activities = { total_activities: 3, total_attendees: 20,
      activities_list: [ { title:'A', activity_date:'2026-07-01', attendee_count:10,
                           activity_type:'talk', delivery_mode:'physical' },
                         { title:'B', activity_date:'2026-07-02', attendee_count:8,
                           activity_type:'talk', delivery_mode:'physical' },
                         { title:'C', activity_date:'2026-07-03', attendee_count:2,
                           activity_type:'talk', delivery_mode:'physical' } ] };
    // 12 booked = 10 + 2.
    window.__breakdown.totals.advisor_sourced = 10;
    window.__breakdown.totals.self_booked     = 2;
    acctSafe = true; acctPanel = 'delivery';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();

  check('client-safe hides a whole session-intensity partition, not one cell of it',
    !/\b10 of\b/.test(txt) && !/\b5 of\b/.test(txt),
    (txt.match(/Seen once[\s\S]{0,90}/) || [''])[0]);
  check('and the member / dependant split with it',
    !/Members:\s*15\b/.test(txt), (txt.match(/Members:[^\n]*/) || [''])[0]);
  check('and the advisor-sourced / self-booked split',
    !/Advisor-sourced[\s\S]{0,30}\b10 of\b/.test(txt),
    (txt.match(/Advisor-sourced[\s\S]{0,60}/) || [''])[0]);
  check('and the per-activity head counts, whose total stays on the page',
    !/\b10\b/.test(txt.split('Group and programme')[1] || ''),
    (txt.split('Group and programme')[1] || '').slice(0, 200));

  await page.evaluate(() => { acctPanel = 'wellbeing'; return window.renderOrgAccount(); });
  await page.waitForTimeout(400);
  txt = await body();
  check('and the dimension bands, which sum to the assessed count beside them',
    !/\b7\b/.test((txt.match(/debt[^\n]*/i) || [''])[0]),
    (txt.match(/debt[^\n]*/i) || [''])[0]);

  // The internal view is the one that is allowed to see everything.
  await page.evaluate(() => { acctSafe = false; return window.renderOrgAccount(); });
  await page.waitForTimeout(400);
  txt = await body();
  check('the internal view still shows every part it has',
    /\b7\b/.test((txt.match(/debt[^\n]*/i) || [''])[0]),
    (txt.match(/debt[^\n]*/i) || [''])[0]);

  // The header prints the same assessed population wellbeing withholds.
  await page.evaluate(() => {
    window.__makeIndicators = (args => {
      const orig = window.__makeIndicatorsOrig;
      return a => { const d = orig(a); d.cohort.assessed = 2; return d; };
    })();
    acctSafe = true; acctPanel = 'wellbeing';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  check('client-safe does not print an assessed count of two in the header',
    !/\b2\b[\s\S]{0,20}Have assessed/i.test(txt), (txt.match(/[^\n]*Have assessed[^\n]*/i) || [''])[0]);

  await page.evaluate(() => {
    window.__makeIndicators = window.__makeIndicatorsOrig;
    window.__report = JSON.parse(JSON.stringify(FIXED_REPORT));
    window.__breakdown = JSON.parse(JSON.stringify(FIXED_BREAKDOWN));
    acctSafe = false; acctPanel = 'issues';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);

  // One failure must not produce two error cards saying the same thing.
  await page.evaluate(() => {
    window.__indFail = true; acctPanel = 'issues';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  check('an indicators failure on its own tab is reported once, not twice',
    !(/Cohort figures unavailable/i.test(txt) && /Indicators unavailable/i.test(txt))
    && /unavailable/i.test(txt), txt.slice(0, 240));
  await page.evaluate(() => { window.__indFail = false; return window.renderOrgAccount(); });
  await page.waitForTimeout(300);

  // A withheld cohort must not be followed by a coverage card of dashes
  // that reads like missing data rather than withheld data.
  await page.evaluate(() => {
    window.__report = Object.assign({}, window.__report, { insufficient_cohort: true });
    acctPanel = 'wellbeing';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(400);
  txt = await body();
  check('a withheld cohort drops the coverage card rather than filling it with dashes',
    !/How much to trust this/i.test(txt) && /withheld/i.test(txt));
  await page.evaluate(() => {
    window.__report = JSON.parse(JSON.stringify(FIXED_REPORT));
    acctPanel = 'issues';
    return window.renderOrgAccount();
  });
  await page.waitForTimeout(300);

  check('no uncaught JavaScript errors from the account file',
    errors.filter(e => /acct|OrgAccount|indicator/i.test(e)).length === 0, errors.join(' | '));

  await browser.close();
  console.log('\n  ' + pass + ' passed, ' + fail + ' failed.\n');
  process.exit(fail ? 1 : 0);
})();
