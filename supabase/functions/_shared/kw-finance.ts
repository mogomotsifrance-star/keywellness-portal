// Key Wellness — shared finance primitives
// ============================================================
// The arithmetic and classification both advisor reports depend on, in one
// place so they cannot drift apart:
//
//   supabase/functions/advance-recommendation/compute.ts   (Advance Recommendation)
//   supabase/functions/debt-rehab-plan/compute-rehab.ts    (Debt Rehab Plan)
//
// Everything here was written for, and proven by, the Advance Recommendation
// (31 Aug 2026 — tests/advance-recommendation.test.mjs, 17 checks). It moved
// here on 3 Sep 2026 when the Debt Rehab Plan needed the same rate parser,
// the same BURS table, the same "live liability" filter and the same tier
// constants. Nothing was rewritten in the move; the AR's suite is the proof.
//
// Pure module: no imports, no I/O, no Date.now(). Runs unchanged under Deno
// (Edge Functions) and Node 22 (the test suites).
//
// Mirrors advisor.html exactly where the two overlap:
//   - PAYE: calcAnnualTax() / calcMonthlyPAYE() (annualised-earnings method)
//   - Total monthly income: net salary + spouse + rentals + business + dividends
//   - "Live" liability filter: panelReport()'s liabData test
//   - Budget grouping: EXPENSE_GROUPS
// If advisor.html changes one of those, change it here in the same commit.
// ============================================================

// ── Thresholds (tune here; nothing hard-coded inline) ────────────
export const DSR_GREEN_MAX = 35;          // ≤ 35% → GREEN
export const DSR_AMBER_MAX = 45;          // ≤ 45% → AMBER, above → RED
export const DISPOSABLE_FLOOR_PCT = 10;   // disposable after < 10% of income → RED
export const HIGH_COST_RATE_PA = 20;      // ≥ 20% p.a. equivalent → high-cost
export const DEFAULT_TERM_MONTHS = 24;
export const REPEATED_BORROWING_COUNT = 3; // ≥ 3 informal lenders → HR-letter hold default on

// Household-name Botswana lenders. Used ONLY to pre-fill the advisor's
// classification screen; the advisor's confirmed classification is what
// compute() actually uses.
const FORMAL_HINTS = [
  "stanbic", "fnb", "first national", "absa", "barclays", "standard chartered",
  "stanchart", "bank gaborone", "bbs", "botswana building society", "access bank",
  "banc abc", "bancabc", "first capital", "bank of baroda", "botswana savings bank",
  "bsb", "letshego", "nbfira", "ndb", "national development bank", "ceda",
];
const INFORMAL_HINTS = [
  "motshelo", "metshelo", "friend", "family", "relative", "mother", "father",
  "brother", "sister", "uncle", "aunt", "cousin", "colleague", "mashonisa",
  "loan shark", "cash loan", "microlender", "micro lender", "micro-lender",
];

export type Classification = "formal" | "informal";
export type RatePeriod = "annual" | "monthly";
export type Tier = "GREEN" | "AMBER" | "RED";

export interface RawLiability {
  item?: string;
  institution?: string;
  loanAmount?: unknown;
  interestRate?: unknown;
  balance?: unknown;
  monthlyInstalment?: unknown;
}

// The assessment subset both reports read. `assets`, `savings` and
// `budgetOtherCustom` are used only by the Debt Rehab Plan; the AR ignores
// them, which is why they are optional and additive.
export interface RawAsset {
  name?: string;
  value?: unknown;
  status?: string;            // "Income-Generating" | "Personal Use"
  size?: string;
  monthlyIncome?: unknown;
  potentialIncome?: unknown;
}

export interface RawSaving {
  institution?: string;
  currentBalance?: unknown;
  monthlyContribution?: unknown;
  purpose?: string;
  expectedMaturity?: string;
}

export interface Assessment {
  personal?: Record<string, unknown>;
  kids?: unknown[];
  income?: Record<string, unknown>;
  liabilities?: RawLiability[];
  assets?: RawAsset[];
  savings?: RawSaving[];
  budget?: Record<string, unknown>;
  budgetOtherCustom?: { id?: string; name?: string }[];
  notes?: Record<string, unknown>;
}

