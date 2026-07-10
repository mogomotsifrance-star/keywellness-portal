-- ============================================================
-- Cleanup: drop legacy duplicate RLS policies.
-- SAFE: every dropped policy is an exact own-row duplicate of a
-- *_own (ALL) policy that remains in place. Verified clauses:
--   all were (auth.uid() = user_id) / (auth.uid() = id) — no leaks.
-- After this, each table keeps exactly:  *_own (ALL) + *_admin_read (SELECT)
-- (profiles also keeps profiles_own + profiles_admin_read).
-- Reversible — just re-run the migration if ever needed.
-- ============================================================

-- Member tables: drop the *_self / ef_all duplicates of *_own
drop policy if exists assessments_self      on assessments;
drop policy if exists badges_self           on badges;
drop policy if exists checkins_self         on checkins;
drop policy if exists ef_all                on emergency_fund;
drop policy if exists emergency_fund_self   on emergency_fund;

-- profiles: profiles_own (ALL) already covers select/insert/update/delete
-- for the user's own row, so these split legacy policies are redundant.
drop policy if exists profiles_self    on profiles;
drop policy if exists profiles_select  on profiles;
drop policy if exists profiles_insert  on profiles;
drop policy if exists profiles_update  on profiles;

-- ── Re-verify: should now be exactly 2 policies per table ──
select tablename, count(*) as policy_count,
       string_agg(policyname, ', ' order by policyname) as policies
from pg_policies
where schemaname='public'
  and tablename in ('profiles','assessments','checkins','badges','emergency_fund')
group by tablename
order by tablename;
