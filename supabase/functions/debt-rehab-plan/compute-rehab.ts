// Key Wellness — Debt Rehab Plan: deterministic computation
// ============================================================
// Every figure, every per-debt action, every phase band and every review
// trigger in a Debt Rehab Plan comes from THIS file, never from the
// language model. The model receives computeRehab()'s output as formatted
// strings and writes prose around it; it cannot change a number, an
// action or a band. Same division of labour as the Advance Recommendation
// (advance-recommendation/compute.ts), whose helpers this module shares
// through _shared/kw-finance.ts.
//
// Pure module: no I/O, no Date.now(). The plan date comes in through prep
// and the review date is arithmetic on that string. Runs unchanged under
// Deno (Edge Function), Node 22 (tests/debt-rehab-plan.test.mjs) and
// esbuild (tests/smoke-rehab.js).
//
// Rules (docs/build/debt-rehab-plan-spec.md §4, decisions in
// docs/build/debt-rehab-plan.md):
//   CONSOLIDATE  informal / high-cost (hint list, monthly-period rate, or
//                ≥ HIGH_COST_RATE_PA p.a. equivalent)
//   RENEGOTIATE  formal facility whose instalment ALONE exceeds the lending
//                norm (35%) of total monthly income
//   RETAIN       everything else, stated explicitly
//   REFER        plan-level: DSR with every lever applied still > 45%, or
//                ≥ 3 informal lenders with no vehicle / uncaptured balances
// The advisor confirms every action on the Prepare screen; what is
// confirmed is what is computed and stored.
// ============================================================
import {
  DSR_GREEN_MAX, DSR_AMBER_MAX, HIGH_COST_RATE_PA, REPEATED_BORROWING_COUNT, DEFAULT_TERM_MONTHS,
  LENDING_NORM_PCT, EXPENSE_GROUP_IDS,
  pf, isBlank, round2, fmtP, fmtPct, totalIncome, parseRate, liveLiabilities, suggestClassification,
} from "../_shared/kw-finance.ts";
import type { Assessment, Classification, RatePeriod, RawLiability, Tier, IncomeView } from "../_shared/kw-finance.ts";

export const DEFAULT_EXTENSION_MONTHS = 24;   // renegotiation: derived remaining term + this
export const DEFAULT_REVIEW_DAYS = 30;
export const INCOME_DROP_TRIGGER_PCT = 10;    // review trigger: income falls > 10%
export const ASSET_SALE_DEADLINE_DAYS = 60;   // review trigger: lever asset unsold
export const MAX_EXTENSION_SEARCH = 360;      // months, when looking for a reachable term

export type Action = "RETAIN" | "CONSOLIDATE" | "RENEGOTIATE";
export type Vehicle = "advance" | "savings" | "asset" | "none";
export type DsrStatus = "within_norm" | "strained" | "over_indebted";

export interface RehabPrepLiability {
  index: number;                    // index into liveLiabilities()
  action?: Action;                  // confirmed action; absent → suggestion
  classification?: Classification;  // confirmed classification; absent → suggestion
  rate_period?: RatePeriod | null;
  term_months?: number | null;      // advisor-entered remaining term when it cannot be derived
}
export interface RehabPrepLever { asset_index: number; on: boolean }
export interface RehabPrep {
  plan_date?: string;               // YYYY-MM-DD (the day of generation)
  consultation_date?: string;
  extension_months?: number;
  review_days?: number;
  lending_norm_pct?: number;        // from threshold_config, read by the Edge Function
  liabilities?: RehabPrepLiability[];
  levers?: RehabPrepLever[];
}

// The client's latest Advance Recommendation, read by the Edge Function.
export interface RehabContext {
  version: number;
  status: string;                   // draft | final
  decision: string;
  tier: string;
  advance_amount: number | null;
  term_months: number | null;
  generated_at: string;             // ISO
  debt_rehab_on: boolean;
}
export interface RehabInputs {
  rehab_context?: RehabContext | null;
  advisor_notes?: string[];         // Diagnostics notes + timeline excerpts, for fact detection only
}

export interface RenegotiationView {
  cap: number;                                  // lending norm × income
  remaining_term_months: number | null;
  term_source: "derived" | "advisor" | null;
  new_term_months: number | null;
  amortised: number | null;                     // payment at captured rate over the new term
  band_low: number | null;                      // min(amortised, cap)
  band_high: number;                            // cap
  reachable: boolean | null;                    // can any extension get under the cap?
  extension_needed_months: number | null;       // smallest extension that gets under the cap
}

