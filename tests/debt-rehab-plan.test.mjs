// Node 22 test for supabase/functions/debt-rehab-plan/compute-rehab.ts
// Run: node tests/debt-rehab-plan.test.mjs
//
// The fixture is Olorato Maliko's real advisor_clients.assessment, read from
// the live project on 3 Sep 2026 — the worked example in
// docs/build/debt-rehab-plan-spec.md §7. Her figures are reproduced to the
// cent here for the same reason Tumelo's are in the Advance Recommendation
// suite: a worked example nobody can reproduce is not a specification.
import { computeRehab, suggestAction, lendingNorm, dtiBand, pmt, nper, liveLiabilities }
  from "../supabase/functions/debt-rehab-plan/compute-rehab.ts";
import assert from "node:assert/strict";

const OLORATO = {
  personal:{ name:"Olorato", surname:"Maliko", employer:"HOLLARD", maritalStatus:"Married",
             regime:"In Community of Property", age:"33" },
  kids:[],
  income:{ monthlySalary:16200, otherDeductions:6512.5, businessIncome:4500, spouseIncome:0, rentals:0, dividends:0 },
  liabilities:[
    {item:"Personal Loan", institution:"First National Bank Botswana (FNB)", loanAmount:250000, interestRate:"", balance:250000, monthlyInstalment:5500, fixed:true},
    {item:"Mortgage Loan", institution:"", loanAmount:0, interestRate:"", balance:0, monthlyInstalment:0, fixed:true},
    {item:"Credit Card",   institution:"", loanAmount:0, interestRate:"", balance:0, monthlyInstalment:0, fixed:true},
    {item:"Car Loan",      institution:"", loanAmount:0, interestRate:"", balance:0, monthlyInstalment:0, fixed:true},
    {item:"Other", institution:"Motshelo",        loanAmount:16000, interestRate:"30", balance:16000, monthlyInstalment:0},
    {item:"Other", institution:"Motshelo Mother", loanAmount:7000,  interestRate:"25", balance:7000,  monthlyInstalment:0},
  ],
  assets:[
    {name:"Empty Plot Kasane", value:40000,  status:"Personal Use", monthlyIncome:0, potentialIncome:0},
    {name:"AUDI A3 ",          value:100000, status:"Personal Use", monthlyIncome:0, potentialIncome:0},
  ],
  savings:[
    {institution:"Motshelo",      currentBalance:0, monthlyContribution:2000, purpose:""},
    {institution:"Motshelo Food", currentBalance:0, monthlyContribution:400,  purpose:""},
  ],
  budget:{ food:2000, housing:3000, motshelo:2400, personal:600, childcare:1500, subscript:600, utilities:900,
           custom_id_a:2000, custom_id_b:2000, custom_id_c:150, custom_id_d:500, custom_id_e:200 },
  budgetOtherCustom:[{id:"custom_id_a",name:"Helper"},{id:"custom_id_b",name:"fuel"},
                     {id:"custom_id_c",name:"Garden Boy"},{id:"custom_id_d",name:"Church Offerings"},
                     {id:"custom_id_e",name:"Airtime"}],
  notes:{ debt:"…", income:"…", expense:"…", general:"…", lifestyle:"…" },
};

// Her three live liabilities, confirmed on the Prepare screen the way an
// advisor would: FNB renegotiated, both motshelos consolidated at monthly rates.
const PREP = {
  generated_date: "2026-09-03",
  liabilities: [
    { index:0, action:"RENEGOTIATE", rate_period:null },
    { index:1, action:"CONSOLIDATE", rate_period:"monthly" },
    { index:2, action:"CONSOLIDATE", rate_period:"monthly" },
  ],
};

// The Advance Recommendation spec §7 refers to: P 23,000.00 over 24 months,
// finalised 28 Aug 2026. No such row exists live, so the cross-reference path
// is exercised with this synthetic one.
const AR_FINAL = {
  version: 1, status: "final", decision: "Proceed with Conditional Approval", tier: "AMBER",
  advance_amount: 23000, advance_instalment: 958.33, term_months: 24,
  generated_at: "2026-08-28T09:00:00Z", debt_rehab_on: true,
};

