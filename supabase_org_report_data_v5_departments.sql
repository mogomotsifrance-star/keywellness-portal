-- ############################################################
-- ## HISTORY — DO NOT RE-RUN THIS FILE.
-- ##
-- ## This is not what is deployed. M3 Part 2 rewrote
-- ## _org_report_period_data and _dept_metrics IN PLACE, via
-- ## pg_get_functiondef, so that they count
-- ## service_line = 'financial' only. supabase_admin_internal_view.sql
-- ## then added p_client_safe the same way.
-- ##
-- ## Re-running this file restores the pre-M3 body and puts
-- ## counselling bookings back into HR's session totals.
-- ##
-- ## To see what is actually deployed:
-- ##   select pg_get_functiondef(p.oid)
-- ##     from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
-- ##    where ns.nspname = 'public'
-- ##      and p.proname in ('_org_report_period_data','_dept_metrics');
-- ############################################################

-- ============================================================
-- Key Wellness — Batch 9: department-level HR reporting (v5, ADDITIVE)
-- Run in the Supabase SQL Editor AFTER supabase_org_report_data_v4.sql,
-- supabase_org_units_hr_scope.sql, and supabase_sedimosa_phase2_batch1.sql
-- (which added profiles.department_id + unit_departments). Safe to re-run.
--
-- PRODUCTION-LIVE on apply. Purely additive: TWO new functions. It does NOT
-- touch _org_report_period_data / org_report_data / org_report_company_breakdown
-- (the v4 report is byte-identical afterwards), so the blast radius is limited
-- to the new department breakdown alone.
--
-- What it adds — a per-department breakdown for ONE company/site unit:
--   • Departments are enumerated SERVER-SIDE from unit_departments of the
--     validated unit — there is no client-supplied department filter to forge.
--   • Each department row is INDEPENDENTLY ≥5-cohort-guarded; a small
--     department returns { suppressed:true } with a withheld-for-privacy reason
--     and no numbers. Every cell is <3-suppressed (via _suppress_count).
--   • An "Unassigned" row (unit members with no department) is included, under
--     the same guard.
--   • A parent / combined unit (e.g. Debswana) gets NO department breakdown this
--     iteration ({ department_breakdown_available:false }).
--   • Scope is validated with hr_unit_in_scope(): a company manager can only
--     pass their own unit (or a descendant); admins & whole-org (fund) managers
--     may drill into any company's departments. Forged units -> "not authorised".
--
-- HR-data invariant preserved: band counts / aggregates only — NO names, emails,
-- or per-person financial direction values. Gender is an aggregate split subject
-- to the same suppression, never per person.
--
-- Rollback: migrations/rollback-org-report-departments.sql
-- ============================================================