export interface RehabLiabilityView {
  index: number;
  item: string;
  institution: string;
  label: string;
  classification: Classification;
  rate_value: number | null;
  rate_period: RatePeriod | null;
  rate_pa_equivalent: number | null;
  rate_text: string;
  balance: number | null;
  instalment: number;
  instalment_pct_income: number | null;
  action: Action;
  suggested_action: Action;
  suggested_reason: string;
  settled_by: Exclude<Vehicle, "none"> | null;
  settled_with: string | null;                  // "P 23,000.00 advance (AR v1, 28 Aug 2026)" / "Savings at FNB"
  outcome: string;                              // the Debt-by-Debt table's last column
  renegotiation: RenegotiationView | null;
  gaps: string[];
}

export interface BudgetGroupView {
  id: string; name: string; amount: number; pct: number | null;
  target_pct: number | null; target_kind: "max" | "min" | null; cut: number;
}
export interface PhaseView {
  key: "phase1" | "phase2" | "phase3";
  title: string; window: string;
  dsr_low: number | null; dsr_high: number | null;
  surplus_after: number | null;
  actions: { key: string; label: string }[];
}

export interface RehabComputed {
  employee: { name: string; employer: string; age: string; marital_status: string; dependants: number };
  income: IncomeView;
  lending_norm_pct: number;
  liabilities: RehabLiabilityView[];
  debt_service: number;
  dsr: number | null;
  dsr_status: DsrStatus | null;
  tier: Tier;
  disposable: number | null;
  net_worth: { assets: number; savings: number; liabilities: number; net: number; savings_captured: boolean; assets_captured: boolean };
  advance_recommendation: { version: number; status: string; decision: string; tier: string; date: string; debt_rehab_on: boolean } | null;
  consolidation: {
    rows: number[]; balance: number; uncaptured: number[];
    vehicle: Vehicle;
    advance: { amount: number; term_months: number; instalment: number; version: number; date: string; decision: string } | null;
    advance_reference: { amount: number | null; version: number; date: string; decision: string; status: string } | null;
    savings_matches: { saving_index: number; institution: string; balance: number; settles_index: number; settles_label: string; settles_balance: number }[];
    asset_cover: { asset_index: number; name: string; value: number; cover_multiple: number | null }[];
  };
  budget: {
    captured: boolean; groups: BudgetGroupView[]; total_spend: number | null;
    shortfall: number | null; budgeted_debt_lines: number | null; cash_gap: number | null; motshelo_flag: boolean;
  };
  levers: {
    assets: { asset_index: number; name: string; value: number; on: boolean; cover_multiple: number | null }[];
    income_concentration: string[];
  };
  phases: PhaseView[];
  exit: { dsr_target: number; surplus_target: number; gap_points_from_phase2: number | null };
  refer: { on: boolean; reasons: string[] };
  headline: string;
  triggers: { key: string; label: string }[];
  review: { plan_date: string; review_date: string; consultation_date: string };
  gaps: string[];
  actions: { key: string; label: string; on: boolean; group: string }[];
}

// ── helpers ─────────────────────────────────────────────────────
const liabLabel = (raw: RawLiability) =>
  (raw.item === "Other" && raw.institution) ? String(raw.institution) : `${raw.item || "Liability"}${raw.institution ? " – " + raw.institution : ""}`;

function monthlyRate(value: number | null, period: RatePeriod | null): number | null {
  if (value == null) return null;
  return period === "monthly" ? value / 100 : value / 100 / 12;
}
// Months left on an amortising loan with balance B, monthly rate r, payment I.
export function remainingTerm(B: number, r: number, I: number): number | null {
  if (!(B > 0) || !(I > 0)) return null;
  if (r === 0) return Math.ceil(B / I);
  if (r * B >= I) return null;             // the instalment does not cover the interest
  return Math.ceil(-Math.log(1 - r * B / I) / Math.log(1 + r));
}
export function amortisedPayment(B: number, r: number, n: number): number {
  if (!(n > 0)) return B;
  if (r === 0) return B / n;
  return B * r / (1 - Math.pow(1 + r, -n));
}
// Add days to a YYYY-MM-DD string without touching the clock.
export function addDays(iso: string, days: number): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || "");
  if (!m) return iso;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}
export function fmtDateLong(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || "");
  if (!m) return iso || "";
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return `${+m[3]} ${months[+m[2] - 1]} ${m[1]}`;
}

