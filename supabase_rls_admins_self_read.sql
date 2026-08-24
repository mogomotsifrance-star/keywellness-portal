-- ============================================================
-- Key Wellness — RLS fix: the admins table was readable by every
-- signed-in user.
--
-- Run in the Supabase SQL Editor. Safe to re-run.
--
-- Rollback: migrations/rollback-rls-admins-self-read.sql
-- ============================================================
--
-- WHY
--
-- admins_read was:
--
--   for select using (auth.role() = 'authenticated')
--
-- which is not a scope at all — it is true for every signed-in user. The
-- admins table has one column, email, so any member could read the full
-- list of Key Wellness administrator addresses. Confirmed against a real
-- member session: profiles showed 1 row (their own) and employers showed
-- 0, both correct, while admins showed all 4.
--
-- Not credentials, but it is the targeting list for exactly the accounts
-- that can grant roles and read every member's financial data.
--
-- The sibling table already had this right. employers_self_read reads:
--
--   (user_id = auth.uid()) or (lower(email) = lower(auth.jwt() ->> 'email'))
--
-- admins simply never got the same treatment. This aligns them. admins
-- has no user_id column, so the email arm is the whole predicate.
--
-- NO FRONTEND CHANGE IS NEEDED. All four pages query this table as
-- .from('admins').select('email').eq('email', ownEmail) — own row only,
-- which is exactly what the new policy allows. The admin Roles & Access
-- screen lists administrators via the is_admin()-gated
-- admin_roles_overview() RPC, not a table read.
--
-- is_admin() is unaffected: it is SECURITY DEFINER and so bypasses RLS
-- on this table entirely.
--
-- ------------------------------------------------------------
-- THE NON-OBVIOUS COUPLING
--
-- bookings carries a legacy policy, bookings_admin, whose predicate is
--
--   (auth.jwt() ->> 'email') in (select admins.email from admins)
--
-- That subquery is evaluated under the CALLER's RLS context on admins,
-- so narrowing this policy narrows that subquery too. It still resolves
-- correctly — an admin sees their own row, so their own email is in the
-- result and the predicate holds; a member sees no rows and it does not.
-- Verified explicitly rather than reasoned about: after this change an
-- admin still reads every bookings row and a member still reads only
-- their own.
--
-- Any FUTURE policy that subqueries admins inherits the same coupling.
-- Prefer is_admin() over an inline subquery — it is SECURITY DEFINER and
-- therefore immune to it.
-- ------------------------------------------------------------

begin;

drop policy if exists admins_read on admins;

create policy admins_read on admins
  for select
  using (lower(email) = lower(auth.jwt() ->> 'email'));

commit;


-- ── Verification ─────────────────────────────────────────────
--
-- 1. The live predicate:
--   select polname, pg_get_expr(polqual, polrelid)
--     from pg_policy where polname = 'admins_read';
--   -- expect: (lower(email) = lower((auth.jwt() ->> 'email'::text)))
--
-- 2. A member sees nothing and is not an admin; an admin sees their own
--    row and still reads every booking. Run as postgres:
--
--   do $$
--   declare v_email text; v_id uuid; v_admins int; v_bk int;
--           v_isadmin boolean; v_total_bk int; v_own_bk int;
--   begin
--     select count(*) into v_total_bk from bookings;
--
--     select u.id, u.email into v_id, v_email from auth.users u
--      where lower(u.email) not in (select lower(email) from admins)
--      order by u.created_at limit 1;
--     select count(*) into v_own_bk from bookings where user_id = v_id;
--     perform set_config('request.jwt.claims',
--       json_build_object('sub',v_id,'role','authenticated','email',v_email)::text, true);
--     perform set_config('role','authenticated',true);
--     select count(*) into v_admins from admins;
--     select count(*) into v_bk     from bookings;
--     select is_admin() into v_isadmin;
--     reset role;
--     if v_admins <> 0    then raise exception 'FAIL member: % admin rows', v_admins; end if;
--     if v_isadmin        then raise exception 'FAIL member: reports admin'; end if;
--     if v_bk <> v_own_bk then raise exception 'FAIL member: % bookings, owns %', v_bk, v_own_bk; end if;
--
--     select a.email into v_email from admins a limit 1;
--     select u.id into v_id from auth.users u where lower(u.email)=lower(v_email) limit 1;
--     perform set_config('request.jwt.claims',
--       json_build_object('sub',v_id,'role','authenticated','email',v_email)::text, true);
--     perform set_config('role','authenticated',true);
--     select count(*) into v_admins from admins;
--     select count(*) into v_bk     from bookings;
--     select is_admin() into v_isadmin;
--     reset role;
--     if v_admins <> 1      then raise exception 'FAIL admin: % admin rows', v_admins; end if;
--     if not v_isadmin      then raise exception 'FAIL admin: no longer admin'; end if;
--     if v_bk <> v_total_bk then raise exception 'FAIL admin: % of % bookings', v_bk, v_total_bk; end if;
--
--     raise notice 'all checks passed';
--   end $$;
--
-- Applied to production 2026-08-24, both checks passing.
-- ============================================================
