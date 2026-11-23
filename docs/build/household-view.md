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
