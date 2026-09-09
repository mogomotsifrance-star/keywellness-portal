# Do not merge this branch

**Status: superseded and parked, 9 Sep 2026.**

This branch carries a **second, independent implementation of the Debt Rehab
Plan**. The feature it builds is already on `dev` (merge commit `193ba81`,
PR #3) and has been applied to the live project since 4 Sep 2026, where
`debt_rehab_plans` already holds real rows.

Merging this branch would attempt to create the same table, the same five
RPCs and the same Edge Function a second time. **The migration would fail on
the table name, and if it did not, it would replace a stricter access design
with a weaker one.**

## Why the merged version is the one to keep

| | On `dev` (keep) | On this branch (discard) |
|---|---|---|
| Read path | **No policy at all**; reads go through `debt_rehab_plan_list()`, so even the owning advisor gets zero rows from a direct select | One SELECT policy under `can_manage_advisor()` |
| Unit checks | 38 | 43 |
| RLS assertions | 28 | 36 |
| Live | applied 4 Sep, in use | never applied |

The zero-policy design is the stronger one: a read path that does not exist
cannot be widened by accident. This branch's plan argued the opposite and was
wrong.

## What is worth taking from here

One thing. `tests/debt-rehab-plan.test.mjs` on this branch is built from
**Olorato Maliko's real `advisor_clients` record**. The suite on `dev` uses a
synthetic fixture (employer "Sedimosa", salary P 4,000, one asset) engineered
to reach the same P 12,300.00 income, so it never exercises the real record's
shape: the five `custom_id_*` budget rows that land in "Other", the second
lever asset, and rates stored as bare "30" / "25" with no period text.

The shipped compute **was run against the real record on 9 Sep and reproduces
spec §7 exactly** — income P 12,300.00, DSR 44.72%, budget
60.16 / 9.76 / 19.51 / 39.43%, shortfall P 3,550.00, cash gap P 9,050.00, net
worth −P 133,000.00, both levers at 1.74× and 4.35×. So this is a
test-coverage gap, not a defect. Porting the real-record fixture onto `dev`'s
suite is a small, useful follow-up; merging this branch is not.

See `/workspace/vault/keywellness-portal/decisions/2026-09-09-two-sessions-built-the-same-feature.md`.
