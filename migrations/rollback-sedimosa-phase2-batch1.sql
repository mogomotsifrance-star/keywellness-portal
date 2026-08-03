-- ============================================================
-- ROLLBACK — Sedimosa Phase 2, Batch 1
-- Reverses supabase_sedimosa_phase2_batch1.sql.
-- Written & committed BEFORE the migration was applied (rollback-first rule).
-- Run in the Supabase SQL Editor. Additive migration => this drop-based
-- rollback is safe, EXCEPT the two caveats called out below.
--
-- CAVEATS (read before running):
--   1. Dropping `notifications`, `webinar_views`, and `unit_departments`
--      DESTROYS any rows written since the migration (notifications sent,
--      webinar views logged, departments chosen). Only roll back before
--      those surfaces have carried real member data, or accept the loss.
--   2. Dropping `profiles.gender` / `department_id` / `will_status`
--      DESTROYS values collected since the migration. `profiles.phone` is
--      NOT dropped here — it pre-existed Batch 1 and is real member data.
--   3. The DeBeers member reassignment (profiles moved DeBeers -> DBGSS)
--      is NOT auto-reversed: the migration did not record which rows were
--      originally on DeBeers. If DeBeers had 0 members at migration time
--      (expected — the units are new), this is moot. Otherwise reassign by hand.
-- ============================================================

-- ── Drop set-once dimension guard (must precede column drops) ────
drop trigger if exists trg_lock_profile_dims on profiles;
drop function if exists lock_profile_dims();

-- ── Drop notification read_at guard ─────────────────────────────
drop trigger if exists trg_guard_notification_update on notifications;
drop function if exists guard_notification_update();

-- ── Drop department_id column (FK to unit_departments) BEFORE the table ──
alter table profiles drop column if exists department_id;

-- ── Drop new tables ─────────────────────────────────────────────
drop table if exists webinar_views;
drop table if exists notifications;
drop table if exists unit_departments;

-- ── Drop the other additive profiles columns (NOT phone) ────────
alter table profiles drop column if exists gender;
alter table profiles drop column if exists will_status;

-- ── Drop content_items.webinar_date ─────────────────────────────
alter table public.content_items drop column if exists webinar_date;

-- ── Reverse the seed corrections ────────────────────────────────
do $$
declare
  v_org uuid;
begin
  select id into v_org from organizations where name ilike '%sedimosa%' limit 1;
  if v_org is null then
    raise notice 'Sedimosa org not found — nothing to reverse.';
    return;
  end if;

  -- Reactivate the DeBeers unit
  update org_units set is_active = true
   where org_id = v_org and name = 'DeBeers';

  -- Restore the original 'Morupule' name (only if MCM exists and Morupule does not)
  update org_units set name = 'Morupule'
   where org_id = v_org and name = 'Morupule Coal Mine (MCM)'
     and not exists (select 1 from org_units where org_id = v_org and name = 'Morupule');

  raise notice 'Reversed seed corrections for org %.', v_org;
end $$;

-- ── Verification after rollback ─────────────────────────────────
-- select column_name from information_schema.columns
--   where table_schema='public' and table_name='profiles'
--     and column_name in ('gender','department_id','will_status');   -- expect 0 rows
-- select to_regclass('public.unit_departments'), to_regclass('public.notifications'),
--        to_regclass('public.webinar_views');                        -- expect all NULL
-- select name, is_active from org_units
--   where org_id=(select id from organizations where name ilike '%sedimosa%' limit 1)
--     and name in ('Morupule','DeBeers');                            -- both present, active
-- ============================================================
