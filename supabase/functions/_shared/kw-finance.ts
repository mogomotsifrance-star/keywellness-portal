// Key Wellness — shared finance helpers (Edge Functions)
// ============================================================
// The arithmetic and parsing that more than one advisor-portal report
// needs: the tier thresholds, the BURS PAYE table, total monthly income,
// the free-text rate parser, the "live liability" filter, the formatters
// and the Formal / Informal pre-classification. Moved here verbatim from
// advance-recommendation/compute.ts on 3 Sep 2026 so the Debt Rehab Plan
// could reuse them instead of copying them; compute.ts re-exports every
// name, so nothing that imported from it had to change.
//
// Pure module: no imports, no I/O, no Date.now(). Runs unchanged under
// Deno (Edge Functions), Node 22 (unit tests) and esbuild (browser suites).
//
// Mirrors advisor.html exactly where the two overlap:
//   - PAYE: calcAnnualTax() / calcMonthlyPAYE() (annualised-earnings method)
//   - Total monthly income: net salary + spouse + rentals + business + dividends
//   - "Live" liability filter: panelReport()'s liabData test
//   - Lending norm: kwLendingNorm(), the manageable band's ceiling
// If advisor.html changes one of those, change it here in the same commit.
// ============================================================

export const DSR_GREEN_MAX = 35;          // ≤ 35% → GREEN
export const DSR_AMBER_MAX = 45;          // ≤ 45% → AMBER, above → RED
export const DISPOSABLE_FLOOR_PCT = 10;   // disposable after < 10% of income → RED
export const HIGH_COST_RATE_PA = 20;      // ≥ 20% p.a. equivalent → high-cost
export const DEFAULT_TERM_MONTHS = 24;
export const REPEATED_BORROWING_COUNT = 3; // ≥ 3 informal lenders → HR-letter hold default on
// The lending norm quoted to clients — the ceiling of the "manageable" DTI
// band. advisor.html reads it from threshold_config (kwLendingNorm()); the
// Edge Function does the same and passes it in, and this is the fallback
// when the config cannot be read. Keep equal to indicator.dti.bands[manageable].max.
export const LENDING_NORM_PCT = 35;

// Household-name Botswana lenders. Used ONLY to pre-fill the advisor's
// classification screen; the advisor's confirmed classification is what
// compute() actually uses.
export const FORMAL_HINTS = [
  "stanbic", "fnb", "first national", "absa", "barclays", "standard chartered",
  "stanchart", "bank gaborone", "bbs", "botswana building society", "access bank",
  "banc abc", "bancabc", "first capital", "bank of baroda", "botswana savings bank",
  "bsb", "letshego", "nbfira", "ndb", "national development bank", "ceda",
];
export const INFORMAL_HINTS = [
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

export interface Assessment {
  personal?: Record<string, unknown>;
  kids?: unknown[];
  income?: Record<string, unknown>;
  liabilities?: RawLiability[];
  budget?: Record<string, unknown>;
  notes?: Record<string, unknown>;
  assets?: RawAsset[];
  savings?: RawSaving[];
  budgetOtherCustom?: { id?: string; name?: string }[];
}

export interface RawAsset {
  name?: string; value?: unknown; status?: string; size?: string;
  monthlyIncome?: unknown; potentialIncome?: unknown;
}
export interface RawSaving {
  institution?: string; currentBalance?: unknown; monthlyContribution?: unknown;
  purpose?: string; expectedMaturity?: unknown;
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

// Income — identical to advisor.html calcTotals(): net salary after PAYE
// and other deductions, plus spouse and passive income.
export interface IncomeView {
  gross_salary: number; paye: number; other_deductions: number; net_salary: number;
  spouse_income: number; rental_income: number; business_income: number; dividends: number;
  total_monthly_income: number;
}
export function totalIncome(a: Assessment): IncomeView {
  const income = a.income || {};
  const gross = pf(income.monthlySalary);
  const paye = calcMonthlyPAYE(gross);
  const other = pf(income.otherDeductions);
  const net = Math.max(0, gross - paye - other);
  const spouse = pf(income.spouseIncome), rentals = pf(income.rentals),
        business = pf(income.businessIncome), dividends = pf(income.dividends);
  return {
    gross_salary: round2(gross), paye: round2(paye), other_deductions: round2(other), net_salary: round2(net),
    spouse_income: spouse, rental_income: rentals, business_income: business, dividends,
    total_monthly_income: round2(net + spouse + rentals + business + dividends),
  };
}

// Budget groups — mirror of advisor.html EXPENSE_GROUPS (ids only; the
// portal owns the labels). Custom "Other" items live in budgetOtherCustom.
export const EXPENSE_GROUP_IDS: { id: "needs" | "wants" | "savings" | "other"; name: string; cats: string[] }[] = [
  { id: "needs",   name: "Needs",                 cats: ["housing", "utilities", "food", "transport", "health", "childcare", "insurance", "debt_min"] },
  { id: "wants",   name: "Wants",                 cats: ["entertain", "dining", "shopping", "personal", "subscript", "travel"] },
  { id: "savings", name: "Savings & Investments", cats: ["emfund", "retirement", "invest", "goals", "motshelo", "debt_extra"] },
  { id: "other",   name: "Other",                 cats: ["misc"] },
];
