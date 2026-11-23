// Household view: attribution parser, the two views, Edge parity, leak gate.
// Run: node tests/household.test.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import "../js/kw-household.js";
const H = globalThis.KWHousehold;
let n = 0; const ok = (name, f) => { f(); n++; console.log("  ✓ " + name); };
const clone = (x) => JSON.parse(JSON.stringify(x));
const read = (p) => fs.readFileSync(new URL("../" + p, import.meta.url), "utf8");

const OLD = JSON.parse(read("tests/household-old-record.json"));   // { record, calcTotals } from the code at 3ccd4d0

// The page's own calcTotals(), taken from advisor.html and run in a sandbox.
const html = read("advisor.html");
const grab = (from, to) => { const i = html.indexOf(from), j = html.indexOf(to, i); assert.ok(i >= 0 && j > i, "anchor " + from); return html.slice(i, j); };
const box = { KWHousehold: H, kwLendingNorm: () => 40 };
vm.createContext(box);
vm.runInContext("function pf(v){const n=parseFloat(String(v==null?'':v).replace(/[,P\\s]/g,''));return isFinite(n)?n:0;}\n"
  + grab("function calcAnnualTax(", "/* ── Client model ── */") + grab("const EXPENSE_GROUPS = [", "function panelBudget(") + grab("function calcTotals(c){", "function diagIncome("), box);
const totals = (c) => { box.__c = c; return clone(vm.runInContext("calcTotals(__c)", box)); };
const net = (c) => { box.__c = c; return vm.runInContext("calcNetSalary(__c.income).net", box); };
const views = (c) => H.householdViews(c, net(c));

console.log("Batch 1: data shape");
ok("no keys: household off, every line client 100, every loan client", () => {
  const r = H.normalise(OLD.record);
  assert.deepEqual(r.household, { enabled: false, spouseContribution: null });
  Object.values(r.budgetPaidBy).forEach((p) => assert.deepEqual(p, { by: "client", split: 100, setAt: null }));
  r.liabilities.forEach((l) => assert.deepEqual([l.liable, l.paidBy, l.paidSplit], ["client", "client", 100]));
});
ok("bad values fall back: unknown payer is client, split clamps, missing split is 50, zero stays zero", () => {
  const c = { budget: { a: 10, b: 10, c: 10, d: 10 }, budgetPaidBy: { a: { by: "uncle" }, b: { by: "shared", split: 140 }, c: { by: "shared" }, d: { by: "shared", split: 0 } } };
  assert.deepEqual(["a", "b", "c", "d"].map((k) => H.paidBy(c, k).split), [100, 100, 50, 0]);
});
ok("a spouse-only loan keeps its name and instalment and nothing else", () => {
  const r = H.stripSpouseLoan({ item: "Car Loan", institution: "FNB", loanAmount: 9, interestRate: "9%", balance: 8, termMonths: 7, monthlyInstalment: 500, liable: "spouse" });
  assert.deepEqual(r, { item: "Car Loan", institution: "", loanAmount: 0, interestRate: "", balance: null, termMonths: null, monthlyInstalment: 500, liable: "spouse" });
});
ok("an old record gives exactly the calcTotals() figures pinned from the code before this build", () => {
  const t = totals(OLD.record);
  Object.keys(OLD.calcTotals).filter((k) => k !== "spouseIncome").forEach((k) => assert.equal(t[k], OLD.calcTotals[k], k));
});

console.log("Batch 2: two computations");
// The design note's worked example. Take-home 12,000 comes from the page's
// PAYE table, so other deductions are set to whatever lands there exactly.
const EX = {
  ...clone(OLD.record),
  income: { monthlySalary: 14000, otherDeductions: 0, spouseIncome: 0, rentals: 0, businessIncome: 0, dividends: 0 },
  household: { enabled: true, spouseContribution: 9000 },
  budget: { housing: 5500, food: 3200, custom_fam: 1500, debt_min: 4200 }, budgetOtherCustom: [{ id: "custom_fam", name: "Family support" }],
  budgetPaidBy: { housing: { by: "shared", split: 50 }, food: { by: "spouse" } },
  liabilities: [ { item: "Car Loan", institution: "FNB", balance: 60000, monthlyInstalment: 2800, liable: "client", paidBy: "spouse" },
                 { item: "Personal Loan", institution: "Absa", balance: 20000, monthlyInstalment: 1400 } ],
};
EX.income.otherDeductions = net(EX) - 12000;
const SP = { item: "Other", monthlyInstalment: 999, liable: "spouse" };

