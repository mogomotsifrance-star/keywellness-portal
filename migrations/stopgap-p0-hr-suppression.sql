-- ============================================================
-- P0 HR suppression leak — STOP-GAP (NOT APPLIED)
-- Written 5 Oct 2026 for Tshenolo's decision. Do not run without a GO.
-- Rollback: migrations/rollback-stopgap-p0-hr-suppression.sql
-- Findings: docs/build/BATCH-0-P0-HR-SUPPRESSION-FINDINGS.md
--
-- WHAT IT DOES
--   Withholds a whole block from an EMPLOYER whenever that block holds a
--   cell of 1 or 2 people, by sending the "not enough data" shape that the
--   live employer.html (main) already renders. No page change is needed, and
--   no blank or NaN cell appears. Admin output is unchanged everywhere: the
--   floors are for the employer, not for us (CLAUDE.md).
--
--   SG-1 org_financial_indicators
--        any band of 1-2, or any block of 1-4 people (a median of 1-4 people
--        is one person's figure) -> {eligible:false, assessed_count, withheld}.
--        The page shows its existing "Data appears once 5+ employees..." card
--        for Debt Health, Retirement Readiness and the three headline medians.
--   SG-2 org_overview
--        Workforce Distribution with a band of 1-2 -> suppressed:true (the
--        page's existing "Appears once at least 3..." card).
--        completeness with a cell of 1-2 -> suppressed (not displayed today).
--        Emergency-fund share whose count, or whose complement, is 1-2 ->
--        pct null (the page already hides the tile on null).
--   SG-3 org_stress_summary
--        window fixed at 90 days (the page's default), so the cohort cannot
--        be differenced by calling 30, 31, 32... days; any band of 1-2 ->
--        insufficient_cohort:true (the page's existing message).
--   SG-4 org_report_data (5-arg), org_report_company_breakdown (4-arg),
--        org_report_department_breakdown (5-arg)
--        admin only. employer.html never calls them (HR reads published
--        snapshots from org_reports), so nothing on the HR page changes; this
--        only closes the API route where a whole-org HR login can pull the
--        org, every company and every department and subtract. The three
--        back-compat delegators reach these bodies, so they are covered.
--        publish_org_report runs as an admin and is unaffected.
--
-- WHAT IT DOES NOT DO
--   It does not touch the one already-published report (data_snapshot is a
--   frozen document). It does not stop an admin publishing a new report, and
--   _org_report_period_data still returns total_reach / total_attended beside
--   suppressed cells. Operational rule until Batch 1: publish no org report.
--
-- COST TO HR, ON 5 OCT 2026 DATA
--   Sedimosa and Test Co both lose Debt Health, Retirement Readiness and the
--   three headline medians (both have a band of 1-2), and both lose Workforce
--   Distribution (Sedimosa has a band of 2, Test Co has a band of 2). Enrolled,
--   Completed Assessment, Avg score, dimensions and trend stay.
--   The card wording is not perfect: "(13 of 5)" and "Appears once at least 3
--   employees..." are the existing texts written for a different reason. They
--   make no claim about anyone's money, which the alternatives do (see the
--   findings doc: withholding only the total makes the Debt card say "No
--   employees have reported" and blanking the bands makes the action strip say
--   "Debt levels look manageable").
--
-- HOW: same method as B1 / DSR Batch 2. Capture the live bodies into
-- kw_fn_backup, substitute at needles that were checked on 5 Oct 2026 to occur
-- exactly once, assert each landed, execute. A needle not found raises and the
-- whole migration rolls back.
-- ============================================================

begin;

-- ── 0. Capture the live bodies (idempotent) ──────────────────
insert into kw_fn_backup (tag, proname, identity_args, definition)
select 'p0-hr-suppression-stopgap', p.proname, pg_get_function_identity_arguments(p.oid),
       pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and (p.proname, pg_get_function_identity_arguments(p.oid)) in (
         ('org_financial_indicators',        'target_org uuid'),
         ('org_overview',                    'target_org uuid'),
         ('org_stress_summary',              'p_window_days integer'),
         ('org_report_data',                 'p_org_id uuid, p_start date, p_end date, p_unit_id uuid, p_client_safe boolean'),
         ('org_report_company_breakdown',    'p_org_id uuid, p_start date, p_end date, p_client_safe boolean'),
         ('org_report_department_breakdown', 'p_org_id uuid, p_start date, p_end date, p_unit_id uuid, p_client_safe boolean'))
   and not exists (select 1 from kw_fn_backup b
                    where b.tag = 'p0-hr-suppression-stopgap' and b.proname = p.proname
                      and b.identity_args = pg_get_function_identity_arguments(p.oid));

do $$
begin
  if (select count(*) from kw_fn_backup where tag = 'p0-hr-suppression-stopgap') <> 6 then
    raise exception 'expected 6 captured bodies under p0-hr-suppression-stopgap';
  end if;
end $$;

-- ── 1. The substitutions ─────────────────────────────────────
create temp table _p0_patch (
  ord int, proname text, args text, pat text, repl text
) on commit drop;

insert into _p0_patch values
-- SG-1
(1, 'org_financial_indicators', 'target_org uuid',
 $p$return json_build_object\(\s*'eligible', true,$p$,
 $r$-- P0 stop-gap (5 Oct 2026): a band of 1-2 sits beside its block total and
  -- its sibling bands, so it can be recovered by subtraction; a block of 1-4
  -- people makes its median one person's figure. Until the Batch 1 fix an
  -- employer gets no financial indicators while any block has either.
  -- Admin output unchanged. Rollback: kw_fn_backup 'p0-hr-suppression-stopgap'.
  if not is_admin() and (
       v_dti_reported    between 1 and 4
    or v_ret_reported    between 1 and 4
    or v_stress_reported between 1 and 4
    or exists (select 1 from json_array_elements(coalesce(v_dti_bands,    '[]'::json)) e where (e->>'suppressed')::boolean)
    or exists (select 1 from json_array_elements(coalesce(v_ret_bands,    '[]'::json)) e where (e->>'suppressed')::boolean)
    or exists (select 1 from json_array_elements(coalesce(v_stress_bands, '[]'::json)) e where (e->>'suppressed')::boolean)
  ) then
    return json_build_object('eligible', false, 'assessed_count', v_assessed_count,
                             'withheld', 'small_cells');
  end if;

  return json_build_object(
    'eligible', true,$r$),
-- SG-2a: Workforce Distribution
(2, 'org_overview', 'target_org uuid',
 $p$-- ── 4\. Dimensions$p$,
 $r$-- P0 stop-gap (5 Oct 2026): the page prints each band's count, so a band
  -- of 1-2 is shown outright. Withhold the whole distribution from an employer.
  if not is_admin() and not coalesce((v_distribution->>'suppressed')::boolean, false)
     and (   (v_distribution->'struggling'->>'count')::int between 1 and 2
          or (v_distribution->'coping'->>'count')::int     between 1 and 2
          or (v_distribution->'thriving'->>'count')::int   between 1 and 2) then
    v_distribution := json_build_object(
      'suppressed', true, 'assessed_count', v_assessed_n,
      'struggling', null, 'coping', null, 'thriving', null);
  end if;

  -- ── 4. Dimensions$r$),
-- SG-2b: completeness + emergency-fund share
(3, 'org_overview', 'target_org uuid',
 $p$return json_build_object\(\s*'suppressed',\s*false,\s*'summary',$p$,
 $r$-- P0 stop-gap (5 Oct 2026): completeness has no cell floor (its <3 test is
  -- on the whole cohort, which is always 5+ here); the emergency-fund share
  -- times its base is a count, and so is its complement.
  if not is_admin() then
    if not coalesce((v_completeness->>'suppressed')::boolean, false)
       and (   (v_completeness->>'none')::int between 1 and 2
            or (v_completeness->>'some')::int between 1 and 2
            or (v_completeness->>'most')::int between 1 and 2) then
      v_completeness := json_build_object(
        'suppressed', true, 'none', null, 'some', null, 'most', null,
        'n', v_completeness->'n', 'label', v_completeness->'label');
    end if;
    if (v_distress->>'pct_low_emergency_fund') is not null
       and (   round((v_distress->>'pct_low_emergency_fund')::numeric
                     * (v_distress->>'n_assessed')::int / 100) between 1 and 2
            or (v_distress->>'n_assessed')::int
               - round((v_distress->>'pct_low_emergency_fund')::numeric
                       * (v_distress->>'n_assessed')::int / 100) between 1 and 2) then
      v_distress := json_build_object(
        'suppressed', true, 'pct_low_emergency_fund', null,
        'n_assessed', v_distress->'n_assessed', 'label', v_distress->'label');
    end if;
  end if;

  return json_build_object(
    'suppressed',   false,
    'summary',$r$),
-- SG-3a: fixed window
(4, 'org_stress_summary', 'p_window_days integer',
 $p$target_org := employer_org\(\);$p$,
 $r$-- P0 stop-gap (5 Oct 2026): a caller-chosen window lets the cohort be
  -- differenced day by day. Fixed at the page's own default.
  p_window_days := 90;

  target_org := employer_org();$r$),
-- SG-3b: any band of 1-2
(5, 'org_stress_summary', 'p_window_days integer',
 $p$v_bands := json_build_object\($p$,
 $r$-- P0 stop-gap (5 Oct 2026): cohort_size is returned beside the bands, so
  -- one hidden band is cohort minus the other two.
  if v_low_n between 1 and 2 or v_moderate_n between 1 and 2 or v_high_n between 1 and 2 then
    return json_build_object('insufficient_cohort', true, 'withheld', 'small_cells');
  end if;

  v_bands := json_build_object($r$),
-- SG-4: admin only
(6, 'org_report_data', 'p_org_id uuid, p_start date, p_end date, p_unit_id uuid, p_client_safe boolean',
 $p$v_safe := coalesce\(p_client_safe, true\) or not is_admin\(\);$p$,
 $r$-- P0 stop-gap (5 Oct 2026): employer.html never calls this (HR reads
  -- published snapshots). Admin only until Batch 1, so an HR login cannot pull
  -- org / company / department / previous-period payloads and subtract.
  if not is_admin() then
    raise exception 'not authorised';
  end if;
  v_safe := coalesce(p_client_safe, true) or not is_admin();$r$),
(7, 'org_report_company_breakdown', 'p_org_id uuid, p_start date, p_end date, p_client_safe boolean',
 $p$v_safe := coalesce\(p_client_safe, true\) or not is_admin\(\);$p$,
 $r$-- P0 stop-gap (5 Oct 2026): admin only until Batch 1 (see org_report_data).
  if not is_admin() then
    raise exception 'not authorised';
  end if;
  v_safe := coalesce(p_client_safe, true) or not is_admin();$r$),
(8, 'org_report_department_breakdown', 'p_org_id uuid, p_start date, p_end date, p_unit_id uuid, p_client_safe boolean',
 $p$v_safe := coalesce\(p_client_safe, true\) or not is_admin\(\);$p$,
 $r$-- P0 stop-gap (5 Oct 2026): admin only until Batch 1 (see org_report_data).
  if not is_admin() then
    raise exception 'not authorised';
  end if;
  v_safe := coalesce(p_client_safe, true) or not is_admin();$r$);

do $$
declare
  f record;
  s record;
  v_def text;
  v_hits int;
begin
  -- One pass per function, applying its substitutions in order, then one
  -- execute, so a function is never left half-patched.
  for f in select distinct proname, args from _p0_patch loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = f.proname
       and pg_get_function_identity_arguments(p.oid) = f.args;
    if v_def is null then
      raise exception 'function %(%) not found', f.proname, f.args;
    end if;

    for s in select * from _p0_patch where proname = f.proname and args = f.args order by ord loop
      select count(*) into v_hits from regexp_matches(v_def, s.pat, 'g');
      if v_hits <> 1 then
        raise exception 'needle % in %: expected 1 hit, found %', s.ord, f.proname, v_hits;
      end if;
      v_def := regexp_replace(v_def, s.pat, s.repl);
    end loop;

    execute v_def;
  end loop;
end $$;

-- ── 2. Assert ────────────────────────────────────────────────
do $$
declare v_n int;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosrc like '%P0 stop-gap (5 Oct 2026)%';
  if v_n <> 6 then
    raise exception 'expected 6 patched functions, found %', v_n;
  end if;

  -- The grants did not move (create or replace keeps them, but say so).
  if has_function_privilege('anon', 'public.org_report_data(uuid,date,date,uuid,boolean)', 'EXECUTE') then
    raise exception 'org_report_data became anon-callable';
  end if;
end $$;

commit;

-- ── 3. Verification (read-only, after commit) ────────────────
-- a) Security sweep from CLAUDE.md: expect exactly the ten known rows.
-- b) As the Test Co HR login (not an admin):
--      org_financial_indicators(null) -> eligible false, withheld small_cells
--      (org_overview(null))->'distribution'->>'suppressed' -> true
--      org_stress_summary(30) -> same as org_stress_summary(365)
--      org_report_data(<test co>, ...) -> raises 'not authorised'
-- c) As an admin: all six return exactly what they returned before.
-- d) employer.html on the live site: no blank, NaN or "null" anywhere.
