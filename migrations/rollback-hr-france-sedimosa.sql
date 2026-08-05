-- ============================================================
-- ROLLBACK — supabase_hr_france_sedimosa.sql
-- Removes france@keywealth.co.bw's HR access to Sedimosa.
-- Safe to re-run. Does NOT touch their auth.users account (if they
-- have registered) — it only revokes the employer/HR mapping.
-- ============================================================

delete from employers
where lower(email) = lower('france@keywealth.co.bw')
  and org_id = (select id from organizations where name ilike '%sedimosa%' limit 1);

-- Defensive: clear any unit scope that may have been added for them later.
delete from hr_unit_scope
where lower(hr_email) = lower('france@keywealth.co.bw');

-- Verify: both should return 0 rows
-- select * from employers where lower(email) = 'france@keywealth.co.bw';
-- select * from hr_unit_scope where lower(hr_email) = 'france@keywealth.co.bw';
-- ============================================================
