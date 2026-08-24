-- ============================================================
-- Key Wellness — Organisation Account View, PHASE 1a
-- Lock the Phase 1 internal helpers.
--
-- Run in the Supabase SQL Editor AFTER
-- supabase_org_account_phase1_indicators.sql. Safe to re-run.
--
-- Rollback: migrations/rollback-org-account-phase1a-lock-internal-helpers.sql
-- ============================================================
--
-- WHY
--
-- Phase 1 called _org_indicator_counts an "internal helper: not granted
-- to authenticated". That was never true. Postgres grants EXECUTE on a
-- new function to PUBLIC by default, so declining to write a GRANT locks
-- nothing — you have to REVOKE.
--
-- _org_indicator_counts is SECURITY DEFINER and carries no authorisation
-- check of its own; the is_admin() / is_team_lead() gate lives only in
-- admin_org_indicators. So any caller holding the anon key — which is
-- published in every frontend page — could read a named organisation's
-- indicator counts directly, bypassing both the gate and the client-safe
-- low-base suppression. Confirmed as the anon role against a real org:
-- registered 8, assessed 6, no_emergency_buffer 4 of 6. Bases below the
-- low_base threshold of 5 were returned too, which is precisely what the
-- suppression rules exist to withhold.
--
-- Org ids are not secret. A member's own profile carries theirs.
--
-- This is the same lockdown _dept_metrics already has. After this runs,
-- all three match: postgres and service_role only.
--
-- NO FRONTEND CHANGE IS NEEDED. Nothing calls the helpers directly.
-- admin_org_indicators is SECURITY DEFINER owned by postgres, so it
-- keeps its own access to them regardless of the caller's role, and its
-- own grant to authenticated is deliberately left alone.
--
-- _jsonb_array_pos is deliberately NOT revoked: it is a pure jsonb
-- utility, immutable, with no data access and nothing to leak.
-- ------------------------------------------------------------

revoke execute on function public._org_indicator_counts(uuid, uuid[], date)
  from public, anon, authenticated;

revoke execute on function public._org_indicator_catalogue()
  from public, anon, authenticated;


-- ── Verification ─────────────────────────────────────────────
--
-- 1a. Both helpers locked down, and the gated RPC untouched:
--   select p.proname,
--          has_function_privilege('anon', p.oid, 'EXECUTE')          as anon_can,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_can
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('_org_indicator_counts','_org_indicator_catalogue',
--                        'admin_org_indicators');
--   -- expect false/false, false/false, true/true
--
-- 1b. The ACL should now read exactly as _dept_metrics does:
--   select proname, array_to_string(proacl, ' | ')
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and proname in ('_dept_metrics', '_org_indicator_counts');
--   -- expect: postgres=X/postgres | service_role=X/postgres
--
-- 1c. anon must be refused (expect insufficient_privilege):
--   set local role anon;
--   select _org_indicator_counts('<org_id>', null, current_date);
--   reset role;
--
-- 1d. The panel must still build for an admin — signed in as one:
--   select jsonb_array_length(
--            admin_org_indicators('<org_id>', date '2026-01-01', current_date)
--            -> 'headline');   -- expect 6
-- ============================================================
