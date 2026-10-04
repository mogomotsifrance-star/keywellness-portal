// Key Wellness — Advance Recommendation: deterministic computation
// ============================================================
// Every number that appears in an Advance Recommendation Report comes
// from THIS file, never from the language model. The model receives the
// output of compute() and writes prose around it; it cannot change a
// figure, a classification or the risk tier. That is what makes a
// recommendation auditable: the same input snapshot always yields the
// same numbers, and both are stored with the report.
//
// Pure module: no I/O, no Date.now(). Runs unchanged under
// Deno (Edge Function) and Node 22 (tests/advance-recommendation.test.mjs).
//
// Mirrors advisor.html exactly where the two overlap:
//   - PAYE: calcAnnualTax() / calcMonthlyPAYE() (annualised-earnings method)
//   - Total monthly income: net salary + spouse + rentals + business + dividends
//     (disposable income and the budget check use this: it is the cash)
//   - DSR: debt repayments ÷ the client's OWN gross salary (4 Oct 2026)
//   - "Live" liability filter: panelReport()'s liabData test
// If advisor.html changes one of those, change it here in the same commit.
//
// THE ADVANCE (Hollard programme, decided 4 Oct 2026)
//   amount      = the lower of
//                   the debt-based amount: the captured balances of every
//                   debt the advisor confirmed as informal / high-cost, and
//                   the cap: ADVANCE_SALARY_MULTIPLE (4) × gross monthly salary
//   term        = DEFAULT_TERM_MONTHS (24), fixed by the programme
//   instalment  = amount ÷ 24, 0% interest
//   When the cap binds, the advance settles whole debts in order of cost
//   (highest annual-equivalent rate first, then largest balance) while they
//   fit; whatever is left of the cap is applied towards the next debt, whose
//   instalment is assumed UNCHANGED in the DSR after, because nobody has
//   agreed a new one. DSR after = (repayments now − instalments of the debts
//   fully settled + advance instalment) ÷ gross salary.
// ============================================================


// Shared with the Debt Rehab Plan since 3 Sep 2026 — see _shared/kw-finance.ts.
// Re-exported so tests, report.ts and index.ts keep importing from here.
import {
  DSR_GREEN_MAX, DSR_AMBER_MAX, DISPOSABLE_FLOOR_PCT, HIGH_COST_RATE_PA,
  DEFAULT_TERM_MONTHS, REPEATED_BORROWING_COUNT, ADVANCE_SALARY_MULTIPLE,
  pf, isBlank, round2, fmtPct, fmtP, calcMonthlyPAYE, parseRate, liveLiabilities, suggestClassification,
} from "../_shared/kw-finance.ts";
import type { Assessment, Classification, RatePeriod, RawLiability, Tier } from "../_shared/kw-finance.ts";
export {
  DSR_GREEN_MAX, DSR_AMBER_MAX, DISPOSABLE_FLOOR_PCT, HIGH_COST_RATE_PA,
  DEFAULT_TERM_MONTHS, REPEATED_BORROWING_COUNT, LENDING_NORM_PCT, ADVANCE_SALARY_MULTIPLE,
  DSR_BENCHMARK_PCT, DSR_OVER_INDEBTED_PCT, dsrBand, dsrTier,
  pf, round2, fmtP, fmtPct, calcAnnualTax, calcMonthlyPAYE, parseRate, liveLiabilities, suggestClassification,
} from "../_shared/kw-finance.ts";
export type { Assessment, Classification, RatePeriod, RawLiability, Tier } from "../_shared/kw-finance.ts";

export interface PrepLiability {
  index: number;                 // index into the LIVE liability list (see liveLiabilities)
  classification: Classification;
  rate_period: RatePeriod | null; // null when no rate captured
}

export interface Prep {
  term_months?: number;
  consultation_date?: string;    // YYYY-MM-DD
  recommendation_date?: string;  // YYYY-MM-DD (the day of generation)
  consultant_name?: string;
  liabilities?: PrepLiability[];
  advisor_context?: string;      // optional free text for the narrative only
}

export interface LiabilityView {
  index: number;
  item: string;
  institution: string;
  loan_amount: number | null;
  rate_value: number | null;       // numeric part of the captured rate, or null
  rate_period: RatePeriod | null;
  rate_pa_equivalent: number | null;
  rate_text: string;               // "12% p.a." / "30% per month" / "Not captured"
  balance: number | null;          // null = not captured
  instalment: number;              // 0 when blank
  classification: Classification;
  settled_by_advance: boolean;
  gaps: string[];
}

