/* ================================================================
   Key Wellness: household attribution (advisor portal)

   Who pays a budget line, who is liable for a loan, and the two views
   worked out from those answers. Pure functions: no DOM, no storage.
   Edge twin: clientOnly() in supabase/functions/_shared/kw-finance.ts.
   Change both together; tests/household.test.mjs holds them equal.

   Every key is optional. Absent means client / 100 / client / disabled,
   so a record saved before 23 Nov 2026 reads exactly as it always did.

   Attributions ALWAYS apply. household.enabled decides only whether the
   Household column and the report tick are shown (gate, 23 Nov 2026).
   income.spouseIncome is legacy and read by no calculation.
   ================================================================ */
(function (g) {
  'use strict';

  function num(v) {
    var n = parseFloat(String(v === null || v === undefined ? '' : v).replace(/[,P\s]/g, ''));
    return isFinite(n) ? n : 0;
  }
  function payer(v) { return v === 'spouse' || v === 'shared' ? v : 'client'; }
  function split(v) {
    if (v === null || v === undefined || v === '') return 50;
    var n = Number(v);
    return isFinite(n) ? Math.min(100, Math.max(0, n)) : 50;
  }
  function blank(v) { return v === null || v === undefined || String(v).trim() === ''; }

  // Attribution of one budget category, defaults applied.
  function paidBy(c, cat) {
    var p = ((c && c.budgetPaidBy) || {})[cat] || {};
    var by = payer(p.by);
    return { by: by, split: by === 'shared' ? split(p.split) : by === 'spouse' ? 0 : 100, setAt: p.setAt || null };
  }
  // What the client pays of a category. A 100% share returns the amount
  // untouched, so nothing moves by a rounding step on an old record.
  function clientAmount(c, cat) {
    var amt = num(((c && c.budget) || {})[cat]), s = paidBy(c, cat).split;
    return s === 100 ? amt : amt * s / 100;
  }
  function loan(r) {
    r = r || {};
    var by = payer(r.paidBy);
    return {
      liable: r.liable === 'spouse' || r.liable === 'joint' ? r.liable : 'client',
      paidBy: by,
      paidSplit: by === 'shared' ? split(r.paidSplit) : by === 'spouse' ? 0 : 100
    };
  }
  function isSpouseOnly(r) { return loan(r).liable === 'spouse'; }
  function isLive(r) {
    return !!(num(r.balance) || num(r.monthlyInstalment) || num(r.loanAmount) || !blank(r.institution));
  }
  // The loans every computed figure reads: client or joint, whoever pays.
  function clientLoans(c) { return ((c && c.liabilities) || []).filter(function (r) { return !isSpouseOnly(r); }); }

  // A loan only the spouse is liable for keeps its name and instalment and
  // nothing else (gate, conflict 3).
  function stripSpouseLoan(r) {
    r.institution = ''; r.loanAmount = 0; r.interestRate = ''; r.balance = null; r.termMonths = null;
    delete r._termError;
    return r;
  }
  function household(c) {
    var h = (c && c.household) || {};
    return { enabled: h.enabled === true, spouseContribution: blank(h.spouseContribution) ? null : num(h.spouseContribution) };
  }
  function normalise(c) {
    var pb = {};
    Object.keys((c && c.budget) || {}).forEach(function (k) { pb[k] = paidBy(c, k); });
    return {
      household: household(c), budgetPaidBy: pb,
      liabilities: ((c && c.liabilities) || []).map(function (r) { return Object.assign({}, r, loan(r)); })
    };
  }

  /* The two views. `net` is the client's net salary, worked out by the page
     from its own PAYE table. debt_min is left out of expenses here: loans are
     counted once, from their instalments (gate, conflict 1). The budget's own
     surplus in calcTotals() is a different figure and is unchanged.
     The household object carries no ratio of any kind. Do not add one. */
  function householdViews(c, net) {
    var inc = (c && c.income) || {}, budget = (c && c.budget) || {};
    var gross = num(inc.monthlySalary);
    var passive = num(inc.rentals) + num(inc.businessIncome) + num(inc.dividends);
    var cats = Object.keys(budget).filter(function (k) { return k !== 'debt_min'; });
    var live = ((c && c.liabilities) || []).filter(isLive);
    var sum = function (rows) { return rows.reduce(function (s, r) { return s + num(r.monthlyInstalment); }, 0); };

    var own = live.filter(function (r) { return !isSpouseOnly(r); });
    var iInc = num(net) + passive, basis = gross + passive;
    var iExp = cats.reduce(function (s, k) { return s + clientAmount(c, k); }, 0), iDebt = sum(own);
    var individual = {
      income: iInc, expenses: iExp, debtService: iDebt,
      dsr: basis > 0 ? iDebt / basis * 100 : null, dsrBasis: basis,
      surplus: iInc - iExp - iDebt,
      loans: own.map(function (r) { var l = loan(r); return { item: r.item, instalment: num(r.monthlyInstalment), liable: l.liable, paidBy: l.paidBy }; })
    };
    var h = household(c), hh = null;
    if (h.enabled) {
      var hInc = iInc + (h.spouseContribution || 0);
      var hExp = cats.reduce(function (s, k) { return s + num(budget[k]); }, 0), hDebt = sum(live);
      hh = { income: hInc, expenses: hExp, debtService: hDebt, surplus: hInc - hExp - hDebt };
    }
    return { individual: individual, household: hh };
  }

  g.KWHousehold = {
    paidBy: paidBy, clientAmount: clientAmount, loan: loan, isSpouseOnly: isSpouseOnly, isLive: isLive,
    clientLoans: clientLoans, stripSpouseLoan: stripSpouseLoan, household: household,
    normalise: normalise, householdViews: householdViews
  };
})(typeof window !== 'undefined' ? window : globalThis);
