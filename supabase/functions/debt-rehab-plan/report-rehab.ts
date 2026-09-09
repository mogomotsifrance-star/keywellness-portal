// Key Wellness — Debt Rehab Plan: content assembly
// ============================================================
// Pure module (no I/O). Turns computeRehab() output into the editable
// content structure the Report tab renders — the ten sections of spec §6 —
// and supplies the deterministic fallback narrative used when the model is
// unavailable. Shared by the Edge Function and tests/smoke-rehab.js so the
// browser test renders exactly what production would.
//
// Names (client, consultant) are placed here from the record, never from
// the model, which does not receive them.
// ============================================================
import { fmtP, fmtPct } from "../_shared/kw-finance.ts";
import type { RehabComputed } from "./compute-rehab.ts";
import { fmtDateLong } from "./compute-rehab.ts";

export const PRINT_HEADER = "CONFIDENTIAL — INTERNAL DEBT REHAB PLAN (Key Wellness use only — not for distribution to employer or employee)";
export const DOC_TITLE = "Debt Rehab Plan";
export const MAX_ROOT_CAUSES = 3;
export const MAX_LINES = 12;

export interface RehabNarrative {
  root_causes: string[];        // ≤ 3, interpretive
  debt_lines: string[];         // one per liability, in order
  budget_paragraph: string;
  lever_bullets: string[];
  phase_paragraphs: string[];   // exactly 3
  trigger_lines: string[];
  closing_sentence: string;
}

export interface RehabMeta {
  consultant: string;
  consultation_date: string;
  plan_date: string;
  notes: { diagnostics: Record<string, string>; timeline: { date: string; author: string; body: string }[] };
}

const band = (lo: number | null, hi: number | null) =>
  lo == null && hi == null ? "Not computable" : lo != null && hi != null && lo !== hi ? `${fmtPct(lo)} – ${fmtPct(hi)}` : fmtPct(hi ?? lo);

export function fallbackNarrative(c: RehabComputed): RehabNarrative {
  const root: string[] = [];
  if (c.consolidation.rows.length) root.push(`Informal and high-cost borrowing (${c.consolidation.rows.length} lender${c.consolidation.rows.length === 1 ? "" : "s"}) is being carried alongside formal debt.`);
  c.levers.income_concentration.slice(0, 2).forEach((s) => root.push(s + "."));
  if (c.budget.captured && c.budget.shortfall != null && c.budget.shortfall > 0) root.push(`Monthly spending exceeds income by ${fmtP(c.budget.shortfall)} before any loan instalment is counted.`);
  const debt_lines = c.liabilities.map((l) => {
    const head = `${l.label}: ${l.rate_text === "Not captured" ? "rate not captured" : l.rate_text}, ${l.instalment > 0 ? `instalment ${fmtP(l.instalment)} (${fmtPct(l.instalment_pct_income)} of income)` : "no monthly instalment"}${l.balance == null ? ", balance not captured" : `, balance ${fmtP(l.balance)}`}.`;
    return `${head} ${l.action}: ${l.outcome}.`;
  });
  const budget_paragraph = !c.budget.captured
    ? "No household budget is on file, so a monthly shortfall cannot be ruled out; capturing it is the first action."
    : c.budget.shortfall != null && c.budget.shortfall > 0
      ? `Budgeted spending of ${fmtP(c.budget.total_spend)} against income of ${fmtP(c.income.total_monthly_income)} leaves a shortfall of ${fmtP(c.budget.shortfall)} a month, the most urgent item in this plan.${c.budget.cash_gap != null ? ` The budget carries no loan line; once the ${fmtP(c.debt_service)} of debt service is added the gap is ${fmtP(c.budget.cash_gap)}.` : ""}`
      : `Budgeted spending of ${fmtP(c.budget.total_spend)} fits within income of ${fmtP(c.income.total_monthly_income)}, leaving ${fmtP(-(c.budget.shortfall as number))} a month.`;
  const lever_bullets: string[] = [];
  c.levers.assets.forEach((l) => lever_bullets.push(`${l.name} (${fmtP(l.value)}): ${l.on ? (l.cover_multiple != null ? `covers the informal balance ${l.cover_multiple.toFixed(2)}× and removes its running costs` : "a personal-use asset producing no income") : "kept — not to be sold"}.`));
  c.consolidation.savings_matches.forEach((m) => lever_bullets.push(`${fmtP(m.balance)} at ${m.institution} would settle ${m.settles_label} (${fmtP(m.settles_balance)}) outright.`));
  if (!lever_bullets.length) lever_bullets.push(c.net_worth.assets_captured ? "No personal-use asset without income is available as a lever." : "Assets are not captured, so no lever can be assessed.");
  const p = c.phases;
  const phase_paragraphs = [
    `Phase 1 (${p[0].window}): DSR moves to ${band(p[0].dsr_low, p[0].dsr_high)} once the consolidation lands${c.consolidation.vehicle === "advance" ? ", the higher figure reflecting the advance instalment" : ""}.`,
    `Phase 2 (${p[1].window}): with the budget corrected and any renegotiation in place, DSR sits in the ${band(p[1].dsr_low, p[1].dsr_high)} band${p[1].surplus_after != null ? `, with a monthly surplus of ${fmtP(p[1].surplus_after)}` : ""}.`,
    `Phase 3 (${p[2].window}): exit when DSR is at or below ${fmtPct(c.exit.dsr_target)} and the monthly surplus is positive${c.exit.gap_points_from_phase2 ? `; Phase 2 leaves ${c.exit.gap_points_from_phase2.toFixed(2)} points to close` : ""}.`,
  ];
  return {
    root_causes: root.slice(0, MAX_ROOT_CAUSES),
    debt_lines,
    budget_paragraph,
    lever_bullets,
    phase_paragraphs,
    trigger_lines: c.triggers.map((t) => t.label + "."),
    closing_sentence: `Next review on ${fmtDateLong(c.review.review_date)}: ${c.phases[0].actions.slice(0, 2).map((a) => a.label.replace(/\s*\(.*?\)/g, "")).join(" and ") || "progress on every Phase 1 action"} must be on the table by then.`,
  };
}

