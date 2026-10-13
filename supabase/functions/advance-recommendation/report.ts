// Key Wellness — Advance Recommendation: report content assembly
// ============================================================
// Pure module (no I/O). Turns compute() output into the editable content
// structure the Report tab renders, and supplies the deterministic
// fallback narrative used when the model is unavailable. Shared by the
// Edge Function and tests/smoke-advance.js so the browser test renders
// exactly what production would.
// ============================================================
import { fmtP, fmtPct, DSR_BENCHMARK_PCT, stripDashes } from "./compute.ts";
import type { Computed } from "./compute.ts";

export const MAX_BULLETS = 6;
export const ADVANCE_TYPE = "Salary / Incentive Advance";

// The employer is named four times in a finished report: the programme
// heading, the payroll line on the debt table, the confidentiality statement,
// and the header field. All four used to say "Hollard" literally, and the
// header fell back to "Hollard" when the employer was blank — so a client
// with no employer captured got a document asserting a Hollard programme.
//
// Only an organisation with organizations.offers_advances may reach this
// code now, and the employer name comes from the client's record. For a
// Hollard client every string below is byte-identical to what it produced
// before; for anyone else it is correct instead of wrong.
export const EMPLOYER_UNKNOWN = "Not captured";
export const programmeFor = (employer: string) =>
  `${employer} Employee Financial Wellness Program`;
export const payrollLineFor = (employer: string) => `${employer} (payroll)`;
export const confidentialityFor = (employer: string) =>
  `This report contains only the professional recommendation from the Financial Wellness Consultation, to support ${employer}'s advance approval process. Underlying financial details remain confidential between the employee and the Consultant, disclosed only as required by law or with consent.`;

// ── Deterministic content skeleton ──────────────────────────────
// Tables and fixed text. Prose slots start with the fallback narrative
// so the report is complete even before the model answers.
export interface Narrative {
  reasoning_intro: string; reasoning_bullets: string[]; reasoning_close: string;
  dsr_paragraph: string; ability_paragraph: string; risk_sentences: string;
  recommendation_intro: string; closing_sentence: string;
}

// "Other – Express Credit" reads badly; when the item is the generic
// "Other", the institution is the name that means something.
const liabLabel = (l: { item: string; institution: string }) =>
  l.item === "Other" && l.institution ? l.institution : `${l.item}${l.institution ? " – " + l.institution : ""}`;

// ── The advisor's figure (13 Oct 2026) ─────────────────────────
// Prose for a report computed on an override. Every string goes through
// stripDashes (the copy rule for new report strings). None of it mentions
// the portal's own figure, the cap, or that the figure was changed.
export const ADVISOR_SECTION_TITLE = "Advisor's recommendation";

export function overrideNarrative(c: Computed): Narrative {
  const o = c.override!, adv = c.advance!, aft = c.after!;
  const full = o.allocations.filter((x) => x.settles_in_full).length;
  const bullets = o.allocations.slice(0, MAX_BULLETS).map((x) =>
    x.kind === "liability"
      ? `${x.label}: ${fmtP(x.amount)}${x.settles_in_full ? ", settling the balance in full" : x.outstanding_balance != null ? ` towards a balance of ${fmtP(x.outstanding_balance)}` : ""}.`
      : `${x.label}: ${fmtP(x.amount)}.`);
  const dsr_paragraph = c.dsr_change
    ? (c.dsr_change.direction === "worsened"
        ? `DSR rises from ${fmtPct(c.before.dsr)} to ${fmtPct(aft.dsr)}: the advance instalment of ${fmtP(adv.instalment)} is more than the instalments of the debts it settles.`
        : c.dsr_change.direction === "improved"
          ? `DSR falls from ${fmtPct(c.before.dsr)} to ${fmtPct(aft.dsr)} because the advance instalment is less than the instalments of the debts it settles. It remains ${aft.dsr! >= DSR_BENCHMARK_PCT ? "above" : "below"} the ${DSR_BENCHMARK_PCT}% wellbeing benchmark.`
          : `DSR is effectively unchanged at ${fmtPct(aft.dsr)}.`)
    : `DSR after the advance is ${fmtPct(aft.dsr)}.`;
  const n: Narrative = {
    reasoning_intro: `The consultant has set the advance to cover the uses listed in the advisor's recommendation${full ? `, settling ${full} debt${full === 1 ? "" : "s"} in full` : ""}.`,
    reasoning_bullets: bullets,
    reasoning_close: `The recommended advance is ${fmtP(adv.amount)}, repaid at ${fmtP(adv.instalment)} per month over ${c.term_months} months with no interest.`,
    dsr_paragraph,
    ability_paragraph: `The advance instalment of ${fmtP(adv.instalment)} is ${fmtPct(adv.instalment_pct_income)} of own gross income, leaving ${fmtP(aft.disposable)} after all debt service. ${c.budget.captured ? (c.budget.shortfall ? "The captured household budget already exceeds income, which is the binding constraint." : "The captured household budget fits within that amount.") : "No household budget is on file, so living costs cannot be confirmed against that figure."}`,
    risk_sentences: c.decision_reasons.join(" "),
    recommendation_intro: `The conditions below apply to the advance recommended above.`,
    closing_sentence: `Re-assess within 30 days of disbursement, once proof of payment for the uses above has been received.`,
  };
  return cleanNarrative(n);
}

