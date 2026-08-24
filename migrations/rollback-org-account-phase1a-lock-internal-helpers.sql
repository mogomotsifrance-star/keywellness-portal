-- ============================================================
-- ROLLBACK — Organisation Account View, Phase 1a
-- Reverses supabase_org_account_phase1a_lock_internal_helpers.sql.
-- Safe to re-run.
--
-- READ THIS BEFORE RUNNING IT.
--
-- Phase 1a closed a data leak. Running this rollback REOPENS it: any
-- caller holding the published anon key could again read a named
-- organisation's indicator counts directly, bypassing the
-- is_admin() / is_team_lead() gate and the client-safe low-base
-- suppression.
--
-- Nothing in the frontend needs these grants — nothing calls the helpers
-- directly, and admin_org_indicators reaches them as its own SECURITY
-- DEFINER owner. So there is no legitimate reason to run this except to
-- restore the exact pre-Phase-1a state of the database.
--
-- If the indicator panel is broken, the cause is not this grant. Check
-- admin_org_indicators' own grant to authenticated, and is_admin() /
-- is_team_lead(), first.
-- ============================================================

grant execute on function public._org_indicator_counts(uuid, uuid[], date)
  to public, anon, authenticated;

grant execute on function public._org_indicator_catalogue()
  to public, anon, authenticated;


-- ── Verify ───────────────────────────────────────────────────
--
--   select p.proname,
--          has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('_org_indicator_counts','_org_indicator_catalogue');
--   -- expect true / true, i.e. back to the leaky pre-Phase-1a state
-- ============================================================
