// Key Wellness — Debt Rehab Plan: report content assembly
// ============================================================
// Pure module (no I/O). Turns computeRehab() output into the editable content
// structure the Report tab renders, and supplies the deterministic fallback
// narrative used when the model is unavailable. Shared by the Edge Function
// and tests/smoke-rehab.js so the browser test renders exactly what
// production would.
//
// INTERNAL DOCUMENT. Every string here is written for a Key Wellness advisor,
// not for an employer, an HR manager or the client. The confidentiality banner
// is not decoration: this plan names debts, assets and behaviour that the
// Advance Recommendation deliberately keeps out of an employer-facing report.
// ============================================================
import { fmtP, fmtPct } from "../_shared/kw-finance.ts";
import type { ComputedRehab } from "./compute-rehab.ts";

export const MAX_BULLETS = 6;

export const CONFIDENTIAL_BANNER =
  "CONFIDENTIAL — INTERNAL DEBT REHAB PLAN (Key Wellness use only — not for distribution to employer or employee)";

export interface RehabNarrative {
  root_causes: string[];
  debt_lines: string[];
  budget_paragraph: string;
  lever_bullets: string[];
  phase_paragraphs: string[];
  trigger_lines: string[];
  closing_sentence: string;
}

const actionWord: Record<string, string> = {
  RETAIN: "RETAIN", CONSOLIDATE: "CONSOLIDATE", RENEGOTIATE: "RENEGOTIATE",
};

// ── Deterministic fallback ───────────────────────────────────────
// Terse on purpose. It is built entirely from `computed`, so it can state a
// figure but never interpret one — root causes, the only interpretive
// section, degrade to what the data itself shows.
export function fallbackNarrative(c: ComputedRehab): RehabNarrative {
  const root_causes: string[] = [];
  if (c.counts.consolidate > 0) {
    root_causes.push(`${c.counts.consolidate} informal or high-cost debt${c.counts.consolidate === 1 ? "" : "s"} totalling ${fmtP(c.informal_total)}, compounding faster than they are being serviced.`);
  }
  if (c.counts.renegotiate > 0) {
    const r = c.liabilities.find((l) => l.action === "RENEGOTIATE");
    root_causes.push(`A single formal facility taking ${fmtPct(r?.pct_of_income)} of monthly income on its own.`);
  }
  if (c.budget.shortfall != null && c.budget.shortfall > 0) {
    root_causes.push(`Household spending exceeds income by ${fmtP(c.budget.shortfall)} a month before any debt repayment is counted.`);
  }
  if (!root_causes.length) root_causes.push(`Debt service is ${fmtPct(c.dsr.dsr)} of total monthly income.`);

  const debt_lines = c.liabilities.map((l) => {
    const head = `${l.label}: ${actionWord[l.action]}`;
    if (l.action === "RENEGOTIATE") return `${head} — ${fmtP(l.instalment)} is ${fmtPct(l.pct_of_income)} of income on its own; target ${l.target_text}.`;
    if (l.action === "CONSOLIDATE") return `${head} — ${fmtP(l.balance)} at ${l.rate_text === "Not captured" ? "a rate that is not captured" : l.rate_text}${l.instalment > 0 ? `, serviced at ${fmtP(l.instalment)} a month` : ", not currently serviced"}.`;
    return `${head} — ${fmtP(l.instalment)} a month, inside the ${c.lending_norm_pct}% line; no action needed.`;
  });

  let budget_paragraph: string;
  if (!c.budget.captured) {
    budget_paragraph = "No household budget is on file, so no spending target can be set and a monthly shortfall cannot be ruled out. Capturing it is the first action in this plan.";
  } else if (c.budget.shortfall != null && c.budget.shortfall > 0) {
    budget_paragraph = `Spending of ${fmtP(c.budget.spend)} against income of ${fmtP(c.income.total_monthly_income)} leaves a shortfall of ${fmtP(c.budget.shortfall)} every month. That is the most urgent item in this plan: it is what forces new borrowing.`
      + (c.budget.all_in_shortfall != null ? ` Loan repayments are not in the budget at all, so the true monthly gap is ${fmtP(c.budget.all_in_shortfall)}.` : "");
  } else {
    budget_paragraph = `Spending of ${fmtP(c.budget.spend)} sits within income of ${fmtP(c.income.total_monthly_income)}. The correction below is about the shape of that spending, not its total.`;
  }

  const lever_bullets = c.levers.filter((l) => l.included).slice(0, MAX_BULLETS).map((l) => l.detail + ".");
  if (!lever_bullets.length) lever_bullets.push("No asset or savings lever is available on the record as captured.");

  const phase_paragraphs = c.phases.map((p) => {
    const band = p.key === "phase_3"
      ? `The plan closes when debt service is ${p.band_text.toLowerCase()} of income and the monthly surplus is positive.`
      : `Debt service over this window is ${p.band_text} of income.`;
    return `${p.title} (${p.window}). ${band} ${p.assumptions[0] || ""}`.trim();
  });

  const closing_sentence = c.review_date
    ? `Next review ${c.review_date}. By then the actions in Phase 1 must be started and the budget correction agreed with the client.`
    : "Set a review date within 30 days and confirm the Phase 1 actions have been started.";

  return {
    root_causes: root_causes.slice(0, 3),
    debt_lines,
    budget_paragraph,
    lever_bullets,
    phase_paragraphs,
    trigger_lines: c.triggers.slice(),
    closing_sentence,
  };
}

