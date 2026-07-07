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

- **Financial Stress added as a third indicator** (post-hoc scope clarification
  — the original batch spec only named DTI and retirement). Sourced from
  `stress_logs.level` (1-10 scale, latest log per member), reusing the same
  `>=7 = high stress` threshold already used member-side in index.html's
  dashboard. Bands: Low (1-3), Moderate (4-6), High (7-10). Same
  reported_count/median/cell-suppression shape as `dti`.

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

---

# Email Template Standardisation

Work against `kw-prompt-email-templates.md`'s batch plan. Two things diverged
from the prompt's assumptions during Batch 0 discovery — recorded here along
with the manual follow-ups every batch produced.

## Batch 0 — discovery findings

- **`kw-email-design-preview.html` does not exist** anywhere in this repo or
  its git history. The prompt's Batch 1 instructs the shared module to match
  it "faithfully." Absent the file, `supabase/functions/_shared/kw-email.ts`
  was built directly from the HTML/CSS skeleton and values embedded in the
  prompt text itself (colours, spacing, structure). If a real design-preview
  file exists elsewhere, diff it against the module and adjust.

- **FormSubmit had a second, live, unstyled send path** beyond the one the
  prompt already knew about (the booking Edge Function had already replaced
  FormSubmit for the initial "booking received" email — confirmed via git
  history: *"Replace FormSubmit with Resend via Supabase Edge Function for
  booking emails"*). `admin.html`'s `updateBookingStatus()` still posted
  directly to `https://formsubmit.co/wellness@keywellness.co.bw` with an
  `_autoresponse` field whenever HR confirmed a booking — a third,
  completely unstyled template source. **Retired in Batch 2**: this send now
  goes through `send-booking-email` (Edge Function) with `type: "confirmed"`,
  using the shared template, same trigger condition (`status === 'confirmed'`),
  same best-effort/non-blocking semantics, but now logs failures to console
  instead of failing silently. The dead, never-called `fsSubmit()` helper in
  `index.html` (a leftover from before the Resend migration — real bookings
  already went through the Edge Function, not this helper) was deleted in the
  same pass. FormSubmit is now fully retired from the codebase; only a
  historical code comment and the stale `CLAUDE.md` "Bookings: FormSubmit.co"
  line reference it.

- **No PNG logo asset exists.** Only `assets/img/kw-icon.svg` and
  `assets/img/kw-logo-horizontal.svg` are in the repo (confirmed on `dev`;
  `assets/img/` doesn't exist on `main` at all yet). `KW_LOGO_URL` in
  `kw-email.ts` points to `https://keywellness.co.bw/assets/img/kw-logo-horizontal.png`,
  which **does not resolve** until (a) a PNG export is added at that path and
  (b) `dev` is merged to `main`. Until then every email's logo will show as a
  broken image. See "Manual follow-ups" below.

- **No physical address or Help/Privacy pages exist yet.** The member footer
  needs a mailing address and Help/Privacy links per the prompt's spec. No
  address was found anywhere in the repo, and there is no in-app Help or
  Privacy page (only a Privacy section within the signup flow). The footer
  currently reads "Key Wellness · Botswana" and links Help to
  `mailto:wellness@keywellness.co.bw` and Privacy to a placeholder
  `https://keywellness.co.bw/privacy` URL that doesn't exist yet. Fix once a
  real address and pages exist — single edit in `renderFooter()` in
  `kw-email.ts`.

- **OTP/link expiry could not be discovered from code** (no
  `supabase/config.toml` in this repo — auth settings are dashboard-only).
  The Batch 4 auth templates use generic wording ("This link expires soon
  for your security") rather than a specific hour count, per the prompt's
  instruction not to assume a number. Confirm the actual expiry in
  Dashboard → Authentication → Email/OTP settings and tighten the copy if a
  specific figure is wanted.

## Batch 1 — shared module

`supabase/functions/_shared/kw-email.ts` — new file, additive, delete to
revert. Verified: zero `svg`/`base64` hits, `#E8C018` used only for
`background`/`border-left` (never `color:`), both member and internal
variants render correctly (manually paste-tested via a Node-transpiled copy
of the render logic, screenshotted in-browser since Deno isn't installed in
this environment).

## Batch 2 — booking Edge Function

`supabase/functions/send-booking-email/index.ts` rewired to use the shared
module; `admin.html`'s FormSubmit call replaced with an Edge Function call
(see Batch 0 above). Success/failure semantics unchanged for the original
"new booking" flow (client send still gates, team notification still
best-effort but still surfaces as a 502 if it fails, matching the original
code's behaviour exactly).

**⚠️ Not deployed. Not tested against real Resend/Gmail.** This function
serves production (shared Supabase project) the moment it's deployed —
deploying and sending real test emails from an agent session isn't something
I'll do without you present. Manual steps before this ships:

1. `supabase functions deploy send-booking-email` (and confirm `_shared/` is
   included — Supabase bundles relative imports automatically, but verify in
   the deploy output).
2. Make one real test booking on the dev site. Confirm:
   - Client confirmation email arrives, renders correctly in Gmail web and
     one mobile mail client, Reply-To lands at `wellness@keywellness.co.bw`.
   - Team notification arrives at `wellness@keywellness.co.bw`, Reply-To is
     the client's address.
3. In the admin dashboard, confirm a test booking and verify the
   "booking confirmed" email arrives styled correctly with the shared
   template (this is the newly migrated FormSubmit replacement — hasn't been
   exercised against real Resend at all yet).
4. Force a team-notification failure (e.g. temporarily break `TEAM`'s
   address) and confirm: the error is logged to the function's console
   output, and the client email still sends successfully.
5. Rollback: Supabase retains function deploy history; redeploy the previous
   version from the dashboard, or `git revert` this commit on `dev`.

## Batch 3 — certificate renderer

`certificateReadyEmail()` added to `kw-email.ts`. No send path created —
confirmed via repo-wide grep for `resend.emails.send`/`api.resend.com`
(only hit is the existing Batch 2 `sendEmail()` call). Rendered with sample
data and grepped for `improvement`/score/topic-name leakage — zero hits.

## Batch 4 — Supabase Auth templates (⚠️ manual dashboard paste required)

Five files generated in `email-templates/auth/`: `confirm-signup.html`,
`invite-user.html`, `magic-link.html`, `reset-password.html`,
`change-email.html`, plus `SUBJECTS.md`. Each contains exactly 3 references
to `{{ .ConfirmationURL }}` (button href, alt-link text, alt-link href).
Yellow-as-text grep: zero hits.

**Manual procedure (this is live in production the instant it's saved —
do it in a low-traffic window):**

1. Before touching anything: Dashboard → Authentication → Email Templates →
   for each of the 5 template types, copy the **current** body HTML into
   `email-templates/auth/_previous/<template-name>.html` in this repo. That
   folder exists and is currently empty — it's the rollback copy.
2. For each of the 5 types, paste the subject from `SUBJECTS.md` and the
   body from the matching file in `email-templates/auth/`.
3. Save.
4. Trigger one of each from the dev site: a test signup (Confirm signup), a
   password reset (Reset password), and an invite if there's an invite flow
   wired up (Invite user). Verify rendering and that the links work
   end-to-end. Magic link and Change email can be spot-checked the same way
   if those flows are reachable.
5. Rollback: paste the corresponding file back from `_previous/`.

Also confirm before pasting: which of the 6 possible template types
(Confirm signup, Invite user, Magic link, Reset password, Change email,
Reauthentication) are actually **enabled** in this project — the prompt
listed Reauthentication as a possible 6th type but gave no spec for it, so
no file was generated for it. If it's enabled and in use, it needs its own
template; flag back if so.

## Batch 5 — logo, retirement, sweep

- **Logo**: no PNG export exists (see Batch 0). Requesting a **no-slogan**
  horizontal lockup from the brand manual is worth doing at the same time —
  the current SVG (`assets/img/kw-logo-horizontal.svg`) includes the
  "Wellness Is Key, Be About It." slogan lockup used on the login screen,
  which will be illegible at 210px in an email. Once a PNG (ideally
  slogan-less) exists at a stable path, update the one `KW_LOGO_URL`
  constant in `kw-email.ts` — nothing else needs to change.
- **FormSubmit**: retired, not just reported (see Batch 0/2 above).
- **Sweep**: repo-wide grep for ad-hoc email HTML strings outside the shared
  module and the auth template files found none remaining.
- **Post-merge check (do after `dev` → `main`)**: confirm
  `https://keywellness.co.bw/assets/img/kw-logo-horizontal.png` (or whatever
  path the eventual PNG lands at) returns 200, then send one test of each
  email family from production.

## Manual follow-up — NOT attempted by Claude

- **DPA lawyer sign-off** on the footer trust line wording ("Your individual
  data is never shared with your employer.") before employer-cohort
  scale-up, per the prompt's own requirement.
- **Resend dashboard**: confirm domain verification covers
  `noreply@keywellness.co.bw`, and that both scoped API keys are unchanged.
  Not checkable from code.
- **Which Supabase Auth template types are enabled**, and the actual
  OTP/link expiry value — dashboard-only, see Batch 0/4 above.
- **PNG logo export** (ideally slogan-less) — see Batch 5.
- **Physical address and Help/Privacy page URLs** for the member email
  footer — see Batch 0.
- **`admin.html` env/deploy note**: this batch didn't touch any Supabase
  schema or RPCs, but the booking Edge Function change (Batch 2) is
  undeployed — see the deploy checklist there before it's live.
- **`CLAUDE.md`'s tech-stack table still lists "Bookings: FormSubmit.co"** —
  stale even before this batch (bookings have gone through the Edge Function
  since the earlier "Replace FormSubmit..." commit); worth a one-line fix
  next time that file is touched. Not changed here since it's the project's
  instruction file, not build output.
