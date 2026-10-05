/* Key Wellness — employer.html renders the HR suppression shapes cleanly.

   Written for the P0 stop-gap (5 Oct 2026), kept for Batch 1. Feeds the HR
   dashboard the payloads org_overview / org_financial_indicators /
   org_stress_summary return to an employer, and checks the page shows the
   "not enough data" paths with no NaN, null or undefined anywhere, and no
   figure the stop-gap is meant to withhold.

   Usage:  node tests/smoke-employer-hr.js [page-root]
     page-root defaults to the repo. Pass a checkout of main to test what the
     live site will render against the same payloads.
*/
const { chromium } = require('playwright');
const path = require('path');
const url = require('url');

const ROOT = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const PAGE = url.pathToFileURL(path.join(ROOT, 'employer.html')).href;

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name); }
  else    { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}

const DIMS = [
  { dimension: 'savings', avg: 28.7 }, { dimension: 'income', avg: 31 },
  { dimension: 'emergency', avg: 33.6 }, { dimension: 'retirement', avg: 39.6 },
  { dimension: 'spending', avg: 52.6 }, { dimension: 'insurance', avg: 53.2 },
  { dimension: 'goals', avg: 60.1 }, { dimension: 'debt', avg: 61.2 }];

function overview(o) {
  return Object.assign({
    suppressed: false,
    summary: { n_employees: 25, participation_pct: 56, avg_score: 44.2, engaged_not_scored: 2 },
    completeness: { suppressed: false, none: 11, some: 7, most: 7, n: 25, label: 'x' },
    funnel: { signed_up: 25, completed_assessment: 14, did_checkin: 5 },
    distribution: { suppressed: true, assessed_count: 14, struggling: null, coping: null, thriving: null },
    dimensions: { suppressed: false, items: DIMS, focus_dimension: 'savings' },
    distress: { suppressed: false, pct_low_emergency_fund: 53.8, n_assessed: 13, label: 'x' },
    trend: [{ period: '2026 Q2', avg_score: 46.4, participants: 12, suppressed: false },
            { period: '2026 Q3', avg_score: null, participants: null, suppressed: true }]
  }, o || {});
}

/* Counts only. A = Test Co as its HR login received it after the stop-gap,
   read back live on 5 Oct 2026. B = Sedimosa's shape after the stop-gap
   (its HR login is an admin, so this is the employer view built from the
   same rules). C = the pre-stop-gap leak, as a control: proves the checks
   below can see the figures they say are gone. */
const CASES = {
  'A stop-gap, Test Co live payload': {
    overview: overview(),
    fin: { eligible: false, assessed_count: 14, withheld: 'small_cells' },
    stress: { insufficient_cohort: true }
  },
  'B stop-gap, Sedimosa shape': {
    overview: overview({
      summary: { n_employees: 78, participation_pct: 16.7, avg_score: 54.7, engaged_not_scored: 0 },
      funnel: { signed_up: 78, completed_assessment: 13, did_checkin: null },
      distribution: { suppressed: true, assessed_count: 13, struggling: null, coping: null, thriving: null },
      distress: { suppressed: true, pct_low_emergency_fund: null, n_assessed: 13, label: 'x' }
    }),
    fin: { eligible: false, assessed_count: 13, withheld: 'small_cells' },
    stress: { insufficient_cohort: true, withheld: 'small_cells' }
  },
  'C control, pre-stop-gap leak': {
    overview: overview({
      distribution: { suppressed: false, assessed_count: 13,
        struggling: { label: 'Struggling (0–39)', count: 2, pct: 15.4 },
        coping:     { label: 'Coping (40–64)',    count: 7, pct: 53.8 },
        thriving:   { label: 'Thriving (65–100)', count: 4, pct: 30.8 } }
    }),
    fin: { eligible: true, assessed_count: 13,
      dti: { reported_count: 10, median: 36.5, bands: [
        { key: 'healthy', label: 'Healthy', count: 6, suppressed: false },
        { key: 'manageable', label: 'Manageable', count: null, suppressed: true },
        { key: 'strained', label: 'Strained', count: 0, suppressed: false },
        { key: 'over_indebted', label: 'Overindebted', count: 3, suppressed: false }] },
      retirement: { reported_count: 13, median: 50, bands: [
        { key: 'excellent', label: 'Excellent', count: 0, suppressed: false },
        { key: 'good', label: 'Good', count: null, suppressed: true },
        { key: 'fair', label: 'Fair', count: 4, suppressed: false },
        { key: 'needs_work', label: 'Needs Work', count: 5, suppressed: false },
        { key: 'critical', label: 'Critical', count: 3, suppressed: false }] },
      stress: { reported_count: 1, median: 5, bands: [
        { key: 'low', label: 'Low', count: 0, suppressed: false },
        { key: 'moderate', label: 'Moderate', count: null, suppressed: true },
        { key: 'high', label: 'High', count: 0, suppressed: false }] } },
    stress: { insufficient_cohort: true }
  }
};

