// Key Wellness — Debt Rehab Plan: deterministic computation
// ============================================================
// The Debt Rehab Plan is an INTERNAL working document for the advisor, and
// every figure, action, band, trigger and gap in it comes from THIS file.
// The model receives the output and writes prose around it; it cannot change
// a number, an action or a phase band. Same division of labour as the
// Advance Recommendation, adopted deliberately on 31 Aug 2026: a model that
// can classify can also misclassify.
//
// Pure module: no imports beyond _shared/kw-finance.ts, no I/O, no
// Date.now() — the generation date arrives on `prep`. Runs unchanged under
// Deno (Edge Function) and Node 22 (tests/debt-rehab-plan.test.mjs).
//
// Governing document: docs/build/debt-rehab-plan-spec.md (spec v2, 3 Sep 2026).
// Section references below are to that file.
// ============================================================
import {
  DSR_GREEN_MAX, DSR_AMBER_MAX, REPEATED_BORROWING_COUNT, DEFAULT_TERM_MONTHS,
  pf, isBlank, round2, fmtP, fmtPct,
  parseRate, liveLiabilities, suggestClassification, monthlyIncome, budgetGroups,
} from "../_shared/kw-finance.ts";
import type {
  Assessment, IncomeSummary, RatePeriod, RawLiability, RawAsset, RawSaving,
} from "../_shared/kw-finance.ts";

export { fmtP, fmtPct, liveLiabilities, suggestClassification };
export type { Assessment };

// ── Constants this report owns ───────────────────────────────────
export const NEEDS_TARGET_PCT = 50;
export const WANTS_TARGET_PCT = 30;
export const SAVINGS_TARGET_PCT = 20;
export const DEFAULT_EXTENSION_MONTHS = 24;   // the term extension a renegotiation opens with
export const LEVER_DEADLINE_DAYS = 60;        // an asset put up for sale is chased at 60 days
export const INCOME_DROP_TRIGGER_PCT = 10;    // "income falls by more than this" → review
export const REVIEW_DAYS = 30;                // next scheduled review, from generation

export type Action = "RETAIN" | "CONSOLIDATE" | "RENEGOTIATE";
export type Headline = "REHABILITATE" | "REFER";

// ── Input shapes ─────────────────────────────────────────────────

// One row of the advisor's confirmed Prepare screen. What the human confirms
// is what is computed and what is stored — exactly as the AR does with its
// Formal/Informal classification.
export interface PrepLiability {
  index: number;                    // index into the LIVE liability list
  action: Action;
  rate_period: RatePeriod | null;   // null when no rate is captured
  months_remaining?: number | null; // for RENEGOTIATE: the term left as the advisor knows it
  extension_months?: number | null; // for RENEGOTIATE: how much longer (default 24)
}

// One row of the asset lever opt-out. `include` false = the advisor has said
// this asset is off-limits (the data has no primary-residence flag, so the
// human decides).
export interface PrepAsset {
  index: number;
  include: boolean;
}

export interface Prep {
  liabilities?: PrepLiability[];
  assets?: PrepAsset[];
  review_date?: string;             // YYYY-MM-DD; default = generation + 30 days
  generated_date?: string;          // YYYY-MM-DD, supplied by the Edge Function
  consultant_name?: string;
  advisor_context?: string;         // free text for the narrative only, never printed
}

// The latest Advance Recommendation for this client, read as the caller.
// Optional: absent means the plan proposes sizing a consolidation through an
// Advance Recommendation rather than inventing an amount.
export interface RehabContext {
  version: number;
  status: "draft" | "final";
  decision: string | null;
  tier: string | null;
  advance_amount: number | null;
  advance_instalment: number | null;
  term_months: number | null;
  generated_at: string | null;      // ISO
  debt_rehab_on: boolean;
}

// threshold_config's indicator.dti value, as the portal reads it. Null → the
// shared constants stand in, so a failed fetch degrades to correct numbers.
export interface DtiConfig {
  bands?: { key: string; max: number | null; label?: string }[];
  flag_band?: string;
}

