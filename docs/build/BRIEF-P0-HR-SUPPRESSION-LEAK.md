# Claude Code Prompt: HR suppression leak (P0)

## Read this first
- Key Wellness Financial Wellbeing Portal. Frontend plain HTML/CSS/JS on `dev` only; never commit to `main`.
- One shared Supabase project: every SQL change is live on both sites the moment it runs. Additive only where possible. **Write the rollback before you apply anything.**
- HR and employer users must never see, or be able to infer, an individual member's data. That is the whole point of this prompt.
- Patch live functions the way `CLAUDE.md` describes: capture the live body into `kw_fn_backup`, substitute, assert, execute. Several of these functions were rewritten in place (B1, M3, DSR Batch 2), so their disk files are history.
- Work in batches. Stop at the GO/NO-GO gate and wait for Tshenolo.

## The problem
The suppression rule hides a band with 1 or 2 members (`count: null, suppressed: true`), but the same payload also returns the total. A hidden cell is therefore total minus the visible cells.

Seen live on 4 Oct 2026, in `org_financial_indicators('Sedimosa')`, DTI block: `reported_count` 10; bands 6, *suppressed*, 0, 3. The suppressed band is 10 − 6 − 0 − 3 = **1**. With a department or site filter (`hr_scoped_unit_ids()`), the cohort shrinks and the person behind a "1" becomes guessable.

The retirement and stress blocks of the same function have the same shape. Other HR-reachable functions may too.

## Batch 0: read-only discovery (no changes)
Report, with function names and line references:
1. Every function an HR/employer user can reach, directly or through a delegator (`employer_org()`, `hr_unit_in_scope()`, `hr_scoped_unit_ids()`, the `p_client_safe := true` paths), that returns a suppressed cell **alongside** a total, a base, a percentage of a known base, or sibling cells that sum to a known figure. Starting list from a catalogue scan on 4 Oct:
   - `org_financial_indicators`: DTI, retirement and stress blocks (confirmed)
   - `org_overview`
   - `admin_org_indicators` in client-safe mode (count + base per indicator)
   - `org_report_data` / `_org_report_period_data` and the company and department breakdowns
   - `org_stress_summary`
   - `publish_org_report`: what is snapshotted to HR
   - the helpers `_kw_cell`, `_suppress_count`, `_suppress_rate`
2. For each one: can a hidden cell be derived (a) from one payload by subtraction, (b) across two payloads with different filters (whole org vs one site; this period vs last), or (c) from a rate plus its base?
3. What `employer.html` actually displays: totals, medians, percentages. A median over a small cohort is also a disclosure.
4. Published reports already handed to HR: are any affected? Count only.

**Report format:** a plain-language summary, then a table of function, leak type (a/b/c), example (counts only, no names) and fix options.

**GO/NO-GO gate.** Stop. Proposed fixes for Tshenolo to choose from:
- **Complementary suppression:** when exactly one cell in a group is suppressed, also suppress the next-smallest cell, so no single hidden cell can be derived. Keep the total.
- **Withhold the total:** drop `reported_count` / `base` whenever any cell is suppressed; show "fewer than 5" or a rounded total instead.
- **Rounding:** round every count to the nearest 5 for HR (with the floor kept).
- **Merge small bands:** collapse a suppressed band into its neighbour ("Strained or overindebted").

Recommend one, with the trade-off for HR usefulness, and cover cross-filter differencing (b). Complementary suppression alone does not stop it.

## Batch 1 (after GO): fix
- One shared helper (revoked from `public, anon, authenticated`, per `CLAUDE.md`) applied to every function found in Batch 0.
- Admin internal views (`p_client_safe = false`) unchanged: the floors are for the employer, not for us.
- Psychosocial stays floored for everyone.

**Rollback:** restore the captured bodies from `kw_fn_backup` (new tag).

**Checklist:**
- [ ] The Sedimosa case returns no derivable cell.
- [ ] A crafted cohort of 6 with one cell of 1 cannot be recovered from the total, the sibling cells, a site filter, or the previous period.
- [ ] The admin internal view still shows true counts.
- [ ] The security sweep returns only the ten expected rows.
- [ ] `employer.html` renders with no blank or NaN cells.

## Close-out
BUILD-NOTES entry; vault decision (the option chosen and the ones rejected); note whether any already-published report needs re-issuing.
