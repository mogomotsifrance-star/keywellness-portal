-- ============================================================
-- ROLLBACK — Organisation Account View, Phase 1
-- Reverses supabase_org_account_phase1_indicators.sql. Safe to re-run.
--
-- Phase 1 is purely additive: three new functions, no schema change, no
-- data written. Removing them cannot lose anything, and Phase 0 / 0a are
-- unaffected — unlike the 0a rollback, this one stands alone.
--
-- The only caller is the organisation account view. If that UI is live,
-- take it down first or its indicator panel will error.
-- ============================================================

drop function if exists admin_org_indicators(uuid, date, date, uuid, boolean);
drop function if exists _org_indicator_counts(uuid, uuid[], date);
drop function if exists _org_indicator_catalogue();
drop function if exists _jsonb_array_pos(jsonb, text);


-- ── Verify ───────────────────────────────────────────────────
--
--   select count(*) as should_be_zero from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('admin_org_indicators','_org_indicator_counts',
--                        '_org_indicator_catalogue','_jsonb_array_pos');
--
-- threshold_config is deliberately left alone: its indicator rows were
-- seeded by Phase 0 and are read by advisor.html's DTI banding, not just
-- by this phase. Rolling those back is rollback-org-account-phase0.sql's
-- job.
-- ============================================================