function installStub(page, payload) {
  return page.addInitScript((payload) => {
    const q = (table) => {
      const chain = {
        select: () => chain, eq: () => chain, or: () => chain, order: () => chain,
        limit: () => chain, in: () => chain, gte: () => chain, lte: () => chain,
        maybeSingle: async () => {
          if (table === 'employers')     return { data: { org_id: 'org-1' }, error: null };
          if (table === 'organizations') return { data: { name: 'Test Org' }, error: null };
          return { data: null, error: null };
        },
        single: async () => ({ data: null, error: null }),
        then: (res) => res({ data: [], error: null })
      };
      return chain;
    };
    const fake = {
      from: (t) => q(t),
      rpc: async (fn) => {
        if (fn === 'org_overview')             return { data: payload.overview, error: null };
        if (fn === 'org_financial_indicators') return { data: payload.fin, error: null };
        if (fn === 'org_stress_summary')       return { data: payload.stress, error: null };
        return { data: null, error: null };
      },
      auth: {
        getSession: async () => ({ data: { session: { user: { id: 'u1', email: 'hr@example.test' } } } }),
        getUser: async () => ({ data: { user: { id: 'u1', email: 'hr@example.test' } } }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
        signOut: async () => ({ error: null })
      }
    };
    window.supabase = { createClient: () => fake };
    // Chart.js is a CDN script (aborted below, unreachable in CI anyway).
    // The cards under test do not depend on it; a stub keeps the trend chart
    // from throwing after the cards have rendered.
    window.Chart = function () { return { destroy() {}, update() {} }; };
  }, payload);
}

(async () => {
  console.log('page: ' + PAGE);
  const browser = await chromium.launch();
  const seen = {};
  for (const [name, payload] of Object.entries(CASES)) {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
    await page.route('**cdn.jsdelivr.net/npm/chart.js**', r => r.abort());
    await installStub(page, payload);
    await page.goto(PAGE);
    await page.waitForFunction(() => document.querySelectorAll('#page-content .card').length > 2, null, { timeout: 8000 })
      .catch(() => {});
    const text = await page.evaluate(() => document.getElementById('page-content').innerText);
    seen[name] = text;
    const tag = name.split(' ')[0];

    check(tag + ' no page errors', errors.length === 0, errors.join(' | '));
    check(tag + ' no NaN / null / undefined', !/\bNaN\b|\bnull\b|\bundefined\b/.test(text),
      (text.match(/.{0,40}\b(NaN|null|undefined)\b.{0,40}/) || [''])[0]);
    check(tag + ' dashboard rendered', /Enrolled Employees/i.test(text));

    if (tag === 'C') {
      check('C control: leak is visible pre-stop-gap (Struggling 2 employees, stress median)',
        /2 employees/.test(text) && /Median Financial Stress/i.test(text));
      continue;
    }
    check(tag + ' Debt Health withheld', /Debt Health[\s\S]{0,40}Data appears once 5\+ employees/.test(text));
    check(tag + ' Retirement withheld', /Retirement Readiness[\s\S]{0,40}Data appears once 5\+ employees/.test(text));
    check(tag + ' no median tiles', !/Median (Financial Stress|Retirement Readiness|Debt|DTI)/i.test(text));
    check(tag + ' distribution withheld', /Workforce Distribution[\s\S]{0,20}Appears once at least 3/.test(text)
      && !/Struggling \(0/.test(text));
    check(tag + ' stress card shows not-enough-data', /Not enough check-in data yet/.test(text));
    if (tag === 'B') check('B emergency-fund tile hidden when withheld', !/46\.2%/.test(text));
    if (tag === 'A') check('A emergency-fund tile kept when safe', /53\.8%/.test(text));
    await page.close();
  }
  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
