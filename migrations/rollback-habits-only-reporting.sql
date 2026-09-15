-- ============================================================
-- ROLLBACK — supabase_habits_only_reporting.sql (B1)
--
-- Restores the five reporting functions to the bodies captured immediately
-- before the change, and drops profiles.picture_sources.
--
-- ══ WHY IT RESTORES FROM A TABLE, NOT FROM DISK ════════════
--
-- _org_report_period_data and _dept_metrics were rewritten IN PLACE by M3
-- Part 2 and their disk files (supabase_org_report_data_v4.sql,
-- _v5_departments.sql) are HISTORY — re-running either would put counselling
-- bookings back into HR's session totals. So the forward migration captured
-- the LIVE bodies into kw_fn_backup first, and this restores those.
--
-- Two tags, because the forward file works in two passes:
--   'phase-b-habits-only'         org_overview, _org_indicator_counts,
--                                 org_financial_indicators,
--                                 _org_report_period_data, _dept_metrics
--   'phase-b-habits-only-caller'  admin_org_indicators, plus a second
--                                 capture of the three patched in pass two
--
-- Where both tags hold a body for the same function, the EARLIER one is the
-- true pre-change body. This script takes the earliest capture per function.
--
-- ══ WHAT THIS CANNOT UNDO ══════════════════════════════════
--
-- The backfill nulled live_score / live_cat_scores for habits-only members
-- whose four-source gate was unmet. Those values are GONE — they were written
-- without the gate and there is no history table for them. On the live
-- database this was exactly ONE profile (the Test Co test account, which held
-- 57); its assessments.score of 63 is untouched and the dashboard recomputes
-- a live score the moment that member meets the gate. Verify the count for
-- yourself before rolling back:
--
--   select count(*) from profiles p
--     where p.live_score is null and p.picture_sources is not null
--       and exists (select 1 from assessments a where a.user_id = p.id);
--
-- Dropping picture_sources also discards the backfilled counts. They are
-- derived, and re-running section 3 of the forward file rebuilds them.
--
-- ══ ALSO REVERT ════════════════════════════════════════════
--
-- index.html — persistLiveWellness() and kwPictureSources(). Left in place,
-- the front end simply stops writing a score for un-gated members and writes
-- a picture_sources column that no longer exists, which fails the whole
-- profiles update. Revert the commit or drop the column reference first.
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
     where b.tag in ('phase-b-habits-only', 'phase-b-habits-only-caller')
     order by b.proname, b.identity_args, b.taken_at asc, b.id asc
  loop
    execute r.definition;
    v_n := v_n + 1;
    raise notice 'restored %(%)', r.proname, r.identity_args;
  end loop;

  if v_n = 0 then
    raise exception 'kw_fn_backup holds no bodies for these tags — nothing restored';
  end if;
  raise notice 'restored % function bodies', v_n;
end $$;

-- Assert the restore actually undid the change rather than reporting success
-- over a no-op.
do $$
declare v_n int;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('org_overview','org_financial_indicators','_org_indicator_counts',
                       '_org_report_period_data','_dept_metrics','admin_org_indicators')
     and (pg_get_functiondef(p.oid) like '%\_habits\_only%'
       or pg_get_functiondef(p.oid) like '%engaged\_not\_scored%');
  if v_n > 0 then
    raise exception '% function(s) still carry the B1 gate after restore', v_n;
  end if;
end $$;

-- The M3 service-line split must have come back with them.
do $$
declare v_n int;
begin
  select (length(pg_get_functiondef(p.oid))
          - length(replace(pg_get_functiondef(p.oid), 'kw_line_is_confidential', '')))
         / length('kw_line_is_confidential')
    into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = '_dept_metrics';
  if coalesce(v_n, 0) <> 2 then
    raise exception 'M3 service-line split is % in _dept_metrics after restore, expected 2', v_n;
  end if;
end $$;

alter table profiles drop column if exists picture_sources;

-- kw_fn_backup is deliberately LEFT IN PLACE. It costs nothing, it is the
-- only record of these bodies, and dropping it would make a second attempt
-- at this change unrollbackable.