// Applies the copy rule to a narrative (model or deterministic) for an
// overridden report.
export function cleanNarrative(n: Narrative): Narrative {
  return {
    reasoning_intro: stripDashes(n.reasoning_intro), reasoning_bullets: n.reasoning_bullets.map(stripDashes),
    reasoning_close: stripDashes(n.reasoning_close), dsr_paragraph: stripDashes(n.dsr_paragraph),
    ability_paragraph: stripDashes(n.ability_paragraph), risk_sentences: stripDashes(n.risk_sentences),
    recommendation_intro: stripDashes(n.recommendation_intro), closing_sentence: stripDashes(n.closing_sentence),
  };
}

export function fallbackNarrative(c: Computed): Narrative {
  if (c.override && c.advance && c.after) return overrideNarrative(c);
  const inf = c.liabilities.filter((l) => l.classification === "informal");
  const bullets = (inf.length ? inf : c.liabilities).slice(0, MAX_BULLETS).map((l) =>
    `${liabLabel(l)}: ${l.rate_text === "Not captured" ? "rate not captured" : l.rate_text}, ${l.instalment > 0 ? "serviced at " + fmtP(l.instalment) + " per month" : "not currently serviced"}${l.balance == null ? ", balance not captured" : ""}.`);
  const adv = c.advance, aft = c.after;
  const reasoning_close = adv
    ? `The recommended advance is ${fmtP(adv.amount)}, sized to clear the informal and high-cost balances exactly and nothing more.`
    : `No advance amount is recommended: ${c.decision_reasons[0] || "there is no consolidation opportunity."}`;
  const dsr_paragraph = adv && aft && c.dsr_change
    ? (c.dsr_change.direction === "worsened"
        ? `DSR rises from ${fmtPct(c.before.dsr)} to ${fmtPct(aft.dsr)}. This is a deterioration: the informal debts being settled carried no monthly instalment, so the advance instalment is a new cash obligation rather than a replacement.`
        : c.dsr_change.direction === "improved"
          ? `DSR falls from ${fmtPct(c.before.dsr)} to ${fmtPct(aft.dsr)} because a serviced high-cost instalment is replaced by a smaller advance instalment. It remains ${aft.dsr! >= DSR_BENCHMARK_PCT ? "above" : "below"} the ${DSR_BENCHMARK_PCT}% wellbeing benchmark.`
          : `DSR is effectively unchanged at ${fmtPct(aft.dsr)}.`)
    : `Current DSR is ${fmtPct(c.before.dsr)} of own gross monthly income of ${fmtP(c.income.dsr_income ?? c.income.gross_salary)}.`;
  const ability_paragraph = adv && aft
    ? `The advance instalment of ${fmtP(adv.instalment)} is ${fmtPct(adv.instalment_pct_income)} of own gross income, leaving ${fmtP(aft.disposable)} after all debt service. ${c.budget.captured ? (c.budget.shortfall ? "The captured household budget already exceeds income, which is the binding constraint." : "The captured household budget fits within that amount.") : "No household budget is on file, so living costs cannot be confirmed against that figure."}`
    : `Disposable income after current debt service is ${fmtP(c.before.disposable)}. ${c.budget.captured ? "" : "No household budget is on file."}`.trim();
  return {
    reasoning_intro: adv
      ? `The employee carries ${inf.length} informal or high-cost obligation${inf.length === 1 ? "" : "s"} alongside formal borrowing. Only the informal and high-cost balances are candidates for consolidation; formal facilities are left unchanged.`
      : `No informal or high-cost debt is available to consolidate, so an advance would not remove any existing obligation.`,
    reasoning_bullets: bullets,
    reasoning_close,
    dsr_paragraph,
    ability_paragraph,
    risk_sentences: c.decision_reasons.join(" "),
    recommendation_intro: adv ? `On the figures above, the consultant's recommendation is as follows.` : `On the figures above, an advance is not recommended at this time.`,
    closing_sentence: adv
      ? `Re-assess within 30 days of disbursement, once proof of settlement of the informal debts has been received.`
      : `Re-assess once updated creditor statements and a household budget are on file.`,
  };
}