// ── Content skeleton (spec §6) ───────────────────────────────────
// Ten sections. Names, employer and consultant are rendered from the record,
// never from model output — the model never receives them.
export function buildRehabContent(
  c: ComputedRehab,
  meta: { client_name: string; employer: string; consultant: string; generated_date: string; consultation_notes: { label: string; body: string }[] },
  n: RehabNarrative,
) {
  const debtRows = c.liabilities.map((l) => ({
    debt: l.label,
    institution: l.institution || "—",
    rate: l.rate_text,
    instalment: fmtP(l.instalment),
    action: l.action,
    outcome: l.action === "RENEGOTIATE" ? l.target_text
      : l.action === "CONSOLIDATE"
        ? (l.settled_by_advance ? `Settled by the advance (${fmtP(l.balance)})` : `${fmtP(l.balance)} outstanding — consolidation not yet sized`)
        : "No change",
  }));

  const budgetRows = c.budget.rows.map((r) => ({
    group: r.label,
    actual: fmtP(r.actual),
    pct: fmtPct(r.pct_of_income),
    target_pct: r.target_pct == null ? "—" : r.target_pct + "%",
    cut: r.cut == null ? "—" : (r.cut > 0 ? fmtP(r.cut) : "None"),
    note: r.note,
  }));

  return {
    meta: {
      title: "Debt Rehab Plan",
      banner: CONFIDENTIAL_BANNER,
      client_name: meta.client_name,
      employer: meta.employer || "Not captured",
      consultant: meta.consultant,
      generated_date: meta.generated_date,
      review_date: c.review_date,
      headline: c.headline,
      enrollment_trigger: c.consolidation.ar_version != null
        ? `Advance Recommendation v${c.consolidation.ar_version}${c.consolidation.dated ? " of " + c.consolidation.dated : ""}`
        : `Debt service at ${fmtPct(c.dsr.dsr)} of income`,
      band: c.band,
    },
    sections: {
      root_causes: { title: "Root Causes", bullets: n.root_causes },
      position: {
        title: "Financial Position Snapshot",
        rows: [
          { label: "Total monthly income", value: fmtP(c.income.total_monthly_income) },
          { label: "Monthly debt service", value: fmtP(c.dsr.debt_service) },
          { label: "Debt service ratio", value: fmtPct(c.dsr.dsr) },
          { label: "Disposable after debt service", value: fmtP(c.dsr.disposable) },
          { label: "Assets", value: fmtP(c.net_worth.assets) },
          { label: "Savings", value: fmtP(c.net_worth.savings) },
          { label: "Liabilities", value: fmtP(c.net_worth.liabilities) },
          { label: "Net worth", value: fmtP(c.net_worth.total) },
        ],
        headline_reasons: c.headline_reasons,
      },
      debts: { title: "Debt-by-Debt Actions", rows: debtRows, lines: n.debt_lines, consolidation_note: c.consolidation.note },
      budget: {
        title: "Budget Correction",
        rows: budgetRows,
        paragraph: n.budget_paragraph,
        motshelo_note: c.budget.motshelo_note,
      },
      levers: { title: "Income & Asset Levers", bullets: n.lever_bullets },
      phases: {
        title: "Phased Recovery Plan",
        phases: c.phases.map((p, i) => ({
          key: p.key, title: p.title, window: p.window, band: p.band_text,
          paragraph: n.phase_paragraphs[i] || "",
          actions: p.actions,
        })),
      },
      triggers: { title: "Risk Monitoring — Review Triggers", lines: n.trigger_lines },
      review: { title: "Next Scheduled Review", date: c.review_date, closing: n.closing_sentence },
      notes: { title: "Consultant Notes", consultant: meta.consultant, entries: meta.consultation_notes },
      gaps: c.gaps,
    },
  };
}
