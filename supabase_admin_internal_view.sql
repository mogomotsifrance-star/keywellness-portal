-- ============================================================
-- Key Wellness — the internal (unsuppressed) admin view
--
-- Rollback: migrations/rollback-admin-internal-view.sql
--
-- ══ WHAT THIS FIXES ════════════════════════════════════════
--
-- The base-5 floor and the <3 cell floor exist so that a report handed to
-- an EMPLOYER cannot name a person. Key Wellness is not the employer. We
-- hold the individual records already — admin reads profiles, assessments
-- and checkins directly under RLS — so a floor applied to us protects
-- nobody and only stops us servicing the client.
--
-- Today BOPEU (2 members) returns insufficient_cohort to admin exactly as
-- it does to HR: no organisation summary on the Users tab, no report, no
-- account file. That is the bug.
--
-- This is not a new principle. It is the one already taken for the
-- financial indicators — admin_org_indicators(p_client_safe) — extended to
-- the report and the breakdowns, which predate that decision. (org_overview
-- is left alone; section 7 explains why.)
--
-- ══ WHAT DOES NOT CHANGE ═══════════════════════════════════
--
--   HR can never obtain the internal view. Every entry point forces
--   p_client_safe := true when the caller is not is_admin().
--
--   A PUBLISHED report is always the client-safe snapshot.
--   publish_org_report passes true explicitly, and still refuses to
--   publish below the base-5 floor.
--
--   PSYCHOSOCIAL stays floored for everyone, always. Decided 25 Aug and
--   not reopened by this file: theme_counts() is untouched and keeps its
--   hard floor of 5 with no internal view.
--
--   Every existing caller keeps today's behaviour. The 3-arg and 4-arg
--   org_report_data and the 3-arg/4-arg breakdowns are retained as
--   wrappers that pass client-safe = true; org_overview() is not touched
--   at all. The internal view is strictly new surface, reached only by
--   passing the new argument or calling admin_org_summary().
--
-- ══ TWO THINGS FOUND WHILE WRITING THIS ════════════════════
--
-- 1. THE REPO DOES NOT DESCRIBE WHAT IS DEPLOYED.
--    supabase_org_report_data_v4.sql is NOT the live body of
--    _org_report_period_data. M3 Part 2 rewrote the live function in
--    place, via pg_get_functiondef, to count the financial line only.
--    Re-running the v4 file would silently undo that and put counselling
--    bookings back into HR's session totals.
--
--    So this file patches the LIVE definition textually, the same way M3
--    did, rather than re-creating it from source — and asserts the M3
--    split is present before it starts and still present when it ends.
--    Verification step 8 then dumps the patched definition so it can be
--    committed as the real source of truth and this trap closed for good.
--
-- 2. _dept_metrics COUNTS PSYCHOSOCIAL INTO HR's DEPARTMENT TOTALS.
--    M3 Part 2 patched _org_report_period_data by name. _dept_metrics was
--    added by v5 (departments), reads `bookings` unsplit, and was not in
--    that sweep. It is latent, not live — there are 0 psychosocial
--    bookings today — but it becomes a real disclosure the day Karabo or
--    Nicola takes one. Section 3 closes it while patching the same
--    function, because leaving it for later means shipping HR a number
--    that silently includes counselling.
--
-- ══ ONE THING THAT DOES TIGHTEN, ON PURPOSE ════════════════
--
-- org_report_data(org, start, end) — the 3-arg form — used to authorise on
-- `is_admin() or employer_org() = p_org_id`, with no check that the caller
-- is whole-org scoped. The 4-arg form called with a null unit_id has always
-- required `hr_scoped_unit_ids() is null` as well. Same question, two
-- different answers, so a SITE-SCOPED HR manager could read whole-org
-- figures by calling the 3-arg version.
--
-- Both now route to one body carrying the stricter check. Nothing in the
-- app is affected — only admin.html calls these, and the employer dashboard
-- reads the published snapshot, never the live RPC — but a site-scoped HR
-- manager driving the API by hand loses an org-wide read they should never
-- have had. Recorded here rather than fixed silently.
--
-- ══ PREDICTION, WRITTEN BEFORE THE APPLY ═══════════════════
--
--   Sedimosa (10) and Test Co (22): every existing screen identical.
--   BOPEU (2): admin gains a full report and summary; HR still gets
--     insufficient_cohort; publish still refuses.
--   Hollard (0): admin gets a report of zeroes, not a refusal.
-- ============================================================