let n = 0; const ok = (name, fn) => { fn(); n++; console.log("  ✓", name); };

// ── 1. Olorato, no Advance Recommendation on file ────────────────
console.log("Olorato Maliko (spec §7 worked example) — no AR on file");
const c = computeRehab(OLORATO, PREP, null, null);

ok("three live liabilities; the three blank template rows are dropped", () => {
  assert.equal(liveLiabilities(OLORATO).length, 3);
  assert.equal(c.liabilities.length, 3);
});
ok("income: gross P 16,200.00, PAYE P 1,887.50, net P 7,800.00, total P 12,300.00", () => {
  assert.equal(c.income.gross_salary, 16200);
  assert.equal(c.income.paye, 1887.5);
  assert.equal(c.income.net_salary, 7800);
  assert.equal(c.income.total_monthly_income, 12300);
});
ok("DSR 44.72% on debt service P 5,500.00 — strained, not yet over-indebted", () => {
  assert.equal(c.dsr.debt_service, 5500);
  assert.equal(c.dsr.dsr, 44.72);
  assert.equal(c.band, "strained");
});
ok("FNB → RENEGOTIATE: 44.72% of income on its own, target at or below P 4,305.00", () => {
  const fnb = c.liabilities[0];
  assert.equal(fnb.action, "RENEGOTIATE");
  assert.equal(fnb.pct_of_income, 44.72);
  assert.equal(fnb.target_cap, 4305);
  assert.match(fnb.target_text, /At or below P 4,305\.00/);
});
ok("FNB's blank rate is a printed gap, not a zero — the extension cannot be computed", () => {
  assert.equal(c.liabilities[0].rate_value, null);
  assert.equal(c.liabilities[0].rate_text, "Not captured");
  assert.equal(c.liabilities[0].target_low, null);
  assert.ok(c.gaps.some(g => /Interest rate not captured for Personal Loan – First National Bank/.test(g)));
});
ok("both motshelos → CONSOLIDATE at 360% and 300% p.a. equivalent; informal total P 23,000.00", () => {
  assert.deepEqual(c.liabilities.map(l => l.action), ["RENEGOTIATE","CONSOLIDATE","CONSOLIDATE"]);
  assert.equal(c.liabilities[1].rate_pa_equivalent, 360);
  assert.equal(c.liabilities[2].rate_pa_equivalent, 300);
  assert.equal(c.informal_total, 23000);
  assert.deepEqual(c.counts, { retain:0, consolidate:2, renegotiate:1, informal:2 });
});
ok("budget 60.16 / 9.76 / 19.51 / 39.43% of income", () => {
  assert.deepEqual(c.budget.rows.map(r => r.pct_of_income), [60.16, 9.76, 19.51, 39.43]);
  assert.deepEqual(c.budget.rows.map(r => r.actual), [7400, 1200, 2400, 4850]);
});
ok("spend P 15,850.00 → shortfall P 3,550.00; needs cut P 1,250.00, wants none, savings never cut", () => {
  assert.equal(c.budget.spend, 15850);
  assert.equal(c.budget.shortfall, 3550);
  assert.equal(c.budget.rows[0].cut, 1250);
  assert.equal(c.budget.rows[1].cut, 0);
  assert.equal(c.budget.rows[2].cut, null);
});
ok("the Other residual carries the rest of the shortfall: P 2,300.00", () => {
  assert.equal(c.budget.rows[3].cut, 2300);
  assert.equal(1250 + 2300, 3550);
});
ok("no debt line in the budget → gap printed and the all-in gap is P 9,050.00", () => {
  assert.equal(c.budget.debt_service_in_budget, 0);
  assert.equal(c.budget.all_in_shortfall, 9050);
  assert.ok(c.gaps.some(g => /Budget carries no debt repayments/.test(g)));
});
ok("motshelo under Savings is called debt service, not saving", () => {
  assert.match(c.budget.motshelo_note, /P 2,400\.00 sits under Savings/);
  assert.match(c.budget.motshelo_note, /debt service, not saving/);
});
ok("levers: AUDI covers the informal balances 4.35× over, the Kasane plot 1.74×", () => {
  const audi = c.levers.find(l => /AUDI/.test(l.name));
  const plot = c.levers.find(l => /Kasane/.test(l.name));
  assert.equal(audi.covers_informal, 4.35);
  assert.equal(audi.settles_outright, true);
  assert.equal(plot.covers_informal, 1.74);
  assert.ok(audi.included && plot.included);
});
ok("savings balances are zero → a gap, not a lever", () => {
  assert.equal(c.levers.filter(l => l.kind === "savings").length, 0);
  assert.ok(c.gaps.some(g => /Savings balances not captured/.test(g)));
});
ok("net worth including savings: −P 133,000.00", () => {
  assert.equal(c.net_worth.assets, 140000);
  assert.equal(c.net_worth.savings, 0);
  assert.equal(c.net_worth.liabilities, 273000);
  assert.equal(c.net_worth.total, -133000);
});
ok("no finalised AR → no amount is invented; sizing one is the Phase 1 action", () => {
  assert.equal(c.consolidation.source, "none");
  assert.equal(c.consolidation.amount, null);
  assert.ok(c.phases[0].actions.some(a => /Size a consolidation through an Advance Recommendation/.test(a)));
});
ok("phases without an advance: 44.72% now, 35.00–44.72% by Phase 2, exit at 35%", () => {
  assert.equal(c.phases[0].dsr_low, 44.72);
  assert.equal(c.phases[1].dsr_low, 35);
  assert.equal(c.phases[1].dsr_high, 44.72);
  assert.equal(c.phases[1].band_text, "35.00% – 44.72%");
  assert.equal(c.phases[2].dsr_high, 35);
  assert.match(c.phases[2].band_text, /At or below 35%/);
});
ok("headline is REHABILITATE, not REFER — the levers reach the line", () => {
  assert.equal(c.headline, "REHABILITATE");
});
ok("five review triggers, in priority order, the AUDI chased at 60 days", () => {
  assert.equal(c.triggers.length, 5);
  assert.match(c.triggers[0], /new informal borrowing/i);
  assert.ok(c.triggers.some(t => /AUDI A3 still unsold at 60 days/.test(t)));
  assert.ok(c.triggers.some(t => /Business income falling below P 4,500\.00/.test(t)));
  assert.match(c.triggers[c.triggers.length-1], /Phase 2 checkpoint/);
});
ok("review date defaults to 30 days after generation", () => {
  assert.equal(c.review_date, "2026-10-03");
});
ok("every gap becomes a checkable action; no action list is empty", () => {
  const gapActions = c.actions.filter(a => a.group === "gap");
  assert.equal(gapActions.length, c.gaps.length);
  c.phases.forEach(p => assert.ok(p.actions.length >= 1));
});

