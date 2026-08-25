# Batch 0 — Discovery: Org Webinars, Quarterly Reward Thresholds & HR Rewards Explainer

Read-only batch (2026-07-14). Investigated via repo SQL/JS files plus live PostgREST
probes with the anon key (GET-only — `PGRST205` = table absent, `42703` = column
absent; both unambiguous and RLS-independent). No repo file was written until this
report itself (the gate output); no SQL was executed; no Supabase write of any kind.

---

## 1. Schema reality check

### Orgs / member linkage
- Table is **`organizations`** (not `orgs`): `id uuid pk, name, invite_code unique,
  is_active, created_at` ([supabase_multitenancy.sql:18](supabase_multitenancy.sql:18)).
- Member ↔ org: **`profiles.org_id`** (nullable FK). HR ↔ org: **`employers(user_id, org_id)`**.
- Live-confirmed: `organizations.program_name` does **not** exist (42703) — branding
  columns are new, as planned.

### content_items — EXISTS, but as the LMS lessons table
Created by the Learning Pathways build ([supabase_lms_schema.sql:48](supabase_lms_schema.sql:48)):
`id uuid pk, title, pathway_id smallint → pathways, section_label, sort_order,
video_path, poster_path, duration_seconds, created_at, unique(pathway_id, sort_order)`.
RLS: `select to authenticated using (true)`; no member writes.
Live-confirmed: **no `org_id`, no `kind`, no `published` column** (42703 on all).
→ Per this brief's own rule ("do not create a duplicate table where a suitable one
exists; extend it additively instead"), Batch 1 **extends** it:
`kind text not null default 'lesson' check (kind in ('lesson','webinar'))`,
`org_id uuid null → organizations`, `description text`,
`published boolean not null default true` (default **true**, not the brief's false, so
the 26 live lesson rows stay visible — webinar inserts set it explicitly),
and reuses the existing **`video_path`** column instead of adding a duplicate
`storage_path`. Deviations recorded in the final report.