// ── Output shapes ────────────────────────────────────────────────
export interface LiabilityView {
  index: number;
  item: string;
  institution: string;
  label: string;
  rate_value: number | null;
  rate_period: RatePeriod | null;
  rate_pa_equivalent: number | null;
  rate_text: string;
  balance: number | null;
  instalment: number;
  pct_of_income: number | null;
  action: Action;
  action_reason: string;
  suggested_action: Action;
  confirmed_by_advisor: boolean;
  // RENEGOTIATE only
  target_cap: number | null;          // the lending-norm line in Pula
  target_low: number | null;          // the payment an extension actually reaches
  target_text: string;                // printed as a band, never as a promise
  months_remaining: number | null;
  extension_months: number | null;
  // CONSOLIDATE only
  settled_by_advance: boolean;
  gaps: string[];
}

export interface BudgetRow {
  key: "needs" | "wants" | "savings" | "other";
  label: string;
  actual: number;
  pct_of_income: number | null;
  target_pct: number | null;
  target_amount: number | null;
  cut: number | null;                 // Pula to remove; null where there is no target
  note: string;
}

export interface Lever {
  kind: "asset" | "savings";
  index: number;
  name: string;
  value: number;
  included: boolean;
  covers_informal: number | null;     // multiple of the informal total, e.g. 4.35
  settles_outright: boolean;
  detail: string;
}

export interface Phase {
  key: "phase_1" | "phase_2" | "phase_3";
  title: string;
  window: string;
  dsr_low: number | null;
  dsr_high: number | null;
  band_text: string;
  surplus_low: number | null;
  surplus_high: number | null;
  assumptions: string[];
  actions: string[];
}

export interface ActionItem {
  key: string;
  group: "phase_1" | "phase_2" | "phase_3" | "lever" | "gap" | "trigger";
  label: string;
  on: boolean;
}

export interface ComputedRehab {
  client: { employer: string; age: string; marital_status: string; dependants: number };
  income: IncomeSummary;
  dsr: { debt_service: number; dsr: number | null; disposable: number | null };
  net_worth: { assets: number; savings: number; liabilities: number; total: number };
  liabilities: LiabilityView[];
  counts: { retain: number; consolidate: number; renegotiate: number; informal: number };
  lending_norm_pct: number;
  band: string | null;                // the threshold_config band the current DSR sits in
  budget: {
    captured: boolean;
    rows: BudgetRow[];
    spend: number | null;
    shortfall: number | null;         // spend − income, positive = urgent
    debt_service_in_budget: number;
    all_in_shortfall: number | null;  // spend + debt service outside the budget − income
    motshelo_note: string | null;
  };
  levers: Lever[];
  informal_total: number;
  consolidation: {
    source: "advance_recommendation" | "none";
    amount: number | null;
    instalment: number | null;
    term_months: number | null;
    dated: string | null;
    ar_version: number | null;
    note: string;
  };
  phases: Phase[];
  triggers: string[];
  headline: Headline;
  headline_reasons: string[];
  review_date: string | null;
  gaps: string[];
  actions: ActionItem[];
}

// ── helpers ──────────────────────────────────────────────────────
const liabLabel = (raw: RawLiability) =>
  (raw.item === "Other" && raw.institution) ? String(raw.institution)
    : `${raw.item || "Liability"}${raw.institution ? " – " + raw.institution : ""}`;

// The ceiling of the "manageable" band is the lending norm the portal quotes
// to clients (advisor.html kwLendingNorm()). Config first, shared constant as
// the fallback, so a change to threshold_config cannot leave this report
// quoting one number and the diagnostics screen another.
export function lendingNorm(cfg: DtiConfig | null | undefined): number {
  const bands = cfg?.bands || [];
  for (const b of bands) if (b.key === "manageable") {
    return (b.max === null || b.max === undefined) ? DSR_GREEN_MAX : Number(b.max);
  }
  return DSR_GREEN_MAX;
}

// advisor.html kwDtiBand(): `max` is an EXCLUSIVE upper bound, so exactly 45.0
// is over-indebted. Do not "fix" it to <=; every published figure uses this.
export function dtiBand(dsr: number | null, cfg: DtiConfig | null | undefined): string | null {
  if (dsr == null || !isFinite(dsr)) return null;
  const bands = cfg?.bands?.length ? cfg.bands : [
    { key: "healthy", max: 20 }, { key: "manageable", max: DSR_GREEN_MAX },
    { key: "strained", max: DSR_AMBER_MAX }, { key: "over_indebted", max: null },
  ];
  for (const b of bands) {
    if (b.max === null || b.max === undefined || Number(dsr) < Number(b.max)) return b.key;
  }
  return null;
}

