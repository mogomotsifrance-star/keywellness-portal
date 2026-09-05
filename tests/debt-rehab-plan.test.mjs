// Node 22 test for supabase/functions/debt-rehab-plan/compute-rehab.ts
// Run: node tests/debt-rehab-plan.test.mjs
import { computeRehab, suggestAction, remainingTerm, amortisedPayment, addDays } from "../supabase/functions/debt-rehab-plan/compute-rehab.ts";
import { liveLiabilities } from "../supabase/functions/_shared/kw-finance.ts";
import assert from "node:assert/strict";

// Olorato Maliko, reconstructed from spec v2 §1/§7 and the live record
// (FNB rate blank; balance derived from net worth −P 133,000.00).
// Income P 12,300.00 = net salary P 4,000.00 (below the tax threshold) + BNO Fashions P 8,300.00.
const BLANK = [
  {item:"Mortgage Loan", institution:"", loanAmount:"0", interestRate:"", balance:"0", monthlyInstalment:"0"},
  {item:"Credit Card", institution:"", loanAmount:"0", interestRate:"", balance:"0", monthlyInstalment:"0"},
  {item:"Car Loan", institution:"", loanAmount:"0", interestRate:"", balance:"0", monthlyInstalment:"0"},
  {item:"Other", institution:"", loanAmount:"0", interestRate:"", balance:"0", monthlyInstalment:"0"},
];
const OLORATO = {
  personal:{ name:"Olorato", surname:"Maliko", employer:"Sedimosa", maritalStatus:"Married", regime:"Out of Community", age:"38" },
  kids:[{},{}],
  income:{ monthlySalary:4000, otherDeductions:0, spouseIncome:0, rentals:0, businessIncome:8300, dividends:0 },
  liabilities:[
    {item:"Personal Loan", institution:"FNB", loanAmount:"250000", interestRate:"", balance:"210000", monthlyInstalment:"5500"},
    ...BLANK,
    {item:"Other", institution:"Motshelo", loanAmount:"16000", interestRate:"30% monthly", balance:"16000", monthlyInstalment:"0"},
    {item:"Other", institution:"Mother", loanAmount:"7000", interestRate:"25% monthly", balance:"7000", monthlyInstalment:"0"},
  ],
  assets:[ {name:"AUDI A3", value:100000, status:"Personal Use", size:"", monthlyIncome:0, potentialIncome:0} ],
  savings:[],
  budget:{ housing:4000, food:2400, transport:1000, entertain:1200, emfund:2400, misc:4850 },
  notes:{ income:"", expense:"", debt:"Failed forex investment funded by motshelo.", lifestyle:"", general:"BNO Fashions income has been declining since May." },
};
const AR_CTX = { version:1, status:"final", decision:"Proceed with Conditional Approval", tier:"AMBER", advance_amount:23000, term_months:24, generated_at:"2026-08-28T09:00:00Z", debt_rehab_on:true };
const NOTES = ["Failed forex investment funded by motshelo.", "BNO Fashions income has been declining since May."];
const PLAN = { plan_date:"2026-09-03", consultation_date:"2026-09-01" };

let n = 0; const ok = (name, fn) => { fn(); n++; console.log("  ✓", name); };
const byInst = (c, s) => c.liabilities.find(l => l.institution === s);

console.log("Olorato (spec §7, corrected)");
const live = liveLiabilities(OLORATO);
ok("blank template rows dropped → 3 live", () => assert.equal(live.length, 3));
const sugg = live.map(l => suggestAction(l.raw, 12300, 35));
ok("suggested actions: FNB RENEGOTIATE, motshelo + mother CONSOLIDATE", () =>
  assert.deepEqual(sugg.map(s => s.action), ["RENEGOTIATE", "CONSOLIDATE", "CONSOLIDATE"]));
