// Node 22 test for supabase/functions/advance-recommendation/compute.ts
// Run: node tests/advance-recommendation.test.mjs
import { compute, liveLiabilities, suggestClassification } from "../supabase/functions/advance-recommendation/compute.ts";
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

let n = 0; const ok = (name, fn) => { fn(); n++; console.log("  ✓", name); };

console.log("Tumelo (worked example)");
const live = liveLiabilities(TUMELO);
ok("blank template rows dropped → 6 live", () => assert.equal(live.length, 6));
const sugg = live.map(l => suggestClassification(l.raw));
ok("auto-classification: 1 formal, 5 informal", () => {
  assert.deepEqual(sugg.map(s=>s.classification), ["formal","informal","informal","informal","informal","informal"]);
});
const prep = { term_months:24, liabilities: live.map((l,i)=>({ index:i, classification:sugg[i].classification, rate_period:sugg[i].rate_period })) };
const c = compute(TUMELO, prep);
ok("income: PAYE 9,033.15, net 24,819.58", () => { assert.equal(c.income.paye, 9033.15); assert.equal(c.income.total_monthly_income, 24819.58); });
ok("debt service before 11,275.98 · DSR 45.43%", () => { assert.equal(c.before.debt_service, 11275.98); assert.equal(c.before.dsr, 45.43); });
ok("advance P 36,850.00 · instalment 1,535.42", () => { assert.equal(c.advance.amount, 36850); assert.equal(c.advance.instalment, 1535.42); });
ok("debt service after 10,611.40 · DSR 42.75% · improved", () => { assert.equal(c.after.debt_service, 10611.40); assert.equal(c.after.dsr, 42.75); assert.equal(c.dsr_change.direction, "improved"); });
ok("tier AMBER · Proceed with Conditional Approval", () => { assert.equal(c.tier, "AMBER"); assert.equal(c.decision, "Proceed with Conditional Approval"); });
ok("conditions: proof on, rehab on (AMBER), HR hold on (5 informal lenders)", () => {
  const m = Object.fromEntries(c.conditions.map(x=>[x.key,x.on])); assert.deepEqual(m, {proof_of_payment:true, debt_rehab:true, hr_letter_hold:true});
});
ok("gaps: two rates not captured + budget not captured", () => {
  assert.equal(c.gaps.filter(g=>/Interest rate/.test(g)).length, 2);
  assert.ok(c.gaps.some(g=>/budget/.test(g)));
});
ok("5 rows settled by advance, Stanbic unchanged", () => { assert.equal(c.advance.settles.length, 5); assert.equal(c.liabilities[0].settled_by_advance, false); });

console.log("Rising DSR — unserviced motshelo only, stays AMBER (agreed rule)");
const R = { ...TUMELO, liabilities:[ TUMELO.liabilities[0], {item:"Other",institution:"Motshelo",loanAmount:"5000",interestRate:"30",balance:"6000",monthlyInstalment:"0"} ] };
const rl = liveLiabilities(R);
const rc = compute(R, { term_months:24, liabilities:[{index:0,classification:"formal",rate_period:"annual"},{index:1,classification:"informal",rate_period:"annual"}] });
ok("DSR worsens 36.57 → 37.58 but tier is AMBER, not RED", () => { assert.equal(rc.dsr_change.direction, "worsened"); assert.equal(rc.tier, "AMBER"); });

console.log("Rising DSR that crosses 45% → RED");
const X = { ...TUMELO, income:{...TUMELO.income, monthlySalary:30000}, liabilities:[ TUMELO.liabilities[0], {item:"Other",institution:"Motshelo",loanAmount:"5000",interestRate:"30",balance:"60000",monthlyInstalment:"0"} ] };
const xc = compute(X, { term_months:24, liabilities:[{index:0,classification:"formal",rate_period:"annual"},{index:1,classification:"informal",rate_period:"annual"}] });
ok("RED · Decline – Refer to Debt Restructuring", () => { assert.equal(xc.tier, "RED"); assert.equal(xc.decision, "Decline – Refer to Debt Restructuring"); });

