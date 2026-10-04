# Claude Code Prompt: retire the old `indicator.dti` config row

## Read this first
- **Run this only after the DSR build has been merged to `main`** and the live site serves `advisor.html` that reads `indicator.dsr`.
- One shared Supabase project: deleting the row is live at once for both sites. Write the rollback first.
- Stop at the GO/NO-GO gate.

## Why
The DSR build (4 Oct 2026) added `threshold_config` row `indicator.dsr` (40/50/60, benchmark 40, line 60) as a **new** row, so that `advisor.html` on `main` kept reading `indicator.dti` (20/35/45) until the merge. Once `main` reads `indicator.dsr`, the old row is dead weight and a trap: anyone who edits it thinks they are changing the bands.

## Batch 0: read-only discovery
1. Confirm `main` contains `js/dsr-bands.js` and that `advisor.html` on `main` queries `indicator.dsr` (`git show origin/main:advisor.html | grep indicator`).
2. Search everything that could still read `indicator.dti`:
   - the repo, on all branches
   - live SQL: `select proname from pg_proc where prosrc ~ 'indicator\.dti'`
   - Edge Functions (deployed source)
   - views

   Expect: nothing, except history files and `kw_fn_backup` bodies.
3. Record the row's current value verbatim, for the rollback.

**GO/NO-GO gate.** NO-GO if anything live still reads it.

## Batch 1 (after GO)
- **Rollback (write first):** `insert into threshold_config (key, value) values ('indicator.dti', '<recorded json>') on conflict (key) do nothing;`
- Delete the row. Update the comments in `js/dsr-bands.js`, `supabase/functions/_shared/kw-finance.ts` and `CLAUDE.md` that mention it. Leave history files alone.

**Checklist:**
- [ ] The advisor portal still bands correctly on `main` and `dev`.
- [ ] `kw_dti_band(45)` = manageable.
- [ ] The HR Debt Health panel renders.
- [ ] The rollback is tested by reading only, never by applying it.