export interface Computed {
  employee: { name: string; employer: string; age: string; marital_status: string; dependants: number };
  income: {
    gross_salary: number; paye: number; other_deductions: number; net_salary: number;
    spouse_income: number; rental_income: number; business_income: number; dividends: number;
    total_monthly_income: number;
  };
  liabilities: LiabilityView[];
  term_months: number;
  before: { debt_service: number; dsr: number | null; disposable: number | null };
  after:  { debt_service: number; dsr: number | null; disposable: number | null } | null;
  advance: {
    amount: number; instalment: number; instalment_pct_income: number | null; settles: number[];
    debt_based_amount: number;       // what the confirmed informal balances add up to
    cap: number;                     // ADVANCE_SALARY_MULTIPLE × gross monthly salary
    capped: boolean;                 // true when the cap, not the debts, set the amount
    partial: { index: number; applied: number } | null;  // cap remainder applied to one more debt
  } | null;
  dsr_change: { direction: "improved" | "worsened" | "unchanged"; delta_points: number } | null;
  budget: { captured: boolean; expenses: number | null; shortfall: boolean | null };
  informal_count: number;
  has_monthly_compounding: boolean;
  gaps: string[];                  // human-readable data gaps, deduplicated
  tier: Tier;
  decision: string;
  decision_reasons: string[];
  conditions: { key: string; label: string; on: boolean }[];
  support_plan: { key: string; label: string; on: boolean }[];
  follow_up: { key: string; label: string; on: boolean }[];
}


