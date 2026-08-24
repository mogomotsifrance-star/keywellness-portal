-- ============================================================
-- ROLLBACK — RLS fix: admins self-read
-- Reverses supabase_rls_admins_self_read.sql. Safe to re-run.
--
-- READ THIS BEFORE RUNNING IT.
--
-- This restores `using (auth.role() = 'authenticated')`, which is not a
-- scope: it is true for every signed-in user. Running this rollback makes
-- the full list of Key Wellness administrator email addresses readable by
-- any member again.
--
-- No frontend needs that. All four pages query this table filtered to
-- their own email, and the admin Roles & Access screen goes through the
-- is_admin()-gated admin_roles_overview() RPC. So there is no legitimate
-- reason to run this except to restore the exact pre-fix state.
--
-- If something looks broken after the fix, this is almost certainly not
-- the cause. Check instead:
--   * is_admin() — SECURITY DEFINER, bypasses RLS here, unaffected by
--     the policy either way;
--   * that the caller's JWT actually carries an `email` claim;
--   * case. The new policy compares lower() on both sides, matching how
--     is_admin() and employers_self_read already do it.
-- ============================================================

begin;

drop policy if exists admins_read on admins;

create policy admins_read on admins
  for select
  using (auth.role() = 'authenticated');

commit;


-- ── Verify ───────────────────────────────────────────────────
--
--   select polname, pg_get_expr(polqual, polrelid)
--     from pg_policy where polname = 'admins_read';
--   -- expect: (auth.role() = 'authenticated'::text)
--   -- i.e. back to the pre-fix state, readable by every signed-in user
-- ============================================================
