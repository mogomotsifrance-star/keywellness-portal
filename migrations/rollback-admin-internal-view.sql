-- ============================================================
-- ROLLBACK: supabase_admin_internal_view.sql
--
-- Restores the state where the base-5 and <3 floors apply to Key Wellness
-- admin exactly as they do to an employer.
--
-- ══ READ THIS BEFORE RUNNING ═══════════════════════════════
--
-- This rollback does NOT restore the bodies of _org_report_period_data or
-- _dept_metrics from a file, because no file holds them — see note 1 in the
-- forward migration. It reverses the same textual substitutions on whatever
-- is live, which is the only way to undo the change without also undoing
-- M3's financial-line split.
--
-- One thing is deliberately NOT reversed: the M3 split added to
-- _dept_metrics by section 3 of the forward migration. Removing it would
-- put counselling bookings back into HR's department totals. That was a
-- latent disclosure fixed in passing; it is not part of what is being
-- rolled back. If you genuinely need it gone, take that decision on its own.
--
-- Rollback does not undo a disclosure. Nothing here can unsee a number.
-- ============================================================


-- ── 1. Un-flag _org_report_period_data ──────────────────────
do $$
declare v_def text; v_new text; n int;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = '_org_report_period_data'
     and pg_get_function_identity_arguments(p.oid)
         = 'p_org_id uuid, p_start date, p_end date, p_unit_ids uuid[], p_client_safe boolean';

  if v_def is null then
    raise notice 'rollback: the 5-arg _org_report_period_data is absent — nothing to undo.';
    return;
  end if;

  n := (select count(*) from regexp_matches(v_def, '_kw_cell\(p_client_safe, ', 'g'));

  v_new := replace(v_def, 'p_unit_ids uuid[], p_client_safe boolean)', 'p_unit_ids uuid[])');
  v_new := replace(v_new, 'if p_client_safe and n < 5 then', 'if n < 5 then');
  v_new := replace(v_new, '_kw_cell(p_client_safe, ',        '_suppress_count(');
  v_new := replace(v_new, '(p_client_safe and cnt < 3) as cell_suppressed',
                          '(cnt < 3) as cell_suppressed');

  if v_new ~ 'p_client_safe' then
    raise exception 'rollback: p_client_safe still appears in the rewritten body. '
                    'Do this one BY HAND rather than leaving a half-reversed function.';
  end if;

  execute v_new;
  raise notice 'rollback: _org_report_period_data restored (% cell gates).', n;
end $$;


-- ── 2. Un-flag _dept_metrics (keeping the M3 split) ─────────
do $$
declare v_def text; v_new text; n int;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = '_dept_metrics'
     and pg_get_function_identity_arguments(p.oid)
         = 'p_org_id uuid, p_start date, p_end date, p_unit_id uuid, p_dept_id uuid, p_client_safe boolean';

  if v_def is null then
    raise notice 'rollback: the 6-arg _dept_metrics is absent — nothing to undo.';
    return;
  end if;

  n := (select count(*) from regexp_matches(v_def, '_kw_cell\(p_client_safe, ', 'g'));

  v_new := replace(v_def, 'p_dept_id uuid, p_client_safe boolean)', 'p_dept_id uuid)');
  v_new := replace(v_new, 'if p_client_safe and n < 5 then', 'if n < 5 then');
  v_new := replace(v_new, '_kw_cell(p_client_safe, ',        '_suppress_count(');

  if v_new ~ 'p_client_safe' then
    raise exception 'rollback: p_client_safe still appears in the rewritten _dept_metrics.';
  end if;
  -- The M3 split stays. See the banner above.
  if v_new !~ 'service_line = ''financial''' then
    raise exception 'rollback: refusing to restore a _dept_metrics that counts '
                    'psychosocial into HR''s totals.';
  end if;

  execute v_new;
  raise notice 'rollback: _dept_metrics restored (% cell gates), M3 split kept.', n;
end $$;


-- ── 3. Restore the pre-change wrappers ──────────────────────
create or replace function _org_report_period_data(p_org_id uuid, p_start date, p_end date)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select _org_report_period_data(p_org_id, p_start, p_end, null::uuid[]);
$$;