export function buildContent(c: Computed, meta: { consultant: string; consultation_date: string; recommendation_date: string }, n: Narrative) {
  const adv = c.advance, aft = c.after;
  const employerName = (c.employee.employer || "").trim() || EMPLOYER_UNKNOWN;
  const settled = new Set(adv ? adv.settles : []);
  const o = c.override;
  // On the advisor's figure, every partly-paid liability is named, and an
  // informal debt the advance does not touch is "not covered", not "beyond
  // the cap" (the cap is not what sized it).
  const partOf = (idx: number) => o ? o.allocations.find((x) => x.live_index === idx && !x.settles_in_full) : undefined;
  const debtRows = c.liabilities.map((l) => ({
    debt: l.item, institution: l.institution || "—", interest: l.rate_text,
    balance: fmtP(l.balance), instalment: fmtP(l.instalment),
    status: settled.has(l.index) ? "Settled by advance"
      : o ? (partOf(l.index) ? `Part-paid by advance (${fmtP(partOf(l.index)!.amount)}); instalment unchanged`
            : l.classification === "informal" ? "Not covered by the advance" : "Unchanged")
      : (adv && adv.partial && adv.partial.index === l.index) ? `Part-paid by advance (${fmtP(adv.partial.applied)}); instalment unchanged`
      : l.classification === "informal" ? (l.balance == null ? "Informal – balance not captured" : "Informal – beyond the advance cap")
      : "Unchanged",
  }));
  if (adv) debtRows.push({
    debt: "New advance", institution: payrollLineFor(employerName), interest: "0%", balance: fmtP(adv.amount),
    instalment: "—", status: `${fmtP(adv.instalment)} / month for ${c.term_months} months`,
  });
  return {
    meta: {
      programme: programmeFor(employerName),
      employee_name: c.employee.name, employer: employerName,
      consultation_date: meta.consultation_date, recommendation_date: meta.recommendation_date,
      consultant: meta.consultant, advance_type: ADVANCE_TYPE,
      recommended_amount: adv ? fmtP(adv.amount) : "None",
      repayment_term: adv ? `${c.term_months} months` : "Not applicable",
      tier: c.tier, decision: c.decision,
    },
    sections: {
      reasoning: { intro: n.reasoning_intro, bullets: n.reasoning_bullets, close: n.reasoning_close },
      dsr: {
        title: adv ? "Debt Service Ratio — Before vs After" : "Debt Service Ratio — Current Position",
        rows: [
          { label: "Monthly debt service", before: fmtP(c.before.debt_service), after: aft ? fmtP(aft.debt_service) : null },
          { label: "Own gross monthly income", before: fmtP(c.income.dsr_income ?? c.income.gross_salary), after: aft ? fmtP(c.income.dsr_income ?? c.income.gross_salary) : null },
          { label: "Debt Service Ratio", before: fmtPct(c.before.dsr), after: aft ? fmtPct(aft.dsr) : null },
        ],
        paragraph: n.dsr_paragraph,
      },
      ability: { title: adv ? `Ability to Repay Over ${c.term_months} Months` : "Ability to Repay", paragraph: n.ability_paragraph },
      debt_position: { title: adv ? "Debt Position — Before vs After" : "Debt Position (as captured)", rows: debtRows },
      risk: { tier: c.tier, text: n.risk_sentences },
      recommendation: { decision: c.decision, intro: n.recommendation_intro, closing: n.closing_sentence },
      gaps: o ? c.gaps.map(stripDashes) : c.gaps,
      confidentiality: confidentialityFor(employerName),
      ...(o && adv ? { advisor_recommendation: advisorSection(c) } : {}),
    },
  };
}

// The section printed beside the decision when the advisor set the figure.
// What it does NOT carry: the portal's figure, the cap, the internal notes,
// and the words "override" or "amended".
function advisorSection(c: Computed) {
  const o = c.override!, adv = c.advance!;
  const total = o.allocations.reduce((s, x) => s + x.amount, 0);
  return {
    title: ADVISOR_SECTION_TITLE,
    justification: stripDashes(o.justification),
    recommended_advance: fmtP(adv.amount),
    repayment: stripDashes(`${fmtP(adv.instalment)} per month over ${c.term_months} months, no interest`),
    use_of_funds: {
      headers: ["Lender or purpose", "Outstanding balance", "Allocated amount"],
      rows: o.allocations.map((x) => ({
        label: stripDashes(x.label),
        balance: x.kind === "liability" && x.outstanding_balance != null ? fmtP(x.outstanding_balance) : "",
        amount: fmtP(x.amount),
      })),
      total_label: "Total",
      total: fmtP(Math.round(total * 100) / 100),
    },
  };
}
