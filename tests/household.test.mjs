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

console.log(`\n${n} checks passed`);
