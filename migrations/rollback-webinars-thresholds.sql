-- ============================================================
-- ROLLBACK — Org Webinars, Quarterly Reward Thresholds & HR Explainer run
-- (2026-07-14). Written BEFORE the forward migrations, per project rule.
--
-- Forward files this reverses, in apply order:
--   1. supabase_webinars_thresholds_schema.sql   (Batch 1)
--   2. supabase_webinar_learning_rpcs.sql        (Batch 4)
--   3. supabase_utilisation_rpcs.sql             (Batch 5)
--
-- Run sections BOTTOM-UP (Batch 5 → 4 → 1) if rolling back everything.
-- Every statement is safe against pre-existing objects: nothing here
-- touches anything that existed before this run.
-- ============================================================


-- ────────────────────────────────────────────────────────────
-- SECTION C — rollback for supabase_utilisation_rpcs.sql (Batch 5)
-- ────────────────────────────────────────────────────────────

drop function if exists public.utilisation_qualified(uuid, text);
drop function if exists public.my_rewards_qualification();
drop trigger if exists trg_award_session_attended on public.bookings;
drop function if exists public.award_session_attended();

-- Restore award_points() to the pre-run definition: re-run the full
-- CREATE OR REPLACE FUNCTION public.award_points(...) from
-- supabase_points_integrity_fix.sql (the live definition before this run —
-- kept verbatim in that file; do not retype it here to avoid drift).

-- Restore org_rewards() qualification flags to pure points thresholds:
-- re-run the full CREATE OR REPLACE FUNCTION public.org_rewards(...) from
-- supabase_rewards_reshape.sql §2 (the live definition before this run).


-- ────────────────────────────────────────────────────────────
-- SECTION B — rollback for supabase_webinar_learning_rpcs.sql (Batch 4)
-- ────────────────────────────────────────────────────────────

drop function if exists public.record_video_progress(uuid, int, int);
drop function if exists public.learning_qualified(uuid, text);

-- Restore complete_video() to the pre-run definition (which awards
-- 'video_watched' directly on first completion): re-run the full
-- CREATE OR REPLACE FUNCTION public.complete_video(...) from
-- supabase_lms_rpcs.sql §1.


-- ────────────────────────────────────────────────────────────
-- SECTION A — rollback for supabase_webinars_thresholds_schema.sql (Batch 1)
-- ────────────────────────────────────────────────────────────

-- A1. points_catalog changes.
-- The five new event types cannot be DELETEd once any points_events row
-- references them (FK) — deactivate instead; delete only if truly unused.
update public.points_catalog set active = false
  where event_type in ('budget_saved','checkin_logged','session_attended','ef_tool_used','tool_used');
-- If (and only if) zero points_events reference them:
--   delete from public.points_catalog
--   where event_type in ('budget_saved','checkin_logged','session_attended','ef_tool_used','tool_used')
--     and not exists (select 1 from public.points_events pe where pe.event_type = points_catalog.event_type);

-- Restore superseded values / reactivate superseded events:
update public.points_catalog set points = 100 where event_type = 'session_booked';
update public.points_catalog set active = true  where event_type in ('monthly_checkin','tool_first_use');

-- A2. threshold_config
drop table if exists public.threshold_config;

-- A3. video watch tables (destroys watch positions / quarterly credits
-- recorded since ship — export first if members have used the feature)
drop table if exists public.video_watch_credits;
drop table if exists public.video_watch_progress;

-- A4. tool usage events (destroys usage history recorded since ship)
drop table if exists public.tool_usage_events;

-- A5. content_items extension.
-- WARNING: dropping these columns deletes every webinar row's org/publish
-- state. Delete webinar rows first (they are meaningless without `kind`),
-- then drop the columns, then restore the original SELECT policy.
delete from public.content_items where kind = 'webinar';
drop policy if exists content_items_admin_all on public.content_items;
drop policy if exists content_items_readable on public.content_items;
alter table public.content_items
  drop column if exists published,
  drop column if exists description,
  drop column if exists org_id,
  drop column if exists kind;
-- Original policy, verbatim from supabase_lms_schema.sql §8:
create policy content_items_readable on public.content_items
  for select to authenticated using (true);

-- A6. branding RPC, then organizations branding columns (discards Sedimosa seed)
drop function if exists public.my_program_branding();
alter table public.organizations
  drop column if exists program_logo_path,
  drop column if exists program_name;

-- A7. webinars bucket. Direct DELETE on storage.buckets is blocked by
-- Supabase's protect_delete() trigger (42501) — remove via the dashboard
-- (Storage → Buckets → webinars → Delete) or the Storage API with the
-- service-role key. Empty the bucket first; bucket deletion fails while
-- objects remain.
drop policy if exists "webinars_no_direct_read" on storage.objects;  -- only if Batch 1 created one (it does not; listed defensively)
