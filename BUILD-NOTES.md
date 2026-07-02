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
