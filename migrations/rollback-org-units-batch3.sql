-- ============================================================
-- ROLLBACK — Company Units, Batch 3 (unit-scoped HR reporting)
-- Reverses supabase_org_units_hr_scope.sql, supabase_org_report_data_v4.sql,
-- and supabase_org_overview_scoped.sql. Run in the Supabase SQL Editor.
--
-- Batch 1 objects (org_units, hr_unit_scope, profiles.org_unit_id) are NOT
-- touched here — use migrations/rollback-org-units.sql for those.
-- ============================================================

-- ── 1. Restore the unscoped function bodies by re-applying the base files ──
-- Re-apply IN THIS ORDER, then run the drops below:
--   a) supabase_org_report_data_v3.sql     (restores 3-arg _org_report_period_data + 3-arg org_report_data)
--   b) supabase_live_wellness.sql          (restores unscoped org_overview + org_financial_indicators)
--   c) supabase_publish_org_report.sql     (restores the non-unit publish_org_report)
-- (Do that first; the drops below remove only the net-new objects.)

-- ── 2. Drop the net-new report functions ────────────────────
drop function if exists org_report_data(uuid, date, date, uuid);
drop function if exists org_report_company_breakdown(uuid, date, date);
drop function if exists _org_report_period_data(uuid, date, date, uuid[]);

-- ── 3. Drop the scope helpers ────────────────────────────────
drop function if exists hr_unit_in_scope(uuid, uuid);
drop function if exists hr_scoped_unit_ids();
drop function if exists unit_descendants(uuid);

-- ── 4. Drop the org_reports unit dimension (DESTRUCTIVE) ──────
-- Any published snapshot's recorded scope is lost. Only run if fully rolling back.
alter table org_reports drop column if exists unit_id;

-- ── VERIFY ───────────────────────────────────────────────────
-- select proname, pronargs from pg_proc where proname in
--   ('org_report_data','_org_report_period_data','org_overview','org_financial_indicators');
--   -- org_report_data: only the 3-arg remains; _org_report_period_data: only 3-arg.
-- select to_regprocedure('hr_scoped_unit_ids()');  -- expect NULL
-- ============================================================