// ── 2. Olorato, with the finalised AR spec §7 refers to ──────────
console.log("\nOlorato with a finalised Advance Recommendation (P 23,000.00 over 24 months)");
const cAR = computeRehab(OLORATO, PREP, AR_FINAL, null);
ok("the advance figure is carried across, never re-derived", () => {
  assert.equal(cAR.consolidation.source, "advance_recommendation");
  assert.equal(cAR.consolidation.amount, 23000);
  assert.equal(cAR.consolidation.instalment, 958.33);
  assert.equal(cAR.consolidation.ar_version, 1);
  assert.equal(cAR.consolidation.dated, "2026-08-28");
  assert.match(cAR.consolidation.note, /carried across, not re-derived/);
});
ok("Phase 1 DSR rises to 52.51% and the plan says why", () => {
  assert.equal(cAR.phases[0].dsr_low, 52.51);
  assert.ok(cAR.phases[0].assumptions.some(x => /no instalment become a real cash obligation/.test(x)));
});
ok("Phase 2 band 35.00–52.51%; the advance is on the Phase 3 exit list", () => {
  assert.equal(cAR.phases[1].dsr_low, 35);
  assert.equal(cAR.phases[1].dsr_high, 52.51);
  assert.ok(cAR.phases[2].actions.some(a => /advance cleared in full/.test(a)));
});
ok("the two motshelos are marked settled by the advance", () => {
  assert.deepEqual(cAR.liabilities.map(l => l.settled_by_advance), [false, true, true]);
});
ok("a missed advance instalment becomes a review trigger", () => {
  assert.ok(cAR.triggers.some(t => /missed advance instalment/i.test(t)));
});