-- ── 0. Preconditions ────────────────────────────────────────
do $$
declare v_oid oid; v_src text;
begin
  select p.oid, p.prosrc into v_oid, v_src
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = '_org_report_period_data'
     and pg_get_function_identity_arguments(p.oid)
         = 'p_org_id uuid, p_start date, p_end date, p_unit_ids uuid[]';

  if v_oid is null then
    raise exception 'precondition: _org_report_period_data(uuid,date,date,uuid[]) is missing';
  end if;

  if v_src !~ 'service_line = ''financial''' then
    raise exception 'precondition: the M3 financial-line split is NOT present on the live '
                    '_org_report_period_data. Either M3 Part 2 never ran, or something has '
                    'since re-created this function from supabase_org_report_data_v4.sql and '
                    'undone it. Do not patch on top of that — establish which, first.';
  end if;

  if to_regprocedure('public.is_admin()') is null then
    raise exception 'precondition: is_admin() is missing';
  end if;

  raise notice 'precondition: live _org_report_period_data found, M3 split present.';
end $$;


-- ── 1. The cell gate, as a function of who is asking ────────
-- Mirrors _suppress_count exactly when client-safe, and is a pass-through
-- when it is not. The flag comes FIRST deliberately: it makes the call-site
-- rewrite in sections 2 and 3 a plain textual substitution of
-- `_suppress_count(` for `_kw_cell(p_client_safe, `, which stays correct
-- however many nested parentheses the argument contains.
--
-- Pure — reads no table — so the REVOKE rule in CLAUDE.md does not bite.
-- Revoked anyway: nothing outside the report bodies has a use for it.
create or replace function _kw_cell(p_client_safe boolean, v integer)
returns jsonb language sql immutable as $$
  select case
    when v is null               then jsonb_build_object('value', 0,    'suppressed', false)
    when p_client_safe and v < 3 then jsonb_build_object('value', null, 'suppressed', true)
    else                              jsonb_build_object('value', v,    'suppressed', false)
  end;
$$;

create or replace function _kw_cell(p_client_safe boolean, v bigint)
returns jsonb language sql immutable as $$
  select case
    when v is null               then jsonb_build_object('value', 0,    'suppressed', false)
    when p_client_safe and v < 3 then jsonb_build_object('value', null, 'suppressed', true)
    else                              jsonb_build_object('value', v,    'suppressed', false)
  end;
$$;

revoke all on function _kw_cell(boolean, integer) from public, anon, authenticated;
revoke all on function _kw_cell(boolean, bigint)  from public, anon, authenticated;


-- ── 2. _org_report_period_data gains the flag ───────────────
-- Patched from the LIVE definition, never from the v4 file. See note 1.
do $$
declare
  v_def text;
  v_new text;
  n_sig int; n_base int; n_cell int; n_cross int;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = '_org_report_period_data'
     and pg_get_function_identity_arguments(p.oid)
         = 'p_org_id uuid, p_start date, p_end date, p_unit_ids uuid[]';

  -- Counted BEFORE substituting, so a body that has moved on since this
  -- file was written fails loudly instead of being half-patched.
  n_sig   := (select count(*) from regexp_matches(v_def, 'p_unit_ids uuid\[\]\)', 'g'));
  n_base  := (select count(*) from regexp_matches(v_def, 'if n < 5 then', 'g'));
  n_cell  := (select count(*) from regexp_matches(v_def, '_suppress_count\(', 'g'));
  n_cross := (select count(*) from regexp_matches(v_def, '\(cnt < 3\) as cell_suppressed', 'g'));

  if n_sig <> 1 or n_base <> 1 or n_cross <> 1 or n_cell = 0 then
    raise exception 'the live body no longer matches what this patch expects '
                    '(signature %, base gate %, cell gates %, cross-tab gate %). '
                    'Re-read it and adjust the substitutions BY HAND.',
                    n_sig, n_base, n_cell, n_cross;
  end if;

  v_new := replace(v_def, 'p_unit_ids uuid[])', 'p_unit_ids uuid[], p_client_safe boolean)');
  v_new := replace(v_new, 'if n < 5 then',      'if p_client_safe and n < 5 then');
  v_new := replace(v_new, '_suppress_count(',   '_kw_cell(p_client_safe, ');
  v_new := replace(v_new, '(cnt < 3) as cell_suppressed',
                          '(p_client_safe and cnt < 3) as cell_suppressed');

  execute v_new;
  raise notice '_org_report_period_data: patched (% cell gates + base + cross-tab).', n_cell;