ok("bare '30' / '25' on the live 'Motshelo' and 'Motshelo Mother' rows read as per month", () => {
  const live30 = suggestAction({item:"Other", institution:"Motshelo", loanAmount:"16000", interestRate:"30", balance:"16000", monthlyInstalment:"0"}, 12300, 35);
  const live25 = suggestAction({item:"Other", institution:"Motshelo Mother", loanAmount:"7000", interestRate:"25", balance:"7000", monthlyInstalment:"0"}, 12300, 35);
  assert.equal(live30.rate_period, "monthly"); assert.equal(live25.rate_period, "monthly"); assert.equal(live30.action, "CONSOLIDATE");
  assert.equal(suggestAction({item:"Personal Loan", institution:"FNB", loanAmount:"250000", interestRate:"14", balance:"250000", monthlyInstalment:"5500"}, 12300, 35).rate_period, "annual");
});
const c = computeRehab(OLORATO, { ...PLAN, liabilities: live.map((l,i)=>({ index:i, action:sugg[i].action, classification:sugg[i].classification, rate_period:sugg[i].rate_period })) }, { rehab_context: AR_CTX, advisor_notes: NOTES });
ok("income P 12,300.00 · debt service P 5,500.00 · DSR 44.72% · strained", () => {
  assert.equal(c.income.total_monthly_income, 12300); assert.equal(c.debt_service, 5500); assert.equal(c.dsr, 44.72); assert.equal(c.dsr_status, "strained"); assert.equal(c.tier, "AMBER");
});
ok("FNB: RENEGOTIATE, cap P 4,305.00, rate blank → no amortised figure, rate gap", () => {
  const f = byInst(c, "FNB"); assert.equal(f.action, "RENEGOTIATE"); assert.equal(f.instalment_pct_income, 44.72);
  assert.equal(f.renegotiation.cap, 4305); assert.equal(f.renegotiation.amortised, null); assert.equal(f.renegotiation.band_high, 4305);
  assert.ok(f.gaps.some(g => /Interest rate not captured/.test(g))); assert.match(f.outcome, /Target ≤ P 4,305\.00/);
});
ok("motshelo + mother: CONSOLIDATE, monthly rates, P 23,000.00 settled by the AR v1 advance of 28 Aug 2026", () => {
  assert.equal(byInst(c, "Motshelo").rate_pa_equivalent, 360); assert.equal(byInst(c, "Mother").rate_period, "monthly");
  assert.equal(c.consolidation.balance, 23000); assert.equal(c.consolidation.vehicle, "advance");
  assert.equal(c.consolidation.advance.instalment, 958.33); assert.equal(c.consolidation.advance.version, 1);
  assert.match(byInst(c, "Motshelo").outcome, /P 23,000\.00 advance \(AR v1, 28 Aug 2026\)/);
});
ok("budget 60.16 / 9.76 / 19.51 / 39.43% · spend P 15,850.00 · shortfall P 3,550.00", () => {
  assert.deepEqual(c.budget.groups.map(g => g.pct), [60.16, 9.76, 19.51, 39.43]);
  assert.equal(c.budget.total_spend, 15850); assert.equal(c.budget.shortfall, 3550);
});
ok("cuts sum to the shortfall: needs P 1,250.00, wants 0, other P 2,300.00", () =>
  assert.deepEqual(c.budget.groups.map(g => g.cut), [1250, 0, 0, 2300]));
ok("all-in cash gap P 9,050.00 (budget carries no debt line)", () => { assert.equal(c.budget.budgeted_debt_lines, 0); assert.equal(c.budget.cash_gap, 9050); });
ok("levers: AUDI on, covers the informal balance 4.35×; savings not captured is a gap; single earner + declining business", () => {
  assert.equal(c.levers.assets.length, 1); assert.equal(c.levers.assets[0].on, true); assert.equal(c.levers.assets[0].cover_multiple, 4.35);
  assert.ok(c.gaps.some(g => /Savings and investments not captured/.test(g)));
  assert.equal(c.levers.income_concentration.length, 3);
});
ok("net worth −P 133,000.00 (assets 100,000 − liabilities 233,000, savings 0)", () => assert.equal(c.net_worth.net, -133000));
ok("Phase 1 band 44.72% – 52.51% · Phase 2 band 35.00% – 42.79% · Phase 3 target 35%", () => {
  assert.equal(c.phases[0].dsr_low, 44.72); assert.equal(c.phases[0].dsr_high, 52.51);
  assert.equal(c.phases[1].dsr_low, 35); assert.equal(c.phases[1].dsr_high, 42.79); assert.equal(c.phases[1].surplus_after, 0);
  assert.equal(c.phases[2].dsr_high, 35); assert.equal(c.exit.gap_points_from_phase2, 0);
});
ok("no REFER · headline 1 renegotiate · 2 consolidate · 0 retain; shortfall P 3,550.00", () => {
  assert.equal(c.refer.on, false); assert.equal(c.headline, "1 renegotiate · 2 consolidate · 0 retain; shortfall P 3,550.00");
});
ok("five review triggers incl. missed advance, AUDI unsold at 60 days, income below P 11,070.00", () => {
  assert.equal(c.triggers.length, 5);
  assert.ok(c.triggers.some(t => /AUDI A3 unsold 60 days/.test(t.label)));
  assert.ok(c.triggers.some(t => /below P 11,070\.00/.test(t.label)));
  assert.ok(c.triggers.some(t => t.key === "missed_advance"));
});
ok("review date 30 days after the plan date: 2026-10-03", () => assert.equal(c.review.review_date, "2026-10-03"));
ok("checkable actions carry phase / lever / trigger groups and all start on", () => {
  const g = new Set(c.actions.map(a => a.group)); ["phase1","phase2","phase3","lever","trigger"].forEach(k => assert.ok(g.has(k), k));
  assert.ok(c.actions.every(a => a.on));
});