console.log("\nA draft Advance Recommendation is named as pending, never used");
const cDraft = computeRehab(OLORATO, PREP, { ...AR_FINAL, status: "draft" }, null);
ok("draft → no amount, and the note says finalise it", () => {
  assert.equal(cDraft.consolidation.source, "none");
  assert.equal(cDraft.consolidation.amount, null);
  assert.match(cDraft.consolidation.note, /still a draft/);
});

// ── 3. The advisor's confirmations are what is computed ──────────
console.log("\nThe advisor's confirmation overrides the suggestion");
const cRetain = computeRehab(OLORATO, { ...PREP, liabilities:[
  { index:0, action:"RETAIN", rate_period:null },
  { index:1, action:"CONSOLIDATE", rate_period:"monthly" },
  { index:2, action:"CONSOLIDATE", rate_period:"monthly" },
]}, null, null);
ok("FNB set to RETAIN → no target band, and the suggestion is still recorded", () => {
  assert.equal(cRetain.liabilities[0].action, "RETAIN");
  assert.equal(cRetain.liabilities[0].suggested_action, "RENEGOTIATE");
  assert.equal(cRetain.liabilities[0].confirmed_by_advisor, true);
  assert.equal(cRetain.liabilities[0].target_cap, null);
  assert.equal(cRetain.liabilities[0].target_text, "");
});
ok("with nothing renegotiated the Phase 2 lower bound stops improving", () => {
  assert.equal(cRetain.phases[1].dsr_low, 44.72);
});

console.log("\nUnticking a lever asset removes it from the plan");
const cNoAudi = computeRehab(OLORATO, { ...PREP, assets:[{ index:1, include:false }] }, null, null);
ok("the AUDI is off, the plot stays, and the sale action goes with it", () => {
  assert.equal(cNoAudi.levers.find(l => /AUDI/.test(l.name)).included, false);
  assert.equal(cNoAudi.levers.find(l => /Kasane/.test(l.name)).included, true);
  assert.ok(!cNoAudi.phases[0].actions.some(a => /AUDI/.test(a)));
  assert.ok(!cNoAudi.triggers.some(t => /AUDI/.test(t)));
});

// ── 4. Edge cases ────────────────────────────────────────────────
console.log("\nEdge: budget not captured");
const cNoBudget = computeRehab({ ...OLORATO, budget:{} }, PREP, null, null);
ok("capturing the budget is action one and no numeric target prints", () => {
  assert.equal(cNoBudget.budget.captured, false);
  assert.equal(cNoBudget.budget.rows.length, 0);
  assert.equal(cNoBudget.budget.shortfall, null);
  assert.match(cNoBudget.phases[0].actions[0], /^Capture the household budget/);
  assert.ok(cNoBudget.gaps.some(g => /Household budget not captured/.test(g)));
});

console.log("\nEdge: no informal debt at all");
const cFormalOnly = computeRehab({ ...OLORATO, liabilities:[OLORATO.liabilities[0]] },
  { ...PREP, liabilities:[{ index:0, action:"RENEGOTIATE", rate_period:null }] }, null, null);
ok("nothing to consolidate: no CONSOLIDATE row, no coverage multiple, no AR gap", () => {
  assert.equal(cFormalOnly.counts.consolidate, 0);
  assert.equal(cFormalOnly.informal_total, 0);
  assert.equal(cFormalOnly.levers.find(l => /AUDI/.test(l.name)).covers_informal, null);
  assert.ok(!cFormalOnly.gaps.some(g => /finalised Advance Recommendation/.test(g)));
});