// Level payment on a declining balance. Returns null when the inputs cannot
// support one — a zero or missing rate falls back to straight-line, which is
// what "no rate captured" honestly means.
export function pmt(balance: number, annualRatePct: number | null, months: number): number | null {
  if (!(balance > 0) || !(months > 0)) return null;
  if (annualRatePct == null || annualRatePct <= 0) return round2(balance / months);
  const r = annualRatePct / 100 / 12;
  const f = Math.pow(1 + r, months);
  if (!isFinite(f) || f <= 1) return null;
  return round2(balance * r * f / (f - 1));
}

// Months left on a facility, solved from balance, rate and instalment. Null
// when the instalment does not cover the interest (the balance never falls)
// or an input is missing — either way the advisor is asked instead of guessed.
export function nper(balance: number, annualRatePct: number | null, instalment: number): number | null {
  if (!(balance > 0) || !(instalment > 0)) return null;
  if (annualRatePct == null || annualRatePct <= 0) return Math.ceil(balance / instalment);
  const r = annualRatePct / 100 / 12;
  if (instalment <= balance * r) return null;
  const n = Math.log(instalment / (instalment - balance * r)) / Math.log(1 + r);
  return isFinite(n) && n > 0 ? Math.ceil(n) : null;
}

function addDays(iso: string | undefined, days: number): string | null {
  if (!iso || !/^\d{4}-\d{2}-\d{2}$/.test(iso)) return null;
  const [y, m, d] = iso.split("-").map(Number);
  const t = Date.UTC(y, m - 1, d) + days * 86400000;
  return new Date(t).toISOString().slice(0, 10);
}

// ── Per-liability action (spec §4) ───────────────────────────────
// Suggested by code, confirmed by the advisor on the Prepare screen.
//   CONSOLIDATE  — informal / high-cost (the AR's own classification)
//   RENEGOTIATE  — a FORMAL facility whose instalment alone exceeds the
//                  lending norm of total monthly income
//   RETAIN       — everything else, stated so the advisor spends no effort there
export function suggestAction(raw: RawLiability, totalIncome: number, normPct: number):
    { action: Action; rate_period: RatePeriod | null; reason: string } {
  const sugg = suggestClassification(raw);
  if (sugg.classification === "informal") {
    return { action: "CONSOLIDATE", rate_period: sugg.rate_period, reason: sugg.reason };
  }
  const instalment = pf(raw.monthlyInstalment);
  if (totalIncome > 0 && instalment > totalIncome * normPct / 100) {
    const share = round2(instalment / totalIncome * 100);
    return {
      action: "RENEGOTIATE", rate_period: sugg.rate_period,
      reason: `Instalment alone is ${fmtPct(share)} of total monthly income, above the ${normPct}% line`,
    };
  }
  return { action: "RETAIN", rate_period: sugg.rate_period, reason: sugg.reason };
}