console.log("FNB variant — rate captured (12% p.a.), so the term is derived");
const V = { ...OLORATO, liabilities: OLORATO.liabilities.map(l => l.institution === "FNB" ? { ...l, interestRate:"12" } : l) };
const vc = computeRehab(V, PLAN, { rehab_context: AR_CTX });
ok("remaining term 49 → +24 = 73 months · amortised P 4,067.08 ≤ cap · Phase 2 low 33.07%", () => {
  const r = byInst(vc, "FNB").renegotiation;
  assert.equal(r.term_source, "derived"); assert.equal(r.remaining_term_months, 49); assert.equal(r.new_term_months, 73);
  assert.equal(r.amortised, 4067.08); assert.equal(r.reachable, true); assert.equal(r.extension_needed_months, 24);
  assert.equal(vc.phases[1].dsr_low, 33.07);
});
ok("annuity helpers agree with the hand calculation", () => {
  assert.equal(remainingTerm(210000, 0.01, 5500), 49); assert.equal(Math.round(amortisedPayment(210000, 0.01, 73) * 100) / 100, 4067.08);
  assert.equal(addDays("2026-12-25", 30), "2027-01-24");
});

console.log("Budget not captured");
const B = { ...OLORATO, budget:{} };
const bc = computeRehab(B, PLAN, { rehab_context: AR_CTX });
ok("action one is capturing the budget; no targets, shortfall null, no cash gap", () => {
  assert.equal(bc.budget.captured, false); assert.equal(bc.budget.shortfall, null); assert.equal(bc.budget.cash_gap, null); assert.equal(bc.budget.groups.length, 0);
  assert.equal(bc.phases[0].actions[0].key, "budget_capture"); assert.ok(bc.gaps.some(g => /budget not captured/.test(g)));
  assert.equal(bc.phases[1].surplus_after, null);
});

console.log("No informal debt");
const N = { ...OLORATO, liabilities:[ OLORATO.liabilities[0] ] };
const nc = computeRehab(N, PLAN, { rehab_context: null });
ok("no CONSOLIDATE rows, vehicle none, Phase 1 band collapses to the current DSR", () => {
  assert.equal(nc.consolidation.rows.length, 0); assert.equal(nc.consolidation.vehicle, "none");
  assert.equal(nc.phases[0].dsr_low, 44.72); assert.equal(nc.phases[0].dsr_high, 44.72);
  assert.ok(!nc.triggers.some(t => t.key === "missed_advance"));
});

console.log("Three informal lenders, no balances, no AR → REFER");
const R = { ...OLORATO, assets:[], liabilities:[ OLORATO.liabilities[0],
  {item:"Other", institution:"Motshelo", interestRate:"30% monthly", balance:"", monthlyInstalment:"0"},
  {item:"Other", institution:"Mashonisa", interestRate:"", balance:"0", monthlyInstalment:"0"},
  {item:"Other", institution:"Uncle", interestRate:"", balance:"", monthlyInstalment:"0"} ] };