console.log("Monthly rate text");
const M = { ...TUMELO, liabilities:[ {item:"Other",institution:"Mashonisa",loanAmount:"2000",interestRate:"30% per month",balance:"2600",monthlyInstalment:"0"} ] };
const mc = compute(M, { term_months:24 });
ok("parsed as monthly, 360% p.a. equivalent, rehab default on", () => { assert.equal(mc.liabilities[0].rate_period, "monthly"); assert.equal(mc.liabilities[0].rate_pa_equivalent, 360); assert.equal(mc.has_monthly_compounding, true); });
ok("GREEN by arithmetic (P 108.33/month) with rehab still suggested", () => { assert.equal(mc.tier, "GREEN"); assert.equal(mc.conditions.find(x=>x.key==="debt_rehab").on, true); });

console.log("Bare rate period follows the lender");
const cls = (institution, interestRate, item="Other") => suggestClassification({ item, institution, loanAmount:"1000", interestRate, balance:"1000", monthlyInstalment:"0" });
ok("motshelo '30' → monthly (defaulted, reason says so)", () => { const r = cls("Motshelo", "30"); assert.equal(r.rate_period, "monthly"); assert.match(r.reason, /read as per month/); });
ok("'Motshelo Mother' '25' → monthly · mashonisa '2.5' → monthly", () => { assert.equal(cls("Motshelo Mother", "25").rate_period, "monthly"); assert.equal(cls("Mashonisa", "2.5").rate_period, "monthly"); });
ok("motshelo '30% p.a.' / '30 per annum' → annual, text wins", () => { assert.equal(cls("Motshelo", "30% p.a.").rate_period, "annual"); assert.equal(cls("Motshelo", "30 per annum").rate_period, "annual"); assert.doesNotMatch(cls("Motshelo", "30% p.a.").reason, /read as per month/); });
ok("bank '12' → annual · unknown lender '25' → annual (high-cost) · blank → null", () => { assert.equal(cls("Stanbic", "12").rate_period, "annual"); const u = cls("Express Credit", "25"); assert.equal(u.rate_period, "annual"); assert.equal(u.classification, "informal"); assert.equal(cls("Motshelo", "").rate_period, null); });
ok("Tumelo's bare-rate motshelo and microlender now read per month", () => { assert.equal(sugg[3].rate_period, "monthly"); assert.equal(sugg[2].rate_period, "monthly"); assert.equal(sugg[1].rate_period, "annual"); });

console.log("Nothing to consolidate → decline");
const D = { ...TUMELO, liabilities:[ TUMELO.liabilities[0] ] };
const dc = compute(D, { term_months:24, liabilities:[{index:0,classification:"formal",rate_period:"annual"}] });
ok("RED · no advance · Decline – No Consolidation Opportunity (DSR 36.57 < 45)", () => { assert.equal(dc.advance, null); assert.equal(dc.tier, "RED"); assert.equal(dc.decision, "Decline – No Consolidation Opportunity"); assert.equal(dc.conditions.length, 0); });

console.log("Budget shortfall on file → RED even when DSR is fine");
const B = { ...TUMELO, budget:{ rent:20000, food:6000 }, liabilities:[ {item:"Other",institution:"Motshelo",loanAmount:"5000",interestRate:"30",balance:"6000",monthlyInstalment:"0"} ] };
const bc = compute(B, { term_months:24 });
ok("RED · Proceed Only Under Prerequisites · shortfall true", () => { assert.equal(bc.budget.shortfall, true); assert.equal(bc.tier, "RED"); assert.equal(bc.decision, "Proceed Only Under Prerequisites"); });

console.log("Informal debt with no balance → cannot size");
const N = { ...TUMELO, liabilities:[ {item:"Other",institution:"Motshelo",loanAmount:"5000",interestRate:"30",balance:"0",monthlyInstalment:"0"} ] };
const nc = compute(N, { term_months:24 });
ok("Decline – Insufficient Data, balance gap flagged", () => { assert.equal(nc.decision, "Decline – Insufficient Data"); assert.ok(nc.gaps.some(g=>/Balance not captured/.test(g))); });

console.log(`\n${n} checks passed`);
