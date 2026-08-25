/* Key Wellness — headless checks for the advisor add-client organisation
   picker (Phase 0a).

   Loads the real advisor.html in Chromium with a stubbed Supabase client,
   then drives the picker the way an advisor would and inspects the exact
   payload that would be sent to advisor_clients.

   The stub satisfies the boot sequence (session, advisor_me, the role
   probe), so the page reaches its normal signed-in state before the
   picker is driven.

   Usage:  node tests/smoke-picker.js
*/
const { chromium } = require('playwright');
const path = require('path');

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name); }
  else    { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}

// Mirrors what advisor_org_options() returns: two orgs, one with sites,
// one without. The closed company and orphan site are already excluded
// server-side, which the SQL suite asserts separately.
// The bands exactly as supabase_org_account_phase0.sql seeds them.
const DTI_FIXTURE = {
  flag_band: 'over_indebted',
  bands: [
    { key:'healthy',       max:20,   label:'Healthy (under 20%)'   },
    { key:'manageable',    max:35,   label:'Manageable (20–34.9%)' },
    { key:'strained',      max:45,   label:'Strained (35–44.9%)'   },
    { key:'over_indebted', max:null, label:'Over-indebted (45%+)'  }
  ]
};

const ORG_FIXTURE = [
  { org_id: 'org-bopeu', name: 'BOPEU', units: [] },
  { org_id: 'org-sed',   name: 'Sedimosa', units: [
      { id: 'unit-gabs', label: 'Head Office Co — Gaborone' },
      { id: 'unit-fran', label: 'Head Office Co — Francistown' }
  ]}
];

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));

  /* advisor.html loads supabase-js from jsdelivr in <head>. The stub below is
     installed by addInitScript before page scripts run, but the CDN library
     lands afterwards and overwrites window.supabase — the page then builds a
     REAL client and bounces to index.html. The suite only passed when the CDN
     was unreachable. Block it so the stub is authoritative either way. */
  await page.route('**cdn.jsdelivr.net/npm/@supabase/**', route => route.abort());

  // Stub the Supabase client before any page script runs, and capture
  // every insert so the payload can be asserted.
  await page.addInitScript(({ orgs, dti }) => {
    window.__inserted = [];
    window.__dtiConfig = dti;
    window.__rpcCalls = [];
    const table = () => ({
      insert(payload) {
        window.__inserted.push(payload);
        const chain = {
          select: () => chain,
          single: async () => ({
            data: { id: 'new-client-id', member_user_id: null, org_id: payload.org_id },
            error: null
          })
        };
        return chain;
      },
      select: () => {
        const q = {
          __table: null,
          eq: () => q, or: () => q,
          maybeSingle: async () => ({ data: null, error: null }),
          single: async () => ({ data: null, error: null }),
          then: (res) => res({ data: [], error: null })
        };
        return q;
      },
      update: () => ({ eq: async () => ({ error: null }) }),
      delete: () => ({ eq: async () => ({ error: null }) })
    });
    const fakeSb = {
      from: (name) => {
        const t = table();
        if (name === 'threshold_config') {
          t.select = () => ({
            eq: () => ({
              maybeSingle: async () => ({ data: { value: window.__dtiConfig }, error: null })
            })
          });
        }
        return t;
      },
      rpc: async (fn) => {
        window.__rpcCalls.push(fn);
        if (fn === 'advisor_org_options') return { data: window.__orgs || orgs, error: null };
        if (fn === 'advisor_me') return { data: {
          id: 'advisor-1', full_name: 'Test Advisor',
          email: 'adv@keywealth.co.bw', title: 'Advisor', is_team_lead: false
        }, error: null };
        if (fn === 'advisor_clients_list') return { data: [], error: null };
        return { data: null, error: null };
      },
      auth: {
        getSession: async () => ({ data: { session: {
          user: { id: 'user-1', email: 'adv@keywealth.co.bw' }
        } } }),
        getUser: async () => ({ data: {
          user: { id: 'user-1', email: 'adv@keywealth.co.bw' } } }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } })
      }
    };
    window.supabase = { createClient: () => fakeSb };
  }, { orgs: ORG_FIXTURE, dti: DTI_FIXTURE });

  await page.goto('file://' + path.resolve(__dirname, '..', 'advisor.html'));
  await page.waitForTimeout(700);

  // The page boots against the stub; these keep the assertions focused on
  // the picker rather than on list rendering and navigation.
  await page.evaluate(() => {
    window.loadClients = async () => {};
    window.openClient  = () => {};
    window.showBanner  = (m) => { window.__banner = m; };
  });

  // ── The picker fills ────────────────────────────────────────
  await page.evaluate(() => window.openNewClientModal());
  await page.waitForTimeout(200);

  const orgOptions = await page.$$eval('#nc-org option', els =>
    els.map(e => ({ value: e.value, text: e.textContent })));
  check('picker lists both organisations plus a prompt', orgOptions.length === 3,
    JSON.stringify(orgOptions));
  check('the prompt has no value, so nothing is pre-selected',
    orgOptions[0].value === '');

  // ── Sites appear only where they exist ──────────────────────
  const hiddenForNoUnits = await page.evaluate(() => {
    document.getElementById('nc-org').value = 'org-bopeu';
    window.ncOrgChanged();
    return document.getElementById('nc-unit-wrap').hidden;
  });
  check('an organisation with no sites hides the site picker', hiddenForNoUnits === true);

  const unitState = await page.evaluate(() => {
    document.getElementById('nc-org').value = 'org-sed';
    window.ncOrgChanged();
    return {
      hidden: document.getElementById('nc-unit-wrap').hidden,
      options: Array.from(document.querySelectorAll('#nc-unit option')).map(o => o.textContent)
    };
  });
  check('an organisation with sites shows them', unitState.hidden === false);
  check('sites carry the company — site label',
    unitState.options.includes('Head Office Co — Gaborone'), JSON.stringify(unitState.options));
  check('"whole organisation" stays available as a choice',
    unitState.options[0].indexOf('whole organisation') !== -1);

  // ── Private client and organisation are mutually exclusive ──
  const exclusive = await page.evaluate(() => {
    document.getElementById('nc-noorg').checked = true;
    window.ncNoOrgChanged();
    return {
      orgDisabled: document.getElementById('nc-org').disabled,
      orgValue:    document.getElementById('nc-org').value,
      unitHidden:  document.getElementById('nc-unit-wrap').hidden
    };
  });
  check('ticking private client disables the organisation picker', exclusive.orgDisabled === true);
  check('and clears whatever was chosen', exclusive.orgValue === '');
  check('and hides the site picker', exclusive.unitHidden === true);

  // ── Neither chosen: refuse, with a useful message ───────────
  const refused = await page.evaluate(async () => {
    document.getElementById('nc-noorg').checked = false;
    window.ncNoOrgChanged();
    document.getElementById('nc-name').value = 'Test';
    document.getElementById('nc-org').value = '';
    window.__inserted = []; window.__banner = '';
    await window.createClientRecord();
    return { inserted: window.__inserted.length, banner: window.__banner };
  });
  check('no organisation and not private → nothing is inserted', refused.inserted === 0);
  check('and the advisor is told what to do',
    /organisation/i.test(refused.banner) && /private/i.test(refused.banner), refused.banner);

  // ── A private client sends the declared flag ────────────────
  const privatePayload = await page.evaluate(async () => {
    document.getElementById('nc-name').value = 'Private';
    document.getElementById('nc-noorg').checked = true;
    window.ncNoOrgChanged();
    window.__inserted = [];
    await window.createClientRecord();
    return window.__inserted[0];
  });
  check('private client sends no_org true', privatePayload && privatePayload.no_org === true);
  check('private client sends a null organisation', privatePayload && privatePayload.org_id === null);
  check('private client sends a null site', privatePayload && privatePayload.org_unit_id === null);

  // ── An attributed client sends organisation and site ────────
  const orgPayload = await page.evaluate(async () => {
    window.openNewClientModal();
    await new Promise(r => setTimeout(r, 150));
    document.getElementById('nc-name').value = 'Attributed';
    document.getElementById('nc-org').value = 'org-sed';
    window.ncOrgChanged();
    document.getElementById('nc-unit').value = 'unit-gabs';
    window.__inserted = [];
    await window.createClientRecord();
    return window.__inserted[0];
  });
  check('attributed client sends the organisation', orgPayload && orgPayload.org_id === 'org-sed');
  check('attributed client sends the site', orgPayload && orgPayload.org_unit_id === 'unit-gabs');
  check('attributed client sends no_org false', orgPayload && orgPayload.no_org === false);

  // ── Whole-organisation attribution ──────────────────────────
  const wholeOrg = await page.evaluate(async () => {
    window.openNewClientModal();
    await new Promise(r => setTimeout(r, 150));
    document.getElementById('nc-name').value = 'Whole';
    document.getElementById('nc-org').value = 'org-sed';
    window.ncOrgChanged();
    document.getElementById('nc-unit').value = '';   // whole organisation
    window.__inserted = [];
    await window.createClientRecord();
    return window.__inserted[0];
  });
  check('choosing no site attributes at organisation level',
    wholeOrg && wholeOrg.org_id === 'org-sed' && wholeOrg.org_unit_id === null);

  // ── Reopening resets, so the last client does not leak ──────
  const reset = await page.evaluate(async () => {
    window.openNewClientModal();
    await new Promise(r => setTimeout(r, 150));
    return {
      name:  document.getElementById('nc-name').value,
      org:   document.getElementById('nc-org').value,
      noorg: document.getElementById('nc-noorg').checked
    };
  });
  check('reopening the form clears the previous client',
    reset.name === '' && reset.org === '' && reset.noorg === false, JSON.stringify(reset));

  // ── The picker is not cached, so a new company appears ──────
  const refetch = await page.evaluate(async () => {
    window.__orgs = [
      { org_id: 'org-bopeu', name: 'BOPEU', units: [] },
      { org_id: 'org-sed',   name: 'Sedimosa', units: [
          { id: 'unit-gabs', label: 'Head Office Co — Gaborone' }] },
      { org_id: 'org-new',   name: 'Newly Onboarded Co', units: [] }
    ];
    window.openNewClientModal();
    await new Promise(r => setTimeout(r, 200));
    return Array.from(document.querySelectorAll('#nc-org option')).map(o => o.textContent);
  });
  check('an organisation added mid-session appears without a page reload',
    refetch.includes('Newly Onboarded Co'), JSON.stringify(refetch));

  const rpcCount = await page.evaluate(() =>
    window.__rpcCalls.filter(f => f === 'advisor_org_options').length);
  check('the options are re-fetched each time the form opens, not cached once',
    rpcCount > 1, 'advisor_org_options called ' + rpcCount + ' time(s)');

  // ── DTI bands come from threshold_config ────────────────────
  const bands = await page.evaluate(() =>
    [12, 19.9, 20, 34.9, 35, 44.9, 45, 50, 81.3].map(d => ({
      dti: d, band: window.kwDtiBand(d), flagged: window.kwIsOverIndebted(d)
    })));
  const bandOf = d => (bands.find(b => b.dti === d) || {}).band;
  check('12% bands healthy',                 bandOf(12)   === 'healthy');
  check('20% bands manageable',              bandOf(20)   === 'manageable');
  check('34.9% is still manageable',         bandOf(34.9) === 'manageable');
  check('35% bands strained',                bandOf(35)   === 'strained');
  check('44.9% is still strained',           bandOf(44.9) === 'strained');
  check('45% bands over-indebted (inclusive boundary, matches SQL)',
    bandOf(45) === 'over_indebted');
  check('81.3% bands over-indebted',         bandOf(81.3) === 'over_indebted');

  const flags = d => (bands.find(b => b.dti === d) || {}).flagged;
  check('44.9% is not flagged for debt', flags(44.9) === false);
  check('45% is flagged for debt',       flags(45)   === true);
  check('50% is flagged — the reading that changes for advisors',
    flags(50) === true);

  // ── diagDebt renders from those bands ───────────────────────
  const diag = await page.evaluate(() =>
    [25, 40, 50].map(dti => {
      const d = window.diagDebt({ dti: dti, totalIncome: 30000, capacity35: 1000 });
      return { dti: dti, color: d.color, label: d.label };
    }));
  check('25% shows green Manageable',
    diag[0].color === 'green'  && diag[0].label === 'Manageable', JSON.stringify(diag[0]));
  check('40% shows orange Strained',
    diag[1].color === 'orange' && diag[1].label === 'Strained',   JSON.stringify(diag[1]));
  check('50% shows red Over-indebted (was gold "Acceptable")',
    diag[2].color === 'red'    && diag[2].label === 'Over-indebted', JSON.stringify(diag[2]));

  // The activity report flags anything not green; that line must stay at 35%.
  check('the activity-report flag line stays at 35%',
    diag[0].color === 'green' && diag[1].color !== 'green');

  // ── A failed threshold fetch must not blank the diagnostic ──
  const fallback = await page.evaluate(() => {
    const saved = window.KW_DTI;
    window.KW_DTI = null;                       // simulate the fetch failing
    const d = window.diagDebt({ dti: 50, totalIncome: 30000, capacity35: 1000 });
    window.KW_DTI = saved;
    return { color: d.color, label: d.label };
  });
  check('a failed threshold fetch degrades to the same numbers, not a blank',
    fallback.color === 'red' && fallback.label === 'Over-indebted', JSON.stringify(fallback));

  check('no uncaught JavaScript errors from the picker',
    errors.filter(e => /nc-|ncOrg|ncNoOrg|OrgPicker|createClientRecord|kwDti|diagDebt|loadThresholds/.test(e)).length === 0,
    errors.join(' | '));

  await browser.close();
  console.log('\n  ' + pass + ' passed, ' + fail + ' failed.\n');
  process.exit(fail ? 1 : 0);
})();
