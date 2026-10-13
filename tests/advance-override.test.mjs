// Node 22+ test: the advisor's figure in compute.ts / report.ts (13 Oct 2026)
// Run: node tests/advance-override.test.mjs
import { compute, stripDashes } from "../supabase/functions/advance-recommendation/compute.ts";
import { buildContent, fallbackNarrative } from "../supabase/functions/advance-recommendation/report.ts";
import assert from "node:assert/strict";

const TUMELO = {
  personal:{ name:"Tumelo", surname:"Kgamayane", employer:"Hollard", maritalStatus:"Married", regime:"In Community of Property", age:"41" },
  kids:[],
  income:{ monthlySalary:44782.61, otherDeductions:10929.88, spouseIncome:0, rentals:0, businessIncome:0, dividends:0 },
  liabilities:[
    {item:"Personal Loan", institution:"Stanbic Bank Botswana", loanAmount:"550000", interestRate:"12", balance:"433020.45", monthlyInstalment:"9075.98"},
    {item:"Mortgage Loan", institution:"", loanAmount:"0", interestRate:"", balance:"0", monthlyInstalment:"0"},
    {item:"Credit Card", institution:"", loanAmount:"0", interestRate:"", balance:"0", monthlyInstalment:"0"},
    {item:"Car Loan", institution:"", loanAmount:"0", interestRate:"", balance:"0", monthlyInstalment:"0"},
    {item:"Other", institution:"Express Credit", loanAmount:"50000", interestRate:"25", balance:"25000", monthlyInstalment:"2200"},
    {item:"Other", institution:"Close Friends Microlender", loanAmount:"10000", interestRate:"25", balance:"3600", monthlyInstalment:"0"},
    {item:"Other", institution:"Motshelo", loanAmount:"1500", interestRate:"30", balance:"2300", monthlyInstalment:"0"},
    {item:"Other", institution:"Motshelo 2", loanAmount:"2000", interestRate:"", balance:"2450", monthlyInstalment:"0"},
    {item:"Other", institution:"Motshelo", loanAmount:"10000", interestRate:"", balance:"3500", monthlyInstalment:"0"},
    {item:"Other", institution:"", loanAmount:"0", interestRate:"", balance:"0", monthlyInstalment:"0"},
  ],
  budget:{},
};
const META = { consultant:"France Mogomotsi", consultation_date:"2026-10-13", recommendation_date:"2026-10-13" };
const DASH = /[–—]|--/;
let n = 0; const ok = (name, fn) => { fn(); n++; console.log("  ✓", name); };

const OVR = {
  id: "ovr-1", amount: 55000,
  justification: "School fees for two children are due in January — the employee asked for help with them.",
  allocations: [
    { kind:"liability", liability_index:4, lender:"Express Credit", outstanding_balance:25000, purpose:null, amount:25000 },
    { kind:"liability", liability_index:5, lender:"Close Friends Microlender", outstanding_balance:3600, purpose:null, amount:3600 },
    { kind:"other", liability_index:null, lender:null, outstanding_balance:null, purpose:"School fees, January 2027", amount:26400 },
  ],
};

console.log("Portal figure first (the snapshot the override replaces)");
const base = compute(TUMELO, {});
ok("portal recommends P 36,850.00 and carries no override key", () => { assert.equal(base.advance.amount, 36850); assert.equal("override" in base, false); });

console.log("Tumelo on the advisor's P 55,000");
const c = compute(TUMELO, { override: OVR });
ok("advance is the advisor's: 55,000 over 24 months, P 2,291.67 a month", () => {
  assert.equal(c.advance.amount, 55000); assert.equal(c.advance.instalment, 2291.67); assert.equal(c.term_months, 24); assert.equal(c.advance.capped, false);
});
ok("the two liabilities paid in full are settled; nothing else is", () => {
  const settled = c.liabilities.filter(l => l.settled_by_advance).map(l => l.institution);
  assert.deepEqual(settled, ["Express Credit", "Close Friends Microlender"]);
});
ok("DSR after = (11,275.98 − 2,200 + 2,291.67) / 44,782.61 = 25.38%", () => {
  assert.equal(c.after.debt_service, 11367.65); assert.equal(c.after.dsr, 25.38);
});
ok("tier computed honestly (GREEN, under 40%); decision follows the advisor", () => {
  assert.equal(c.tier, "GREEN"); assert.equal(c.decision, "Proceed on the Consultant's Recommendation");
});
ok("override block keeps the portal figure for the internal record only", () => {
  assert.equal(c.override.system_amount, 36850); assert.equal(c.override.amount, 55000);
  assert.deepEqual(c.override.allocations.map(a => a.settles_in_full), [true, true, false]);
});
ok("the cap-binding note is not in the gaps", () => assert.equal(c.gaps.some(g => g.includes("exceed the advance cap")), false));

