// Node 22 test for supabase/functions/advance-recommendation/compute.ts
// Run: node tests/advance-recommendation.test.mjs
import { compute, liveLiabilities, suggestClassification, dsrTier, dsrBand } from "../supabase/functions/advance-recommendation/compute.ts";
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
// 4 Oct 2026: DSR is on the client's own GROSS salary (44,782.61), not on
// household take-home (24,819.58). Same debts, smaller ratio.
ok("debt service before 11,275.98 · DSR 25.18% of gross", () => { assert.equal(c.before.debt_service, 11275.98); assert.equal(c.before.dsr, 25.18); });
ok("advance P 36,850.00 · instalment 1,535.42 · cap 179,130.44 not binding", () => { assert.equal(c.advance.amount, 36850); assert.equal(c.advance.instalment, 1535.42); assert.equal(c.advance.cap, 179130.44); assert.equal(c.advance.capped, false); });
ok("debt service after 10,611.40 · DSR 23.70% · improved", () => { assert.equal(c.after.debt_service, 10611.40); assert.equal(c.after.dsr, 23.70); assert.equal(c.dsr_change.direction, "improved"); });
ok("tier GREEN · Proceed with Approval (below the 40% benchmark)", () => { assert.equal(c.tier, "GREEN"); assert.equal(c.decision, "Proceed with Approval"); });
ok("conditions: proof on, rehab on (monthly-compounding motshelo), HR hold on (5 informal lenders)", () => {
  const m = Object.fromEntries(c.conditions.map(x=>[x.key,x.on])); assert.deepEqual(m, {proof_of_payment:true, debt_rehab:true, hr_letter_hold:true});
});
ok("gaps: two rates not captured + budget not captured", () => {
  assert.equal(c.gaps.filter(g=>/Interest rate/.test(g)).length, 2);
  assert.ok(c.gaps.some(g=>/budget/.test(g)));
});
ok("5 rows settled by advance, Stanbic unchanged", () => { assert.equal(c.advance.settles.length, 5); assert.equal(c.liabilities[0].settled_by_advance, false); });

console.log("Rising DSR — unserviced motshelo only, never RED on its own (agreed rule)");
const R = { ...TUMELO, liabilities:[ TUMELO.liabilities[0], {item:"Other",institution:"Motshelo",loanAmount:"5000",interestRate:"30",balance:"6000",monthlyInstalment:"0"} ] };
const rl = liveLiabilities(R);
const rc = compute(R, { term_months:24, liabilities:[{index:0,classification:"formal",rate_period:"annual"},{index:1,classification:"informal",rate_period:"annual"}] });
ok("DSR worsens 20.27 → 20.83 but tier is GREEN, not RED", () => { assert.equal(rc.before.dsr, 20.27); assert.equal(rc.after.dsr, 20.83); assert.equal(rc.dsr_change.direction, "worsened"); assert.equal(rc.tier, "GREEN"); });

console.log("Rising DSR that crosses the 60% line → RED");
// gross 20,000: before 9,075.98 = 45.38%; advance 80,000 (exactly the 4× cap,
// so not capped) at 3,333.33 → after 12,409.31 = 62.05%.
const X = { ...TUMELO, income:{...TUMELO.income, monthlySalary:20000}, liabilities:[ TUMELO.liabilities[0], {item:"Other",institution:"Motshelo",loanAmount:"5000",interestRate:"30",balance:"80000",monthlyInstalment:"0"} ] };
const xc = compute(X, { term_months:24, liabilities:[{index:0,classification:"formal",rate_period:"annual"},{index:1,classification:"informal",rate_period:"annual"}] });
ok("45.38% → 62.05% · RED · Decline – Refer to Debt Restructuring", () => { assert.equal(xc.before.dsr, 45.38); assert.equal(xc.after.dsr, 62.05); assert.equal(xc.advance.capped, false); assert.equal(xc.tier, "RED"); assert.equal(xc.decision, "Decline – Refer to Debt Restructuring"); });

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
ok("RED · no advance · Decline – No Consolidation Opportunity (DSR 20.27 < 60)", () => { assert.equal(dc.advance, null); assert.equal(dc.tier, "RED"); assert.equal(dc.decision, "Decline – No Consolidation Opportunity"); assert.equal(dc.conditions.length, 0); });

