# Batch 0 findings — Advisor debt, budget, DSR and Hollard advance (4 Oct 2026)

Read-only discovery for the "Advisor Portal Debt, Budget, DSR and Hollard
Advance" build. Live database read with SELECT only; no writes.

## Gate result

GO on all three automatic conditions:

- **Hollard is identifiable**: organisation `Hollard` (`87ff91c9…`),
  `offers_advances = true`. 13 advisor clients carry it; none is linked to a
  portal account and no member profile belongs to it.
- **Gross salary is stored**: advisor side `assessment.income.monthlySalary`
  (missing for 1 of 25 clients, 0 of 13 Hollard); member side
  `profiles.gross_income` (missing for 85 of 115 members).
- **No HR-facing RPC returns individual liability data.**

## What changed the plan

| Finding | Effect | Decision (Tshenolo, 4 Oct) |
|---|---|---|
| No liabilities table. Advisor liabilities are a JSON array in `advisor_clients.assessment`, saved by direct UPDATE from the browser | No columns to add | New JSON key `termMonths` only |
| `institution` already exists (67 of 131 rows filled); `balance` already exists and is what the Advance Recommendation treats as the amount owed; `loanAmount` is the principal | Two of three "new" fields exist | Relabel `balance` "Outstanding balance"; keep `loanAmount` as principal |
| Advisor DSR = instalments ÷ household take-home (net salary + spouse + rentals + business + dividends) | LD1 changes every advisor figure | Instalments ÷ client's own gross income: gross salary + their own business, rental and dividend income; spouse income out (revised 4 Oct from "salary only", after a P 4,000-salary business owner read 137.5%) |
| 7+ DSR implementations with different bands (20/35/45, 35/50/65, 30/45/60, 35/40, 40), inclusive and exclusive 45, and "gross" labels on take-home maths | One source needed | `threshold_config` row `indicator.dsr` + `js/dsr-bands.js` |
| `threshold_config` `indicator.dti` already drives `kw_dti_band()`; lending norm is read from `manageable.max` | New bands would move the norm to 50 | Keep `over_indebted` key, label "Overindebted", add `benchmark: 40`, `over_indebted_line: 60` |
| HR sees DSR bands in aggregate (`org_financial_indicators()` → employer.html Debt Health), hard-coded 20/35/45 on take-home `monthly_income` | HR follows | Gross where present, else take-home; suppression unchanged |
| Advance Recommendation already exists for Hollard (debt-sized, no salary cap, 24 m, 0%, tiers 35/45) | Batch 5 overlaps | Fold the 4 × gross cap into it; drop the separate calculator |
| The Advance Recommendation is written for the Hollard HR approver and carries the full liability list | Batch 6 stop rule | Add nothing new to it; log as a separate privacy item |
| Ask Key carries no DSR | Nothing to update | Leave alone; log the `debt_extra` bug |
| `stripAiDashes` does not exist | | Add a dash search to the copy checklist |
| Live `member_debts` table (25 rows) with no migration anywhere | Drift | Documentation-only file `supabase_member_debts_doc.sql` |

## Band movement, old method → new method (counts only)

**Advisor clients (25).** Old: instalments ÷ household take-home, bands 20/35/45.
New: instalments ÷ own gross income (gross salary + own business, rental and
dividend income), bands 40/50/60.

| Band | Old (all) | Old (Hollard) | New (all) | New (Hollard) |
|---|---|---|---|---|
| Healthy | 8 | 4 | 18 | 9 |
| Manageable | 2 | 2 | 0 | 0 |
| Strained | 3 | 1 | 3 | 3 |
| Overindebted | 11 | 6 | 3 | 1 |
| No income | 1 | 0 | 1 | 0 |

(On gross salary alone, before the denominator was revised, it was 17 / 0 /
4 / 3: one business owner moved from strained to healthy.)
**Advisors should expect most flags to drop.** That is the combined effect
of the gross denominator (larger than take-home) and the higher bands.

**Members with a DSR (24 of 115).** Old: `monthly_debt ÷ monthly_income`
(take-home), 20/35/45. New: ÷ gross where recorded else take-home, 40/50/60.

| Band | Old | New |
|---|---|---|
| Healthy | 9 | 17 |
| Manageable | 5 | 1 |
| Strained | 3 | 0 |
| Overindebted | 7 | 6 |

Band counts before and after this change are **not comparable**.

## Detail

The full inventory (file:line for every threshold, every calculation path,
the liabilities RLS, the budget model and the report pipeline) was given in
the session report of 4 Oct 2026. The parts later batches depend on:

- DSR config: `threshold_config` → `kw_threshold()` → `kw_dti_band()` /
  `kw_is_over_indebted()`; advisor `KW_DTI_FALLBACK` / `kwDtiBand()` /
  `kwLendingNorm()` (`advisor.html:1675-1747`); Debt Rehab reads the norm in
  `supabase/functions/debt-rehab-plan/index.ts:235-241`.
- Hard-coded copies: `org_financial_indicators()` (live body, last patched by
  B1), `_org_indicator_catalogue()`, `employer.html:1141`, `admin.html`,
  `advisor.html` `diagDebt` / `analyseDebt` / `panelRobo` / methodology,
  `_shared/kw-finance.ts:22-32`, `advance-recommendation/compute.ts`,
  `report.ts`, `debt-rehab-plan/compute-rehab.ts`, member tools
  (`dti_calculator`, `index.html` tile, `affordability_calculator`,
  `wellness_assessment`).
- Take-home fallback: `dti_calculator.html` `dtiBasis()`;
  `index.html` around `_profGross`.
- Budget: advisor `EXPENSE_GROUPS` (`advisor.html:2746`); no family support
  line; `motshelo` is labelled "Motshelo / Moraka"; `debt_min` / `debt_extra`
  are typed separately from liability instalments.
- Reports: PFA is browser-rendered and never stored; Advance Recommendation
  and Debt Rehab are stored snapshots (6 and 3 drafts, 0 final).

## Bugs found in passing

- `dti_calculator` PDF export ignores the take-home fallback (shows 0%). Fixed in Batch 2.
- `affordability_calculator` prefills gross from a take-home total. Fixed in Batch 2.
- `dti_calculator` save can overwrite `monthly_debt` without payslip loans. Own batch (6b).
- Ask Key snapshot counts `debt_extra` as savings. Logged, not fixed.
- Budget advice "dangerously high" at 40%: see Batch 2 note in BUILD-NOTES.
