-- ============================================================
-- Key Wellness — Rewards Categories in the Points Catalog (Batch 1
-- of the rewards-reshape build: Utilisation / Learning / Progress
-- categories, per-category thresholds, HR fulfilment, headcount)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (ALTER ... ADD COLUMN IF NOT EXISTS,
-- CREATE OR REPLACE VIEW).
--
-- Purely additive: one new column, three new view columns. Nothing
-- existing is altered or dropped. Rollback statements are in
-- migrations/rollback-notes.md — SAVE THE CURRENT my_points DEFINITION
-- (below, copied from supabase_points_ledger.sql §5) BEFORE running
-- this file, in case a rollback is ever needed.
--
-- Why a category column, not a new table: category is a fixed
-- attribute of each event TYPE (not of each event instance), so it
-- belongs on points_catalog exactly like `points` and `active` do.
-- ============================================================


-- ── 1. Category column on points_catalog ───────────────────────
-- 'private' exists so the improvement/legacy events can be excluded from
-- every HR-facing category aggregate while still counting toward a
-- member's own overall total (my_points.season_points, unchanged below).

alter table public.points_catalog
  add column if not exists category text not null default 'utilisation'
    check (category in ('utilisation','learning','progress','private'));

update public.points_catalog set category = 'utilisation'
  where event_type in ('onboarding_complete','monthly_checkin','tool_first_use','session_booked');
update public.points_catalog set category = 'learning'
  where event_type in ('article_read','video_watched','quiz_passed');
update public.points_catalog set category = 'progress'
  where event_type in ('assessment_complete','checkin_streak_3');
update public.points_catalog set category = 'private'
  where event_type in ('improvement','legacy_migration');


-- ── 2. Extend my_points with per-category season sums ──────────
-- Appends three trailing columns to the existing view — total_points and
-- season_points keep their exact names/positions, so index.html's existing
-- `sb.from('my_points').select('*')` (loadAllData()) keeps working unchanged.
-- security_invoker preserved: RLS on points_events/points_catalog is still
-- evaluated as the calling user, not the view owner.
--
-- season_points (unchanged) intentionally still includes 'private' category
-- points (improvement) — that is the member's own overall total, their own
-- data. The three new season_* columns are per-category and therefore
-- EXCLUDE 'private' by construction (the category filter never matches it).

create or replace view public.my_points
with (security_invoker = true) as
  select pe.user_id,
         coalesce(sum(pe.points), 0) as total_points,
         coalesce(sum(pe.points) filter (
           where pe.season = to_char(now(), 'YYYY"-Q"Q')
         ), 0) as season_points,
         coalesce(sum(pe.points) filter (
           where pe.season = to_char(now(), 'YYYY"-Q"Q') and pc.category = 'utilisation'
         ), 0) as season_utilisation,
         coalesce(sum(pe.points) filter (
           where pe.season = to_char(now(), 'YYYY"-Q"Q') and pc.category = 'learning'
         ), 0) as season_learning,
         coalesce(sum(pe.points) filter (
           where pe.season = to_char(now(), 'YYYY"-Q"Q') and pc.category = 'progress'
         ), 0) as season_progress
  from public.points_events pe
  join public.points_catalog pc on pc.event_type = pe.event_type
  group by pe.user_id;

grant select on public.my_points to authenticated;


-- ── VERIFICATION QUERIES ─────────────────────────────────────────

-- 1. Every points_catalog row has a category; improvement/legacy_migration
--    are 'private':
--      select event_type, category from points_catalog order by category;
--    Expect: no nulls, and improvement/legacy_migration both show 'private'.

-- 2. Per-category sums for a seeded test user with events in all categories
--    (run as that user via the browser console, NOT the SQL Editor, so RLS
--    is actually exercised — or as postgres with a specific user_id filter
--    for a structural check only):
--      select * from my_points where user_id = '<test-user-id>';
--    Expect: season_utilisation + season_learning + season_progress +
--    (this-season 'private' points) = season_points for that user.

-- 3. Existing consumer unaffected — in the browser console as any logged-in
--    member:
--      await sb.from('my_points').select('*').maybeSingle();
--    Expect: total_points/season_points still present and correct, plus the
--    three new columns.
-- ─────────────────────────────────────────────────────────────