console.log("\nEdge: three informal lenders and nothing to consolidate them with → plan-level REFER");
const THREE = { ...OLORATO, assets:[], savings:[], liabilities:[
  {item:"Other", institution:"Motshelo",   loanAmount:16000, interestRate:"30", balance:16000, monthlyInstalment:0},
  {item:"Other", institution:"Mother",     loanAmount:7000,  interestRate:"25", balance:7000,  monthlyInstalment:0},
  {item:"Other", institution:"Mashonisa",  loanAmount:5000,  interestRate:"20", balance:5000,  monthlyInstalment:0},
]};
const cRefer = computeRehab(THREE, { generated_date:"2026-09-03", liabilities:[
  {index:0,action:"CONSOLIDATE",rate_period:"monthly"},
  {index:1,action:"CONSOLIDATE",rate_period:"monthly"},
  {index:2,action:"CONSOLIDATE",rate_period:"monthly"}]}, null, null);
ok("REFER, and the reason names the three lenders and the P 28,000.00", () => {
  assert.equal(cRefer.headline, "REFER");
  assert.ok(cRefer.headline_reasons.some(r => /3 informal lenders and nothing to consolidate them with/.test(r)));
  assert.ok(cRefer.headline_reasons.some(r => /P 28,000\.00/.test(r)));
});

console.log("\nEdge: DSR still above 45% after every lever → REFER");
const HEAVY = { ...OLORATO, liabilities:[
  {item:"Personal Loan", institution:"FNB", loanAmount:250000, interestRate:"12", balance:250000, monthlyInstalment:5500},
  {item:"Car Loan", institution:"Stanbic", loanAmount:200000, interestRate:"14", balance:180000, monthlyInstalment:4200},
]};
const cHeavy = computeRehab(HEAVY, { generated_date:"2026-09-03", liabilities:[
  {index:0,action:"RENEGOTIATE",rate_period:"annual"},
  {index:1,action:"RETAIN",rate_period:"annual"}]}, null, null);
ok("REFER, and the reason quotes the after-everything figure", () => {
  assert.ok(cHeavy.phases[1].dsr_low > 45);
  assert.equal(cHeavy.headline, "REFER");
  assert.ok(cHeavy.headline_reasons.some(r => /above the 45% ceiling/.test(r)));
});

console.log("\nEdge: a savings balance that settles an informal debt outright");
const SAVER = { ...OLORATO, savings:[{ institution:"Stanbic 32-day", currentBalance:8000, monthlyContribution:500, purpose:"" }] };
const cSaver = computeRehab(SAVER, PREP, null, null);
ok("P 8,000.00 settles the P 7,000.00 owed to the mother, and says so", () => {
  const lever = cSaver.levers.find(l => l.kind === "savings");
  assert.equal(lever.settles_outright, true);
  assert.match(lever.detail, /P 8,000\.00 at Stanbic 32-day would settle Motshelo Mother \(P 7,000\.00\) outright/);
});

console.log("\nEdge: rate text that fails to parse");
const BADRATE = { ...OLORATO, liabilities:[
  {item:"Other", institution:"Motshelo", loanAmount:16000, interestRate:"thirty percent monthly", balance:16000, monthlyInstalment:0}]};
const cBad = computeRehab(BADRATE, { generated_date:"2026-09-03", liabilities:[{index:0,action:"CONSOLIDATE",rate_period:null}]}, null, null);
ok("unparseable rate prints Not captured and becomes a gap, never 0%", () => {
  assert.equal(cBad.liabilities[0].rate_value, null);
  assert.equal(cBad.liabilities[0].rate_text, "Not captured");
  assert.equal(cBad.liabilities[0].rate_pa_equivalent, null);
  assert.ok(cBad.gaps.some(g => /Interest rate not captured for Motshelo/.test(g)));
});

console.log("\nEdge: a renegotiation where the rate and term ARE captured");
const RATED = { ...OLORATO, liabilities:[
  {item:"Personal Loan", institution:"FNB", loanAmount:250000, interestRate:"12", balance:250000, monthlyInstalment:5500}]};
