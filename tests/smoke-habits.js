/* Key Wellness — headless checks for the habits check (P0-3).

   wellness_assessment.html had no automated coverage, and P0-3 removed all
   sixteen Pula fields from it and rewrote how every dimension is scored. The
   assertions here are the ones that would let a regression through quietly:

     · no Pula field survives, and nothing is required except the MCQs;
     · the assessments INSERT keeps its exact shape (user_id, score, cat_scores,
       answers, created_at) — HR's "assessed" count and the whole reporting
       chain read that row, so its shape is a contract, not an implementation
       detail;
     · a missing figure scores as UNKNOWN, not zero. This is the whole point of
       the change: the old formulas blended an MCQ with a ratio, so a member who
       skipped the optional fields was told they were "Critical" on dimensions
       they had never answered (audit F10). Two ways that can come back — the
       score itself, and a results screen that prints "0.0%" or "P 0" — are both
       asserted;
     · the page writes NO financial column to profiles. Those columns are the
       prefill source for DTI, Retirement, Goals and Affordability, so writing
       nulls here would blank whatever the member's budget had filled in.

   Usage:  node tests/smoke-habits.js
*/
const { chromium } = require('playwright');
const path = require('path');
const url = require('url');

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name); }
  else    { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}

const PAGE = url.pathToFileURL(path.resolve(__dirname, '..', 'wellness_assessment.html')).href;
const UID = 'u1';

/* Same CDN note as every other suite here: supabase-js from jsdelivr would
   overwrite this stub and the page would talk to production. jsPDF is left
   reachable — exportPDF is exercised below and degrades without it. */
function installStub(page, { profile = {}, prevAssessment = null } = {}) {
  return page.addInitScript(({ profile, prevAssessment, uid }) => {
    try { localStorage.removeItem('kw_assessment_v2'); localStorage.removeItem('kw_assessment_result'); } catch (_) {}
    window.__inserts = [];   // assessments rows
    window.__updates = [];   // profiles patches
    window.__profile = profile;

    const chain = (table, op, payload) => {
      const c = {
        eq: () => c, in: () => c, order: () => c, limit: () => c, select: () => c,
        maybeSingle: async () => ({
          data: table === 'profiles' ? window.__profile : table === 'emergency_fund' ? null : null,
          error: null }),
        single: async () => ({ data: payload || {}, error: null }),
        then: (res) => res({
          data: table === 'assessments' ? (prevAssessment ? [prevAssessment] : []) : [],
          error: null }),
      };
      if (table === 'assessments' && op === 'insert') window.__inserts.push(payload);
      if (table === 'profiles'    && op === 'update') window.__updates.push(payload);
      return c;
    };
    const fake = {
      from: (t) => ({
        select: () => chain(t, 'select'), insert: (p) => chain(t, 'insert', p),
        update: (p) => chain(t, 'update', p), upsert: (p) => chain(t, 'upsert', p),
        delete: () => chain(t, 'delete'),
      }),
      rpc: async () => ({ data: null, error: null }),
      auth: {
        getSession: async () => ({ data: { session: { user: { id: uid, email: 'm@example.com' } } } }),
        getUser: async () => ({ data: { user: { id: uid, email: 'm@example.com' } }, error: null }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      },
    };
    window.supabase = { createClient: () => fake };
  }, { profile, prevAssessment, uid: UID });
}

/* CDN scripts (jsPDF, its autotable plugin) are unreachable in an offline run,
   and their absence surfaces as a pageerror that says nothing about this change.
   Filter those out so the "no uncaught errors" checks stay meaningful. */
const CDN_NOISE = /jspdf|autotable|Chart|jsdelivr|cdnjs/i;

async function boot(browser, opts) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => { if (!CDN_NOISE.test(String(e))) errors.push(String(e)); });
  await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
  await installStub(page, opts);
  await page.goto(PAGE);
  await page.waitForFunction(() => typeof window.calculateWellness === 'function', null, { timeout: 10000 });
  await page.waitForTimeout(400);
  return { page, errors };
}

/* Answer every MCQ at a chosen level and tick `covers` insurance boxes.
   level 'low' picks the worst option, 'high' the best. */
async function answerAll(page, level, covers) {
  return page.evaluate(({ level, covers }) => {
    const qs = [...new Set([...document.querySelectorAll('.mcq-opt[data-q]')].map(o => o.dataset.q))];
    qs.forEach(q => {
      const opts = [...document.querySelectorAll(`.mcq-opt[data-q="${q}"]`)]
        .sort((a, b) => Number(a.dataset.val) - Number(b.dataset.val));
      const pick = level === 'low' ? opts[0] : opts[opts.length - 1];
      if (pick) pick.click();
    });
    [...document.querySelectorAll('.mcq-opt[data-ins]')].slice(0, covers).forEach(el => el.click());
    return qs;
  }, { level, covers });
}

