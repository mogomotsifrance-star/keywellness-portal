# Build notes — Points/Rewards + Leaderboard + HR Financial Indicators

Schema deviations from the original build spec, and follow-ups, discovered while
implementing. See `.claude` plan history for the full reasoning; this file is the
durable record.

## Batch 1 — Points ledger

- **Badge id scheme differs from the spec.** `kw-badges.js` uses tiered ids
  (`budget_master_t1/t2/t3`, `ef_t1/t2/t3`, etc.), not the flat legacy ids the
  spec assumed (`budget_master`, `ef_halfway`). Public/private classification
  (Batch 2) is applied per-tier using the rule: badges revealing a specific
  financial-state threshold are private; badges reflecting pure engagement or
  consistency are public. Final mapping (each entry now carries
  `public: true/false` in `kw-badges.js`):
  - **Public**: `first_login`, `first_assessment`, `booked_session`, `ef_t1`,
    `checkin_streak_t1..t3`, `learning_t1..t3`, `budget_year_t1..t12`
  - **Private**: `high_scorer`, `ef_t2`, `ef_t3`, `budget_master_t1..t3`,
    `savings_champ_t1..t3`, `debt_destroyer_t1..t3`, `retirement_planner_t1..t3`,
    `insurance_hero_t1..t3`, `retire_ready_t1..t4`, `savings_rate_t1..t3`,
    `savings_streak_t1..t3`, `investor_t1..t4`

  **Duplication note**: `org_leaderboard()`'s `badge_count` (Batch 4,
  `supabase_leaderboard.sql`) hardcodes the same public-id array in SQL,
  since a Postgres function can't import a JS array. If a badge's public/private
  status ever changes in `kw-badges.js`, `v_public_badges` in
  `supabase_leaderboard.sql` must be updated to match, or the leaderboard's
  badge count will silently drift from what the Badges page shows.

- **Badge card "+N pts" labels are now cosmetic, not literal.** Since points
  are awarded exclusively through the catalog-driven ledger (Batch 1) at a
  small set of evidence-checked events, and badge tiers are no longer paid
  out via `award()`/`awardProgress()`, the `pts` figures shown on badge cards
  in `renderBadgeCards()` (`index.html`) no longer add up to the member's
  actual point total. This is an intentional consequence of closing the
  self-reported-assessment gaming hole, not a bug — but the UI copy wasn't
  updated to reflect it (out of scope for this build). Worth a follow-up pass
  if members notice the mismatch.

- **`article_read`, `video_watched`, `tool_first_use` have no server-side
  evidence check.** There is no backing table row proving an article was read
  or a video watched. Per the spec's own guidance for this case, these events
  are accepted without evidence, bounded only by the ledger's
  `unique(user_id, event_type, ref_id)` constraint and the point caps in
  `points_catalog`. Accepted gap — a determined user could call
  `award_points('article_read', '<new-fake-title>')` repeatedly with distinct
  ref_ids to farm 15 pts each time. Low severity (small point value, no
  financial-state leakage) but worth revisiting if abuse is observed.

- **`session_booked` evidence uses the real booking id**, not a "created in the
  last hour" time window, because the spec's time-window fallback would let a
  user replay the RPC repeatedly within that hour for free points. Batch 2 adds
  `.select('id').single()` to the `bookings` insert in `index.html` so the
  frontend has a real id to pass as `ref_id`.

## Batch 6 (planned) — Financial indicators

- **DTI is not stored in `assessments`.** The raw ratio is computed in
  `wellness_assessment.html` and only ever written to `localStorage`. It IS
  persisted to `profiles.monthly_debt` / `profiles.monthly_income` on every
  assessment save (and `monthly_income`/`monthly_expenses` on every budget
  save), so `org_financial_indicators()` computes
  `DTI% = monthly_debt / nullif(monthly_income, 0) * 100` from `profiles`
  instead of from `assessments`. This means DTI freshness is tied to whenever
  the member last completed an assessment or saved their budget, not to a
  dedicated DTI-calculator save (the DTI calculator tool itself still only
  writes to `tool_data`/localStorage).

- **Pension contribution % is not derivable.** `monthlyPension` (entered in the
  retirement section of the assessment) is a local JS variable in
  `wellness_assessment.html` and is never written to Supabase. Per the spec's
  own fallback instruction, this indicator is **omitted** from
  `org_financial_indicators()` rather than invented.

## Manual follow-up — NOT attempted by Claude

- **Privacy notice / consent copy update required.** Once opt-in leaderboards
  and the HR Rewards tab (Batch 7) are live, the employee-facing privacy
  notice and consent flow need to disclose: (a) leaderboard participation is
  optional and what it exposes, and (b) HR receives name + points for
  opted-in members via the Rewards tab. This is a legal/compliance copy change
  under the Botswana Data Protection Act (Act 18 of 2024) and should be
  reviewed by Tshenolo before shipping to production, not drafted by an
  agent.

---

# Rewards reshape — Categories, Thresholds & HR Fulfilment

