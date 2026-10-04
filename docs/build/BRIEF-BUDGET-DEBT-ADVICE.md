# Claude Code Prompt: budget planner minimum-debt advice (40% vs 25%)

## Read this first
- Options and a recommendation only. **No change in this prompt.**
- Member-facing copy: no em dashes, en dashes or double hyphens; the Phase D tone rules apply (`docs/phase-d-category-model.md`: "We never scold").
- `CLAUDE.md` rules on advice ranking (`kw_phase_d`) and never naming a Need in cut advice still apply.

## What exists (found 4 Oct 2026)
`budget_planner.html` `renderAdvice()`:

```js
if (debtMin / totalIncome > 0.40) // "Minimum debt payments are X% of income. This is dangerously high. Consider the Debt Management Plan tool."
```

- **It is not DSR.** The numerator is the budget's `debt_min` only: no salary-deducted loans (`payslip.loans`), no `debt_extra`. The denominator is the budget's total income rows, which is take-home.
- **It does not match the approved Phase D copy.** The spec (`docs/phase-d-category-model.md:44`) says, for `debt_min`: "Minimum debt payments are {pct}% of income. Above about 25% this is what makes a month feel tight even when nothing has gone wrong." Same intent, different threshold (25%), and no "dangerously".
- The DSR build made the dashboard and DTI calculator use 40/50/60 on gross (or labelled take-home). A member can now see "Healthy" DSR on the dashboard and "dangerously high" in the budget for the same debts, because the two measure different things on different incomes.

## Batch 0: read-only discovery
1. How many budgets currently trip the 40% line, and how many would trip 25% (counts only, from `tool_data`).
2. Whether the advice is ranked or capped out today (`kw_phase_d` marking).
3. What the budget knows that could make it a real DSR: payslip gross, payslip loans.

## Options to present at the gate
- **A. Implement the approved Phase D copy as written:** 25% on budget take-home, calm wording. Matches the signed-off spec; still not DSR; may contradict a "Healthy" dashboard DSR.
- **B. Make it a DSR line:** (`debt_min` + payslip loans) ÷ payslip gross where the payslip has gross, else take-home with the same label the dashboard uses; band through `js/dsr-bands.js`; Phase D tone. One measure everywhere; needs Phase D copy re-approved.
- **C. Remove the threshold sentence**, keep a neutral statement of the share, and link to the DTI calculator for the verdict.

**Recommendation to put to Tshenolo:** B. One debt measure across the portal is the point of the DSR build, and the budget already holds the payslip figures it needs. A is the fallback if the Phase D copy must not be reopened.

**GO/NO-GO gate.** Stop after presenting the options with the counts.