create or replace function org_report_data(p_org_id uuid, p_start date, p_end date, p_unit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids      uuid[];
  v_current  jsonb;
  v_previous jsonb;
  v_days     int;
  v_prev_start date;
  v_prev_end   date;
begin
  if p_end < p_start then
    raise exception 'period_end must not be before period_start';
  end if;

  if p_unit_id is null then
    if not (is_admin() or (coalesce(employer_org() = p_org_id, false)
                           and hr_scoped_unit_ids() is null)) then
      raise exception 'not authorised';
    end if;
    v_ids := null;
  else
    if not hr_unit_in_scope(p_org_id, p_unit_id) then
      raise exception 'not authorised';
    end if;
    select array_agg(d.id) into v_ids from unit_descendants(p_unit_id) d;
  end if;

  v_current := _org_report_period_data(p_org_id, p_start, p_end, v_ids);
  if coalesce((v_current->>'insufficient_cohort')::boolean, false) then
    return jsonb_build_object('insufficient_cohort', true, 'unit_id', p_unit_id);
  end if;

  v_days       := p_end - p_start;
  v_prev_end   := p_start - 1;
  v_prev_start := v_prev_end - v_days;
  v_previous := _org_report_period_data(p_org_id, v_prev_start, v_prev_end, v_ids);

  return v_current || jsonb_build_object('previous_period', v_previous, 'unit_id', p_unit_id);
end;
$$;

create or replace function org_report_data(p_org_id uuid, p_start date, p_end date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current  jsonb;
  v_previous jsonb;
  v_days     int;
  v_prev_start date;
  v_prev_end   date;
begin
  if not (is_admin() or coalesce(employer_org() = p_org_id, false)) then
    raise exception 'not authorised';
  end if;
  if p_end < p_start then
    raise exception 'period_end must not be before period_start';
  end if;

  v_current := _org_report_period_data(p_org_id, p_start, p_end);
  if coalesce((v_current->>'insufficient_cohort')::boolean, false) then
    return jsonb_build_object('insufficient_cohort', true);
  end if;

  v_days       := p_end - p_start;
  v_prev_end   := p_start - 1;
  v_prev_start := v_prev_end - v_days;
  v_previous := _org_report_period_data(p_org_id, v_prev_start, v_prev_end);

  return v_current || jsonb_build_object('previous_period', v_previous);
end;
$$;

create or replace function org_report_company_breakdown(p_org_id uuid, p_start date, p_end date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row       record;
  v_ids       uuid[];
  v_report    jsonb;
  v_companies jsonb := '[]'::jsonb;
  v_unassigned int;
begin
  if not (is_admin() or (coalesce(employer_org() = p_org_id, false)
                         and hr_scoped_unit_ids() is null)) then
    raise exception 'not authorised';
  end if;
  if p_end < p_start then
    raise exception 'period_end must not be before period_start';
  end if;

  for v_row in
    select id, name from org_units
    where org_id = p_org_id and parent_unit_id is null and is_active = true
    order by sort_order, name
  loop
    select array_agg(d.id) into v_ids from unit_descendants(v_row.id) d;
    v_report := _org_report_period_data(p_org_id, p_start, p_end, v_ids);
    if coalesce((v_report->>'insufficient_cohort')::boolean, false) then
      v_companies := v_companies || jsonb_build_array(jsonb_build_object(
        'unit_id', v_row.id, 'name', v_row.name, 'suppressed', true));
    else
      v_companies := v_companies || jsonb_build_array(jsonb_build_object(
        'unit_id',          v_row.id,
        'name',             v_row.name,
        'suppressed',       false,
        'n_employees',      v_report->'n_employees',
        'kpi_summary',      v_report->'kpi_summary',
        'engagement_funnel',v_report->'engagement_funnel'));
    end if;
  end loop;

  select count(*) into v_unassigned
  from profiles p
  where p.org_id = p_org_id and p.org_unit_id is null;

  return jsonb_build_object(
    'companies',           v_companies,
    'unassigned_members',  v_unassigned,
    'period_start',        p_start,
    'period_end',          p_end
  );
end;
$$;

create or replace function org_report_department_breakdown(p_org_id uuid, p_start date, p_end date,
                                                           p_unit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row          record;
  v_departments  jsonb := '[]'::jsonb;
  v_has_children boolean;
begin
  if p_end < p_start then
    raise exception 'period_end must not be before period_start';
  end if;
  if p_unit_id is null then
    raise exception 'a unit_id is required for the department breakdown';
  end if;

  if not hr_unit_in_scope(p_org_id, p_unit_id) then
    raise exception 'not authorised';
  end if;

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

  for v_row in
    select id, name from unit_departments
    where unit_id = p_unit_id and is_active = true
    order by sort_order, name
  loop
    v_departments := v_departments || jsonb_build_array(
      jsonb_build_object('department_id', v_row.id, 'name', v_row.name)
      || _dept_metrics(p_org_id, p_start, p_end, p_unit_id, v_row.id));
  end loop;

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

create or replace function publish_org_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row      org_reports;
  v_snapshot jsonb;
begin
  if not is_admin() then
    raise exception 'not authorised';
  end if;

  select * into v_row from org_reports where id = p_report_id;
  if not found then
    raise exception 'report not found';
  end if;
  if v_row.status = 'published' then
    raise exception 'report is already published';
  end if;

  if v_row.unit_id is null then
    v_snapshot := org_report_data(v_row.org_id, v_row.period_start, v_row.period_end);
  else
    v_snapshot := org_report_data(v_row.org_id, v_row.period_start, v_row.period_end, v_row.unit_id);
  end if;

  if coalesce((v_snapshot->>'insufficient_cohort')::boolean, false) then
    raise exception 'cannot publish: fewer than 5 enrolled members for this period/scope';
  end if;

  update org_reports
  set data_snapshot = v_snapshot,
      status        = 'published',
      published_by  = auth.uid(),
      published_at  = now(),
      updated_at    = now()
  where id = p_report_id;
end;
$$;


-- ── 4. Drop the new surface ─────────────────────────────────
drop function if exists org_report_data(uuid, date, date, uuid, boolean);
drop function if exists org_report_company_breakdown(uuid, date, date, boolean);
drop function if exists org_report_department_breakdown(uuid, date, date, uuid, boolean);
drop function if exists admin_org_summary(uuid);
drop function if exists _org_report_period_data(uuid, date, date, uuid[], boolean);
drop function if exists _org_report_period_data(uuid, date, date, boolean);
drop function if exists _kw_cell(boolean, integer);
drop function if exists _kw_cell(boolean, bigint);


-- ── 5. Restore grants ───────────────────────────────────────
revoke all on function _org_report_period_data(uuid, date, date)        from public, anon, authenticated;
revoke all on function _org_report_period_data(uuid, date, date, uuid[]) from public, anon, authenticated;
revoke all on function _dept_metrics(uuid, date, date, uuid, uuid)      from public, anon, authenticated;

grant execute on function org_report_data(uuid, date, date)                       to authenticated;
grant execute on function org_report_data(uuid, date, date, uuid)                 to authenticated;
grant execute on function org_report_company_breakdown(uuid, date, date)          to authenticated;
grant execute on function org_report_department_breakdown(uuid, date, date, uuid) to authenticated;


-- ── 6. Post-conditions ──────────────────────────────────────
do $$
declare r record; n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname in ('_kw_cell', 'admin_org_summary');
  if n > 0 then
    raise exception 'rollback: % new function(s) survived the drop.', n;
  end if;

  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.prosrc
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname in ('_org_report_period_data', '_dept_metrics')
       and p.prosrc ~ 'bookings'
  loop
    if r.prosrc !~ 'service_line = ''financial''' then
      raise exception 'rollback: %(%) lost the M3 financial-line split. Do NOT leave it '
                      'like this — HR would be shown counselling.', r.proname, r.args;
    end if;
  end loop;

  raise notice 'rollback complete: floors reapplied to admin, M3 split intact.';
end $$;


-- ── AFTER ROLLBACK ───────────────────────────────────────────
-- Revert the admin.html changes too, or the page will call
-- org_report_data(..., p_client_safe) and admin_org_summary() and get
-- "function does not exist" on the Users tab and the account file:
--
--   git revert <the admin.html commit>
-- ============================================================
