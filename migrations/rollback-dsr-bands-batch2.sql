-- ============================================================
-- ROLLBACK — supabase_dsr_bands_batch2.sql (DSR bands, Batch 2, SQL part)
--
-- Restores the five functions to the bodies captured immediately before the
-- change, from kw_fn_backup tag 'dsr-bands-batch2':
--   kw_dti_band, kw_is_over_indebted, _org_indicator_catalogue,
--   _org_indicator_counts, org_financial_indicators
--
-- WHY FROM A TABLE: org_financial_indicators and _org_indicator_counts were
-- last rewritten IN PLACE by B1 (supabase_habits_only_reporting.sql); no file
-- on disk holds their live body. The forward migration captured the live
-- bodies first. A copy of the same bodies, as read on 4 Oct 2026, is in
-- migrations/backup-dsr-bands-batch2-pre.sql for reading; restore from the
-- table, which is what was actually live.
--
-- After this, kw_dti_band() reads indicator.dti again (20/35/45), so HR and
-- admin figures return to the old bands and the take-home denominator.
--
-- ALSO REVERT: the front-end commit on dev (js/dsr-bands.js and the pages),
-- and the Edge Functions to the versions recorded in BUILD-NOTES (Batch 2).
-- Leaving the pages on 40/50/60 while SQL reads 20/35/45 makes the advisor
-- screen and HR disagree, which is the defect this build removed.
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
     where b.tag = 'dsr-bands-batch2'
     order by b.proname, b.identity_args, b.taken_at asc, b.id asc
  loop
    execute r.definition;
    v_n := v_n + 1;
  end loop;
  if v_n <> 5 then
    raise exception 'expected 5 backed-up functions under dsr-bands-batch2, restored %', v_n;
  end if;
end $$;

-- Verify: every restored body reads indicator.dti again or has no DSR read.
select p.proname,
       p.prosrc ~ 'indicator\.dsr' as still_reads_dsr
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('kw_dti_band','kw_is_over_indebted','_org_indicator_catalogue',
                     '_org_indicator_counts','org_financial_indicators');
-- expect still_reads_dsr = false on all five