const cRated = computeRehab(RATED, { generated_date:"2026-09-03", liabilities:[
  {index:0, action:"RENEGOTIATE", rate_period:"annual", months_remaining:60, extension_months:36}]}, null, null);
ok("the band is a real payment range over a real term: P 4,063.21 – P 4,305.00 over 96 months", () => {
  const l = cRated.liabilities[0];
  assert.equal(l.months_remaining, 60);
  assert.equal(l.extension_months, 36);
  assert.equal(l.target_low, 4063.21);
  assert.equal(l.target_low, pmt(250000, 12, 96));
  assert.equal(l.target_text, "P 4,063.21 – P 4,305.00 over 96 months");
});
ok("the default 24-month extension does NOT reach the line here, and the plan says so rather than promising", () => {
  const short = computeRehab(RATED, { generated_date:"2026-09-03", liabilities:[
    {index:0, action:"RENEGOTIATE", rate_period:"annual", months_remaining:60}]}, null, null);
  const l = short.liabilities[0];
  assert.equal(l.extension_months, 24);
  assert.equal(l.target_low, 4413.18);          // above the P 4,305.00 cap
  assert.match(l.target_text, /a 24-month extension alone reaches only P 4,413\.18/);
  assert.match(l.target_text, /a longer term or a rate change is needed/);
});
ok("with no term given, the months remaining are solved from balance, rate and instalment", () => {
  const solved = computeRehab(RATED, { generated_date:"2026-09-03", liabilities:[
    {index:0, action:"RENEGOTIATE", rate_period:"annual"}]}, null, null);
  assert.equal(solved.liabilities[0].months_remaining, 61);   // nper(250000, 12, 5500): just over five years
});

console.log("\nEdge: thresholds come from config, with the constants as fallback");
ok("a 40% norm in config moves the line and the cap", () => {
  const cfg = { flag_band:"over_indebted", bands:[
    {key:"healthy",max:20},{key:"manageable",max:40},{key:"strained",max:50},{key:"over_indebted",max:null}]};
  const c40 = computeRehab(OLORATO, PREP, null, cfg);
  assert.equal(c40.lending_norm_pct, 40);
  assert.equal(c40.liabilities[0].target_cap, 4920);
  assert.equal(c40.band, "strained");
  assert.equal(lendingNorm(null), 35);
  assert.equal(dtiBand(44.72, null), "strained");
});
ok("the band boundary is exclusive: exactly 45.0 is over-indebted", () => {
  assert.equal(dtiBand(44.99, null), "strained");
  assert.equal(dtiBand(45, null), "over_indebted");
});

console.log("\nEdge: no income captured");
const cNoIncome = computeRehab({ ...OLORATO, income:{} }, PREP, null, null);
ok("no ratio is invented; both gaps print", () => {
  assert.equal(cNoIncome.dsr.dsr, null);
  assert.equal(cNoIncome.liabilities[0].target_cap, null);
  assert.ok(cNoIncome.gaps.some(g => /Gross salary not captured/.test(g)));
  assert.ok(cNoIncome.gaps.some(g => /No income captured/.test(g)));
});

console.log("\nThe suggestion helpers on their own");
ok("suggestAction: a formal facility under the line is RETAIN, over it RENEGOTIATE", () => {
  const raw = {item:"Personal Loan", institution:"FNB", interestRate:"12", monthlyInstalment:5500};
  assert.equal(suggestAction(raw, 12300, 35).action, "RENEGOTIATE");
  assert.equal(suggestAction(raw, 30000, 35).action, "RETAIN");
  assert.equal(suggestAction({item:"Other", institution:"Motshelo", interestRate:"30"}, 12300, 35).action, "CONSOLIDATE");
});
ok("nper returns null when the instalment never clears the interest", () => {
  assert.equal(nper(16000, 360, 100), null);       // P 100 never clears 30%/month interest
  assert.equal(nper(250000, 12, 5500), 61);        // rounded up, never down
});

console.log(`\n${n} checks passed`);