ok("1 worked example: individual 12,000 in, 4,250 expenses, 4,200 loans; household 21,000 in, 14,400 out, 6,600 left", () => {
  const v = views(EX);
  assert.equal(v.individual.income, 12000); assert.equal(v.individual.expenses, 4250); assert.equal(v.individual.debtService, 4200);
  assert.equal(v.individual.surplus, 3550); assert.equal(v.individual.dsr, 30);   // 4,200 / 14,000 gross
  assert.deepEqual(v.household, { income: 21000, expenses: 10200, debtService: 4200, surplus: 6600 });
  assert.equal(v.individual.loans[0].paidBy, "spouse"); assert.equal(v.individual.loans[0].liable, "client");
});
ok("2 no household key: individual figures equal the pinned ones, and household is null", () => {
  const v = views(OLD.record), t = OLD.calcTotals;
  assert.equal(v.individual.income, t.totalIncome); assert.equal(v.individual.dsr, t.dti);
  assert.equal(v.individual.dsrBasis, t.dsrIncome); assert.equal(v.individual.debtService, t.totalDebtInstalment);
  assert.ok(Math.abs(v.individual.expenses - (t.totalExpenses - t.budgetDebtMin)) < 1e-9); assert.equal(v.household, null);
});
ok("2b a record with the legacy spouse figure: it leaves income and surplus, and the DSR does not move", () => {
  const a = clone(OLD.record), b = clone(OLD.record); b.income.spouseIncome = 8000;
  assert.deepEqual(totals(b), totals(a)); assert.deepEqual(views(b), views(a));
});
ok("3 the switch and the contribution change no individual field and no calcTotals figure", () => {
  const off = clone(EX); off.household = { enabled: false, spouseContribution: null };
  const none = clone(EX); delete none.household;
  [off, none].forEach((c) => { assert.deepEqual(views(c).individual, views(EX).individual); assert.deepEqual(totals(c), totals(EX)); assert.equal(views(c).household, null); });
});
ok("4 a spouse-only loan is out of the client's debt service and in the household's; a joint one is in both, in full", () => {
  const c = clone(EX); c.liabilities.push(clone(SP)); c.liabilities[1].liable = "joint"; c.liabilities[1].paidBy = "shared"; c.liabilities[1].paidSplit = 10;
  const v = views(c);
  assert.equal(v.individual.debtService, 4200); assert.equal(v.household.debtService, 5199);
  assert.equal(totals(c).totalDebtInstalment, 4200); assert.equal(totals(c).totalLiabilityBalance, 80000);
});
ok("5 the household object has exactly four keys and no dsr, ratio, band or tier", () => {
  assert.deepEqual(Object.keys(views(EX).household), ["income", "expenses", "debtService", "surplus"]);
  assert.ok(!Object.keys(views(EX).household).some((k) => /dsr|ratio|band|tier/i.test(k)));
});
ok("6 calcTotals and the individual view agree on the DSR, and calcTotals carries no spouse figure", () => {
  assert.equal(totals(EX).dti, views(EX).individual.dsr); assert.ok(!Object.keys(totals(EX)).some((k) => /spouse|household/i.test(k)));
});