(async () => {
  const browser = await chromium.launch();

  /* ── 1. The form itself ───────────────────────────────────────── */
  {
    const { page, errors } = await boot(browser, {});

    const form = await page.evaluate(() => {
      const ids = ['grossSalary','netSalary','otherIncome','expenses','totalSavings','monthlySavings',
        'emergencyFund','essentialExpenses','totalDebtPayments','totalDebtBalance','retirementBalance',
        'monthlyPension','age','retireAge','totalAssets','totalLiabilities'];
      return {
        survivors: ids.filter(id => !!document.getElementById(id)),
        grids: document.querySelectorAll('.form-grid').length,
        prefixes: document.querySelectorAll('.input-prefix').length,
        decimals: [...document.querySelectorAll('input')].filter(i => i.inputMode === 'decimal').length,
        // The scored behaviour questions, excluding the optional estate screen.
        mcqCount: new Set([...document.querySelectorAll('.mcq-opt[data-q]')].map(o => o.dataset.q))
          .size - new Set([...document.querySelectorAll('#stepEstate .mcq-opt[data-q]')].map(o => o.dataset.q)).size,
        insBoxes: document.querySelectorAll('.mcq-opt[data-ins]').length,
        required: Object.values(window.STEP_REQUIRED || {}).flatMap(r => r.fields || []),
        intro: document.getElementById('habitsIntro')?.textContent || '',
        later: !!document.getElementById('doThisLater'),
        laterHref: document.getElementById('doThisLater')?.getAttribute('href'),
        estate: !!document.getElementById('stepEstate'),
      };
    });
    check('1  every Pula field is gone', form.survivors.length === 0, form.survivors.join(', '));
    check('2  and so is every numeric form grid', form.grids === 0 && form.prefixes === 0 && form.decimals === 0,
      `grids=${form.grids} prefixes=${form.prefixes} decimals=${form.decimals}`);
    check('3  no step requires a field any more', form.required.length === 0, JSON.stringify(form.required));
    /* "Eleven questions" in the intro copy = these ten scored MCQs plus the
       six-box insurance checklist, which the member meets as one more screen.
       The four estate questions sit after the progress bar and are optional. */
    check('4  the ten scored behaviour questions survive', form.mcqCount === 10, String(form.mcqCount));
    check('5  the insurance checklist survives', form.insBoxes === 6, String(form.insBoxes));
    check('6  and the estate screen', form.estate === true);
    check('7  the intro promises three minutes and no numbers',
      /Three minutes, no numbers/.test(form.intro) && /Eleven questions/.test(form.intro), form.intro.trim().slice(0, 80));
    check('8  "Do this later" returns to the dashboard without saving',
      form.later && form.laterHref === 'index.html#dashboard', String(form.laterHref));

    /* Step 1 advances on the MCQ alone — it used to demand three figures. */
    const advanced = await page.evaluate(() => {
      document.querySelector('.mcq-opt[data-q="incomeStability"]')?.click();
      window.nextStep(0);
      return document.getElementById('step1')?.classList.contains('active');
    });
    check('9  step 1 advances with no figure entered', advanced === true);
    check('10 no uncaught errors rendering the form', errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ── 2. Scoring: an unknown figure is not a zero ──────────────── */
  {
    const { page, errors } = await boot(browser, {});
    await answerAll(page, 'high', 6);
    await page.evaluate(() => window.calculateWellness());
    await page.waitForTimeout(500);

    const res = await page.evaluate(() => ({
      r: window._wellnessResult,
      inserts: window.__inserts,
      updates: window.__updates,
      cached: JSON.parse(localStorage.getItem('kw_assessment_result') || 'null'),
    }));

    check('11 the run is detected as habits-only', res.r?.habitsOnly === true);
    /* The heart of it: best possible answers must score 100, not ~50. Under the
       old blended formulas the missing figures would drag every dimension to
       roughly half even with perfect behaviour. */
    check('12 perfect answers score 100, not half of it', res.r?.totalScore === 100, String(res.r?.totalScore));
    const dims = Object.fromEntries((res.r?.dims || []).map(d => [d.id, d.score]));
    check('13 every dimension is full marks, none dragged down by an absent figure',
      Object.values(dims).every(v => v === 100), JSON.stringify(dims));
    check('14 no figure is invented — they are null, not 0',
      res.r?.totalIncome === null && res.r?.netWorth === null && res.r?.emMonths === null &&
      res.r?.savingsRate === null && res.r?.dti_pct === null && res.r?.savRate === null,
      JSON.stringify({ i: res.r?.totalIncome, n: res.r?.netWorth, e: res.r?.emMonths }));

    /* The INSERT contract HR reporting depends on. */
    check('15 exactly one assessments row is inserted', res.inserts.length === 1, String(res.inserts.length));
    const row = res.inserts[0] || {};
    check('16 and its shape is unchanged: user_id, score, cat_scores, answers, created_at',
      JSON.stringify(Object.keys(row).sort()) ===
      JSON.stringify(['answers','cat_scores','created_at','score','user_id']), JSON.stringify(Object.keys(row)));
    check('17 cat_scores still carries all eight dimensions plus _insCount',
      ['income','savings','emergency','debt','retirement','insurance','goals','spending','_insCount']
        .every(k => k in (row.cat_scores || {})), JSON.stringify(Object.keys(row.cat_scores || {})));
    check('18 answers are flagged _habits_only for the dashboard score gate',
      row.answers?._habits_only === true);

    /* The profile write. */
    const patch = res.updates[0] || {};
    check('19 the profile write carries the score', patch.last_score === 100 && !!patch.last_cat_scores);
    const FIN = ['gross_income','net_income','other_income','monthly_income','monthly_expenses',
      'essential_expenses','total_assets','total_liabilities','monthly_debt','total_debt_balance',
      'total_savings','monthly_savings','net_is_manual','fin_updated_at'];
    const wrote = FIN.filter(k => k in patch);
    check('20 and NO financial column at all — not even as null', wrote.length === 0, wrote.join(', '));

    /* The cache the dashboard and EF planner read. */
    check('21 the cached result omits figure keys rather than zeroing them',
      !('savingsRate' in res.cached) && !('dti' in res.cached) &&
      !('emMonths' in res.cached) && !('netWorth' in res.cached) && !('figures' in res.cached),
      JSON.stringify(Object.keys(res.cached || {})));
    check('22 and carries the starting point for the dashboard',
      Array.isArray(res.cached?.startingPoint) && res.cached.startingPoint.length >= 1 &&
      res.cached.habitsOnly === true);
    check('23 no uncaught errors scoring a habits run', errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ── 3. The results screen states nothing it was not told ─────── */
  {
    const { page, errors } = await boot(browser, {});
    await answerAll(page, 'low', 0);
    await page.evaluate(() => window.calculateWellness());
    await page.waitForTimeout(600);

    const view = await page.evaluate(() => {
      const vis = id => {
        const el = document.getElementById(id);
        return !!el && getComputedStyle(el).display !== 'none';
      };
      return {
        startingPoint: vis('startingPointCard'), scoreCard: vis('scoreCard'), strip: vis('summaryStrip'),
        spText: document.getElementById('startingPointText')?.textContent || '',
        results: document.getElementById('stepResults')?.textContent || '',
        dimHeading: document.getElementById('dimGridHeading')?.textContent || '',
        bars: document.querySelectorAll('#dimGrid .dim-row').length,
        cta: [...document.querySelectorAll('#stepResults a')].map(a => a.textContent.trim()),
      };
    });
    check('24 the results lead with "Your starting point", not a score ring',
      view.startingPoint === true && view.scoreCard === false);
    check('25 the Savings Rate / DTI / Net Worth / Emergency Cover strip is hidden',
      view.strip === false);
    check('26 the starting point is 2–3 written sentences',
      view.spText.split('.').filter(x => x.trim()).length >= 2 && view.spText.length > 60,
      view.spText.slice(0, 90));
    /* No Pula anywhere on a page built from behaviour answers. */
    check('27 not one Pula figure appears in the results',
      !/P\s?[\d,]+(\.\d\d)?/.test(view.results) && !/\bP0\b/.test(view.results),
      (view.results.match(/P\s?[\d,]+(\.\d\d)?/g) || []).slice(0, 5).join(' | '));
    check('28 and no percentage is asserted about a figure',
      !/\d+\.\d%/.test(view.results), (view.results.match(/\d+\.\d%/g) || []).join(' | '));
    check('29 the dimension bars survive, labelled as habits',
      view.bars === 8 && /habits/i.test(view.dimHeading), `${view.bars} / ${view.dimHeading}`);
    check('30 the closing button goes to the dashboard',
      view.cta.some(t => /Go to my dashboard/.test(t)), JSON.stringify(view.cta));

    /* The worst possible answers must not produce a "Critical" verdict built
       on figures nobody gave. */
    check('31 the lowest answers are not graded "Critical"', !/Critical/.test(view.results));

    /* exportPDF walks the same figures — it must not throw on nulls. */
    const pdf = await page.evaluate(() => {
      try { window.exportPDF(); return 'ok'; } catch (e) { return String(e); }
    });
    /* jsPDF loads from cdnjs, which the offline test run cannot reach, so "ok"
       is not always available. What must never happen is a throw from reading a
       figure that habits mode left null — that is the regression this guards. */
    const pdfLibMissing = /jspdf/i.test(pdf) && /undefined/i.test(pdf);
    check('32 exportPDF does not throw on a null figure',
      pdf === 'ok' || pdfLibMissing, pdf);
    if (pdfLibMissing) console.log('      (jsPDF unreachable offline — asserted no null-figure throw instead)');
    check('33 no uncaught errors on the results screen', errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ── 4. Re-check mode still works with the fields removed ─────── */
  {
    const { page, errors } = await boot(browser, {
      profile: { id: UID, age: 40, gross_income: 20000, net_income: 16000 },
      prevAssessment: { id: 'a1', user_id: UID, score: 55, cat_scores: {}, answers: { savingsHabit: 2 }, created_at: '2026-06-01T00:00:00Z' },
    });
    await page.waitForTimeout(600);

    const re = await page.evaluate(() => ({
      isRe: window._isReassessment === true,
      h1: document.querySelector('.header h1')?.textContent || '',
      banner: document.querySelector('#step0 .card div')?.textContent || '',
      body: document.body.textContent,
    }));
    check('34 a member with a prior assessment is in re-check mode', re.isRe === true);
    check('35 which no longer promises to source figures it will not ask for',
      !/re-enter numbers/i.test(re.body), re.banner.slice(0, 90));

    await answerAll(page, 'high', 3);
    await page.evaluate(() => window.calculateWellness());
    await page.waitForTimeout(500);
    const reRes = await page.evaluate(() => ({
      r: window._wellnessResult, updates: window.__updates, inserts: window.__inserts,
    }));
    check('36 re-check scores without throwing on the removed fields',
      typeof reRes.r?.totalScore === 'number' && reRes.r.habitsOnly === true, JSON.stringify(reRes.r?.totalScore));
    check('37 and still writes no financial column, so the budget is not blanked',
      !('gross_income' in (reRes.updates[0] || {})) && !('net_income' in (reRes.updates[0] || {})));
    check('38 the assessments row keeps its shape on a re-check too',
      JSON.stringify(Object.keys(reRes.inserts[0] || {}).sort()) ===
      JSON.stringify(['answers','cat_scores','created_at','score','user_id']));
    check('39 no uncaught errors in re-check mode', errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ── 5. Scoring maths, spelled out ────────────────────────────── */
  {
    const { page } = await boot(browser, {});
    /* Deliberate mixed answers, so each formula is pinned to a specific value
       rather than to the all-100 case where every formula agrees. */
    const scores = await page.evaluate(() => {
      const pick = (q, v) => document.querySelector(`.mcq-opt[data-q="${q}"][data-val="${v}"]`)?.click();
      pick('incomeStability', 1);        // 1/3        → 33
      pick('savingsHabit', 2);           // 2/3        → 67
      pick('emergencyMonths', 1);        // 1/4        → 25
      pick('debtMgmt', 3);               // 3/3        → 100
      pick('retirementEngagement', 0);   // 0/3        → 0
      pick('insuranceConfidence', 3);
      pick('goalsClarity', 3); pick('goalsTracking', 0);   // .6*1 + .4*0 → 60
      pick('spendingHabits', 3); pick('netWorthReview', 0); // .7*1 + .3*0 → 70
      [...document.querySelectorAll('.mcq-opt[data-ins]')].slice(0, 2).forEach(el => el.click());
      window.calculateWellness();
      return Object.fromEntries(window._wellnessResult.dims.map(d => [d.id, d.score]));
    });
    check('40 income  = incomeStability/3',            scores.income === 33, String(scores.income));
    check('41 savings = savingsHabit/3',               scores.savings === 67, String(scores.savings));
    check('42 emergency = emergencyMonths/4',          scores.emergency === 25, String(scores.emergency));
    check('43 debt = debtMgmt/3',                      scores.debt === 100, String(scores.debt));
    check('44 retirement = retirementEngagement/3',    scores.retirement === 0, String(scores.retirement));
    check('45 goals unchanged: .6 clarity + .4 tracking', scores.goals === 60, String(scores.goals));
    check('46 spending = .7 habits + .3 review',       scores.spending === 70, String(scores.spending));
    /* insurance keeps its checklist half: min(2/4,1)*.5 + 3/3*.5 = .75 */
    check('47 insurance keeps the cover checklist',    scores.insurance === 75, String(scores.insurance));
    /* A zero retirement score must mean "answered: none", never "no figure". */
    check('48 a 0 means the member answered so, not that a figure was missing',
      scores.retirement === 0 && scores.debt === 100,
      'both come from answers, so 0 and 100 are equally earned');
    await page.close();
  }

  /* ── 6. A strength is not also an instruction ──────────────────
     The results screen could print "Strength: Emergency Fund — this is the
     habit you already have" and, in the action plan below, "Start an emergency
     fund". The strength rule lived in buildInsights and the action list simply
     iterated every dimension, so the two never consulted each other.

     Driven directly against buildInsights/buildActions with a synthetic dims
     array: it pins the rule itself rather than one route through the form. */
  {
    const { page, errors } = await boot(browser, {});
    const probe = await page.evaluate(() => {
      /* Emergency clearly the strongest, everything else below it. */
      const dims = [
        { id:'emergency',  label:'Emergency Fund',  score: 90 },
        { id:'income',     label:'Income',          score: 40 },
        { id:'savings',    label:'Savings',         score: 35 },
        { id:'debt',       label:'Debt',            score: 30 },
        { id:'retirement', label:'Retirement',      score: 25 },
        { id:'goals',      label:'Goals',           score: 20 },
        { id:'spending',   label:'Spending',        score: 15 },
        { id:'insurance',  label:'Insurance',       score: 10 },
      ];
      const d = { habitsOnly: true, insCount: 3, essentialExp: 1 };
      return {
        strengthId: window.habitsStrengthId(dims),
        insights: window.buildInsights(dims, d).map(i => i.title),
        actions:  window.buildActions(dims, d).map(a => a.title),
        /* Nothing clears 60: no strength, so every dimension keeps its action. */
        noneHigh: (() => {
          const flat = dims.map(x => ({ ...x, score: 30 }));
          return { strengthId: window.habitsStrengthId(flat),
                   actions: window.buildActions(flat, d).map(a => a.title) };
        })(),
      };
    });
    check('49 the strongest habit above 60 is named the strength',
      probe.strengthId === 'emergency', JSON.stringify(probe.strengthId));
    check('50 and the insights say so',
      probe.insights.some(t => /Strength: Emergency Fund/.test(t)), JSON.stringify(probe.insights));
    check('51 while the action plan no longer tells them to start one',
      !probe.actions.includes('Start an emergency fund'), JSON.stringify(probe.actions));
    check('52 every other dimension keeps its action',
      probe.actions.length === 7, JSON.stringify(probe.actions));
    check('53 with nothing above 60 there is no strength to contradict',
      probe.noneHigh.strengthId === null, JSON.stringify(probe.noneHigh.strengthId));
    check('54 so the emergency action comes back',
      probe.noneHigh.actions.includes('Start an emergency fund'), JSON.stringify(probe.noneHigh.actions));
    check('55 no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }
  {
    /* And once through the real form, so the wiring is proven too. All-high
       answers make the last-sorted dimension a strength. */
    const { page } = await boot(browser, {});
    await answerAll(page, 'high', 6);
    await page.evaluate(() => window.calculateWellness());
    await page.waitForTimeout(600);
    const seen = await page.evaluate(() => {
      const txt = document.getElementById('stepResults')?.textContent || '';
      const m = txt.match(/Strength:\s*([A-Za-z &]+?)\s*This is the habit/);
      return { strengthLabel: m ? m[1].trim() : null,
               actions: [...document.querySelectorAll('#stepResults .action-title, #stepResults h4')]
                          .map(n => n.textContent.trim()),
               text: txt };
    });
    const contradictions = [
      ['Emergency Fund', 'Start an emergency fund'],
      ['Debt Management', 'List every debt in one place'],
      ['Savings',         'Move savings to payday, not month end'],
    ];
    const clash = contradictions.find(([label, act]) =>
      seen.strengthLabel && seen.strengthLabel.includes(label) && seen.text.includes(act));
    check('56 through the real form, no action contradicts the printed strength',
      !clash, JSON.stringify({ strength: seen.strengthLabel, clash }));
    await page.close();
  }

  await browser.close();
  console.log(`\n  ${pass} passed, ${fail} failed.`);
  process.exit(fail ? 1 : 0);
})();