-- ══════════════════════════════════════════════════════════════
-- Internal: guarded metrics for one (unit, department) cohort.
-- p_dept_id NULL => the "Unassigned" cohort (unit members, department_id NULL).
-- Returns { suppressed:true, ... } when the cohort is < 5. Never called from the
-- client (revoked); only from org_report_department_breakdown (SECURITY DEFINER).
-- ══════════════════════════════════════════════════════════════
create or replace function _dept_metrics(p_org_id uuid, p_start date, p_end date, p_unit_id uuid, p_dept_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
  v jsonb;
begin
  select count(*) into n
  from profiles p
  join auth.users u on u.id = p.id
  where p.org_id = p_org_id
    and p.org_unit_id = p_unit_id
    and (case when p_dept_id is null then p.department_id is null else p.department_id = p_dept_id end)
    and u.created_at <= (p_end + interval '1 day');

  if n < 5 then
    return jsonb_build_object(
      'suppressed', true,
      'insufficient_cohort', true,
      'reason', 'Fewer than 5 enrolled members — data withheld for privacy.');
  end if;

  with cohort as (
    select p.id, p.gender, p.live_score, p.live_score_at
    from profiles p
    join auth.users u on u.id = p.id
    where p.org_id = p_org_id
      and p.org_unit_id = p_unit_id
      and (case when p_dept_id is null then p.department_id is null else p.department_id = p_dept_id end)
      and u.created_at <= (p_end + interval '1 day')
  ),
  assessed as (
    select distinct a.user_id from assessments a join cohort c on c.id = a.user_id
    where a.created_at::date between p_start and p_end
  ),
  tool_used as (
    select distinct pe.user_id from points_events pe join cohort c on c.id = pe.user_id
    where pe.event_type = 'tool_first_use' and pe.created_at::date between p_start and p_end
  ),
  booked as (
    select distinct b.user_id from bookings b join cohort c on c.id = b.user_id
    where b.created_at::date between p_start and p_end
  ),
  attended as (
    select distinct b.user_id from bookings b join cohort c on c.id = b.user_id
    where b.attended is true and b.created_at::date between p_start and p_end
  ),
  -- Effective overall wellness score per member: the live score when it is at
  -- least as recent as their latest assessment (and within the period), else the
  -- latest assessment score. Mirrors the body's live-or-assessed rule.
  eff as (
    select c.id,
      case
        when c.live_score is not null and c.live_score_at is not null
             and c.live_score_at::date <= p_end
             and (la.created_at is null or c.live_score_at >= la.created_at)
        then c.live_score
        else la.score
      end as eff_score
    from cohort c
    left join lateral (
      select a.score, a.created_at from assessments a
      where a.user_id = c.id and a.created_at::date <= p_end
      order by a.created_at desc limit 1
    ) la on true
  ),
  bands as (
    select
      count(*) filter (where eff_score < 50)                     as low,
      count(*) filter (where eff_score >= 50 and eff_score < 70) as mid,
      count(*) filter (where eff_score >= 70)                    as high
    from eff where eff_score is not null
  )
  select jsonb_build_object(
    'suppressed', false,
    'n_employees', n,
    'engagement_funnel', jsonb_build_object(
      'registered',           n,
      'completed_assessment', _suppress_count((select count(*) from assessed)),
      'used_tool',            _suppress_count((select count(*) from tool_used)),
      'booked_session',       _suppress_count((select count(*) from booked)),
      'attended_session',     _suppress_count((select count(*) from attended))
    ),
    'wellness_bands', jsonb_build_object(
      'under_50',     _suppress_count((select low  from bands)),
      'band_50_69',   _suppress_count((select mid  from bands)),
      'band_70_plus', _suppress_count((select high from bands))
    ),
    'gender_split', jsonb_build_object(
      'male',              _suppress_count((select count(*) from cohort where gender = 'male')),
      'female',            _suppress_count((select count(*) from cohort where gender = 'female')),
      'prefer_not_to_say', _suppress_count((select count(*) from cohort where gender = 'prefer_not_to_say')),
      'unspecified',       _suppress_count((select count(*) from cohort where gender is null))
    )
  ) into v;
  return v;
end;
$$;

revoke all on function _dept_metrics(uuid, date, date, uuid, uuid) from public, anon, authenticated;


-- ══════════════════════════════════════════════════════════════
-- Public: per-department breakdown for ONE company/site unit.
-- ══════════════════════════════════════════════════════════════
create or replace function org_report_department_breakdown(p_org_id uuid, p_start date, p_end date, p_unit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row         record;
  v_departments jsonb := '[]'::jsonb;
  v_has_children boolean;
begin
  if p_end < p_start then
    raise exception 'period_end must not be before period_start';
  end if;
  if p_unit_id is null then
    raise exception 'a unit_id is required for the department breakdown';
  end if;

  -- Scope validation (server-side): admin / whole-org manager -> any unit in the
  -- org; company manager -> only their own unit or a descendant. Forged units -> throw.
  if not hr_unit_in_scope(p_org_id, p_unit_id) then
    raise exception 'not authorised';
  end if;

  -- A parent / combined unit (e.g. Debswana) gets NO department breakdown this
  -- iteration — combined-across-sites department cohorts invite confusion.
  select exists(
    select 1 from org_units
    where parent_unit_id = p_unit_id and org_id = p_org_id and is_active = true
  ) into v_has_children;
  if v_has_children then
    return jsonb_build_object(
      'department_breakdown_available', false,
      'reason', 'Combined multi-site view — department breakdown is not available in this iteration.',
      'unit_id', p_unit_id, 'period_start', p_start, 'period_end', p_end);
  end if;

  -- One independently-guarded row per active department of the unit.
  for v_row in
    select id, name from unit_departments
    where unit_id = p_unit_id and is_active = true
    order by sort_order, name
  loop
    v_departments := v_departments || jsonb_build_array(
      jsonb_build_object('department_id', v_row.id, 'name', v_row.name)
      || _dept_metrics(p_org_id, p_start, p_end, p_unit_id, v_row.id));
  end loop;

  -- "Unassigned" row: unit members with no department (guard applies too).
  v_departments := v_departments || jsonb_build_array(
    jsonb_build_object('department_id', null, 'name', 'Unassigned')
    || _dept_metrics(p_org_id, p_start, p_end, p_unit_id, null));

  return jsonb_build_object(
    'department_breakdown_available', true,
    'unit_id',      p_unit_id,
    'departments',  v_departments,
    'period_start', p_start,
    'period_end',   p_end);
end;
$$;

grant execute on function org_report_department_breakdown(uuid, date, date, uuid) to authenticated;


-- ── VERIFICATION ─────────────────────────────────────────────
-- Resolve ids in the SQL Editor first:
--   select id from organizations where name ilike '%sedimosa%';            -- org
--   select id,name from org_units where org_id='<org>' and is_active;      -- units
--
-- 1. Leaf unit breakdown (as postgres = admin-equivalent in SQL Editor):
--    select org_report_department_breakdown('<org>','2026-01-01','2026-12-31','<Mmila>');
--    -- expect department_breakdown_available:true; one row per Mmila department
--    -- + an "Unassigned" row; every row with <5 members => {suppressed:true}.
-- 2. Parent/combined unit (Debswana) => department_breakdown_available:false.
-- 3. <3 cell suppression: any funnel/band/gender cell with a raw value <3 comes
--    back as {value:null, suppressed:true} (via _suppress_count).
-- 4. Scope (BROWSER console, logged in):
--    • A company manager scoped to Mmila:
--        await sb.rpc('org_report_department_breakdown',{p_org_id:'<org>',p_start:'2026-01-01',p_end:'2026-12-31',p_unit_id:'<Mmila>'});   // ok
--        await sb.rpc('org_report_department_breakdown',{p_org_id:'<org>',p_start:'2026-01-01',p_end:'2026-12-31',p_unit_id:'<Sesiro>'}); // error: not authorised
--    • An HR/employer with no scope over the org: error.
-- 5. Grep this file: output is band counts / aggregates only — no names, emails,
--    or per-person financial direction values.
-- ============================================================
