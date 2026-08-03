-- ============================================================
-- ROLLBACK — Batch 9: department-level HR reporting
-- Reverses supabase_org_report_data_v5_departments.sql.
-- Additive (two brand-new functions, nothing else touched), so dropping them
-- fully restores v4 behaviour. The existing org_report_data / company breakdown
-- are NOT modified by Batch 9 and need no restore.
-- ============================================================
drop function if exists org_report_department_breakdown(uuid, date, date, uuid);
drop function if exists _dept_metrics(uuid, date, date, uuid, uuid);
-- ============================================================