// ── helpers ──────────────────────────────────────────────────────
export function pf(v: unknown): number {
  const n = parseFloat(String(v == null ? "" : v).replace(/[,P\s]/g, ""));
  return isFinite(n) ? n : 0;
}
export const isBlank = (v: unknown) => v == null || String(v).trim() === "";
export const round2 = (n: number) => Math.round(n * 100) / 100;
export function fmtP(n: number | null | undefined): string {
  if (n == null || !isFinite(Number(n))) return "Not captured";
  const v = Number(n);
  const s = Math.abs(v).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return (v < 0 ? "-" : "") + "P " + s;
}
export function fmtPct(n: number | null | undefined): string {
  if (n == null || !isFinite(Number(n))) return "Not captured";
  return Number(n).toFixed(2) + "%";
}

// Botswana PAYE, resident individual table, annualised-earnings method.
// Identical to advisor.html calcAnnualTax().
export function calcAnnualTax(annual: number): number {
  annual = Math.max(0, annual);
  if (annual <= 48000) return 0;
  if (annual <= 84000) return (annual - 48000) * 0.05;
  if (annual <= 120000) return 1800 + (annual - 84000) * 0.125;
  if (annual <= 156000) return 6300 + (annual - 120000) * 0.1875;
  return 13050 + (annual - 156000) * 0.25;
}
export const calcMonthlyPAYE = (monthlyGross: number) => calcAnnualTax(pf(monthlyGross) * 12) / 12;

// Parse the free-text rate the Liabilities tab stores ("12", "25%",
// "30% per month", "2.5 pm"). Returns the number and whether the text
// itself says monthly. Blank → null.
export function parseRate(raw: unknown): { value: number | null; says_monthly: boolean } {
  if (isBlank(raw)) return { value: null, says_monthly: false };
  const s = String(raw).toLowerCase();
  const m = s.match(/-?\d+(?:[.,]\d+)?/);
  const value = m ? parseFloat(m[0].replace(",", ".")) : null;
  const says_monthly = /(per\s*month|monthly|p\.?\s*m\b|\/\s*m(?:onth)?\b|a month)/.test(s);
  return { value: value != null && isFinite(value) ? value : null, says_monthly };
}

// The same test panelReport() uses to decide a liability row is real and
// not one of the four blank template rows every record carries.
export function liveLiabilities(a: Assessment): { index: number; raw: RawLiability }[] {
  const out: { index: number; raw: RawLiability }[] = [];
  (a.liabilities || []).forEach((r) => {
    if (pf(r.balance) || pf(r.monthlyInstalment) || !isBlank(r.institution) || pf(r.loanAmount)) {
      out.push({ index: out.length, raw: r });
    }
  });
  return out;
}

// Default classification for the advisor's Prepare screen. The advisor
// confirms or overrides; compute() trusts the confirmed list.
export function suggestClassification(raw: RawLiability): { classification: Classification; rate_period: RatePeriod | null; reason: string } {
  const inst = String(raw.institution || "").toLowerCase();
  const item = String(raw.item || "").toLowerCase();
  const rate = parseRate(raw.interestRate);
  const rate_period: RatePeriod | null = rate.value == null ? null : (rate.says_monthly ? "monthly" : "annual");
  if (INFORMAL_HINTS.some((h) => inst.includes(h) || item.includes(h))) {
    return { classification: "informal", rate_period, reason: "Informal or family/friend lender" };
  }
  if (rate.value != null) {
    const pa = rate_period === "monthly" ? rate.value * 12 : rate.value;
    if (pa >= HIGH_COST_RATE_PA) return { classification: "informal", rate_period, reason: `Rate ${pa.toFixed(0)}% p.a. equivalent is at or above ${HIGH_COST_RATE_PA}%` };
  }
  if (FORMAL_HINTS.some((h) => inst.includes(h)) || /mortgage|car loan|vehicle|home loan|credit card/.test(item)) {
    return { classification: "formal", rate_period, reason: "Registered bank or secured facility" };
  }
  // Unknown lender with a reasonable or unknown rate: formal by default,
  // so nothing is folded into an advance without the advisor saying so.
  return { classification: "formal", rate_period, reason: "Lender not recognised — confirm" };
}