// Default action for the Prepare screen. The advisor confirms or overrides.
export function suggestAction(raw: RawLiability, income: number, norm: number, classification?: Classification): { action: Action; classification: Classification; rate_period: RatePeriod | null; reason: string } {
  const sugg = suggestClassification(raw);
  const cls = classification || sugg.classification;
  const inst = pf(raw.monthlyInstalment);
  if (cls === "informal") return { action: "CONSOLIDATE", classification: cls, rate_period: sugg.rate_period, reason: sugg.reason };
  if (income > 0 && inst / income * 100 > norm) {
    return { action: "RENEGOTIATE", classification: cls, rate_period: sugg.rate_period, reason: `Instalment alone is ${fmtPct(round2(inst / income * 100))} of income, above the ${norm}% lending norm` };
  }
  return { action: "RETAIN", classification: cls, rate_period: sugg.rate_period, reason: sugg.reason };
}

// ── main ────────────────────────────────────────────────────────
export function computeRehab(a: Assessment, prep: RehabPrep, inputs: RehabInputs = {}): RehabComputed {
  const personal = a.personal || {};
  const income = totalIncome(a);
  const inc = income.total_monthly_income;
  const norm = Number(prep.lending_norm_pct) > 0 ? Number(prep.lending_norm_pct) : LENDING_NORM_PCT;
  const extension = Math.max(0, Math.round(Number(prep.extension_months) || DEFAULT_EXTENSION_MONTHS));
  const planDate = (prep.plan_date || "").slice(0, 10);
  const reviewDays = Math.max(1, Math.round(Number(prep.review_days) || DEFAULT_REVIEW_DAYS));
  const ctx = inputs.rehab_context || null;
  const notesText = (inputs.advisor_notes || []).join("\n").toLowerCase();

  const gaps = new Set<string>();
  if (income.gross_salary <= 0 && inc <= 0) gaps.add("Income not captured — DSR and every band cannot be computed");

  // ── Liabilities: classification → action ─────────────────────
  const live = liveLiabilities(a);
  const prepMap = new Map<number, RehabPrepLiability>();
  (prep.liabilities || []).forEach((p) => prepMap.set(Number(p.index), p));
  const cap = round2(inc * norm / 100);

  const views: RehabLiabilityView[] = live.map(({ index, raw }) => {
    const p = prepMap.get(index);
    const confirmedCls: Classification | undefined = p?.classification === "informal" || p?.classification === "formal" ? p.classification : undefined;
    const sugg = suggestAction(raw, inc, norm, confirmedCls);
    const classification = confirmedCls || sugg.classification;
    const action: Action = p?.action === "RETAIN" || p?.action === "CONSOLIDATE" || p?.action === "RENEGOTIATE" ? p.action : sugg.action;
    const rate = parseRate(raw.interestRate);
    const rate_period: RatePeriod | null = rate.value == null ? null : (p?.rate_period === "monthly" || p?.rate_period === "annual" ? p.rate_period : sugg.rate_period);
    const rate_pa = rate.value == null ? null : (rate_period === "monthly" ? rate.value * 12 : rate.value);
    const balance = isBlank(raw.balance) || pf(raw.balance) === 0 ? null : pf(raw.balance);
    const instalment = pf(raw.monthlyInstalment);
    const label = liabLabel(raw);
    const rowGaps: string[] = [];
    if (rate.value == null) rowGaps.push(`Interest rate not captured for ${label}`);
    if (balance == null && (instalment > 0 || classification === "informal")) rowGaps.push(`Balance not captured for ${label}`);

    let renegotiation: RenegotiationView | null = null;
    if (action === "RENEGOTIATE") {
      const r = monthlyRate(rate.value, rate_period);
      let remaining: number | null = null, source: RenegotiationView["term_source"] = null;
      if (p?.term_months != null && Number(p.term_months) > 0) { remaining = Math.round(Number(p.term_months)); source = "advisor"; }
      else if (r != null && balance != null) { remaining = remainingTerm(balance, r, instalment); source = remaining == null ? null : "derived"; }
      let amortised: number | null = null, newTerm: number | null = null, reachable: boolean | null = null, needed: number | null = null;
      // Interest alone above the cap: no extension of any length gets under
      // the line, whether or not the remaining term is known.
      if (r != null && balance != null && r > 0 && balance * r > cap) reachable = false;
      if (r != null && balance != null && remaining != null) {
        newTerm = remaining + extension;
        amortised = round2(amortisedPayment(balance, r, newTerm));
        if (reachable === false) { /* already settled above */ }
        else {
          reachable = true;
          if (amortised > cap) {
            needed = null;
            for (let m = extension; m <= MAX_EXTENSION_SEARCH; m++) {
              if (amortisedPayment(balance, r, remaining + m) <= cap) { needed = m; break; }
            }
            if (needed == null) reachable = false;
          } else needed = extension;
        }
      } else {
        if (rate.value == null) { /* rate gap already recorded */ }
        else if (balance == null) { /* balance gap already recorded */ }
        else if (remaining == null) rowGaps.push(`Remaining term cannot be derived for ${label} — the instalment does not cover the interest; enter a term`);
      }
      renegotiation = {
        cap, remaining_term_months: remaining, term_source: source, new_term_months: newTerm, amortised,
        band_low: amortised == null ? null : Math.min(amortised, cap), band_high: cap, reachable, extension_needed_months: needed,
      };
    }
    rowGaps.forEach((g) => gaps.add(g));
    return {
      index, item: String(raw.item || "Other"), institution: String(raw.institution || ""), label, classification,
      rate_value: rate.value, rate_period, rate_pa_equivalent: rate_pa,
      rate_text: rate.value == null ? "Not captured" : `${rate.value}% ${rate_period === "monthly" ? "per month" : "p.a."}`,
      balance, instalment, instalment_pct_income: inc > 0 ? round2(instalment / inc * 100) : null,
      action, suggested_action: sugg.action, suggested_reason: sugg.reason,
      settled_by: null, settled_with: null, outcome: "", renegotiation, gaps: rowGaps,
    };
  });

  const debtService = round2(views.reduce((s, v) => s + v.instalment, 0));
  const dsr = inc > 0 ? round2(debtService / inc * 100) : null;
  const disposable = inc > 0 ? round2(inc - debtService) : null;
  const dsr_status: DsrStatus | null = dsr == null ? null : dsr > DSR_AMBER_MAX ? "over_indebted" : dsr > norm ? "strained" : "within_norm";
  const tier: Tier = dsr == null ? "RED" : dsr > DSR_AMBER_MAX ? "RED" : dsr > DSR_GREEN_MAX ? "AMBER" : "GREEN";

  // ── Net worth (internal view includes savings) ───────────────
  const assets = Array.isArray(a.assets) ? a.assets : [];
  const savings = Array.isArray(a.savings) ? a.savings : [];
  const assetsCaptured = assets.some((r) => !isBlank(r.name) || pf(r.value) > 0);
  const savingsCaptured = savings.some((r) => !isBlank(r.institution) || pf(r.currentBalance) > 0 || pf(r.monthlyContribution) > 0);
  const totalAssets = round2(assets.reduce((s, r) => s + pf(r.value), 0));
  const totalSavings = round2(savings.reduce((s, r) => s + pf(r.currentBalance), 0));
  const totalLiab = round2(views.reduce((s, v) => s + (v.balance || 0), 0));
  if (!savingsCaptured) gaps.add("Savings and investments not captured — a balance that could settle an informal debt cannot be seen");
  if (!assetsCaptured) gaps.add("Assets not captured — no lever can be assessed");

  // ── Consolidation set and its vehicle ────────────────────────
  const consRows = views.filter((v) => v.action === "CONSOLIDATE");
  const consCaptured = consRows.filter((v) => v.balance != null && v.balance > 0);
  const consUncaptured = consRows.filter((v) => v.balance == null);
  const consBalance = round2(consCaptured.reduce((s, v) => s + (v.balance as number), 0));
  const informalCount = views.filter((v) => v.classification === "informal").length;

  // 1. An Advance Recommendation that PROCEEDS. A declined one is a reference only.
  let advance: RehabComputed["consolidation"]["advance"] = null;
  let advanceRef: RehabComputed["consolidation"]["advance_reference"] = null;
  if (ctx) {
    const proceeds = /^proceed/i.test(ctx.decision || "");
    const amt = ctx.advance_amount != null && ctx.advance_amount > 0 ? round2(ctx.advance_amount) : null;
    const date = (ctx.generated_at || "").slice(0, 10);
    if (proceeds && amt != null) {
      const term = ctx.term_months && ctx.term_months > 0 ? Math.round(ctx.term_months) : DEFAULT_TERM_MONTHS;
      advance = { amount: amt, term_months: term, instalment: round2(amt / term), version: ctx.version, date, decision: ctx.decision };
    } else {
      advanceRef = { amount: amt, version: ctx.version, date, decision: ctx.decision || "", status: ctx.status || "" };
    }
  }
  // 2. Savings balances against individual informal balances, largest first.
  const savingsMatches: RehabComputed["consolidation"]["savings_matches"] = [];
  const usedSavings = new Set<number>();
  const settledBySavings = new Set<number>();
  consCaptured.slice().sort((x, y) => (y.balance as number) - (x.balance as number)).forEach((v) => {
    let best = -1, bestBal = Infinity;
    savings.forEach((s, i) => {
      const bal = pf(s.currentBalance);
      if (usedSavings.has(i) || bal < (v.balance as number)) return;
      if (bal < bestBal) { best = i; bestBal = bal; }
    });
    if (best >= 0) {
      usedSavings.add(best); settledBySavings.add(v.index);
      savingsMatches.push({ saving_index: best, institution: String(savings[best].institution || "Savings"), balance: round2(bestBal), settles_index: v.index, settles_label: v.label, settles_balance: v.balance as number });
    }
  });
  // 3. Personal-use assets with no income, unless the advisor unticked them.
  const leverMap = new Map<number, boolean>();
  (prep.levers || []).forEach((l) => leverMap.set(Number(l.asset_index), !!l.on));
  const leverAssets: RehabComputed["levers"]["assets"] = [];
  assets.forEach((r, i) => {
    const val = pf(r.value);
    const candidate = String(r.status || "Personal Use") !== "Income-Generating" && pf(r.monthlyIncome) === 0 && pf(r.potentialIncome) === 0 && val > 0;
    if (!candidate) return;
    const on = leverMap.has(i) ? (leverMap.get(i) as boolean) : true;
    leverAssets.push({ asset_index: i, name: String(r.name || "Asset"), value: round2(val), on, cover_multiple: consBalance > 0 ? round2(val / consBalance) : null });
  });
  const assetCover = leverAssets.filter((l) => l.on && l.cover_multiple != null && l.cover_multiple >= 1)
    .map(({ asset_index, name, value, cover_multiple }) => ({ asset_index, name, value, cover_multiple }));

  const remainingAfterSavings = round2(consCaptured.filter((v) => !settledBySavings.has(v.index)).reduce((s, v) => s + (v.balance as number), 0));
  let vehicle: Vehicle = "none";
  if (consBalance > 0) {
    if (advance) vehicle = "advance";
    else if (remainingAfterSavings === 0) vehicle = "savings";
    else if (assetCover.length) vehicle = "asset";
  }
  consRows.forEach((v) => {
    if (v.balance == null) { v.outcome = "Balance not captured — cannot be sized"; return; }
    if (settledBySavings.has(v.index) && vehicle !== "advance") {
      const m = savingsMatches.find((x) => x.settles_index === v.index)!;
      v.settled_by = "savings"; v.settled_with = `${fmtP(m.balance)} held at ${m.institution}`;
      v.outcome = `Settle outright from ${m.institution} savings (${fmtP(m.balance)})`;
    } else if (vehicle === "advance" && advance) {
      v.settled_by = "advance"; v.settled_with = `${fmtP(advance.amount)} advance (AR v${advance.version}, ${fmtDateLong(advance.date)})`;
      v.outcome = `Settled by the ${fmtP(advance.amount)} advance (AR v${advance.version}, ${fmtDateLong(advance.date)})`;
    } else if (vehicle === "asset") {
      v.settled_by = "asset"; v.settled_with = assetCover.map((x) => x.name).join(", ");
      v.outcome = `Settle from the sale of ${assetCover.map((x) => x.name).join(", ")}`;
    } else {
      v.outcome = "Consolidate — size the vehicle via an Advance Recommendation";
    }
  });
  views.forEach((v) => {
    if (v.action === "RETAIN") v.outcome = "Retain — no change";
    if (v.action === "RENEGOTIATE" && v.renegotiation) {
      const r = v.renegotiation;
      v.outcome = r.reachable === false
        ? `Target ≤ ${fmtP(r.cap)}; interest alone exceeds it — restructuring, not extension`
        : r.amortised != null
          ? `Target ${fmtP(r.band_low as number)} – ${fmtP(r.cap)} over ${r.new_term_months} months`
          : `Target ≤ ${fmtP(r.cap)} (rate or balance not captured — term to be set with the lender)`;
    }
  });

  // ── Budget correction ────────────────────────────────────────
  const budget = a.budget || {};
  const customIds = (Array.isArray(a.budgetOtherCustom) ? a.budgetOtherCustom : []).map((c) => String(c.id || "")).filter(Boolean);
  const budgetVals = Object.values(budget).map(pf);
  const captured = budgetVals.some((v) => v > 0);
  const groups: BudgetGroupView[] = [];
  let totalSpend: number | null = null, shortfall: number | null = null, cashGap: number | null = null, budgetedDebt: number | null = null;
  const TARGETS: Record<string, { pct: number; kind: "max" | "min" } | null> = { needs: { pct: 50, kind: "max" }, wants: { pct: 30, kind: "max" }, savings: { pct: 20, kind: "min" }, other: null };
  if (captured) {
    EXPENSE_GROUP_IDS.forEach((g) => {
      const ids = g.id === "other" ? [...g.cats, ...customIds] : g.cats;
      const amount = round2(ids.reduce((s, id) => s + pf((budget as Record<string, unknown>)[id]), 0));
      const t = TARGETS[g.id];
      groups.push({ id: g.id, name: g.name, amount, pct: inc > 0 ? round2(amount / inc * 100) : null, target_pct: t ? t.pct : null, target_kind: t ? t.kind : null, cut: 0 });
    });
    totalSpend = round2(groups.reduce((s, g) => s + g.amount, 0));
    shortfall = inc > 0 ? round2(totalSpend - inc) : null;
    if (inc > 0) {
      let remaining = Math.max(0, shortfall as number);
      groups.forEach((g) => {
        if (g.target_kind === "max") { g.cut = round2(Math.max(0, g.amount - inc * (g.target_pct as number) / 100)); remaining = round2(Math.max(0, remaining - g.cut)); }
      });
      const other = groups.find((g) => g.id === "other");
      if (other) other.cut = round2(Math.min(other.amount, remaining));
    }
    budgetedDebt = round2(pf((budget as Record<string, unknown>).debt_min) + pf((budget as Record<string, unknown>).debt_extra));
    if (shortfall != null && debtService > budgetedDebt) cashGap = round2(shortfall + (debtService - budgetedDebt));
  } else {
    gaps.add("Household budget not captured — a monthly shortfall cannot be ruled out");
  }
  const motsheloFlag = pf((budget as Record<string, unknown>).motshelo) > 0 && consRows.some((v) => /motshelo|metshelo|moraka/i.test(v.label));

  // ── Levers: income concentration (facts only) ────────────────
  const concentration: string[] = [];
  if (inc > 0 && income.spouse_income === 0) concentration.push("Single-earner household — no spouse income captured");
  if (income.business_income > 0 && /declin|dropp|drop |fall|fell|down|slow/.test(notesText)) concentration.push("Business income reported as declining in the advisor's notes");
  if (inc > 0 && income.net_salary > 0 && income.net_salary / inc < 0.5 && income.business_income > 0) concentration.push("More than half of income is business income, not salary");

  // ── Phase trajectory: scenario bands ─────────────────────────
  const consInst = round2(consCaptured.reduce((s, v) => s + v.instalment, 0));
  const advInst = vehicle === "advance" && advance ? advance.instalment : 0;
  const renegRows = views.filter((v) => v.action === "RENEGOTIATE" && v.renegotiation);
  const renegCurrent = round2(renegRows.reduce((s, v) => s + v.instalment, 0));
  const renegLow = round2(renegRows.reduce((s, v) => s + (v.renegotiation!.band_low ?? v.renegotiation!.cap), 0));
  const renegCap = round2(renegRows.reduce((s, v) => s + v.renegotiation!.cap, 0));
  const pct = (ds: number) => inc > 0 ? round2(Math.max(0, ds) / inc * 100) : null;
  const p1low = pct(debtService - consInst);
  const p1high = pct(debtService - consInst + advInst);
  const p2low = pct(debtService - consInst - renegCurrent + renegLow);
  const p2high = pct(debtService - consInst + advInst - renegCurrent + renegCap);
  const cuts = round2(groups.reduce((s, g) => s + g.cut, 0));
  const surplusAfter = captured && inc > 0 && totalSpend != null ? round2(inc - (totalSpend - cuts)) : null;

  // ── REFER ───────────────────────────────────────────────────
  const referReasons: string[] = [];
  if (p2low != null && p2low > DSR_AMBER_MAX) referReasons.push(`DSR with every lever applied would still be ${fmtPct(p2low)}, above ${DSR_AMBER_MAX}%.`);
  if (informalCount >= REPEATED_BORROWING_COUNT && (vehicle === "none" || consUncaptured.length > 0)) {
    referReasons.push(`${informalCount} informal lenders and ${consUncaptured.length > 0 ? "balances that are not captured" : "no vehicle to consolidate them with"}.`);
  }
  if (renegRows.some((v) => v.renegotiation!.reachable === false)) referReasons.push("A formal facility cannot reach the lending norm by term extension alone.");
  const refer = { on: referReasons.length > 0, reasons: referReasons };

  // ── Actions per phase ───────────────────────────────────────
  const p1: PhaseView["actions"] = [], p2: PhaseView["actions"] = [], p3: PhaseView["actions"] = [];
  if (!captured) p1.push({ key: "budget_capture", label: "Capture the household budget — no target can be set until it is on file" });
  if (consCaptured.length) {
    const names = consCaptured.map((v) => v.label).join(", ");
    if (vehicle === "advance" && advance) p1.push({ key: "consolidate", label: `Settle ${names} (${fmtP(consBalance)}) from the ${fmtP(advance.amount)} advance (AR v${advance.version}); collect proof of settlement` });
    else if (vehicle === "savings") p1.push({ key: "consolidate", label: `Settle ${names} outright from savings: ${savingsMatches.map((m) => `${fmtP(m.balance)} at ${m.institution} → ${m.settles_label}`).join("; ")}` });
    else if (vehicle === "asset") p1.push({ key: "consolidate", label: `Settle ${names} (${fmtP(consBalance)}) from the sale of ${assetCover.map((x) => x.name).join(", ")}` });
    else p1.push({ key: "consolidate", label: `Size a consolidation of ${fmtP(consBalance)} for ${names} via an Advance Recommendation` });
  }
  consUncaptured.forEach((v) => p1.push({ key: "balance_" + v.index, label: `Capture the balance owed to ${v.label} — it cannot be consolidated until it is known` }));
  leverAssets.filter((l) => l.on).forEach((l) => p1.push({ key: "lever_" + l.asset_index, label: `Initiate the sale of ${l.name} (${fmtP(l.value)}); target completion within ${ASSET_SALE_DEADLINE_DAYS} days` }));
  renegRows.forEach((v) => p1.push({ key: "reneg_open_" + v.index, label: `Open the term-extension conversation with ${v.institution || v.label}: instalment ${fmtP(v.instalment)} is ${fmtPct(v.instalment_pct_income)} of income` }));
  if (!savingsCaptured) p1.push({ key: "savings_capture", label: "Capture savings and investment balances" });
  views.filter((v) => v.rate_value == null && v.action !== "RETAIN").forEach((v) => p1.push({ key: "rate_" + v.index, label: `Capture the interest rate on ${v.label}` }));

  if (captured && shortfall != null && shortfall > 0) {
    const cutText = groups.filter((g) => g.cut > 0).map((g) => `${g.name} by ${fmtP(g.cut)}`).join(", ");
    p2.push({ key: "budget_correct", label: `Close the ${fmtP(shortfall)} monthly shortfall: cut ${cutText || "spending to income"}` });
  } else if (captured) p2.push({ key: "budget_hold", label: `Hold spending at or below ${fmtP(inc)} a month; surplus is ${fmtP(surplusAfter as number)}` });
  if (cashGap != null && cashGap > (shortfall ?? 0)) p2.push({ key: "budget_debt_lines", label: `Add the ${fmtP(debtService)} debt service to the budget — the all-in gap is ${fmtP(cashGap)}` });
  renegRows.forEach((v) => p2.push({ key: "reneg_land_" + v.index, label: `Land the ${v.institution || v.label} instalment at or below ${fmtP(v.renegotiation!.cap)}${v.renegotiation!.new_term_months ? ` (about ${v.renegotiation!.new_term_months} months)` : ""}` }));
  if (motsheloFlag) p2.push({ key: "motshelo", label: "Reclassify the motshelo line: it is a loan repayment, not saving, until the balance is cleared" });

  p3.push({ key: "exit_dsr", label: `Hold DSR at or below ${norm}% — no new borrowing of any kind` });
  p3.push({ key: "exit_surplus", label: surplusAfter != null && surplusAfter > 0 ? `Direct the ${fmtP(surplusAfter)} surplus to an emergency fund` : "Reach a positive monthly surplus and direct it to an emergency fund" });

  const phases: PhaseView[] = [
    { key: "phase1", title: "Stabilise", window: "0–3 months", dsr_low: p1low, dsr_high: p1high, surplus_after: null, actions: p1.slice(0, 6) },
    { key: "phase2", title: "Correct", window: "3–12 months", dsr_low: p2low, dsr_high: p2high, surplus_after: surplusAfter, actions: p2.slice(0, 5) },
    { key: "phase3", title: "Exit", window: "12–24 months", dsr_low: null, dsr_high: norm, surplus_after: surplusAfter, actions: p3 },
  ];

  // ── Review triggers ─────────────────────────────────────────
  const triggers: RehabComputed["triggers"] = [
    { key: "new_informal", label: "Any new informal or high-cost borrowing (motshelo, family, microlender)" },
  ];
  if (vehicle === "advance") triggers.push({ key: "missed_advance", label: "A missed advance instalment" });
  leverAssets.filter((l) => l.on).forEach((l) => triggers.push({ key: "unsold_" + l.asset_index, label: `${l.name} unsold ${ASSET_SALE_DEADLINE_DAYS} days after listing` }));
  if (inc > 0) triggers.push({ key: "income_drop", label: `Total monthly income falls below ${fmtP(round2(inc * (100 - INCOME_DROP_TRIGGER_PCT) / 100))}` });
  triggers.push({ key: "dsr_unmoved", label: `DSR not below ${fmtPct(dsr)} at the Phase 2 checkpoint (month 3)` });

  // ── Headline, review, checkables ────────────────────────────
  const counts = { RENEGOTIATE: 0, CONSOLIDATE: 0, RETAIN: 0 };
  views.forEach((v) => { counts[v.action]++; });
  const headline = refer.on
    ? "REFER to formal debt counselling"
    : `${counts.RENEGOTIATE} renegotiate · ${counts.CONSOLIDATE} consolidate · ${counts.RETAIN} retain${shortfall != null && shortfall > 0 ? `; shortfall ${fmtP(shortfall)}` : ""}`;
  const reviewDate = planDate ? addDays(planDate, reviewDays) : "";
  const actions: RehabComputed["actions"] = [
    ...phases.flatMap((ph) => ph.actions.map((x) => ({ key: `${ph.key}:${x.key}`, label: x.label, on: true, group: ph.key }))),
    ...leverAssets.map((l) => ({ key: `lever:${l.asset_index}`, label: `${l.name} (${fmtP(l.value)}) may be sold to settle debt`, on: l.on, group: "lever" })),
    ...triggers.map((t) => ({ key: `trigger:${t.key}`, label: t.label, on: true, group: "trigger" })),
  ];

  const kids = Array.isArray(a.kids) ? a.kids.length : 0;
  const marital = [personal.maritalStatus, personal.regime].filter((x) => !isBlank(x)).join(" (") + (!isBlank(personal.regime) ? ")" : "");
  return {
    employee: {
      name: [personal.name, personal.surname].filter((x) => !isBlank(x)).join(" ").trim(),
      employer: String(personal.employer || "").trim(), age: String(personal.age || ""), marital_status: marital, dependants: kids,
    },
    income, lending_norm_pct: norm, liabilities: views,
    debt_service: debtService, dsr, dsr_status, tier, disposable,
    net_worth: { assets: totalAssets, savings: totalSavings, liabilities: totalLiab, net: round2(totalAssets + totalSavings - totalLiab), savings_captured: savingsCaptured, assets_captured: assetsCaptured },
    advance_recommendation: ctx ? { version: ctx.version, status: ctx.status, decision: ctx.decision, tier: ctx.tier, date: (ctx.generated_at || "").slice(0, 10), debt_rehab_on: !!ctx.debt_rehab_on } : null,
    consolidation: { rows: consRows.map((v) => v.index), balance: consBalance, uncaptured: consUncaptured.map((v) => v.index), vehicle, advance, advance_reference: advanceRef, savings_matches: savingsMatches, asset_cover: assetCover },
    budget: { captured, groups, total_spend: totalSpend, shortfall, budgeted_debt_lines: budgetedDebt, cash_gap: cashGap, motshelo_flag: motsheloFlag },
    levers: { assets: leverAssets, income_concentration: concentration },
    phases,
    exit: { dsr_target: norm, surplus_target: 0, gap_points_from_phase2: p2low == null ? null : round2(Math.max(0, p2low - norm)) },
    refer, headline, triggers,
    review: { plan_date: planDate, review_date: reviewDate, consultation_date: (prep.consultation_date || planDate).slice(0, 10) },
    gaps: Array.from(gaps),
    actions,
  };
}