const narr = fallbackNarrative(c);
const content = buildContent(c, META, narr);
const contentText = JSON.stringify(content);
ok("report content carries the advisor's figure and never the portal's (D1)", () => {
  assert.equal(content.meta.recommended_amount, "P 55,000.00");
  assert.equal(contentText.includes("36,850"), false);
});
ok("report content never says override or amended, nor shows the cap", () => {
  assert.equal(/overrid|amended/i.test(contentText), false);
  assert.equal(contentText.includes("179,130"), false);
});
ok("advisor's recommendation section: justification, advance, repayment in cents", () => {
  const s = content.sections.advisor_recommendation;
  assert.equal(s.title, "Advisor's recommendation");
  assert.equal(s.recommended_advance, "P 55,000.00");
  assert.equal(s.repayment, "P 2,291.67 per month over 24 months, no interest");
  assert.equal(s.justification, "School fees for two children are due in January, the employee asked for help with them.");
});
ok("use-of-funds table: three lines, balances only on liability lines, total = advance", () => {
  const u = content.sections.advisor_recommendation.use_of_funds;
  assert.deepEqual(u.headers, ["Lender or purpose", "Outstanding balance", "Allocated amount"]);
  assert.deepEqual(u.rows.map(r => [r.label, r.balance, r.amount]), [
    ["Express Credit", "P 25,000.00", "P 25,000.00"],
    ["Close Friends Microlender", "P 3,600.00", "P 3,600.00"],
    ["School fees, January 2027", "", "P 26,400.00"],
  ]);
  assert.equal(u.total, "P 55,000.00");
});
ok("debt table: settled lines, untouched informal is 'Not covered by the advance', the new advance row", () => {
  const rows = content.sections.debt_position.rows;
  assert.equal(rows.find(r => r.institution === "Express Credit").status, "Settled by advance");
  assert.equal(rows.find(r => r.institution === "Motshelo 2").status, "Not covered by the advance");
  assert.equal(rows.find(r => r.debt === "New advance").balance, "P 55,000.00");
});
ok("no dash in any new report string (advisor section and narrative)", () => {
  assert.equal(DASH.test(JSON.stringify(content.sections.advisor_recommendation)), false);
  assert.equal(DASH.test(JSON.stringify(narr)), false);
});

console.log("Part-payment, a moved liability, an honest RED, no gross salary");
const part = compute(TUMELO, { override: { ...OVR, amount: 10000, allocations: [
  { kind:"liability", liability_index:4, lender:"Express Credit", outstanding_balance:25000, purpose:null, amount:10000 } ] } });
ok("10,000 towards a 25,000 balance: not settled, instalment kept, status says part-paid", () => {
  assert.equal(part.liabilities.find(l => l.institution === "Express Credit").settled_by_advance, false);
  assert.equal(part.after.debt_service, Math.round((11275.98 + 416.67) * 100) / 100);
  const row = buildContent(part, META, fallbackNarrative(part)).sections.debt_position.rows.find(r => r.institution === "Express Credit");
  assert.equal(row.status, "Part-paid by advance (P 10,000.00); instalment unchanged");
});
const moved = compute(TUMELO, { override: { ...OVR, amount: 25000, allocations: [
  { kind:"liability", liability_index:4, lender:"Some Lender Since Deleted", outstanding_balance:25000, purpose:null, amount:25000 } ] } });
ok("a line whose liability moved settles nothing and is named in the gaps", () => {
  assert.equal(moved.liabilities.some(l => l.settled_by_advance), false);
  assert.equal(moved.gaps.some(g => g.includes("Some Lender Since Deleted") && g.includes("no longer matches")), true);
});
const SMALL = { ...TUMELO, income: { monthlySalary: 6000 }, liabilities: [
  { item:"Personal Loan", institution:"Bank", loanAmount:"0", interestRate:"12", balance:"50000", monthlyInstalment:"3000" },
  { item:"Other", institution:"Shark", loanAmount:"0", interestRate:"30", balance:"4000", monthlyInstalment:"0" } ] };
const red = compute(SMALL, { override: { id:"o2", amount: 24000, justification:"x".repeat(25), allocations: [
  { kind:"liability", liability_index:1, lender:"Shark", outstanding_balance:4000, purpose:null, amount:4000 },
  { kind:"other", liability_index:null, lender:null, outstanding_balance:null, purpose:"Roof repair", amount:20000 } ] } });
ok("tier stays honest: RED when DSR after crosses 60%, decision still the advisor's", () => {
  assert.equal(red.tier, "RED"); assert.equal(red.decision, "Proceed on the Consultant's Recommendation");
  assert.ok(red.after.dsr >= 60, String(red.after.dsr));
  assert.ok(red.conditions.length > 0, "conditions still offered");
});
const noGross = compute({ ...TUMELO, income: {} }, { override: OVR });
ok("no gross salary: the override is not applied and the gap says why", () => {
  assert.equal("override" in noGross, false);
  assert.equal(noGross.gaps.some(g => g.startsWith("The advisor's advance figure cannot be applied")), true);
});

console.log("stripDashes");
ok("em dash, en dash and double hyphen become commas; between numbers, 'to'", () => {
  assert.equal(stripDashes("Fees — due now"), "Fees, due now");
  assert.equal(stripDashes("40–60%"), "40 to 60%");
  assert.equal(stripDashes("a -- b"), "a, b");
  assert.equal(stripDashes("End —."), "End.");
  assert.equal(stripDashes("no dashes here"), "no dashes here");
});

console.log(`\n${n} checks passed`);