// ── main ─────────────────────────────────────────────────────────
export function computeRehab(
  a: Assessment,
  prep: Prep,
  rehab: RehabContext | null,
  dtiCfg: DtiConfig | null,
): ComputedRehab {
  const personal = a.personal || {};
  const gaps = new Set<string>();
  const norm = lendingNorm(dtiCfg);

  // ── Income ──
  const income = monthlyIncome(a.income);
  const totalIncome = income.total_monthly_income;
  if (income.gross_salary <= 0) gaps.add("Gross salary not captured — DSR cannot be computed");
  if (totalIncome <= 0) gaps.add("No income captured — no ratio in this plan can be computed");

  // ── Liabilities and their actions ──
  const live = liveLiabilities(a);
  const prepMap = new Map<number, PrepLiability>();
  (prep.liabilities || []).forEach((p) => prepMap.set(Number(p.index), p));

  const views: LiabilityView[] = live.map(({ index, raw }) => {
    const sugg = suggestAction(raw, totalIncome, norm);
    const p = prepMap.get(index);
    const confirmed = !!p && (p.action === "RETAIN" || p.action === "CONSOLIDATE" || p.action === "RENEGOTIATE");
    const action: Action = confirmed ? (p as PrepLiability).action : sugg.action;
    const rate = parseRate(raw.interestRate);
    const rate_period: RatePeriod | null = rate.value == null ? null
      : (p?.rate_period === "monthly" || p?.rate_period === "annual" ? p.rate_period : sugg.rate_period);
    const rate_pa = rate.value == null ? null : (rate_period === "monthly" ? round2(rate.value * 12) : rate.value);
    const balance = isBlank(raw.balance) || pf(raw.balance) === 0 ? null : pf(raw.balance);
    const instalment = pf(raw.monthlyInstalment);
    const label = liabLabel(raw);
    const rowGaps: string[] = [];
    if (rate.value == null) rowGaps.push(`Interest rate not captured for ${label}`);
    if (balance == null && (instalment > 0 || action === "CONSOLIDATE")) rowGaps.push(`Balance not captured for ${label}`);

    // The RENEGOTIATE target: the payment that brings this facility to the
    // lending norm, printed as a band, never as a promise.
    let target_cap: number | null = null, target_low: number | null = null, target_text = "";
    let months_remaining: number | null = null, extension_months: number | null = null;
    if (action === "RENEGOTIATE") {
      target_cap = totalIncome > 0 ? round2(totalIncome * norm / 100) : null;
      extension_months = Math.max(1, Math.round(Number(p?.extension_months) || DEFAULT_EXTENSION_MONTHS));
      const stated = Number(p?.months_remaining);
      months_remaining = isFinite(stated) && stated > 0 ? Math.round(stated)
        : (balance != null ? nper(balance, rate_pa, instalment) : null);
      if (months_remaining == null) {
        rowGaps.push(`Remaining term not captured for ${label} — the extension needed to reach the ${norm}% line cannot be computed`);
      }
      if (rate.value == null) {
        rowGaps.push(`Interest rate not captured for ${label} — the term needed to reach the ${norm}% line cannot be computed`);
      }
      if (balance != null && months_remaining != null && rate.value != null) {
        target_low = pmt(balance, rate_pa, months_remaining + (extension_months as number));
      }
      if (target_cap == null) {
        target_text = "Not captured";
      } else if (target_low != null && target_low <= target_cap) {
        target_text = `${fmtP(target_low)} – ${fmtP(target_cap)} over ${months_remaining! + extension_months!} months`;
      } else if (target_low != null) {
        target_text = `At or below ${fmtP(target_cap)}; a ${extension_months}-month extension alone reaches only ${fmtP(target_low)}, so a longer term or a rate change is needed`;
      } else {
        target_text = `At or below ${fmtP(target_cap)}`;
      }
    }

    rowGaps.forEach((g) => gaps.add(g));
    return {
      index, item: String(raw.item || "Other"), institution: String(raw.institution || ""), label,
      rate_value: rate.value, rate_period, rate_pa_equivalent: rate_pa,
      rate_text: rate.value == null ? "Not captured" : `${rate.value}% ${rate_period === "monthly" ? "per month" : "p.a."}`,
      balance, instalment,
      pct_of_income: totalIncome > 0 ? round2(instalment / totalIncome * 100) : null,
      action, action_reason: sugg.reason, suggested_action: sugg.action, confirmed_by_advisor: confirmed,
      target_cap, target_low, target_text, months_remaining, extension_months,
      settled_by_advance: false, gaps: rowGaps,
    };
  });

  const debtService = round2(views.reduce((s, v) => s + v.instalment, 0));
  const dsrNow = totalIncome > 0 ? round2(debtService / totalIncome * 100) : null;
  const disposable = totalIncome > 0 ? round2(totalIncome - debtService) : null;
  const band = dtiBand(dsrNow, dtiCfg);

  const consolidateRows = views.filter((v) => v.action === "CONSOLIDATE");
  const renegotiateRows = views.filter((v) => v.action === "RENEGOTIATE");
  const retainRows = views.filter((v) => v.action === "RETAIN");
  const informalTotal = round2(consolidateRows.reduce((s, v) => s + (v.balance || 0), 0));

  // ── Net worth, including savings (spec §6.3) ──
  const assetsRaw: RawAsset[] = (a.assets || []).filter((r) => pf(r.value) > 0 || !isBlank(r.name));
  const savingsRaw: RawSaving[] = (a.savings || []).filter((r) => !isBlank(r.institution) || pf(r.currentBalance) > 0 || pf(r.monthlyContribution) > 0);
  const assetTotal = round2(assetsRaw.reduce((s, r) => s + pf(r.value), 0));
  const savingsTotal = round2(savingsRaw.reduce((s, r) => s + pf(r.currentBalance), 0));
  const liabilityTotal = round2(views.reduce((s, v) => s + (v.balance || 0), 0));
  if (savingsRaw.length && savingsTotal === 0) gaps.add("Savings balances not captured — a settlement lever cannot be sized");
  if (!savingsRaw.length) gaps.add("No savings or investments captured");

  // ── Budget correction (spec §4) ──
  const bg = budgetGroups(a.budget);
  const budgetRows: BudgetRow[] = [];
  let shortfall: number | null = null, allIn: number | null = null, motsheloNote: string | null = null;
  if (!bg.captured) {
    gaps.add("Household budget not captured — capturing it is the first action and no target can be set");
  } else {
    const mk = (key: BudgetRow["key"], label: string, actual: number, target_pct: number | null, note: string): BudgetRow => {
      const target_amount = target_pct != null && totalIncome > 0 ? round2(totalIncome * target_pct / 100) : null;
      return {
        key, label, actual,
        pct_of_income: totalIncome > 0 ? round2(actual / totalIncome * 100) : null,
        target_pct, target_amount,
        cut: target_amount != null ? round2(Math.max(0, actual - target_amount)) : null,
        note,
      };
    };
    const needsRow = mk("needs", "Needs", bg.needs, NEEDS_TARGET_PCT, "");
    const wantsRow = mk("wants", "Wants", bg.wants, WANTS_TARGET_PCT, "");
    const savingsRow = mk("savings", "Savings & Investments", bg.savings, SAVINGS_TARGET_PCT,
      bg.savings < (totalIncome * SAVINGS_TARGET_PCT / 100)
        ? `Saving ${fmtP(round2(Math.max(0, totalIncome * SAVINGS_TARGET_PCT / 100 - bg.savings)))} below the ${SAVINGS_TARGET_PCT}% line — under target is not a cut`
        : "");
    savingsRow.cut = null;  // never cut savings to fix a shortfall
    shortfall = totalIncome > 0 ? round2(bg.total - totalIncome) : null;
    const namedCuts = round2((needsRow.cut || 0) + (wantsRow.cut || 0));
    const residual = shortfall != null && shortfall > 0
      ? round2(Math.min(bg.other, Math.max(0, shortfall - namedCuts))) : 0;
    const otherRow: BudgetRow = {
      key: "other", label: "Other", actual: bg.other,
      pct_of_income: totalIncome > 0 ? round2(bg.other / totalIncome * 100) : null,
      target_pct: null, target_amount: null, cut: residual,
      note: "Not a 50/30/20 group; every Pula here is discretionary until it is named",
    };
    budgetRows.push(needsRow, wantsRow, savingsRow, otherRow);

    // The budget's own debt line. Olorato's carries none while her liabilities
    // carry P 5,500.00 a month, so the 50/30/20 shortfall understates the cash
    // gap by exactly that. Print both rather than the smaller one.
    if (bg.debt_service_in_budget <= 0 && debtService > 0) {
      gaps.add(`Budget carries no debt repayments while liabilities carry ${fmtP(debtService)} per month — the shortfall below is understated by that amount`);
      allIn = totalIncome > 0 ? round2(bg.total + debtService - totalIncome) : null;
    }
    // The portal files motshelo under Savings. A motshelo loan repayment is
    // debt service, not saving, and the plan says so when both appear.
    if (bg.motshelo_in_savings > 0 && consolidateRows.some((v) => /motshelo|metshelo/i.test(v.institution + " " + v.item))) {
      motsheloNote = `${fmtP(bg.motshelo_in_savings)} sits under Savings & Investments as motshelo. A motshelo loan repayment is debt service, not saving, and is counted as such in this plan.`;
    }
  }

  // ── Levers (spec §4) ──
  const assetPrep = new Map<number, boolean>();
  (prep.assets || []).forEach((p) => assetPrep.set(Number(p.index), !!p.include));
  const levers: Lever[] = [];
  assetsRaw.forEach((r, i) => {
    const value = round2(pf(r.value));
    const idle = String(r.status || "") === "Personal Use" && pf(r.monthlyIncome) === 0 && pf(r.potentialIncome) === 0;
    if (!idle || value <= 0) return;
    const included = assetPrep.has(i) ? (assetPrep.get(i) as boolean) : true;
    const covers = informalTotal > 0 ? round2(value / informalTotal) : null;
    levers.push({
      kind: "asset", index: i, name: String(r.name || "Asset").trim(), value, included,
      covers_informal: covers, settles_outright: covers != null && covers >= 1,
      detail: covers != null
        ? `${fmtP(value)}, personal use, earning nothing — covers the informal balances ${covers.toFixed(2)}× over`
        : `${fmtP(value)}, personal use, earning nothing`,
    });
  });
  savingsRaw.forEach((r, i) => {
    const bal = round2(pf(r.currentBalance));
    if (bal <= 0) return;
    // Match this balance against the largest informal debt it can settle.
    const target = consolidateRows.filter((v) => v.balance != null && (v.balance as number) <= bal)
      .sort((x, y) => (y.balance as number) - (x.balance as number))[0];
    levers.push({
      kind: "savings", index: i, name: String(r.institution || "Savings").trim(), value: bal, included: true,
      covers_informal: informalTotal > 0 ? round2(bal / informalTotal) : null,
      settles_outright: !!target,
      detail: target
        ? `${fmtP(bal)} at ${String(r.institution || "").trim() || "this institution"} would settle ${target.label} (${fmtP(target.balance)}) outright`
        : `${fmtP(bal)} at ${String(r.institution || "").trim() || "this institution"} — not enough to settle any single informal balance outright`,
    });
  });
  const leverValue = round2(levers.filter((l) => l.included).reduce((s, l) => s + l.value, 0));
  const leversCoverInformal = informalTotal > 0 && leverValue >= informalTotal;

  // ── Consolidation source (spec §4) ──
  // Cross-reference a FINAL Advance Recommendation; never re-derive an amount.
  // A draft is named as pending, not used.
  let consolidation: ComputedRehab["consolidation"];
  if (rehab && rehab.status === "final" && rehab.advance_amount != null && rehab.advance_amount > 0) {
    const dated = rehab.generated_at ? String(rehab.generated_at).slice(0, 10) : null;
    consolidation = {
      source: "advance_recommendation",
      amount: round2(rehab.advance_amount),
      instalment: rehab.advance_instalment != null ? round2(rehab.advance_instalment) : null,
      term_months: rehab.term_months || null, dated, ar_version: rehab.version,
      note: `Advance Recommendation v${rehab.version}${dated ? " of " + dated : ""} sized this at ${fmtP(rehab.advance_amount)}${rehab.term_months ? " over " + rehab.term_months + " months" : ""}. The figure is carried across, not re-derived.`,
    };
    consolidateRows.forEach((v) => { v.settled_by_advance = true; });
  } else {
    consolidation = {
      source: "none", amount: null, instalment: null, term_months: null, dated: null,
      ar_version: rehab ? rehab.version : null,
      note: rehab && rehab.status === "draft"
        ? `Advance Recommendation v${rehab.version} is still a draft, so no advance amount is carried across. Finalise it, or size the consolidation through a new one.`
        : "No Advance Recommendation has been finalised for this client, so no consolidation amount is stated here. Sizing one is an action in Phase 1.",
    };
    if (consolidateRows.length) gaps.add("No finalised Advance Recommendation to size the consolidation against");
  }

  // ── Phase trajectory (spec §4) — scenarios, never free-styled ──
  const advInstal = consolidation.instalment != null ? consolidation.instalment
    : (consolidation.amount != null && consolidation.term_months ? round2(consolidation.amount / consolidation.term_months) : null);
  const consolidatedInstalments = round2(consolidateRows.reduce((s, v) => s + v.instalment, 0));
  const renegCap = round2(renegotiateRows.reduce((s, v) => s + (v.target_cap != null ? Math.min(v.instalment, v.target_cap) : v.instalment), 0));
  const renegNow = round2(renegotiateRows.reduce((s, v) => s + v.instalment, 0));
  const dsrOf = (svc: number) => totalIncome > 0 ? round2(svc / totalIncome * 100) : null;

  // Phase 1: formal instalments as captured; if a final AR advance exists the
  // consolidated instalments are replaced by its instalment. Levers not yet realised.
  const p1Service = consolidation.source === "advance_recommendation" && advInstal != null
    ? round2(debtService - consolidatedInstalments + advInstal) : debtService;
  const p1 = dsrOf(p1Service);

  // Phase 2: low = renegotiation at the cap AND the levers realised (the
  // advance or the informal balances cleared); high = neither has landed.
  const p2LowService = round2(p1Service - renegNow + renegCap
    - (leversCoverInformal ? (consolidation.source === "advance_recommendation" && advInstal != null ? advInstal : consolidatedInstalments) : 0));
  const p2Low = dsrOf(Math.max(0, p2LowService));
  const p2High = p1;

  // Phase 3: the exit criteria, stated as what must be true.
  const p3Target = norm;
  const spend = bg.captured ? bg.total : null;
  const cutsTotal = round2(budgetRows.reduce((s, r) => s + (r.cut || 0), 0));
  const surplusOf = (svc: number, spendAfterCuts: number | null) =>
    spendAfterCuts == null || totalIncome <= 0 ? null
      : round2(totalIncome - spendAfterCuts - Math.max(0, svc - bg.debt_service_in_budget));
  const spendAfterCuts = spend != null ? round2(spend - cutsTotal) : null;

  const phase1Actions: string[] = [];
  if (consolidation.source === "advance_recommendation") {
    phase1Actions.push(`Settle the informal balances with the ${fmtP(consolidation.amount)} advance and collect proof of payment`);
  } else if (consolidateRows.length) {
    phase1Actions.push("Size a consolidation through an Advance Recommendation — this plan states no amount until one is finalised");
  }
  renegotiateRows.forEach((v) => phase1Actions.push(`Open the term-extension conversation with ${v.institution || v.label}, targeting ${v.target_text}`));
  levers.filter((l) => l.included && l.kind === "asset").forEach((l) => phase1Actions.push(`Put ${l.name} on the market and agree a ${LEVER_DEADLINE_DAYS}-day review date`));
  if (!bg.captured) phase1Actions.unshift("Capture the household budget — nothing below can be targeted until it exists");

  const phase2Actions: string[] = [];
  if (bg.captured && shortfall != null && shortfall > 0) {
    phase2Actions.push(`Close the ${fmtP(shortfall)} monthly shortfall through the cuts in the budget table`);
  }
  if (bg.captured && bg.debt_service_in_budget <= 0 && debtService > 0) {
    phase2Actions.push(`Bring the ${fmtP(debtService)} of loan repayments into the budget as a named line`);
  }
  if (!phase2Actions.length) phase2Actions.push("Hold the corrected budget for three consecutive months");

  const phase3Actions: string[] = [`Debt service at or below ${p3Target}% of income`, "A positive monthly surplus, held for three months"];
  if (consolidation.source === "advance_recommendation") phase3Actions.push("The advance cleared in full");
  if (bg.captured && bg.debt_service_in_budget <= 0 && debtService > 0) phase3Actions.push("Loan repayments carried inside the budget, not outside it");

  const phases: Phase[] = [
    {
      key: "phase_1", title: "Stabilise", window: "0–3 months",
      dsr_low: p1, dsr_high: p1, band_text: p1 == null ? "Not captured" : fmtPct(p1),
      surplus_low: surplusOf(p1Service, spend), surplus_high: surplusOf(p1Service, spend),
      assumptions: consolidation.source === "advance_recommendation"
        ? [`The ${fmtP(consolidation.amount)} advance replaces the informal balances at ${fmtP(advInstal)} a month`,
           "Debts that carried no instalment become a real cash obligation, so this figure can be higher than today's"]
        : ["No advance is in place, so the informal balances are still outstanding and the figure is today's"],
      actions: phase1Actions,
    },
    {
      key: "phase_2", title: "Correct", window: "3–12 months",
      dsr_low: p2Low, dsr_high: p2High,
      band_text: p2Low == null || p2High == null ? "Not captured"
        : (Math.abs((p2High as number) - (p2Low as number)) < 0.01 ? fmtPct(p2Low) : `${fmtPct(p2Low)} – ${fmtPct(p2High)}`),
      surplus_low: surplusOf(Math.max(0, p2LowService), spendAfterCuts),
      surplus_high: surplusOf(p1Service, spendAfterCuts),
      assumptions: [
        renegotiateRows.length ? `Lower bound assumes every renegotiation lands at the ${norm}% line` : "No facility is being renegotiated",
        leversCoverInformal ? "Lower bound assumes the lever assets are sold and the consolidated debt cleared" : "The levers on file do not cover the informal balances in full",
        "Upper bound assumes neither has happened yet",
      ],
      actions: phase2Actions,
    },
    {
      key: "phase_3", title: "Exit", window: "12–24 months",
      dsr_low: null, dsr_high: p3Target,
      band_text: `At or below ${p3Target}%`,
      surplus_low: null, surplus_high: null,
      assumptions: ["These are the exit criteria, not a projection — the plan closes when all of them are true"],
      actions: phase3Actions,
    },
  ];

  // ── Headline: REHABILITATE or REFER (spec §4) ──
  // REFER is a plan-level outcome, never a per-debt one.
  const headlineReasons: string[] = [];
  let headline: Headline = "REHABILITATE";
  if (p2Low != null && p2Low > DSR_AMBER_MAX) {
    headline = "REFER";
    headlineReasons.push(`After every lever in this plan — consolidation settled, renegotiation at the ${norm}% line, budget corrected — debt service is still ${fmtPct(p2Low)} of income, above the ${DSR_AMBER_MAX}% ceiling.`);
  }
  if (consolidateRows.length >= REPEATED_BORROWING_COUNT && consolidation.source === "none" && !leversCoverInformal) {
    headline = "REFER";
    headlineReasons.push(`There are ${consolidateRows.length} informal lenders and nothing to consolidate them with: no finalised Advance Recommendation, and the assets and savings on file do not cover ${fmtP(informalTotal)}.`);
  }
  if (headline === "REHABILITATE") {
    headlineReasons.push(`The plan's own levers bring debt service to ${phases[1].band_text} by the Phase 2 checkpoint, so formal debt counselling is not the first step.`);
  }

  // ── Review triggers (spec §4) — assembled from computed facts ──
  const triggers: string[] = ["Any new informal borrowing, of any size, from any lender"];
  if (consolidation.source === "advance_recommendation") triggers.push("A missed advance instalment, or a settlement without proof of payment");
  levers.filter((l) => l.included && l.kind === "asset").slice(0, 2)
    .forEach((l) => triggers.push(`${l.name} still unsold at ${LEVER_DEADLINE_DAYS} days`));
  if (income.business_income > 0) {
    triggers.push(`Business income falling below ${fmtP(income.business_income)} a month`);
  } else if (totalIncome > 0) {
    triggers.push(`Total monthly income falling by more than ${INCOME_DROP_TRIGGER_PCT}% (${fmtP(round2(totalIncome * INCOME_DROP_TRIGGER_PCT / 100))})`);
  }
  if (p2High != null) triggers.push(`Debt service still above ${fmtPct(p2High)} of income at the Phase 2 checkpoint`);
  const triggerList = triggers.slice(0, 5);

  // ── Checkable actions ──
  const actions: ActionItem[] = [];
  phases.forEach((ph) => ph.actions.forEach((label, i) => actions.push({ key: `${ph.key}_${i}`, group: ph.key, label, on: true })));
  levers.forEach((l, i) => actions.push({ key: `lever_${l.kind}_${l.index}`, group: "lever", label: l.detail, on: l.included }));
  Array.from(gaps).forEach((g, i) => actions.push({ key: `gap_${i}`, group: "gap", label: g, on: true }));
  triggerList.forEach((t, i) => actions.push({ key: `trigger_${i}`, group: "trigger", label: t, on: true }));

  const kids = Array.isArray(a.kids) ? a.kids.length : 0;
  const marital = [personal.maritalStatus, personal.regime].filter((x) => !isBlank(x)).join(" (") + (!isBlank(personal.regime) ? ")" : "");

  return {
    client: {
      employer: String(personal.employer || "").trim(),
      age: String(personal.age || ""),
      marital_status: marital,
      dependants: kids,
    },
    income,
    dsr: { debt_service: debtService, dsr: dsrNow, disposable },
    net_worth: { assets: assetTotal, savings: savingsTotal, liabilities: liabilityTotal, total: round2(assetTotal + savingsTotal - liabilityTotal) },
    liabilities: views,
    counts: { retain: retainRows.length, consolidate: consolidateRows.length, renegotiate: renegotiateRows.length, informal: consolidateRows.length },
    lending_norm_pct: norm,
    band,
    budget: {
      captured: bg.captured, rows: budgetRows,
      spend: bg.captured ? bg.total : null, shortfall,
      debt_service_in_budget: bg.debt_service_in_budget,
      all_in_shortfall: allIn, motshelo_note: motsheloNote,
    },
    levers, informal_total: informalTotal, consolidation,
    phases, triggers: triggerList,
    headline, headline_reasons: headlineReasons,
    review_date: prep.review_date || addDays(prep.generated_date, REVIEW_DAYS),
    gaps: Array.from(gaps),
    actions,
  };
}