end $$;

-- New signature, so a fresh PUBLIC grant. Revoked here, beside the create.
revoke all on function _org_report_period_data(uuid, date, date, uuid[], boolean)
  from public, anon, authenticated;


-- ── 3. _dept_metrics gains the flag, and the M3 split ───────
-- See note 2. The two `from bookings b` reads become the financial line
-- only, matching what M3 Part 2 did to the org-level report.
do $$
declare
  v_def text;
  v_new text;
  n_sig int; n_base int; n_cell int; n_book int;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = '_dept_metrics'
     and pg_get_function_identity_arguments(p.oid)
         = 'p_org_id uuid, p_start date, p_end date, p_unit_id uuid, p_dept_id uuid';

  if v_def is null then
    raise exception 'precondition: _dept_metrics(uuid,date,date,uuid,uuid) is missing';
  end if;

  -- Idempotence: if the split is somehow already there, do not double-wrap.
  v_def := replace(v_def,
    '(select * from bookings where service_line = ''financial'') b', 'bookings b');

  n_sig  := (select count(*) from regexp_matches(v_def, 'p_dept_id uuid\)', 'g'));
  n_base := (select count(*) from regexp_matches(v_def, 'if n < 5 then', 'g'));
  n_cell := (select count(*) from regexp_matches(v_def, '_suppress_count\(', 'g'));
  n_book := (select count(*) from regexp_matches(v_def, 'from bookings b', 'g'));

  if n_sig <> 1 or n_base <> 1 or n_cell = 0 or n_book = 0 then
    raise exception '_dept_metrics no longer matches what this patch expects '
                    '(signature %, base gate %, cell gates %, bookings reads %).',
                    n_sig, n_base, n_cell, n_book;
  end if;

  v_new := replace(v_def, 'p_dept_id uuid)',   'p_dept_id uuid, p_client_safe boolean)');
  v_new := replace(v_new, 'if n < 5 then',     'if p_client_safe and n < 5 then');
  v_new := replace(v_new, '_suppress_count(',  '_kw_cell(p_client_safe, ');
  v_new := replace(v_new, 'from bookings b',
                          'from (select * from bookings where service_line = ''financial'') b');

  execute v_new;
  raise notice '_dept_metrics: patched (% cell gates) and split to the financial line (% reads).',
               n_cell, n_book;
end $$;

-- Adding a parameter creates a NEW function, and Postgres grants EXECUTE on
-- every new function to PUBLIC. The 6-arg _dept_metrics is therefore born
-- readable by anon — a SECURITY DEFINER read of every department's real
-- counts, floors and all. Revoked in the same step that creates it, per the
-- rule in CLAUDE.md. (`create or replace` of an EXISTING signature keeps its
-- ACL; only a new signature resets it. That difference is the whole trap.)
revoke all on function _dept_metrics(uuid, date, date, uuid, uuid, boolean)
  from public, anon, authenticated;


-- ── 4. The org-wide period wrapper ──────────────────────────
-- The pre-existing 3-arg wrapper pointed at the 4-arg body that section 9
-- drops. Repointed here rather than left dangling. Nothing else calls it —
-- org_report_data goes straight to the 5-arg form — but it is kept because
-- dropping a function this file did not create is not this file's business.
create or replace function _org_report_period_data(p_org_id uuid, p_start date, p_end date)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select _org_report_period_data(p_org_id, p_start, p_end, null::uuid[], true);
$$;