### bookings — server-side, attendance infra ALREADY EXISTS
Live table with `status` (+ `updated_at`, `requested_time`, `client_seen_confirmation`
per [supabase_bookings_missing_columns.sql](supabase_bookings_missing_columns.sql)) and
— live-confirmed — **`attended` (boolean), `attendance_confirmed_by`,
`attendance_confirmed_at`, `session_mode`, `client_type`**, written by admin.html's
`updateAttendance()` ([admin.html:923](admin.html:923)). Booking inserts happen server-side
from index.html ([index.html:4739](index.html:4739)).
→ "Attended" for the Sessions criterion = `attended = true AND attendance_confirmed_at`
in quarter — **no `status='attended'` value is added**; the existing boolean pattern is
the server truth (brief's "adapt names to Batch 0 findings" clause applies).

### check-ins — server-side already
`checkins(user_id, vals jsonb, score, notes, created_at)`, RLS own-rows
([supabase_multitenancy.sql:97](supabase_multitenancy.sql:97)); written at
[index.html:4383](index.html:4383). No new table needed.

### budgets — server-side blob, not per-month rows
`budget_planner.html` upserts the full budget state to
`tool_data(user_id, tool='budget_planner', data jsonb)` — shape
`{budgets: {"YYYY-MM": {...}}, currentKey}` ([budget_planner.html:524](budget_planner.html:524)),
month key `YYYY-MM` ([budget_planner.html:492](budget_planner.html:492)).
→ **`monthly_budgets` is NOT created.** The quarterly source of truth becomes
evidence-gated `budget_saved` ledger events (ref = `YYYY-MM`, gated on the month key
existing in the member's `tool_data` blob, `created_at ≤ quarter end` enforced by the
ledger timestamp). This gives per-month dedupe, a server timestamp, AND event-time
points from one mechanism. Deviation recorded.

### tool usage events — none per-quarter; table needed
Tool pages upsert latest state to `tool_data` (one row per tool, only latest
`updated_at`) — no per-quarter usage history. `tool_first_use` points fire on page
OPEN (not meaningful use) and once per lifetime. → **`tool_usage_events` is created**
per the brief.

### video watch / progress — completion only; tables needed
`content_progress(user_id, content_id, completed_at, unique(user_id, content_id))` —
written only by `complete_video()` (SECURITY DEFINER) on the player's `ended` event.
No playback-position tracking. → **`video_watch_progress` + `video_watch_credits`
are created** per the brief.

### points_events / award_points()
- `award_points(p_event_type text, p_ref_id text) returns json` — SECURITY DEFINER,
  points always read from `points_catalog` (never client-supplied), idempotent via
  `unique(user_id, event_type, ref_id)`, season stamped `to_char(now(),'YYYY"-Q"Q')`.
  Current live definition is the hardened one in
  [supabase_points_integrity_fix.sql](supabase_points_integrity_fix.sql) (evidence
  gates for video/article + per-season caps).
- Category lives on **`points_catalog.category`**
  (`utilisation|learning|progress|private`) per
  [supabase_rewards_categories.sql](supabase_rewards_categories.sql).
- Current catalog values that this brief supersedes: `session_booked 100` (→10),
  `monthly_checkin 75` (→ superseded by fortnight-window `checkin_logged` 15),
  `tool_first_use 25` (→ superseded by meaningful-use `ef_tool_used` 25 /
  `tool_used` 10). `video_watched 25` matches the brief and is kept.

### Where thresholds live / the 150-pt Returning Learning threshold
`reward_thresholds(category pk, first_season_points, returning_points)` —
`('learning', 500, **150**)` ([supabase_reward_thresholds.sql:35](supabase_reward_thresholds.sql:35)).
Consumed by:
1. `org_rewards()` qualification flags ([supabase_rewards_reshape.sql:156](supabase_rewards_reshape.sql:156)) — HR-facing.
2. index.html member Rewards Progress card (`isFirstSeasonMember()` +
   `reward_thresholds` read, [index.html:4864](index.html:4864), [index.html:878](index.html:878)).
Both switch to the new qualification functions in Batches 4/5; the learning/utilisation
rows in `reward_thresholds` are deprecated in place (not dropped). Progress row and
Progress logic untouched.

## 2. Storage
- Buckets: **`Videos`** (capital V) — **public**, live-verified (anon fetch of a
  Foundation module returns 200 video/mp4). A stray empty lowercase `videos` bucket
  exists (known, harmless). **No `webinars` bucket** (public fetch 400).
- Bucket creation IS scriptable: `insert into storage.buckets` works via SQL (only
  DELETE is blocked by `protect_delete()`); included in the Batch 1 migration.

## 3. LMS video inventory
- Source of truth: `content_items` rows with `pathway_id` joined to
  `pathways.status = 'active'`. Currently Pathway 1 (Foundation, 16 lessons after the
  Psychology of Spending insert) + Pathway 2 (Financial Stability, 10 lessons) are
  active; Pathway 3 coming_soon; welcome video has `pathway_id null` (excluded).
- **Library size ≈ 26 and is computed live** in `learning_qualified()` as
  `count(*) from content_items ci join pathways p ... where p.status='active' and
  ci.kind='lesson' and ci.published` — never hardcoded. ⅓ threshold today: ceil(26 × 0.3333) = 9.

## 4. HR report surface + `improvement` baseline
- HR rewards UI: employer.html **Rewards tab** (`loadRewards`/`renderRewards`,
  [employer.html:383-760](employer.html:383)) calling `org_rewards`,
  `org_rewards_summary`, `record_reward_fulfilment`, `org_reward_history`.
- Other HR RPCs: `org_overview`, `org_report_data(_v3)`, `org_financial_indicators`,
  `org_stress_summary`. Conventions confirmed intact: cohort ≥ 5 gate
  (`insufficient_cohort`), `_suppress_count`/`_suppress_rate` (< 3 suppression).
- **Pre-change `improvement` grep baseline** (case-insensitive, all repo
  html/js/sql/ts):
  - [employer.html:1150](employer.html:1150) — pre-existing aggregate trend caption
    ("Wellbeing improvement is gradual…") — HR UI copy, no per-person data.
  - index.html:900, wellness_assessment.html:901/905/942 — member-facing only.
  - lifestyle_inflation_calculator.html:599 — member-facing copy.
  - SQL files: points_catalog seed rows, award_points internals, comments, and
    verification notes (points_ledger:26/111/153, points_integrity_fix:70/112,
    rewards_categories:22/37/48/77/80, rewards_reshape:57-59/127/267-272,
    lms_rpcs:314/316, org_stress_summary:169).
  - **No HR-facing RPC output contains the string or any per-member score/delta.**
  - Limitation: live RPC bodies can't be dumped with the anon key; baseline is the
    repo SQL (the project's apply-from-repo convention makes these the record of the
    live definitions).

## 5. Branding assets
- **Sedimosa logo NOT in the repo** (assets/img has only kw-* and pathway art).
  Expected path recorded for Tshenolo: `assets/img/sedimosa-logo.png` → BUILD-NOTES.
  The `organizations.program_logo_path` seed uses that path; header renders a
  text-only fallback until the file exists.
- No Debswana row can be confirmed via anon (organizations RLS blocks reads). The
  seed UPDATE targets `name ilike '%debswana%'` and is harmless (0 rows) if the org
  hasn't been created yet → manual confirmation step in BUILD-NOTES.

## 6. Quarter definition
Canonical and consistent everywhere: **calendar quarters** via
`to_char(now(), 'YYYY"-Q"Q')` server-side (award_points season, org_rewards,
tenure rule) and `quarterKey()` client-side. No conflicting definition found — no stop.
⚠️ Nuance: existing stamps use DB `now()` (UTC); the brief specifies Africa/Gaborone
(UTC+2) for the new window math. New functions use
`(now() at time zone 'Africa/Gaborone')` for quarter/window boundaries; the ±2h skew
vs legacy season stamps at quarter edges is noted in BUILD-NOTES.

---

## GO/NO-GO gate

| # | Item | Status | Resolution |
|---|---|---|---|
| 1a | orgs table + member link | ✅ | `organizations` + `profiles.org_id` — adapt names |
| 1b | content_items exists? | ✅ (exists, different shape) | Extend additively (kind/org_id/published/description; reuse video_path) — decision covered by brief's "extend, don't duplicate" rule |
| 1c | bookings server-side + status | ✅ | Exists incl. attendance columns; use `attended` boolean, no new status value |
| 1d | check-ins server table | ✅ | `checkins` exists |
| 1e | budget saves server-side | ✅ (blob, not rows) | `tool_data` blob + evidence-gated `budget_saved` ledger events; no new table |
| 1f | tool usage events | ❌ absent | Brief already decides: create `tool_usage_events` |
| 1g | video watch/progress | ❌ absent (completion only) | Brief already decides: create `video_watch_progress` + `video_watch_credits` |
| 1h | points_events / award_points | ✅ | Signature + category model confirmed; extend catalog |
| 1i | 150-pt Returning Learning threshold located | ✅ | `reward_thresholds.learning.returning_points` + `org_rewards()` + member card |
| 2 | Storage buckets | ✅ | `Videos` public (confirmed live); no `webinars` bucket; creation scriptable via SQL insert |
| 3 | LMS library enumeration | ✅ | `content_items` × active `pathways`; dynamic denominator ≈ 26 |
| 4 | HR surface + `improvement` baseline | ✅ | Baseline recorded above; zero HR-RPC hits |
| 5 | Sedimosa logo asset | ❌ missing | Brief anticipates: BUILD-NOTES manual item; text fallback shipped |
| 6 | Quarter definition | ✅ | Calendar quarters, consistent; Gaborone TZ nuance flagged, not conflicting |

Every ❌ is resolved by a decision already in the brief. **Verdict: GO.**

Note on apply mechanics: this environment has no SQL execution path to the live
project (CLI has no Docker/db-password; Management API token is in the OS credential
store and off-limits). Migrations follow the established repo convention — SQL files
authored + rollback recorded here, **applied by Tshenolo via the SQL Editor** —
listed as the first BUILD-NOTES manual step. Edge Function deploys via the
authenticated CLI ARE performed by this run.
