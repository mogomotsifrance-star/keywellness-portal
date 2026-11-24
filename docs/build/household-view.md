# Household view (advisor portal)

Built from the 23 Nov 2026 prompt on `dev`. Base commit `3ccd4d0`.

## Rollback, written before each batch

| Batch | Rollback |
|---|---|
| 1 Data shape | Revert the commit. The new keys (`household`, `budgetPaidBy`, and `paidBy` / `paidSplit` / `liable` on a liability) are additive jsonb keys that older code ignores; records keep them harmlessly. |
| 2 Page and Edge readers | Revert the one commit. Edge, if deployed: redeploy both functions as they stand at `3ccd4d0` and verify with `tests/verify-edge-deploy.mjs`. SQL, if applied: `migrations/rollback-household-override-guard.sql` (restores from `kw_fn_backup`, tag `household-override-guard`). Attributions advisors saved meanwhile stop counting: the older code reads every line and loan as the client's. |
| 3 Screens | Revert the commit. One thing a revert cannot undo: a loan marked as the spouse's alone has already had its lender, balance, rate, term and loan amount removed, after a confirmation. |
| 4 Report | Revert the commit. Nothing is stored. |
| 5 Checks | Revert the commit. Tests and documents only. |

## What was built

- **Data shape.** `js/kw-household.js` is the only place household arithmetic
  lives on the page. `household` (`enabled`, `spouseContribution`),
  `budgetPaidBy`, and `paidBy` / `paidSplit` / `liable` on a liability. Absent
  means the client pays and the client is liable, so an untouched record
  computes as before.
- **Two views.** `householdViews()` returns an individual and a household view.
  The household object has no dsr, ratio, band or tier key. `calcTotals()` is
  the individual view; every DSR, band, indicator and report reads it.
- **Screens.** A switch on the Income tab with one figure, Paid by on each
  budget line, Liable and Paid by on each loan, a two-column table on
  Diagnostics. A client without the switch on sees none of it.
- **Report.** A tick beside Print, off each time a client is opened, never
  stored, adds one page after Net Worth. "Serviced by spouse" prints against a
  loan the spouse pays whether or not the tick is on.
- **Edge (committed, NOT deployed).** `clientOnly()` in `_shared/kw-finance.ts`
  reduces a record to the client's own share before either function computes or
  snapshots anything. No `household` object or spouse figure reaches a snapshot.
- **SQL (committed, NOT applied).** `supabase_household_override_guard.sql`: a
  loan only the spouse is liable for cannot be a use-of-funds line.

## Decisions

| Question | Decided |
|---|---|
| DSR income basis | Unchanged: gross salary + own business, rental and dividend income. The retirement build inherits it. |
| The two old spouse figures | Not migrated. Kept as unread legacy (`income.spouseIncome`) and shown to the advisor as a prompt. Hence no `tests/household-verify-live.sql`. |
| Switch off after use | Hides the Household column and the tick. Clears nothing: attributions keep applying, and the Budget tab shows any non-default Paid by read-only with the date it was set. |
| Loans in the household view | Counted once, from Liabilities. `debt_min` is left out; `debt_extra` stays. The budget's own surplus is unchanged. 21 live records carry both. |
| Spouse-only loan | Keeps item and instalment only. Out of net worth, Robo, rehab, AR and calculators. |
| Client-liable loan paid by someone else | Full instalment in the client's DSR. |

## What moves for existing records

Of 40 live clients, 2 hold an old spouse figure. No DSR and no band moves.
Their total income, surplus, percentages and diagnostics fall to their own
income; one has a budget that was already short and is now shorter. Either may
gain "Single income stream" (15 points of income severity) if no passive income
is captured. Neither has an AR or rehab plan. All other records are unchanged.

Wording that changed for everyone: the "household" labels on figures that were
always the individual's; the spouse income row is gone from all reports; the
rehab "Single-earner household" line now reads "Single income stream: no
rental, business or dividend income captured". In `debt-rehab-plan.test.mjs`
one concentration count moved 3 to 2 for that reason.

## What the tests prove

- `tests/household.test.mjs`, 18 checks: an old record computes to figures
  pinned from `3ccd4d0`; splits, loans and old-figure exceptions; Edge output
  identical with the household stripped; the household data keys and new copy
  appear nowhere in the two Edge folders, and nothing household in
  `employer.html` or the employer SQL. The leak gate was seen to fail on a
  planted line. In the Edge folders it bans data keys and new copy, not the
  bare word, because "household budget" is existing AR copy.
- `tests/smoke-advisor-dsr.js` H.1 to H.23: the screens, and that a record with
  no household keys prints byte for byte what it did before the report batch
  (compared with commit `a179bc5`; skips if a shallow clone lacks it).
- The SQL ran in a local Postgres: idempotent, hides and refuses a spouse loan,
  rollback identical. On live, read-only: each substitution anchor occurs once.

Not proven: no real dual-income client has been entered on the dev site, and
nothing was run against deployed Edge code.

## Not done, deliberately

No partner profile, no fourth payer, no household DSR, no employer exposure.
Retirement not started. Consent wording proposed in BUILD-NOTES, not applied.
Also left: on the Budget tab the money input is slightly wider than its column.
It predates this build (`.money-wrap input` padding applies only inside `.field`).

## `indicator.dti` trace (read-only, no change)

No live function, page or Edge file reads `indicator.dti` (20/35/45); the only
mention is a comment at `tests/smoke-picker.js:27`. `kw_dti_band`,
`kw_is_over_indebted`, `org_financial_indicators` and `_org_indicator_catalogue`
read `indicator.dsr`; `_org_indicator_counts` goes through `kw_dti_band`. The
row is still in `threshold_config`, unread.

## Fork check, `advisor.html` against `3ccd4d0`

190 lines added, 42 removed. Every removed line is one of: the Spouse Income
field and its report rows; `spouseIncome` in `calcTotals`; the sums there that
now go through `kwViews`; "household" labels; loan lists that now read
`clientLoans`; Liabilities and Budget rows that gained columns; the Liabilities
minimum width; the Net Worth and Print lines the report section attaches to.
No other feature lost a line. `origin/main` held nothing `origin/dev` lacked.

## Deploy order: with the `main` merge (Tshenolo, 24 Nov 2026)

SQL and Edge serve both sites. The pages on `main` ignore the new keys and go
on counting the old spouse figure until the merge, so deploy with that merge:

1. Apply `supabase_household_override_guard.sql`; confirm 2 backup rows.
2. Deploy `advance-recommendation` and `debt-rehab-plan` with the CLI from the
   committed files, then `tests/verify-edge-deploy.mjs` on each read-back.
3. Merge `dev` to `main`.

Until step 2, do not generate an AR or rehab plan for a record using Paid by or
Liable: the deployed functions still read every line and loan as the client's.

## Suites, 23 Nov 2026

One failure: `smoke-prefill` 213 (budget planner row geometry at 1280px). The
planner, `kw-categories.js` and that test are untouched since `3ccd4d0`, so it
predates this build. `npm test` stops there, so the later suites were run
separately. `test:edge` needs Deno and was not run.