const { clientOnly, clientShare, liveLiabilities } = await import("../supabase/functions/_shared/kw-finance.ts");
const { compute } = await import("../supabase/functions/advance-recommendation/compute.ts");
const { computeRehab } = await import("../supabase/functions/debt-rehab-plan/compute-rehab.ts");
ok("7 Edge twin: same client share for every payer and split, same loans", () => {
  const c = { budget: {}, budgetPaidBy: {}, liabilities: [] };
  [undefined, { by: "client" }, { by: "spouse" }, { by: "shared" }, { by: "shared", split: "" }, { by: "shared", split: 0 }, { by: "shared", split: 33 }, { by: "shared", split: 100 }, { by: "shared", split: 140 }, { by: "shared", split: "x" }, { by: "uncle" }]
    .forEach((p, i) => { c.budget["k" + i] = "1,234.56"; if (p) c.budgetPaidBy["k" + i] = p; });
  Object.keys(c.budget).forEach((k) => assert.equal(clientShare(c, k), H.clientAmount(c, k), k));
  assert.equal(compute(EX, {}).before.dsr, 30); assert.equal(computeRehab(EX, {}).dsr, 30);
  assert.equal(compute(EX, {}).budget.expenses, 8450);   // the client's share, debt_min included as before
});
ok("8 a spouse-only loan keeps its neighbours' indexes and never appears", () => {
  const c = clone(EX); c.liabilities.splice(1, 0, clone(SP));
  assert.deepEqual(liveLiabilities(c).map((x) => x.index), [0, 2]);
  assert.deepEqual(liveLiabilities(clientOnly(c)).map((x) => x.index), [0, 2]);
  assert.ok(!JSON.stringify(compute(c, {})).includes("999")); assert.ok(!JSON.stringify(computeRehab(c, {})).includes("999"));
  // an advisor figure that names it removes no instalment and says so
  const o = compute(c, { override: { id: "o", amount: 999, justification: "x".repeat(30), allocations: [{ kind: "liability", liability_index: 1, lender: "Other", amount: 999 }] } });
  assert.equal(o.before.debt_service, 4200); assert.ok(o.gaps.some((g) => /no longer matches/.test(g)));
  const kept = compute(c, { override: { id: "o", amount: 1400, justification: "x".repeat(30), allocations: [{ kind: "liability", liability_index: 2, lender: "Absa", amount: 1400 }] } });
  assert.equal(kept.override.allocations[0].live_index, 2);
});
ok("9 clientOnly: idempotent, carries nothing about the other person, leaves an old record's figures alone", () => {
  const c = clone(EX); c.liabilities.push(clone(SP)); c.income.spouseIncome = 8000;
  const once = clientOnly(c);
  assert.deepEqual(clientOnly(once), once);
  assert.ok(!/spouse|household|paidBy|paidSplit|liable/i.test(JSON.stringify(once)), JSON.stringify(once));
  assert.deepEqual(clientOnly(OLD.record).budget, OLD.record.budget); assert.deepEqual(clientOnly(OLD.record).liabilities, OLD.record.liabilities);
});
ok("10 a budget paid wholly by the spouse is captured, not missing", () => {
  const c = clone(EX); c.budget = { food: 3200 }; const r = compute(c, {});
  assert.equal(r.budget.captured, true); assert.equal(r.budget.expenses, 0); assert.equal(r.budget.shortfall, false);
  assert.equal(computeRehab(c, {}).budget.captured, true);
});

console.log("Batch 5: leaks");
ok("11 the Advance Recommendation and the rehab plan come out the same with the household stripped", () => {
  const c = clone(EX), bare = clone(EX); delete bare.household;
  c.income.spouseIncome = 8000; c.household.spouseContribution = 123456;
  assert.deepEqual(compute(c, {}), compute(bare, {})); assert.deepEqual(computeRehab(c, {}), computeRehab(bare, {}));
});
ok("12 leak gate: no household data on the advance, rehab or employer path", () => {
  // "household budget" is existing copy in the report files, so the gate bans
  // the data and the new wording there, and the bare word on the HR path.
  const BAN = /spouseContribution|budgetPaidBy|assessment\.household|\.household\b|\[["']household["']\]|spouse_?income|householdViews|household picture|serviced by spouse/i;
  const root = new URL("../", import.meta.url), dir = (d) => fs.readdirSync(new URL(d, root)).filter((f) => f.endsWith(".ts")).map((f) => d + f);
  [...dir("supabase/functions/advance-recommendation/"), ...dir("supabase/functions/debt-rehab-plan/")].forEach((f) => assert.ok(!BAN.test(read(f)), f));
  const hr = ["employer.html", "kw-report-charts.js", ...fs.readdirSync(root).filter((f) => /^supabase_.*(org_report|publish_org|org_overview|employer|indicators).*\.sql$/.test(f))];
  assert.ok(hr.length > 8);
  hr.forEach((f) => assert.ok(!/household|spouseContribution|budgetPaidBy/i.test(read(f)), f));
});
ok("13 the stored snapshots are built from clientOnly()", () => {
  ["advance-recommendation", "debt-rehab-plan"].forEach((d) => {
    const s = read(`supabase/functions/${d}/index.ts`);
    assert.ok(s.includes("const assessment = clientOnly((client.assessment || {}) as Assessment);"), d);
    assert.equal(s.split("client.assessment").length, 2, d);
  });
});

console.log(`\n${n} checks passed`);