// ── income ───────────────────────────────────────────────────────
// The seven lines both computes ran inline. Extracted so a change to the
// deduction order or the passive-income list cannot land in one report and
// not the other. Identical to advisor.html calcTotals().
export interface IncomeSummary {
  gross_salary: number; paye: number; other_deductions: number; net_salary: number;
  spouse_income: number; rental_income: number; business_income: number; dividends: number;
  total_monthly_income: number;
}

export function monthlyIncome(income: Record<string, unknown> | undefined): IncomeSummary {
  const inc = income || {};
  const gross = pf(inc.monthlySalary);
  const paye = calcMonthlyPAYE(gross);
  const other = pf(inc.otherDeductions);
  const net = Math.max(0, gross - paye - other);
  const spouse = pf(inc.spouseIncome), rentals = pf(inc.rentals),
        business = pf(inc.businessIncome), dividends = pf(inc.dividends);
  return {
    gross_salary: round2(gross), paye: round2(paye), other_deductions: round2(other), net_salary: round2(net),
    spouse_income: spouse, rental_income: rentals, business_income: business, dividends,
    total_monthly_income: round2(net + spouse + rentals + business + dividends),
  };
}

// ── budget ───────────────────────────────────────────────────────
// The AR's heuristic, named: a budget exists when any category carries a
// value above zero. A record with every category at 0 is not a budget of
// zero, it is a budget nobody has filled in.
export function budgetCaptured(budget: Record<string, unknown> | undefined): boolean {
  return Object.values(budget || {}).map(pf).some((v) => v > 0);
}

export function budgetTotal(budget: Record<string, unknown> | undefined): number {
  return round2(Object.values(budget || {}).map(pf).reduce((s, v) => s + v, 0));
}

// The category ids of EXPENSE_GROUPS in advisor.html, in the same order.
// Anything not in one of the three named groups falls to "other", which is
// where the page puts its custom_id_* rows.
export const BUDGET_GROUP_IDS: Record<"needs" | "wants" | "savings", string[]> = {
  needs:   ["housing", "utilities", "food", "transport", "health", "childcare", "insurance", "debt_min"],
  wants:   ["entertain", "dining", "shopping", "personal", "subscript", "travel"],
  savings: ["emfund", "retirement", "invest", "goals", "motshelo", "debt_extra"],
};

export interface BudgetGroups {
  needs: number; wants: number; savings: number; other: number; total: number;
  captured: boolean;
  debt_service_in_budget: number;   // debt_min + debt_extra — the loan lines, if captured
  motshelo_in_savings: number;      // the motshelo category, which is debt service, not saving
  other_items: { id: string; amount: number }[];
}

export function budgetGroups(budget: Record<string, unknown> | undefined): BudgetGroups {
  const b = budget || {};
  const sum = (ids: string[]) => round2(ids.reduce((s, id) => s + pf(b[id]), 0));
  const named = new Set([...BUDGET_GROUP_IDS.needs, ...BUDGET_GROUP_IDS.wants, ...BUDGET_GROUP_IDS.savings]);
  const other_items = Object.keys(b).filter((k) => !named.has(k) && pf(b[k]) !== 0)
    .map((id) => ({ id, amount: round2(pf(b[id])) }));
  const needs = sum(BUDGET_GROUP_IDS.needs), wants = sum(BUDGET_GROUP_IDS.wants), savings = sum(BUDGET_GROUP_IDS.savings);
  const other = round2(other_items.reduce((s, x) => s + x.amount, 0));
  return {
    needs, wants, savings, other,
    total: round2(needs + wants + savings + other),
    captured: budgetCaptured(b),
    debt_service_in_budget: round2(pf(b.debt_min) + pf(b.debt_extra)),
    motshelo_in_savings: round2(pf(b.motshelo)),
    other_items,
  };
}
