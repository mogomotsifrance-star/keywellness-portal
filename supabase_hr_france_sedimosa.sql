-- ============================================================
-- Key Wellness — Assign france@keywealth.co.bw as HR for Sedimosa
-- Run in the Supabase SQL Editor. Safe to re-run (skips if the
-- row already exists, case-insensitive on email).
--
-- PRODUCTION-LIVE on apply: on their first login with this email,
-- employer_org() matches them and index.html routes them straight
-- to employer.html (HR dashboard). user_id is backfilled on that
-- first login — no pre-registration needed.
--
-- Scope: WHOLE-ORG. No hr_unit_scope row is inserted, so
-- hr_scoped_unit_ids() returns NULL and they see all of Sedimosa
-- (every company unit). To narrow them to one company later,
-- insert an hr_unit_scope row with their unit_id.
--
-- ROLLBACK: migrations/rollback-hr-france-sedimosa.sql
-- ============================================================

do $$
declare
  v_org uuid;
begin
  select id into v_org
  from organizations
  where name ilike '%sedimosa%'
  limit 1;

  if v_org is null then
    raise exception 'Sedimosa organization not found — check organizations table';
  end if;

  if exists (
    select 1 from employers
    where lower(email) = lower('france@keywealth.co.bw')
  ) then
    raise notice 'france@keywealth.co.bw already exists in employers — no change made';
  else
    insert into employers (email, org_id)
    values ('france@keywealth.co.bw', v_org);
    raise notice 'Added france@keywealth.co.bw as whole-org HR for Sedimosa (org %)', v_org;
  end if;
end $$;

-- ── VERIFICATION ─────────────────────────────────────────────
-- 1. Row exists and points at Sedimosa:
--    select e.email, e.user_id, o.name as org
--    from employers e join organizations o on o.id = e.org_id
--    where lower(e.email) = 'france@keywealth.co.bw';
--    -- expect: 1 row, org = Sedimosa, user_id NULL until first login

-- 2. No accidental unit narrowing:
--    select * from hr_unit_scope
--    where lower(hr_email) = 'france@keywealth.co.bw';
--    -- expect: 0 rows (= whole-org scope)

-- 3. After they sign up / first log in with this email, confirm
--    user_id was backfilled and they landed on employer.html.
-- ============================================================
