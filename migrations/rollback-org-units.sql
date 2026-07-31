-- ============================================================
-- ROLLBACK — Company Units (Sedimosa sub-org structure), Batch 1
-- Companion to supabase_org_units.sql. Run in the Supabase SQL Editor.
--
-- Reverses, in dependency-safe order:
--   1. Tshenolo's account move (Sedimosa/Mmila -> Test Co, org_unit_id NULL)
--   2. the set-once trigger + function on profiles
--   3. profiles.org_unit_id column (DESTRUCTIVE — drops every member's unit)
--   4. hr_unit_scope table
--   5. org_units table (removes the 11 seeded Sedimosa rows)
--   6. helper function current_member_org()
--
-- Safe to re-run (all drops use IF EXISTS). Column/table drops are
-- intentionally destructive — this is a rollback, not a migration.
-- ============================================================

-- ── 1. Reverse the test-account move ─────────────────────────
-- trg_lock_org_id (from supabase_multitenancy.sql) forces org_id back to
-- OLD for non-admins, and the SQL Editor runs as `postgres` (is_admin()
-- = false), so it WOULD block this restore. Disable it for this one
-- statement only, exactly as supabase_seed_test_org.sql does.
alter table profiles disable trigger trg_lock_org_id;

do $$
declare
  v_testco uuid;
  v_prof   uuid;
begin
  select id into v_testco from organizations where invite_code = 'TEST-1234' limit 1;
  select p.id into v_prof
  from profiles p join auth.users u on u.id = p.id
  where lower(u.email) = 'tshenolo@prolearn.co.bw';

  if v_prof is null then
    raise notice 'Tshenolo profile not found — nothing to revert.';
  elsif v_testco is null then
    raise notice 'Test Co (TEST-1234) not found — clearing org_unit_id only, leaving org_id as-is.';
    update profiles set org_unit_id = null where id = v_prof;
  else
    update profiles set org_id = v_testco, org_unit_id = null where id = v_prof;
    raise notice 'Reverted % to Test Co, org_unit_id cleared.', v_prof;
  end if;
end $$;

alter table profiles enable trigger trg_lock_org_id;

-- ── 2. Drop the set-once trigger + function ──────────────────
drop trigger if exists trg_lock_org_unit_id on profiles;
drop function if exists lock_org_unit_id();

-- ── 3. Drop profiles.org_unit_id (DESTRUCTIVE) ───────────────
alter table profiles drop column if exists org_unit_id;

-- ── 4. Drop hr_unit_scope ────────────────────────────────────
drop table if exists hr_unit_scope;

-- ── 5. Drop org_units (removes the seeded Sedimosa rows) ──────
drop table if exists org_units;

-- ── 6. Drop the member-org helper ────────────────────────────
drop function if exists current_member_org();

-- ── VERIFY ───────────────────────────────────────────────────
-- select to_regclass('public.org_units')     as org_units;      -- expect NULL
-- select to_regclass('public.hr_unit_scope') as hr_unit_scope;  -- expect NULL
-- select column_name from information_schema.columns
--   where table_schema='public' and table_name='profiles' and column_name='org_unit_id'; -- expect 0 rows