Product reshape of the points/leaderboard/rewards system above: three
HR-visible categories (Utilisation/Learning/Progress) replace the flat
season total, the member leaderboard is removed in favour of a private
Progress card, HR gets a fulfilment (Reward button) flow, thresholds respect
member tenure, and employers can self-report headcount. SQL files:
`supabase_rewards_categories.sql`, `supabase_reward_thresholds.sql`,
`supabase_drop_leaderboard.sql`, `supabase_rewards_reshape.sql`,
`supabase_reward_fulfilment.sql`, `supabase_org_headcount.sql`. None of
these have been run against the live Supabase project yet — see "Manual
follow-up" at the end of this section.

## Schema deviations from the reshape spec

- **`profiles` has no `created_at` column.** Confirmed absent (only
  `organizations`/`employers` have it; `supabase_seed_test_org.sql` always
  joins `auth.users` for account-creation dates). The tenure rule ("first
  season" = calendar quarter containing account creation) is therefore
  computed from `auth.users.created_at`, joined on `profiles.id =
  auth.users.id`, everywhere it's needed: inline in `org_rewards()` and
  `record_reward_fulfilment()` (`supabase_rewards_reshape.sql` /
  `supabase_reward_fulfilment.sql`), and client-side in `index.html`'s
  `isFirstSeasonMember()` using `currentUser.created_at` (Supabase Auth
  already exposes this on a user's own session — no extra RPC needed for a
  member's own tenure). All three use the identical formula
  `to_char(created_at, 'YYYY"-Q"Q') = to_char(now(), 'YYYY"-Q"Q')` — if this
  ever needs to change, update all three call sites together.

- **`profiles` has no `email` column either** (confirmed the same way).
  `org_rewards()` and `org_reward_history()` join `auth.users` for email —
  the same pattern already established by `handle_new_user()` and
  `supabase_employer_email.sql`'s backfill trigger.

- **`org_rewards()`'s return shape needed a `user_id` column not listed in
  the spec.** The spec's column list (first_name, last_name, email, ...) has
  no stable identifier the frontend can pass to
  `record_reward_fulfilment(p_user_id, ...)` — email alone isn't a usable
  uuid argument. Added `user_id uuid` as the first return column; it
  discloses nothing HR doesn't already see via name+email for the same
  (opted-in-only) row.

- **Dependency-ordering across batches.** `org_rewards()`/
  `org_rewards_summary()` (Batch 4) need to read `reward_fulfilments` (for
  `rewarded_categories`) and `org_headcount_reports` (for
  `reported_headcount`), but those tables' write-RPCs ship in Batches 5 and
  7. Both tables are created (`IF NOT EXISTS`, RLS on, no policies) inside
  `supabase_rewards_reshape.sql` itself; the Batch 5/7 files re-declare them
  `IF NOT EXISTS` (idempotent no-op) alongside the RPCs that are actually
  allowed to touch them. Apply the SQL files in numeric/batch order and
  this resolves itself — there is no window where a function references a
  genuinely missing table.

- **`leaderboard_opt_in` column keeps its original name.** It now means
  "share my points with HR for rewards", not "show me on the leaderboard".
  Renaming it would be a non-additive migration (drop+recreate or a
  multi-step rename) for no functional gain, so the name is a permanent
  naming quirk — grep for `leaderboard_opt_in` before assuming it's
  leaderboard-related in any future change.

- **`display_alias` column is now fully dormant.** The member leaderboard
  (its only renderer) is removed; the alias input was removed from the
  Badges page consent card per the spec's instruction. The column itself is
  left in place (additive discipline) — nothing writes or reads it anymore.
  Safe to drop in a future cleanup if it's confirmed nothing else depends on
  it, but not attempted here.

- **`org_rewards()`/`record_reward_fulfilment()` exclude `season='legacy'`
  from every season sum**, per the spec's blanket instruction — even though
  in practice `pe.season = v_season` already can't match `'legacy'` unless a
  caller explicitly passes `p_season='legacy'`. The extra `and pe.season <>
  'legacy'` guard exists specifically to close that edge case off.

- **`record_reward_fulfilment()`/`org_reward_history()` are strictly
  employer-only** (resolved via `employer_org()`), with no `is_admin()` +
  explicit-org-param override, unlike `org_overview()`/`org_rewards()`. The
  spec's signatures for these two RPCs have no org parameter, so there's no
  way to disambiguate which org an admin means — kept deliberately narrow
  rather than inventing a parameter the spec didn't ask for.

## Post-ship fix — ambiguous column references in PL/pgSQL

After both branches went live, the Rewards tab failed with `column
reference "user_id" is ambiguous`. Root cause: `org_rewards()` and
`record_reward_fulfilment()` both declare `RETURNS TABLE (user_id uuid,
..., org_id uuid, season text, category text, ...)`, and PL/pgSQL exposes
each OUT column as an implicit variable throughout the function body. Any
*unqualified* reference to a column with the same name inside the query
(e.g. `where user_id = p_user_id`) is then ambiguous between the table
column and that implicit variable — Postgres won't guess.

Fixed in three places (all now qualify every column with its table alias):
`org_rewards()`'s `fulfilled` CTE (`user_id`), `record_reward_fulfilment()`'s
idempotent re-fetch (`org_id`/`user_id`/`season`/`category`), and its
`reward_thresholds` lookup (`category`). Re-run the corrected
`supabase_rewards_reshape.sql` and `supabase_reward_fulfilment.sql` — both
are `CREATE OR REPLACE FUNCTION` with unchanged return signatures, so no
`DROP FUNCTION` is needed this time.

**General lesson for future RPCs in this codebase**: whenever a plpgsql
function's `RETURNS TABLE (...)` column list shares a name with a real
table column it queries, qualify every reference to that name with a table
alias, even in single-table subqueries — don't rely on "only one table in
this FROM clause" as proof of non-ambiguity.

**Follow-up — the qualification fix above was incomplete for
`record_reward_fulfilment()`.** After re-deploying, clicking Reward still
raised `42702 column reference "org_id" is ambiguous`, confirmed via
`pg_get_functiondef` to be hitting the exact function text described above
(ruled out: a stale SQL Editor tab, a duplicate function overload — `select
proname, pg_get_function_identity_arguments(oid) from pg_proc where
proname = 'record_reward_fulfilment'` returned exactly one row — and
`employer_org()` itself, which is `language sql` with no OUT parameters and
therefore structurally can't have this bug). Root-caused to the `insert
into reward_fulfilments (org_id, user_id, season, category, ...) ... on
conflict (org_id, user_id, season, category) ...` statement still sharing
those bare column names with the function's own OUT parameters, even
though every *other* reference in the body was already alias-qualified.

Fixed by removing the collision at the source instead of chasing individual
clauses: `record_reward_fulfilment()` now returns `(recorded boolean,
fulfilment reward_fulfilments)` — the whole row as one composite column —
instead of naming `org_id`/`user_id`/`season`/`category` as separate OUT
parameters. This is safe because `employer.html`'s `confirmReward()` only
checks `error`, never destructures the returned row by field name. Revised
lesson: for a table-returning function whose OUT columns are still
partially or wholly a copy of the target table's own columns (as opposed to
a differently-named projection like `org_rewards()`'s `utilisation_points`
etc.), prefer returning the row as a single composite column over naming
each field — it removes the entire bug class rather than requiring every
reference, in every clause, to be perfectly qualified forever.

## Privacy-notice follow-ups for Tshenolo (from the FINAL CHECKLIST)

- **Revised consent copy is live** in `index.html`'s Badges page (Rewards
  Opt-In card) — no longer mentions a leaderboard; states HR sees points and
  qualification status only, never scores/answers/financial information.
  Worth a legal read alongside the existing Botswana Data Protection Act
  follow-up noted above, since the data actually shared with HR has grown
  (name, email, per-category points, qualification, fulfilment history —
  see below) even though the leaderboard exposure has shrunk to zero.

- **Fulfilment records persist after opt-out.** If a member opts out after
  HR has already recorded a reward for them, `reward_fulfilments` rows are
  NOT deleted or anonymised — `org_reward_history()` will still show past
  fulfilments for that person. This is intentional (a record of what was
  already given, not a live roster), but it means "opt out" does not mean
  "disappear from every HR-visible surface retroactively." Worth a line in
  the consent copy or privacy notice if this behaviour needs to be
  disclosed up front.

- **Email disclosure to HR is new.** The prior `org_rewards()` never
  returned email; the reshaped version does (needed for the Reward
  button/CSV export to identify people unambiguously, and because
  `org_reward_history()` needs it too). This is a small but real expansion
  of what HR can see about an opted-in member and should be reflected in
  the consent copy review above.

- **Ops obligation — returning-Learning threshold (300 required-content
  based).** `reward_thresholds.learning.returning_points = 150` assumes
  annual quiz revalidation and/or quarterly new content. Key Wellness must
  review this value each season; if no new point-bearing learning content
  ships, returning members cannot realistically qualify for Learning. (This
  note also lives inline as a SQL comment in `supabase_reward_thresholds.sql`.)

## Manual follow-up — NOT attempted by Claude

- **None of this build's SQL has been run against the live Supabase
  project.** Per this repo's established convention (every `supabase_*.sql`
  file says "run in the SQL Editor"), and because this is a shared prod/dev
  database, Tshenolo needs to run the six new/changed SQL files in the
  Supabase SQL Editor, in this order: `supabase_rewards_categories.sql` →
  `supabase_reward_thresholds.sql` → `supabase_drop_leaderboard.sql` →
  `supabase_rewards_reshape.sql` → `supabase_reward_fulfilment.sql` →
  `supabase_org_headcount.sql`. Each file's own verification-queries block
  should be run afterward, in the browser console against
  `window._toolSb`/`window._toolSb.rpc(...)` (not the SQL Editor, which
  bypasses RLS and the RPCs' own auth checks).

- **Full end-to-end member/HR journey testing needs real data.** The
  frontend changes (Progress card, Rewards tab rebuild, headcount UI) were
  verified for correct rendering logic and mobile layout (390×844) using
  mocked data in a Node/browser harness, since the live DB doesn't yet have
  the new schema. A real walkthrough — a member earning points across all
  three categories, opting in, HR rewarding them, opting out, checking the
  CSV — should happen once the SQL is live.
