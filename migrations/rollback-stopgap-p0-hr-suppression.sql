-- ============================================================
-- ROLLBACK — migrations/stopgap-p0-hr-suppression.sql (NOT APPLIED YET)
--
-- Restores the six functions to the bodies captured immediately before the
-- stop-gap, from kw_fn_backup tag 'p0-hr-suppression-stopgap':
--   org_financial_indicators(uuid), org_overview(uuid),
--   org_stress_summary(integer),
--   org_report_data(uuid,date,date,uuid,boolean),
--   org_report_company_breakdown(uuid,date,date,boolean),
--   org_report_department_breakdown(uuid,date,date,uuid,boolean)
--
-- Restore from the TABLE, not from any file on disk: org_financial_indicators
-- carries DSR Batch 2, org_overview carries B1, and neither has a current file.
--
-- After this the leak is open again exactly as it was on 5 Oct 2026.
-- ============================================================

do $$
declare
  r record;
  v_n int := 0;
begin
  for r in
    select distinct on (b.proname, b.identity_args)
           b.proname, b.identity_args, b.definition
      from kw_fn_backup b
     where b.tag = 'p0-hr-suppression-stopgap'
     order by b.proname, b.identity_args, b.taken_at asc, b.id asc
  loop
    execute r.definition;
    v_n := v_n + 1;
  end loop;
  if v_n <> 6 then
    raise exception 'expected 6 backed-up functions under p0-hr-suppression-stopgap, restored %', v_n;
  end if;
end $$;

-- Verify: expect 0 rows.
select p.proname, pg_get_function_identity_arguments(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prosrc like '%P0 stop-gap (5 Oct 2026)%';