// ── main ─────────────────────────────────────────────────────────
export function compute(a: Assessment, prep: Prep): Computed {
  const personal = a.personal || {};
  const income = a.income || {};
  // The programme fixes the term at 24 months. prep.term_months is ignored
  // (it was advisor-editable before 4 Oct 2026); the stored input still
  // carries whatever was sent, so an old report can be read back.
  const term = DEFAULT_TERM_MONTHS;

  // Income — identical to calcTotals()
  const gross = pf(income.monthlySalary);
  const paye = calcMonthlyPAYE(gross);
  const other = pf(income.otherDeductions);
  const net = Math.max(0, gross - paye - other);
  const spouse = pf(income.spouseIncome), rentals = pf(income.rentals),
        business = pf(income.businessIncome), dividends = pf(income.dividends);
  const totalIncome = net + spouse + rentals + business + dividends;

  const gaps = new Set<string>();
  if (gross <= 0) gaps.add("Gross salary not captured — DSR and the advance cap cannot be computed");

  // Liabilities
  const live = liveLiabilities(a);
  const prepMap = new Map<number, PrepLiability>();
  (prep.liabilities || []).forEach((p) => prepMap.set(Number(p.index), p));

  const views: LiabilityView[] = live.map(({ index, raw }) => {
    const sugg = suggestClassification(raw);
    const p = prepMap.get(index);
    const classification: Classification = p?.classification === "informal" || p?.classification === "formal" ? p.classification : sugg.classification;
    const rate = parseRate(raw.interestRate);
    let rate_period: RatePeriod | null = rate.value == null ? null : (p?.rate_period === "monthly" || p?.rate_period === "annual" ? p.rate_period : sugg.rate_period);
    const rate_pa = rate.value == null ? null : (rate_period === "monthly" ? rate.value * 12 : rate.value);
    const balance = isBlank(raw.balance) || pf(raw.balance) === 0 ? null : pf(raw.balance);
    const instalment = pf(raw.monthlyInstalment);
    const rowGaps: string[] = [];
    const label = (raw.item === "Other" && raw.institution) ? String(raw.institution) : `${raw.item || "Liability"}${raw.institution ? " – " + raw.institution : ""}`;
    if (rate.value == null) rowGaps.push(`Interest rate not captured for ${label}`);
    if (balance == null && (instalment > 0 || classification === "informal")) rowGaps.push(`Balance not captured for ${label}`);
    rowGaps.forEach((g) => gaps.add(g));
    return {
      index,
      item: String(raw.item || "Other"),
      institution: String(raw.institution || ""),
      loan_amount: pf(raw.loanAmount) || null,
      rate_value: rate.value,
      rate_period,
      rate_pa_equivalent: rate_pa,
      rate_text: rate.value == null ? "Not captured" : `${rate.value}% ${rate_period === "monthly" ? "per month" : "p.a."}`,
      balance,
      instalment,
      classification,
      settled_by_advance: false,
      gaps: rowGaps,
    };
  });

  // Before
  const debtServiceBefore = round2(views.reduce((s, v) => s + v.instalment, 0));
  const dsrBefore = gross > 0 ? round2(debtServiceBefore / gross * 100) : null;
  const dispBefore = totalIncome > 0 ? round2(totalIncome - debtServiceBefore) : null;

  // Budget
  const budgetVals = Object.values(a.budget || {}).map(pf);
  const budgetCaptured = budgetVals.some((v) => v > 0);
  const expenses = budgetCaptured ? round2(budgetVals.reduce((s, v) => s + v, 0)) : null;
  const shortfall = budgetCaptured && totalIncome > 0 ? (expenses as number) > totalIncome : null;
  if (!budgetCaptured) gaps.add("Household budget not captured — a monthly shortfall cannot be ruled out");

  // Informal set → advance
  const informal = views.filter((v) => v.classification === "informal");
  const settleable = informal.filter((v) => v.balance != null && v.balance > 0);
  const informalBalance = round2(settleable.reduce((s, v) => s + (v.balance as number), 0));
  const hasMonthly = informal.some((v) => v.rate_period === "monthly");

  let after: Computed["after"] = null, advance: Computed["advance"] = null, change: Computed["dsr_change"] = null;
  if (informalBalance > 0 && gross > 0 && totalIncome > 0) {
    const cap = round2(gross * ADVANCE_SALARY_MULTIPLE);
    const amount = round2(Math.min(informalBalance, cap));
    const capped = informalBalance > cap;
    // Which debts the advance settles in full. Uncapped: all of them. Capped:
    // the most expensive first, while they fit.
    let settled = settleable;
    let partial: { index: number; applied: number } | null = null;
    if (capped) {
      const order = settleable.slice().sort((x, y) =>
        ((y.rate_pa_equivalent ?? -1) - (x.rate_pa_equivalent ?? -1)) || ((y.balance as number) - (x.balance as number)));
      settled = []; let left = amount;
      for (const v of order) {
        if ((v.balance as number) <= left + 0.005) { settled.push(v); left = round2(left - (v.balance as number)); }
      }
      if (left > 0.005) {
        const next = order.find((v) => !settled.includes(v));
        if (next) partial = { index: next.index, applied: round2(left) };
      }
    }
    const instalment = round2(amount / term);
    const replaced = round2(settled.reduce((s, v) => s + v.instalment, 0));
    const debtServiceAfter = round2(debtServiceBefore - replaced + instalment);
    const dsrAfter = round2(debtServiceAfter / gross * 100);
    settled.forEach((v) => { v.settled_by_advance = true; });
    if (capped) gaps.add(`The confirmed informal balances (${fmtP(informalBalance)}) exceed the advance cap of ${ADVANCE_SALARY_MULTIPLE} × gross salary (${fmtP(cap)}); part of the informal debt stays outstanding`);
    after = { debt_service: debtServiceAfter, dsr: dsrAfter, disposable: round2(totalIncome - debtServiceAfter) };
    advance = { amount, instalment, instalment_pct_income: round2(instalment / gross * 100), settles: settled.map((v) => v.index),
                debt_based_amount: informalBalance, cap, capped, partial };
    const delta = round2(dsrAfter - (dsrBefore as number));
    change = { direction: delta > 0.05 ? "worsened" : delta < -0.05 ? "improved" : "unchanged", delta_points: delta };
  }

  // Tier + decision
  let tier: Tier; let decision: string; const reasons: string[] = [];
  if (!advance || !after) {
    tier = "RED";
    if (gross <= 0) { decision = "Decline – Insufficient Data"; reasons.push("Gross salary is not captured, so the DSR and the advance cap cannot be worked out."); }
    else if (totalIncome <= 0) { decision = "Decline – Insufficient Data"; reasons.push("Income is not captured, so affordability cannot be assessed."); }
    else if (informal.length && settleable.length === 0) { decision = "Decline – Insufficient Data"; reasons.push("Informal debts are listed but no balances are captured, so the advance cannot be sized."); }
    else if (dsrBefore != null && dsrBefore >= DSR_AMBER_MAX) { decision = "Decline – Refer to Debt Restructuring"; reasons.push(`No informal or high-cost debt to consolidate, and the current DSR of ${fmtPct(dsrBefore)} is already at or above the ${DSR_AMBER_MAX}% over-indebtedness line.`); }
    else { decision = "Decline – No Consolidation Opportunity"; reasons.push("No informal or high-cost debt is captured, so an advance would add a repayment without removing one."); }
  } else {
    const dsrA = after.dsr as number, dispA = after.disposable as number;
    const lowDisp = dispA < totalIncome * DISPOSABLE_FLOOR_PCT / 100;
    // GREEN below the benchmark, AMBER from the benchmark up to the line,
    // RED at or past the line (exactly 40 is AMBER, exactly 60 is RED).
    const overLine = dsrA >= DSR_AMBER_MAX;
    if (overLine || lowDisp || shortfall === true) {
      tier = "RED";
      if (overLine) reasons.push(`DSR after the advance would be ${fmtPct(dsrA)}, at or above the ${DSR_AMBER_MAX}% over-indebtedness line.`);
      if (lowDisp) reasons.push(`Disposable income after the advance would be ${fmtP(dispA)}, below ${DISPOSABLE_FLOOR_PCT}% of monthly income.`);
      if (shortfall === true) reasons.push(`The captured household budget (${fmtP(expenses)}) already exceeds monthly income.`);
      decision = (overLine && change && change.direction !== "improved")
        ? "Decline – Refer to Debt Restructuring"
        : "Proceed Only Under Prerequisites";
    } else if (dsrA >= DSR_GREEN_MAX) {
      tier = "AMBER"; decision = "Proceed with Conditional Approval";
      reasons.push(`DSR after the advance would be ${fmtPct(dsrA)}: at or above the ${DSR_GREEN_MAX}% wellbeing benchmark, below the ${DSR_AMBER_MAX}% over-indebtedness line.`);
    } else {
      tier = "GREEN"; decision = "Proceed with Approval";
      reasons.push(`DSR after the advance would be ${fmtPct(dsrA)}, below the ${DSR_GREEN_MAX}% wellbeing benchmark.`);
    }
    if (advance!.capped) reasons.push(`The advance is capped at ${ADVANCE_SALARY_MULTIPLE} × gross salary (${fmtP(advance!.cap)}), below the ${fmtP(advance!.debt_based_amount)} of informal balances.`);
    if (change?.direction === "worsened") reasons.push(`DSR rises by ${change.delta_points.toFixed(2)} points because informal debts that carried no monthly instalment become a real cash obligation.`);
    if (change?.direction === "improved") reasons.push(`DSR falls by ${Math.abs(change.delta_points).toFixed(2)} points because a serviced high-cost instalment is replaced by a smaller one.`);
  }

  // Default conditions — DEFAULT SUGGESTIONS, every one removable in the UI.
  // The two condition labels below name the employer: one says the employer
  // does not settle third-party creditors, the other holds their HR letters.
  // Both said "Hollard" literally, which is wrong the moment a second
  // employer is switched on in organizations.offers_advances.
  const employerName = String(personal.employer || "").trim() || "the employer";
  const approving = tier !== "RED" || decision === "Proceed Only Under Prerequisites";
  const conditions = approving ? [
    { key: "proof_of_payment", on: true,
      label: `Advance is paid to the employee, not to creditors directly — ${employerName} does not settle third-party creditors on the employee's behalf. Employee must submit proof of payment for the informal debts being settled to Key Wellness before the funds are treated as settled.` },
    { key: "debt_rehab", on: tier !== "GREEN" || hasMonthly,
      label: "Employee is automatically enrolled in the Key Wellness Debt Rehab Programme." },
    { key: "hr_letter_hold", on: tier === "RED" || informal.length >= REPEATED_BORROWING_COUNT,
      label: `${employerName} HR must not issue an employment confirmation letter for this employee without checking with Key Wellness first.` },
  ] : [];
  const rehabOn = conditions.some((c) => c.key === "debt_rehab" && c.on);
  const support_plan = [
    { key: "adjust_expenses", label: "Adjustment in monthly expenses", on: true },
    { key: "follow_up_consultation", label: "Follow-up Consultation", on: true },
    { key: "debt_rehab", label: rehabOn ? "Enrolled in Debt Rehab Programme" : "Refer to Debt Rehab Programme", on: rehabOn || tier !== "GREEN" },
  ];
  const follow_up = [
    { key: "follow_up_30", label: "A follow-up within 30 days", on: true },
    ...Array.from(gaps).filter((g) => /Balance not captured|Gross salary/.test(g))
      .map((g, i) => ({ key: "gap_" + i, label: "Updated creditor statements required first — " + g.replace(/ — .*$/, ""), on: true })),
  ];
  if (!budgetCaptured) follow_up.push({ key: "budget", label: "Capture a household budget to confirm there is no monthly shortfall", on: true });

  const kids = Array.isArray(a.kids) ? a.kids.length : 0;
  const marital = [personal.maritalStatus, personal.regime].filter((x) => !isBlank(x)).join(" (") + (!isBlank(personal.regime) ? ")" : "");

  return {
    employee: {
      name: [personal.name, personal.surname].filter((x) => !isBlank(x)).join(" ").trim(),
      employer: String(personal.employer || "").trim(),
      age: String(personal.age || ""),
      marital_status: marital,
      dependants: kids,
    },
    income: { gross_salary: round2(gross), paye: round2(paye), other_deductions: round2(other), net_salary: round2(net),
              spouse_income: spouse, rental_income: rentals, business_income: business, dividends, total_monthly_income: round2(totalIncome) },
    liabilities: views,
    term_months: term,
    before: { debt_service: debtServiceBefore, dsr: dsrBefore, disposable: dispBefore },
    after, advance, dsr_change: change,
    budget: { captured: budgetCaptured, expenses, shortfall },
    informal_count: informal.length,
    has_monthly_compounding: hasMonthly,
    gaps: Array.from(gaps),
    tier, decision, decision_reasons: reasons,
    conditions, support_plan, follow_up,
  };
}
