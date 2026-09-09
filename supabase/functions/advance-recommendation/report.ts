// Key Wellness — Advance Recommendation: report content assembly
// ============================================================
// Pure module (no I/O). Turns compute() output into the editable content
// structure the Report tab renders, and supplies the deterministic
// fallback narrative used when the model is unavailable. Shared by the
// Edge Function and tests/smoke-advance.js so the browser test renders
// exactly what production would.
// ============================================================
import { fmtP, fmtPct } from "./compute.ts";
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

export function fallbackNarrative(c: Computed): Narrative {
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
          ? `DSR falls from ${fmtPct(c.before.dsr)} to ${fmtPct(aft.dsr)} because a serviced high-cost instalment is replaced by a smaller advance instalment. It remains ${aft.dsr! > 35 ? "above" : "within"} the 35% comfort level.`
          : `DSR is effectively unchanged at ${fmtPct(aft.dsr)}.`)
    : `Current DSR is ${fmtPct(c.before.dsr)} on total monthly income of ${fmtP(c.income.total_monthly_income)}.`;
  const ability_paragraph = adv && aft
    ? `The advance instalment of ${fmtP(adv.instalment)} is ${fmtPct(adv.instalment_pct_income)} of monthly income, leaving ${fmtP(aft.disposable)} after all debt service. ${c.budget.captured ? (c.budget.shortfall ? "The captured household budget already exceeds income, which is the binding constraint." : "The captured household budget fits within that amount.") : "No household budget is on file, so living costs cannot be confirmed against that figure."}`
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
  const debtRows = c.liabilities.map((l) => ({
    debt: l.item, institution: l.institution || "—", interest: l.rate_text,
    balance: fmtP(l.balance), instalment: fmtP(l.instalment),
    status: settled.has(l.index) ? "Settled by advance" : l.classification === "informal" ? "Informal – balance not captured" : "Unchanged",
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
          { label: "Total monthly income", before: fmtP(c.income.total_monthly_income), after: aft ? fmtP(c.income.total_monthly_income) : null },
          { label: "Debt Service Ratio", before: fmtPct(c.before.dsr), after: aft ? fmtPct(aft.dsr) : null },
        ],
        paragraph: n.dsr_paragraph,
      },
      ability: { title: adv ? `Ability to Repay Over ${c.term_months} Months` : "Ability to Repay", paragraph: n.ability_paragraph },
      debt_position: { title: adv ? "Debt Position — Before vs After" : "Debt Position (as captured)", rows: debtRows },
      risk: { tier: c.tier, text: n.risk_sentences },
      recommendation: { decision: c.decision, intro: n.recommendation_intro, closing: n.closing_sentence },
      gaps: c.gaps,
      confidentiality: confidentialityFor(employerName),
    },
  };
}
