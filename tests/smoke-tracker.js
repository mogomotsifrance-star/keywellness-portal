/* Key Wellness — headless checks for the Expense Tracker's category model
   (Phase D.2).

   What this guards:

     · ONE category list. The tracker carried its own 13 expense and 5 income
       categories, which did not match the budget's. A member who logged daily
       spending and kept a budget had two category models and no way to compare
       them: "Education" here was "Child / Education" there, one "Savings"
       bucket here was six lines there, "Family & Gifts" was two;
     · the migration runs client-side and is idempotent per PAYLOAD, not per
       device — the Supabase restore overwrites localStorage wholesale, so a
       row written before D.2 can land on a device that has already migrated;
     · a transaction is NEVER dropped. An id the map does not know keeps its id
       and reads as "Uncategorised (was: …)". Losing a member's logged spending
       to a category rename is not an acceptable failure;
     · the per-category budget map is remapped too. Remapping the transactions
       and leaving it behind would strand a member's limits;
     · the dropdown floats the member's six most-used to the top. The tracker is
       the one tool used daily, on a phone, and the shared list has 28 expense
       categories where this page had 13.

   Usage:  node tests/smoke-tracker.js
*/
const { chromium } = require('playwright');
const path = require('path');
const url = require('url');

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name); }
  else    { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}

const PAGE = url.pathToFileURL(path.resolve(__dirname, '..', 'expense_tracker.html')).href;
const UID = 'u1';
const LS = 'expense_tracker_v2';
const thisMonth = new Date().toISOString().slice(0, 7);
const CDN_NOISE = /jsdelivr|cdnjs|Chart|jspdf|autotable|fonts/i;

/* A payload in the OLD shape: pre-D.2 ids, no stamp. */
const legacy = (over) => Object.assign({
  transactions: { [thisMonth]: [
    { id:1, type:'expense', desc:'Groceries',  amount:800,  category:'food',      date:thisMonth + '-03', note:'' },
    { id:2, type:'expense', desc:'School fees',amount:1200, category:'education', date:thisMonth + '-04', note:'' },
    { id:3, type:'expense', desc:'Loan',       amount:900,  category:'debt',      date:thisMonth + '-05', note:'' },
    { id:4, type:'expense', desc:'Stokvel',    amount:400,  category:'savings',   date:thisMonth + '-06', note:'' },
    { id:5, type:'expense', desc:'To mum',     amount:600,  category:'family',    date:thisMonth + '-07', note:'' },
    { id:6, type:'expense', desc:'Bits',       amount:150,  category:'other',     date:thisMonth + '-08', note:'' },
  ] },
  budgets: { food: 1000, education: 1500, debt: 900, family: 700 },
  nextId: 7,
}, over || {});

function boot(page, payload, toolRow) {
  return page.addInitScript(({ payload, toolRow, uid, LS }) => {
    try {
      Object.keys(localStorage).filter(k => /^kw_|^expense_tracker/.test(k))
        .forEach(k => localStorage.removeItem(k));
      if (payload) localStorage.setItem(LS, JSON.stringify(payload));
    } catch (_) {}
    window.__writes = [];
    const chain = (table, op, p) => {
      const settle = () => Promise.resolve({ data: [], error: null });
      const c = {
        eq: () => c, in: () => c, or: () => c, order: () => c, limit: () => c, select: () => c,
        maybeSingle: async () => ({
          data: table === 'profiles' ? { id: uid, first_name: 'Neo' }
              : table === 'tool_data' ? (toolRow ? { data: toolRow } : null) : null,
          error: null }),
        single: async () => ({ data: null, error: null }),
        then: (r, j) => settle().then(r, j),
        catch: (f) => settle().catch(f),
        finally: (f) => settle().finally(f),
      };
      if (table === 'tool_data' && (op === 'upsert' || op === 'update')) window.__writes.push(p);
      return c;
    };
    window.supabase = { createClient: () => ({
      from: (t) => ({ select: () => chain(t, 'select'), insert: (p) => chain(t, 'insert', p),
                      update: (p) => chain(t, 'update', p), upsert: (p) => chain(t, 'upsert', p),
                      delete: () => chain(t, 'delete') }),
      rpc: async () => ({ data: null, error: null }),
      auth: {
        getSession: async () => ({ data: { session: { user: { id: uid, email: 'm@e.com' } } } }),
        getUser: async () => ({ data: { user: { id: uid, email: 'm@e.com' } }, error: null }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      } }) };
  }, { payload, toolRow, uid: UID, LS });
}

async function open(browser, payload, toolRow) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => { if (!CDN_NOISE.test(String(e))) errors.push(String(e)); });
  await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
  await boot(page, payload, toolRow);
  await page.goto(PAGE);
  await page.waitForTimeout(1400);
  return { page, errors };
}