export function buildContent(c: RehabComputed, meta: RehabMeta, n: RehabNarrative) {
  const ar = c.advance_recommendation;
  const enrollmentTrigger = ar && ar.debt_rehab_on
    ? `Debt Rehab condition on Advance Recommendation v${ar.version} (${ar.status}, ${fmtDateLong(ar.date)})`
    : `DSR of ${fmtPct(c.dsr)} at consultation — ${c.dsr_status === "over_indebted" ? "over-indebted" : c.dsr_status === "strained" ? "strained" : "within the norm"}`;
  const debtRows = c.liabilities.map((l) => ({
    debt: l.item, institution: l.institution || "—", rate: l.rate_text,
    instalment: fmtP(l.instalment), pct: fmtPct(l.instalment_pct_income), balance: fmtP(l.balance),
    action: l.action, outcome: l.outcome,
  }));
  const budgetRows = c.budget.groups.map((g) => ({
    group: g.name, actual: fmtP(g.amount), pct: fmtPct(g.pct),
    target: g.target_pct == null ? "—" : `${g.target_kind === "min" ? "≥" : "≤"} ${g.target_pct}%`,
    cut: g.cut > 0 ? fmtP(g.cut) : "—",
  }));
  return {
    meta: {
      print_header: PRINT_HEADER, title: DOC_TITLE,
      employee_name: c.employee.name, employer: c.employee.employer || "Not captured",
      consultant: meta.consultant, consultation_date: meta.consultation_date, plan_date: meta.plan_date,
      review_date: c.review.review_date, tier: c.tier, dsr: fmtPct(c.dsr), headline: c.headline, refer: c.refer.on,
    },
    sections: {
      enrollment: {
        rows: [
          { label: "Client", value: c.employee.name || "Not captured" },
          { label: "Employer", value: c.employee.employer || "Not captured" },
          { label: "Age / household", value: `${c.employee.age || "—"} · ${c.employee.marital_status || "—"} · ${c.employee.dependants} dependant${c.employee.dependants === 1 ? "" : "s"}` },
          { label: "Consultant", value: meta.consultant },
          { label: "Enrollment trigger", value: enrollmentTrigger },
          { label: "Plan date", value: fmtDateLong(meta.plan_date) },
          { label: "Tier at enrollment", value: `${c.tier} — DSR ${fmtPct(c.dsr)}` },
        ],
      },
      root_causes: { bullets: n.root_causes },
      snapshot: {
        income_rows: [
          { label: "Gross salary", value: fmtP(c.income.gross_salary) },
          { label: "PAYE", value: fmtP(c.income.paye) },
          { label: "Net salary", value: fmtP(c.income.net_salary) },
          { label: "Spouse income", value: fmtP(c.income.spouse_income) },
          { label: "Business / rental / dividends", value: fmtP(c.income.business_income + c.income.rental_income + c.income.dividends) },
          { label: "Total monthly income", value: fmtP(c.income.total_monthly_income) },
        ],
        debt_rows: [
          { label: "Monthly debt service", value: fmtP(c.debt_service) },
          { label: "Debt Service Ratio", value: fmtPct(c.dsr) },
          { label: "Disposable after debt service", value: fmtP(c.disposable) },
          { label: "Lending norm", value: `${c.lending_norm_pct}% of income = ${fmtP(Math.round(c.income.total_monthly_income * c.lending_norm_pct) / 100)}` },
        ],
        net_worth_rows: [
          { label: "Assets", value: c.net_worth.assets_captured ? fmtP(c.net_worth.assets) : "Not captured" },
          { label: "Savings & investments", value: c.net_worth.savings_captured ? fmtP(c.net_worth.savings) : "Not captured" },
          { label: "Liabilities (captured balances)", value: fmtP(c.net_worth.liabilities) },
          { label: "Net worth", value: fmtP(c.net_worth.net) },
        ],
        budget_status: !c.budget.captured ? "Budget not captured" : c.budget.shortfall != null && c.budget.shortfall > 0 ? `Shortfall ${fmtP(c.budget.shortfall)} / month` : `Surplus ${fmtP(-(c.budget.shortfall as number))} / month`,
      },
      debts: { rows: debtRows, lines: n.debt_lines, consolidation: c.consolidation.vehicle === "advance" && c.consolidation.advance
        ? `Consolidation vehicle: ${fmtP(c.consolidation.advance.amount)} advance over ${c.consolidation.advance.term_months} months (${fmtP(c.consolidation.advance.instalment)} / month), Advance Recommendation v${c.consolidation.advance.version} of ${fmtDateLong(c.consolidation.advance.date)}.`
        : c.consolidation.advance_reference
          ? `Advance Recommendation v${c.consolidation.advance_reference.version} of ${fmtDateLong(c.consolidation.advance_reference.date)} (${c.consolidation.advance_reference.decision}) is on file for reference${c.consolidation.advance_reference.amount != null ? ` — ${fmtP(c.consolidation.advance_reference.amount)} was assessed` : ""}; it is not a consolidation vehicle.`
          : c.consolidation.rows.length ? "No Advance Recommendation is on file; the consolidation is sized only once one is generated." : "" },
      budget: {
        rows: budgetRows,
        shortfall_line: !c.budget.captured ? "Budget not captured — capturing it is action one; no numeric target is set."
          : c.budget.shortfall != null && c.budget.shortfall > 0 ? `Shortfall: ${fmtP(c.budget.total_spend)} budgeted against ${fmtP(c.income.total_monthly_income)} income = ${fmtP(c.budget.shortfall)} a month — the most urgent item.`
          : `Surplus: ${fmtP(-(c.budget.shortfall as number))} a month after budgeted spending.`,
        cash_gap_line: c.budget.cash_gap != null ? `All-in gap once the ${fmtP(c.debt_service)} of debt service is counted (the budget carries ${fmtP(c.budget.budgeted_debt_lines)} of loan lines): ${fmtP(c.budget.cash_gap)} a month.` : null,
        motshelo_line: c.budget.motshelo_flag ? "The budget's Motshelo / Moraka line is a loan repayment while the motshelo balance is outstanding — it is debt service, not saving." : null,
        paragraph: n.budget_paragraph,
      },
      levers: { bullets: n.lever_bullets, concentration: c.levers.income_concentration },
      phases: c.phases.map((p, i) => ({
        key: p.key, title: `Phase ${i + 1} — ${p.title}`, window: p.window,
        band: p.key === "phase3" ? `Target ≤ ${fmtPct(p.dsr_high)}` : band(p.dsr_low, p.dsr_high),
        surplus: p.surplus_after != null ? fmtP(p.surplus_after) : null,
        paragraph: n.phase_paragraphs[i] || "",
      })),
      triggers: { lines: n.trigger_lines },
      review: { date: fmtDateLong(c.review.review_date), closing: n.closing_sentence },
      consultant_notes: meta.notes,
      refer: c.refer,
      gaps: c.gaps,
    },
  };
}

// The checkable items stored in debt_rehab_plans.actions. The review
// triggers take the model's checkable phrasing when it wrote one line per
// trigger; otherwise the computed labels stand. Nothing else is touched.
export function checkableActions(c: RehabComputed, n: RehabNarrative) {
  const trig = c.triggers.length && n.trigger_lines.length === c.triggers.length ? n.trigger_lines : null;
  return c.actions.map((a) => {
    if (a.group !== "trigger" || !trig) return a;
    const i = c.triggers.findIndex((t) => `trigger:${t.key}` === a.key);
    return i >= 0 && trig[i] ? { ...a, label: trig[i] } : a;
  });
}