-- Existing signature, so its ACL survived the replace — belt and braces.
revoke all on function _org_report_period_data(uuid, date, date)
  from public, anon, authenticated;


-- ── 5. org_report_data ──────────────────────────────────────
-- The 5-arg form is now the only body. p_unit_id null => org-wide.
-- Non-admins are forced client-safe here, so no wrapper below can be a
-- way round it and no future caller can forget.
create or replace function org_report_data(p_org_id uuid, p_start date, p_end date,
                                           p_unit_id uuid, p_client_safe boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids      uuid[];
  v_safe     boolean;
  v_current  jsonb;
  v_previous jsonb;
  v_days     int;
  v_prev_start date;
  v_prev_end   date;
begin
  if p_end < p_start then
    raise exception 'period_end must not be before period_start';
  end if;

  -- The floor is only ever lowered for Key Wellness. An HR manager who
  -- passes false gets the client-safe report regardless.
  v_safe := coalesce(p_client_safe, true) or not is_admin();

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

  v_current := _org_report_period_data(p_org_id, p_start, p_end, v_ids, v_safe);
  if coalesce((v_current->>'insufficient_cohort')::boolean, false) then
    return jsonb_build_object('insufficient_cohort', true, 'unit_id', p_unit_id,
                              'client_safe', v_safe);
  end if;

  v_days       := p_end - p_start;
  v_prev_end   := p_start - 1;
  v_prev_start := v_prev_end - v_days;
  v_previous   := _org_report_period_data(p_org_id, v_prev_start, v_prev_end, v_ids, v_safe);

  return v_current || jsonb_build_object('previous_period', v_previous,
                                         'unit_id',     p_unit_id,
                                         'client_safe', v_safe);
end;
$$;

-- The two signatures every existing caller already uses. Unchanged
-- behaviour: client-safe, always.
create or replace function org_report_data(p_org_id uuid, p_start date, p_end date)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select org_report_data(p_org_id, p_start, p_end, null::uuid, true);
$$;

create or replace function org_report_data(p_org_id uuid, p_start date, p_end date, p_unit_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select org_report_data(p_org_id, p_start, p_end, p_unit_id, true);
$$;


-- ── 6. The breakdowns ───────────────────────────────────────
create or replace function org_report_company_breakdown(p_org_id uuid, p_start date, p_end date,
                                                        p_client_safe boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row       record;
  v_ids       uuid[];
  v_safe      boolean;
  v_report    jsonb;
  v_companies jsonb := '[]'::jsonb;
  v_unassigned int;
begin
  -- Only admin or a whole-org employer (fund Wellness Manager).
  if not (is_admin() or (coalesce(employer_org() = p_org_id, false)
                         and hr_scoped_unit_ids() is null)) then
    raise exception 'not authorised';
  end if;
  if p_end < p_start then
    raise exception 'period_end must not be before period_start';
  end if;

  v_safe := coalesce(p_client_safe, true) or not is_admin();

  for v_row in
    select id, name from org_units
    where org_id = p_org_id and parent_unit_id is null and is_active = true
    order by sort_order, name
  loop
    select array_agg(d.id) into v_ids from unit_descendants(v_row.id) d;
    v_report := _org_report_period_data(p_org_id, p_start, p_end, v_ids, v_safe);
    if coalesce((v_report->>'insufficient_cohort')::boolean, false) then
      v_companies := v_companies || jsonb_build_array(jsonb_build_object(
        'unit_id', v_row.id, 'name', v_row.name, 'suppressed', true));
    else
      -- Compact row for the comparison table; full drill-down is available
      -- via org_report_data(p_org_id, p_start, p_end, unit_id, client_safe).
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
    'client_safe',         v_safe,
    'period_start',        p_start,
    'period_end',          p_end
  );
end;
$$;

create or replace function org_report_company_breakdown(p_org_id uuid, p_start date, p_end date)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select org_report_company_breakdown(p_org_id, p_start, p_end, true);
$$;

create or replace function org_report_department_breakdown(p_org_id uuid, p_start date, p_end date,
                                                           p_unit_id uuid, p_client_safe boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row          record;
  v_safe         boolean;
  v_departments  jsonb := '[]'::jsonb;
  v_has_children boolean;
begin
  if p_end < p_start then
    raise exception 'period_end must not be before period_start';
  end if;
  if p_unit_id is null then
    raise exception 'a unit_id is required for the department breakdown';
  end if;

  -- Scope validation (server-side): admin / whole-org manager -> any unit in
  -- the org; company manager -> only their own unit or a descendant.
  if not hr_unit_in_scope(p_org_id, p_unit_id) then
    raise exception 'not authorised';
  end if;

  v_safe := coalesce(p_client_safe, true) or not is_admin();

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
      || _dept_metrics(p_org_id, p_start, p_end, p_unit_id, v_row.id, v_safe));
  end loop;

  -- "Unassigned" row: unit members with no department (guard applies too).
  v_departments := v_departments || jsonb_build_array(
    jsonb_build_object('department_id', null, 'name', 'Unassigned')
    || _dept_metrics(p_org_id, p_start, p_end, p_unit_id, null, v_safe));

  return jsonb_build_object(
    'department_breakdown_available', true,
    'unit_id',      p_unit_id,
    'departments',  v_departments,
    'client_safe',  v_safe,
    'period_start', p_start,
    'period_end',   p_end);
end;
$$;

create or replace function org_report_department_breakdown(p_org_id uuid, p_start date, p_end date,
                                                           p_unit_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select org_report_department_breakdown(p_org_id, p_start, p_end, p_unit_id, true);
$$;


-- ── 7. The Users-tab summary for admin ──────────────────────
-- org_overview() is deliberately NOT touched. It is a ~9KB body carrying
-- five separate floors (n<5, three v_assessed_n<3, count(*)<3,
-- participants<3), it is what index.html and employer.html call, and the
-- text-surgery trick used above cannot be applied to it safely: Postgres
-- replace() substitutes EVERY occurrence, and `begin` and `< 3` both occur
-- in places that must not change. Patching it blind is how you ship HR an
-- unsuppressed average.
--
-- The admin banner needs three numbers. So it gets three numbers, from a
-- small function that is admin-only by construction and has no floors to
-- get wrong. org_overview keeps its floors for everyone, unchanged.
create or replace function admin_org_summary(p_org_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_n        int;
  v_assessed int;
  v_avg      numeric;
begin
  if not is_admin() then
    raise exception 'not authorised';
  end if;

  select count(*) into v_n from profiles p where p.org_id = p_org_id;

  select count(distinct a.user_id), avg(a.score)
    into v_assessed, v_avg
    from assessments a
    join profiles p on p.id = a.user_id
   where p.org_id = p_org_id;

  return jsonb_build_object(
    'n_employees',       v_n,
    'n_assessed',        coalesce(v_assessed, 0),
    'participation_pct', case when v_n > 0
                              then round(100.0 * coalesce(v_assessed, 0)::numeric / v_n, 1)
                              else null end,
    'avg_score',         round(v_avg, 1),
    'client_safe',       false
  );
end;
$$;


-- ── 8. Publishing is always the client-safe snapshot ────────
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

  -- true, explicitly and always. An admin may READ an organisation
  -- unsuppressed; what gets handed to the employer never is.
  v_snapshot := org_report_data(v_row.org_id, v_row.period_start, v_row.period_end,
                                v_row.unit_id, true);

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


-- ── 9. Grants ───────────────────────────────────────────────
-- The top-level RPCs are gated by the check inside them, not by the grant.
revoke all on function org_report_data(uuid, date, date, uuid, boolean)              from public, anon;
revoke all on function org_report_company_breakdown(uuid, date, date, boolean)       from public, anon;
revoke all on function org_report_department_breakdown(uuid, date, date, uuid, boolean) from public, anon;
revoke all on function admin_org_summary(uuid)                                        from public, anon;

grant execute on function org_report_data(uuid, date, date, uuid, boolean)              to authenticated;
grant execute on function org_report_company_breakdown(uuid, date, date, boolean)       to authenticated;
grant execute on function org_report_department_breakdown(uuid, date, date, uuid, boolean) to authenticated;
grant execute on function admin_org_summary(uuid)                                       to authenticated;

-- The old signatures are retained as client-safe wrappers, so their grants
-- must survive a re-create.
--
-- REVOKE FIRST, and not as a formality. These four used to carry the authz
-- check in their own body; now they are thin delegators to the 5-argument
-- form, so their source no longer names a gate. Two things follow:
--
--   * PUBLIC still holds EXECUTE on them (CREATE OR REPLACE does not take a
--     grant away, and nothing here ever revoked it), so anon could call them.
--     No data escapes — the callee raises 'not authorised' for a caller who is
--     neither is_admin() nor the org's employer_org() — but a reachable
--     SECURITY DEFINER entry point is not something to leave resting on the
--     gate one call further down.
--
--   * The CLAUDE.md definer sweep reports them as ungated, because it matches
--     on gate NAMES in prosrc and a delegator contains none. That sweep was
--     clean before this migration.
--
--     THE REVOKE BELOW DOES NOT SILENCE THAT. The sweep flags anything
--     reachable by anon OR authenticated, and these stay granted to
--     authenticated. They are recorded in CLAUDE.md as known delegators
--     instead — the sweep is meant to make somebody prove a definer function
--     is safe, and the honest answer here is "the callee gates it", not a
--     grant removed until the warning goes away.
--
-- Verified 28 Aug 2026: nothing calls these overloads from the front end —
-- admin.html builds the 5-argument form, employer.html calls none of them.
revoke all on function org_report_data(uuid, date, date)                       from public, anon;
revoke all on function org_report_data(uuid, date, date, uuid)                 from public, anon;
revoke all on function org_report_company_breakdown(uuid, date, date)          from public, anon;
revoke all on function org_report_department_breakdown(uuid, date, date, uuid) from public, anon;

grant execute on function org_report_data(uuid, date, date)                       to authenticated;
grant execute on function org_report_data(uuid, date, date, uuid)                 to authenticated;
grant execute on function org_report_company_breakdown(uuid, date, date)          to authenticated;
grant execute on function org_report_department_breakdown(uuid, date, date, uuid) to authenticated;

-- Superseded internal signatures: nothing may reach them any more.
drop function if exists _org_report_period_data(uuid, date, date, uuid[]);
drop function if exists _dept_metrics(uuid, date, date, uuid, uuid);


-- ── 10. Post-conditions ─────────────────────────────────────
do $$
declare r record; n int;
begin
  -- (a) The M3 split survived both patches.
  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.prosrc
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname in ('_org_report_period_data', '_dept_metrics')
       and p.prosrc ~ 'bookings'
  loop
    if r.prosrc !~ 'service_line = ''financial''' then
      raise exception 'POST: %(%) reads bookings without the financial-line split. '
                      'HR would be shown counselling. Roll back.', r.proname, r.args;
    end if;
  end loop;
  raise notice 'POST: the financial-line split holds on every bookings reader patched here.';

  -- (b) Nothing internal is reachable by anon or authenticated.
  -- Names the offender: adding a parameter creates a NEW function with a
  -- fresh PUBLIC grant, and the signature you forgot is the one you cannot
  -- guess from a count.
  n := 0;
  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname in ('_org_report_period_data', '_dept_metrics', '_kw_cell')
       and (has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  loop
    n := n + 1;
    raise warning 'POST: %(%) is still executable by anon/authenticated — '
                  'it needs a revoke beside its create.', r.proname, r.args;
  end loop;
  if n > 0 then
    raise exception 'POST: % internal helper(s) still executable by anon/authenticated '
                    '(named in the warnings above).', n;
  end if;
  raise notice 'POST: internal helpers are revoked.';

  -- (c) theme_counts was not touched.
  perform 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'theme_counts'
     and p.prosrc ~ 'v_floor int := 5';
  if not found then
    raise exception 'POST: theme_counts no longer has its hard floor of 5.';
  end if;
  raise notice 'POST: theme_counts is unchanged — psychosocial stays floored for everyone.';

  -- (d) No SECURITY DEFINER entry point here is reachable by anon.
  -- The back-compat overloads are the trap: they were gated in their own body
  -- before this migration and are thin delegators after it, so they read as
  -- ungated to the CLAUDE.md sweep while keeping the PUBLIC grant they were
  -- created with. Nothing leaks — the callee refuses — but an anon-reachable
  -- definer function that relies on a gate one call down is not the contract
  -- this project works to.
  n := 0;
  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.prosecdef
       and p.proname in ('org_report_data', 'org_report_company_breakdown',
                         'org_report_department_breakdown', 'admin_org_summary')
       and has_function_privilege('anon', p.oid, 'EXECUTE')
  loop
    n := n + 1;
    raise warning 'POST: %(%) is executable by anon — it needs a revoke beside '
                  'its grant.', r.proname, r.args;
  end loop;
  if n > 0 then
    raise exception 'POST: % report RPC(s) reachable with the published anon key '
                    '(named in the warnings above).', n;
  end if;
  raise notice 'POST: no report RPC is reachable by anon.';
end $$;


-- ── VERIFICATION ─────────────────────────────────────────────
-- Run in the browser console as a REAL session, not the SQL Editor —
-- is_admin() is false for postgres, so the SQL Editor proves nothing here
-- except that the functions correctly refuse.
--
-- 1. NO CHANGE for the org that already worked. As admin, on Sedimosa:
--      a = await sb.rpc('org_report_data',{p_org_id:S,p_start:s,p_end:e})
--      b = await sb.rpc('org_report_data',{p_org_id:S,p_start:s,p_end:e,
--                                          p_unit_id:null,p_client_safe:true})
--    a.data and b.data must be identical apart from the added
--    client_safe/unit_id keys.
--
-- 2. THE FIX. As admin, on BOPEU (2 members):
--      old: {insufficient_cohort:true}
--      new: p_client_safe:false -> a full report, real counts, no '·' cells.
--
-- 3. HR CANNOT REACH IT. As the Sedimosa HR manager, passing
--    p_client_safe:false must still return the suppressed payload
--    (client_safe:true in the response) — NOT an error, and NOT real cells.
--
-- 4. PUBLISHING IS UNCHANGED. Publish a Sedimosa report and diff
--    data_snapshot against a fresh client-safe call: identical. Attempt to
--    publish BOPEU: still 'cannot publish: fewer than 5 enrolled members'.
--
-- 5. org_overview IS UNCHANGED. As the Sedimosa HR manager and as a
--    member, the 1-arg org_overview payload must be byte-identical to
--    before this file. As admin on BOPEU it still returns suppressed:true
--    — that is correct; the Users-tab banner now reads admin_org_summary
--    instead. And admin_org_summary must raise 'not authorised' for HR.
--
-- 6. PRIVACY GREP on any payload an employer can obtain: no user_id, no
--    email, no name, no per-person financial values.
--
-- 7. Re-run the SECURITY DEFINER sweep from CLAUDE.md. _kw_cell,
--    _dept_metrics and _org_report_period_data must not appear;
--    admin_org_summary may, and is correctly gated by is_admin().
--
-- 8. CLOSE THE DRIFT TRAP (note 1). Once 1-7 pass, capture what is
--    actually deployed and commit it, so the next person is not reading a
--    file that describes a body Postgres no longer holds:
--
--      select pg_get_functiondef(p.oid)
--        from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
--       where ns.nspname = 'public'
--         and p.proname in ('_org_report_period_data','_dept_metrics')
--       order by p.proname;
--
--    Save the output as supabase_org_report_LIVE_BODY.sql and add a banner
--    to supabase_org_report_data_v4.sql and _v5_departments.sql saying they
--    are HISTORY, not the deployed definition, and must never be re-run.
-- ============================================================