const rc = computeRehab(R, PLAN, { rehab_context: null });
ok("plan-level REFER with three balance gaps; headline says so", () => {
  assert.equal(rc.refer.on, true); assert.equal(rc.consolidation.uncaptured.length, 3);
  assert.equal(rc.gaps.filter(g => /Balance not captured/.test(g)).length, 3);
  assert.equal(rc.headline, "REFER to formal debt counselling");
});

console.log("Savings balance covers an informal balance");
const S = { ...OLORATO, savings:[ {institution:"Stanbic", currentBalance:9000, monthlyContribution:0, purpose:"Emergency"} ] };
const sc = computeRehab(S, PLAN, { rehab_context: null });
ok("mother's P 7,000.00 is settled from Stanbic savings; motshelo still needs a vehicle", () => {
  assert.equal(sc.consolidation.savings_matches.length, 1); assert.equal(sc.consolidation.savings_matches[0].settles_label, "Mother");
  assert.equal(byInst(sc, "Mother").settled_by, "savings"); assert.equal(sc.consolidation.vehicle, "asset");
  assert.match(byInst(sc, "Motshelo").outcome, /AUDI A3/);
});
ok("without the AR, Phase 1 has no advance instalment: band 44.72% – 44.72%", () => { assert.equal(sc.phases[0].dsr_high, 44.72); });

console.log("Rate text that fails to parse");
const P = { ...OLORATO, liabilities:[ { ...OLORATO.liabilities[0], interestRate:"prime plus two" }, OLORATO.liabilities[5] ] };
const pc = computeRehab(P, PLAN, {});
ok("'prime plus two' → Not captured, rate gap, action still RENEGOTIATE on the instalment test", () => {
  const f = byInst(pc, "FNB"); assert.equal(f.rate_value, null); assert.equal(f.rate_text, "Not captured"); assert.equal(f.action, "RENEGOTIATE");
});

console.log("Edges of the RENEGOTIATE line and the advisor's override");
const E = { ...OLORATO, liabilities:[ { ...OLORATO.liabilities[0], monthlyInstalment:"4305" } ] };
ok("a formal loan at exactly 35.00% of income is RETAIN (strict >)", () => assert.equal(computeRehab(E, PLAN, {}).liabilities[0].action, "RETAIN"));
const oc = computeRehab(OLORATO, { ...PLAN, liabilities:[{index:1, action:"RETAIN"}] }, { rehab_context: AR_CTX });
ok("a CONSOLIDATE row the advisor forces to RETAIN is not sized", () => {
  assert.equal(byInst(oc, "Motshelo").action, "RETAIN"); assert.equal(oc.consolidation.balance, 7000);
});
const U = { ...OLORATO, liabilities:[ { ...OLORATO.liabilities[0], interestRate:"40", balance:"210000" } ] };
const uc = computeRehab(U, { ...PLAN, liabilities:[{index:0, action:"RENEGOTIATE", classification:"formal"}] }, {});
ok("interest alone above the cap → unreachable by extension (term not derivable either), REFER input", () => {
  const r = byInst(uc, "FNB").renegotiation; assert.equal(r.reachable, false); assert.equal(r.remaining_term_months, null); assert.equal(uc.refer.on, true);
  assert.match(byInst(uc, "FNB").outcome, /interest alone exceeds it/);
});

console.log("Motshelo flag and a declined AR");
const M = { ...OLORATO, budget:{ ...OLORATO.budget, emfund:0, motshelo:2400 } };
ok("motshelo in the budget's savings group + a motshelo debt → flag and a Phase 2 action", () => {
  const mc = computeRehab(M, PLAN, {}); assert.equal(mc.budget.motshelo_flag, true); assert.ok(mc.phases[1].actions.some(x => x.key === "motshelo"));
  assert.equal(computeRehab(OLORATO, PLAN, {}).budget.motshelo_flag, false);
});
const DC = computeRehab(OLORATO, PLAN, { rehab_context: { ...AR_CTX, decision:"Decline – Refer to Debt Restructuring", tier:"RED" } });
ok("a declined AR is printed for reference, never used as the vehicle", () => {
  assert.equal(DC.advance_recommendation.debt_rehab_on, true);
  assert.equal(DC.consolidation.advance, null); assert.equal(DC.consolidation.advance_reference.decision, "Decline – Refer to Debt Restructuring");
  assert.equal(DC.consolidation.vehicle, "asset");
});

console.log(`\n${n} checks passed`);