console.log("Budget shortfall on file → RED even when DSR is fine");
const B = { ...TUMELO, budget:{ rent:20000, food:6000 }, liabilities:[ {item:"Other",institution:"Motshelo",loanAmount:"5000",interestRate:"30",balance:"6000",monthlyInstalment:"0"} ] };
const bc = compute(B, { term_months:24 });
ok("RED · Proceed Only Under Prerequisites · shortfall true", () => { assert.equal(bc.budget.shortfall, true); assert.equal(bc.tier, "RED"); assert.equal(bc.decision, "Proceed Only Under Prerequisites"); });

console.log("Informal debt with no balance → cannot size");
const N = { ...TUMELO, liabilities:[ {item:"Other",institution:"Motshelo",loanAmount:"5000",interestRate:"30",balance:"0",monthlyInstalment:"0"} ] };
const nc = compute(N, { term_months:24 });
ok("Decline – Insufficient Data, balance gap flagged", () => { assert.equal(nc.decision, "Decline – Insufficient Data"); assert.ok(nc.gaps.some(g=>/Balance not captured/.test(g))); });

console.log("DSR tiers and bands — exact boundaries (4 Oct 2026)");
ok("tier: 39.99 GREEN · 40 AMBER · 59.99 AMBER · 60 RED · null null", () => {
  assert.equal(dsrTier(39.99), "GREEN"); assert.equal(dsrTier(40), "AMBER"); assert.equal(dsrTier(59.99), "AMBER"); assert.equal(dsrTier(60), "RED"); assert.equal(dsrTier(null), null);
});
ok("band: 39.99 healthy · 40 manageable · 49.99 manageable · 50 strained · 59.99 strained · 60 over_indebted", () => {
  assert.deepEqual([39.99,40,49.99,50,59.99,60].map(dsrBand), ["healthy","manageable","manageable","strained","strained","over_indebted"]);
});

console.log("Hollard advance cap — the brief's worked checks (gross 15,000)");
const G = (liabs, extra={}) => ({ personal:{ name:"Test", employer:"Hollard" }, kids:[], income:{ monthlySalary:15000, otherDeductions:0 }, liabilities: liabs, budget:{}, ...extra });
const formal3750 = {item:"Personal Loan",institution:"Stanbic",loanAmount:"100000",interestRate:"12",balance:"80000",monthlyInstalment:"3750"};
// Nothing worth settling: one informal debt with no instalment, far above the cap.
const g1 = compute(G([ {item:"Personal Loan",institution:"Stanbic",loanAmount:"200000",interestRate:"12",balance:"150000",monthlyInstalment:"6750"},
                       {item:"Other",institution:"Motshelo",loanAmount:"100000",interestRate:"",balance:"100000",monthlyInstalment:"0"} ]),
                   { liabilities:[{index:0,classification:"formal",rate_period:"annual"},{index:1,classification:"informal",rate_period:null}] });
ok("cap 60,000 · instalment 2,500 at the maximum", () => { assert.equal(g1.advance.cap, 60000); assert.equal(g1.advance.amount, 60000); assert.equal(g1.advance.instalment, 2500); assert.equal(g1.advance.capped, true); });
ok("repayments 6,750 (45%) → 9,250 (61.67%) · RED", () => { assert.equal(g1.before.dsr, 45); assert.equal(g1.after.debt_service, 9250); assert.equal(g1.after.dsr, 61.67); assert.equal(g1.tier, "RED"); });
ok("capped: the informal debt is part-paid, not settled, and its instalment stays", () => { assert.equal(g1.advance.settles.length, 0); assert.deepEqual(g1.advance.partial, { index:1, applied:60000 }); assert.ok(g1.gaps.some(x=>/exceed the advance cap/.test(x))); });
const g2 = compute(G([ formal3750, {item:"Other",institution:"Express Credit",loanAmount:"50000",interestRate:"25",balance:"40000",monthlyInstalment:"3000"} ]),
                   { liabilities:[{index:0,classification:"formal",rate_period:"annual"},{index:1,classification:"informal",rate_period:"annual"}] });