const stored = (page) => page.evaluate((LS) => JSON.parse(localStorage.getItem(LS) || 'null'), LS);
const catsOf = (d) => (d.transactions[Object.keys(d.transactions)[0]] || []).map(t => t.category);

(async () => {
  const browser = await chromium.launch();

  /* ── 1. The two lists become one ─────────────────────────────── */
  {
    const { page, errors } = await open(browser, legacy());
    const out = await page.evaluate(() => ({
      catCount: CATEGORIES.length,
      sameAsBudget: CATEGORIES === KW_ALL_CATS,
      names: CATEGORIES.map(c => c.name),
      income: INCOME_CATS.map(c => c.id),
    }));
    check('1  the tracker reads the shared model, not its own list',
      out.sameAsBudget === true && out.catCount === 28, `${out.catCount} categories`);
    check('2  so the budget-only lines are available to log against',
      ['Farm costs (moraka & masimo)', 'Family support', 'Contributions', 'Money motshelo']
        .every(n => out.names.includes(n)), out.names.join(', ').slice(0, 200));
    check('3  the five income categories are kept',
      ['salary','business','rental','freelance','other_in'].every(id => out.income.includes(id)),
      out.income.join(','));
    check('4  and the two recognised ones are added, with the budget ids',
      out.income.includes('farm_income') && out.income.includes('motshelo_payout'),
      out.income.join(','));
    check('5  no uncaught errors', errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ── 2. The migration ────────────────────────────────────────── */
  {
    const { page } = await open(browser, legacy());
    const d = await stored(page);
    check('6  education becomes the budget\'s Child / Education',
      catsOf(d).includes('childcare'), catsOf(d).join(','));
    check('7  debt becomes minimum debt payments',
      catsOf(d).includes('debt_min'), catsOf(d).join(','));
    check('8  savings becomes goal savings',
      catsOf(d).includes('goals'), catsOf(d).join(','));
    check('9  family defaults to family support',
      catsOf(d).includes('family_support'), catsOf(d).join(','));
    check('10 other becomes miscellaneous',
      catsOf(d).includes('misc'), catsOf(d).join(','));
    check('11 and food, which is the same in both, is untouched',
      catsOf(d).filter(c => c === 'food').length === 1, catsOf(d).join(','));
    check('12 every transaction survives — none is dropped',
      (d.transactions[thisMonth] || []).length === 6,
      String((d.transactions[thisMonth] || []).length));
    await page.close();
  }
  {
    /* The per-category budget map is keyed by the same ids. */
    const { page } = await open(browser, legacy());
    const d = await stored(page);
    check('13 the per-category budgets are remapped too',
      d.budgets.childcare === 1500 && d.budgets.debt_min === 900
      && d.budgets.family_support === 700, JSON.stringify(d.budgets));
    check('14 and the old keys are gone',
      !('education' in d.budgets) && !('debt' in d.budgets) && !('family' in d.budgets),
      JSON.stringify(d.budgets));
    await page.close();
  }
  {
    /* Two old ids landing on one new one must add, not overwrite. */
    const { page } = await open(browser, legacy({ budgets: { food: 1000, other: 200, misc: 50 } }));
    const d = await stored(page);
    check('15 two ids landing on one add up rather than overwriting',
      d.budgets.misc === 250, JSON.stringify(d.budgets));
    await page.close();
  }

  /* ── 3. Idempotent, and per payload rather than per device ───── */
  {
    const { page } = await open(browser, legacy());
    const first = await stored(page);
    await page.reload();
    await page.waitForTimeout(1200);
    const second = await stored(page);
    check('16 the migration is stamped', first.catModel === 'phase-d', String(first.catModel));
    check('17 and a second load changes nothing',
      JSON.stringify(catsOf(first)) === JSON.stringify(catsOf(second)),
      catsOf(first).join(',') + '  vs  ' + catsOf(second).join(','));
    await page.close();
  }
  {
    /* An unmigrated Supabase row landing on a migrated device. This is the
       case the stamp has to be on the payload for: the restore overwrites
       localStorage wholesale. */
    const migratedLocal = Object.assign(legacy(), { catModel: 'phase-d' });
    migratedLocal.transactions[thisMonth] = [
      { id:9, type:'expense', desc:'Bread', amount:20, category:'food', date:thisMonth+'-01', note:'' }];
    const { page } = await open(browser, migratedLocal, legacy());
    const d = await stored(page);
    check('18 an unmigrated row from Supabase is migrated when it lands',
      !catsOf(d).includes('education') && catsOf(d).includes('childcare'),
      catsOf(d).join(','));
    await page.close();
  }

  /* ── 4. An unknown id is kept, visibly ───────────────────────── */
  {
    const odd = legacy();
    odd.transactions[thisMonth].push(
      { id:7, type:'expense', desc:'Mystery', amount:75, category:'zzz_legacy', date:thisMonth+'-09', note:'' });
    const { page } = await open(browser, odd);
    const d = await stored(page);
    const body = await page.evaluate(() => document.body.textContent);
    check('19 an id the map does not know is never dropped',
      (d.transactions[thisMonth] || []).some(t => t.category === 'zzz_legacy'),
      catsOf(d).join(','));
    check('20 nor silently filed under Other',
      (d.transactions[thisMonth] || []).filter(t => t.category === 'misc').length === 1,
      catsOf(d).join(','));
    check('21 and reads as what it is',
      /Uncategorised \(was: zzz_legacy\)/.test(body), '(label not found)');
    await page.close();
  }

  /* ── 5. The family question ──────────────────────────────────── */
  {
    const { page } = await open(browser, legacy());
    const m = await page.evaluate(() => {
      const el = document.getElementById('kw-family-modal');
      return { open: !!el, text: el ? el.textContent.replace(/\s+/g, ' ') : '' };
    });
    check('22 a member with family entries is asked, once',
      m.open === true, '(no modal)');
    check('23 and the question names both destinations',
      /Family support/.test(m.text) && /Giving/.test(m.text), m.text.slice(0, 200));

    await page.evaluate(() => document.getElementById('kwf-giving').click());
    await page.waitForTimeout(400);
    const d = await stored(page);
    check('24 answering Giving moves those entries',
      catsOf(d).includes('gifts') && !catsOf(d).includes('family_support'),
      catsOf(d).join(','));
    check('25 and moves the budget with them',
      d.budgets.gifts === 700 && !('family_support' in d.budgets), JSON.stringify(d.budgets));
    check('26 the answer is stored, so it is not asked twice',
      d.familyTo === 'gifts', String(d.familyTo));
    await page.close();
  }
  {
    /* Nobody else is asked. */
    const noFamily = legacy({ budgets: {} });
    noFamily.transactions[thisMonth] = noFamily.transactions[thisMonth].filter(t => t.category !== 'family');
    const { page } = await open(browser, noFamily);
    const asked = await page.evaluate(() => !!document.getElementById('kw-family-modal'));
    check('27 a member with no family entries is not asked', asked === false, 'modal shown');
    await page.close();
  }
  {
    /* Not answering leaves the approved default in place. */
    const { page } = await open(browser, legacy());
    const d = await stored(page);
    check('28 an unanswered question leaves family support, the approved default',
      catsOf(d).includes('family_support'), catsOf(d).join(','));
    await page.close();
  }

  /* ── 6. The dropdown ─────────────────────────────────────────── */
  {
    const { page } = await open(browser, legacy());
    const sel = await page.evaluate(() => {
      const s = document.getElementById('txCategory');
      return {
        groups: [...s.querySelectorAll('optgroup')].map(g => g.label),
        firstGroup: [...(s.querySelector('optgroup')?.children || [])].map(o => o.value),
        total: s.querySelectorAll('option').length,
      };
    });
    check('29 the member\'s most-used float to the top',
      sel.groups[0] === 'Most used', sel.groups.join(' | '));
    check('30 with the rest grouped as the budget groups them',
      ['Needs','Wants','Savings & Investments','Other'].every(g => sel.groups.includes(g)),
      sel.groups.join(' | '));
    check('31 every category is offered, none lost to the shortlist',
      sel.total === 28, String(sel.total));
    check('32 an unknown id is not offered as a choice',
      !sel.firstGroup.includes('zzz_legacy'), sel.firstGroup.join(','));
    await page.close();
  }
  {
    /* Income keeps its own flat list. */
    const { page } = await open(browser, legacy());
    const inc = await page.evaluate(() => {
      window.setType('income');
      const s = document.getElementById('txCategory');
      return { ids: [...s.querySelectorAll('option')].map(o => o.value),
               groups: s.querySelectorAll('optgroup').length };
    });
    check('33 income is a flat list of seven', inc.ids.length === 7 && inc.groups === 0,
      inc.ids.join(','));
    check('34 including farm income and motshelo payout',
      inc.ids.includes('farm_income') && inc.ids.includes('motshelo_payout'), inc.ids.join(','));
    await page.close();
  }

  /* ── 7. Colour and icon come from the group ──────────────────── */
  {
    const { page } = await open(browser, legacy());
    const c = await page.evaluate(() => ({
      housing: catColor('housing'), food: catColor('food'),
      dining: catColor('dining'), emfund: catColor('emfund'),
      icon: catIcon('housing'),
    }));
    check('35 two Needs share the group colour', c.housing === c.food, `${c.housing} vs ${c.food}`);
    check('36 and a Want does not', c.dining !== c.housing, `${c.dining} vs ${c.housing}`);
    check('37 nor does a Saving', c.emfund !== c.housing && c.emfund !== c.dining,
      `${c.emfund}`);
    check('38 an icon comes back for every line', !!c.icon, String(c.icon));
    await page.close();
  }

  await browser.close();
  console.log(`\n  ${pass} passed, ${fail} failed.`);
  process.exit(fail ? 1 : 0);
})();
