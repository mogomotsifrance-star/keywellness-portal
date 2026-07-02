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
  consistency are public. Full mapping lives in `kw-badges.js` itself once
  Batch 2 lands (`public: true/false` on each `BADGE_DEFS` entry) — this file
  will be updated with the final table when that batch is committed.

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