ok("settle a 40,000 loan repaying 3,000: instalment 1,666.67 · after 5,416.67 · DSR 36.11% · GREEN", () => {
  assert.equal(g2.before.dsr, 45); assert.equal(g2.advance.amount, 40000); assert.equal(g2.advance.instalment, 1666.67);
  assert.equal(g2.after.debt_service, 5416.67); assert.equal(g2.after.dsr, 36.11); assert.equal(g2.tier, "GREEN"); assert.deepEqual(g2.advance.settles, [1]);
});
const g3 = compute(G([ {item:"Other",institution:"Mashonisa",loanAmount:"40000",interestRate:"30% per month",balance:"50000",monthlyInstalment:"1000"},
                       {item:"Other",institution:"Express Credit",loanAmount:"30000",interestRate:"25",balance:"30000",monthlyInstalment:"800"} ]),
                   { liabilities:[{index:0,classification:"informal",rate_period:"monthly"},{index:1,classification:"informal",rate_period:"annual"}] });
ok("capped at 60,000: the dearest debt (360% p.a.) is settled first, 10,000 goes towards the next", () => {
  assert.equal(g3.advance.debt_based_amount, 80000); assert.equal(g3.advance.amount, 60000); assert.deepEqual(g3.advance.settles, [0]);
  assert.deepEqual(g3.advance.partial, { index:1, applied:10000 });
  assert.equal(g3.after.debt_service, 1800 - 1000 + 2500);
});
ok("term is fixed at 24 whatever the prep says", () => { const t = compute(G([ formal3750, {item:"Other",institution:"Motshelo",balance:"12000",monthlyInstalment:"0"} ]), { term_months:36 }); assert.equal(t.term_months, 24); assert.equal(t.advance.instalment, 500); });
ok("no gross salary → Decline – Insufficient Data, no advance", () => {
  const z = compute({ ...G([ {item:"Other",institution:"Motshelo",balance:"5000",monthlyInstalment:"0"} ]), income:{ monthlySalary:0, spouseIncome:20000 } }, {});
  assert.equal(z.advance, null); assert.equal(z.decision, "Decline – Insufficient Data"); assert.equal(z.before.dsr, null);
});

console.log("DSR on own gross income — salary plus the client's own business / rental / dividend income (4 Oct 2026)");
// Olorato's shape: P 4,000 salary, P 8,300 from her own business, spouse income
// P 5,000 that is NOT hers to repay from. FNB instalment 5,500.
const O = { personal:{ name:"O", employer:"Hollard" }, kids:[], budget:{},
  income:{ monthlySalary:4000, otherDeductions:0, spouseIncome:5000, rentals:0, businessIncome:8300, dividends:0 },
  liabilities:[ {item:"Personal Loan",institution:"FNB",loanAmount:"250000",interestRate:"14",balance:"210000",monthlyInstalment:"5500"},
                {item:"Other",institution:"Motshelo",loanAmount:"16000",interestRate:"30% monthly",balance:"16000",monthlyInstalment:"0"} ] };
const oc = compute(O, { liabilities:[{index:0,classification:"formal",rate_period:"annual"},{index:1,classification:"informal",rate_period:"monthly"}] });
ok("DSR = 5,500 / (4,000 + 8,300) = 44.72%, not 137.5% on salary alone, and spouse income stays out", () => {
  assert.equal(oc.income.dsr_income, 12300); assert.equal(oc.before.dsr, 44.72);
});
ok("the cap stays on gross SALARY: 4 × 4,000 = 16,000, so the 16,000 motshelo fits exactly", () => {
  assert.equal(oc.advance.cap, 16000); assert.equal(oc.advance.amount, 16000); assert.equal(oc.advance.capped, false);
  assert.equal(oc.after.dsr, Math.round((5500 + 16000/24) / 12300 * 10000) / 100);
});
const ob = compute({ ...O, income:{ ...O.income, monthlySalary:0 } }, {});
ok("business income but no salary: a DSR exists, the advance cannot be sized, and the reason says it is the cap", () => {
  assert.equal(ob.before.dsr, round2pct(5500, 8300)); assert.equal(ob.advance, null); assert.equal(ob.decision, "Decline – Insufficient Data");
  assert.ok(ob.decision_reasons.some(r => /advance cap \(4 × gross salary\)/.test(r)));
});
function round2pct(a, b) { return Math.round(a / b * 10000) / 100; }

console.log(`\n${n} checks passed`);
