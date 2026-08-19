-- ============================================================
-- Key Wellness — Department RPCs for the admin dashboard
--
-- Third and last leg of "onboard a client without the Supabase editor"
-- (organisations → companies/sites → departments). Backs the
-- "Departments" sub-tab on the admin Organisations tab.
--
-- Departments are a SEPARATE DIMENSION from the unit tree, not children
-- of it: a member's unit is their company/site leaf, and their
-- department is orthogonal to it (supabase_sedimosa_phase2_batch1.sql).
-- Each department belongs to exactly one unit, so the same department
-- name is duplicated per unit — the original seed applied one shared
-- list of 22 names across 6 Sedimosa units, which is why the live table
-- holds ~161 rows spanning only ~38 distinct names.
--
-- That duplication shapes the API: the useful operations are "add
-- several at once" and "copy another unit's list", not "add one".
-- admin_dept_add() therefore takes an array, and admin_dept_copy_from()
-- reproduces what the seed did by hand.
--
-- Two reporting traps this file exists to make visible:
--
--   1. A PARENT COMPANY REPORTS NO DEPARTMENTS. Per
--      org_report_department_breakdown(), a unit with active sites is a
--      combined multi-site view and its departments never appear. So
--      departments added to such a unit are invisible in reporting —
--      the RPC says so instead of letting it look like it worked.
--
--   2. DEACTIVATING STRANDS MEMBERS. _dept_metrics() enumerates ACTIVE
--      departments plus an "Unassigned" bucket of members whose
--      department_id IS NULL. A member sitting on a deactivated
--      department matches neither, so they silently vanish from the
--      department breakdown (they stay in the unit totals). Closing a
--      department therefore reports how many members that affects, and
--      admin_dept_reassign_members() exists to move them somewhere real
--      — including to Unassigned, which IS reported.
--
-- Run in the Supabase SQL Editor. Safe to re-run (CREATE OR REPLACE).
-- PRODUCTION-LIVE on apply; additive, admin-gated, nothing reads these
-- functions until admin.html ships.
-- ROLLBACK: migrations/rollback-admin-depts-rpcs.sql
-- ============================================================


-- ── 1. Overview — one unit's departments ─────────────────────
create or replace function admin_depts_overview(p_unit_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',         d.id,
      'name',       d.name,
      'is_active',  d.is_active,
      'sort_order', d.sort_order,
      'created_at', d.created_at,
      'member_count', (select count(*) from profiles p where p.department_id = d.id),
      'deletable',  not exists (select 1 from profiles p where p.department_id = d.id)
    ) order by d.sort_order, d.name)
    from unit_departments d
    where d.unit_id = p_unit_id), '[]'::jsonb);
end;
$$;


-- ── 2. Add one or many ───────────────────────────────────────
-- Takes an array so a pasted list is one call. Trims, drops blanks,
-- de-duplicates within the array AND against what the unit already has
-- (both case-insensitively — the table's own unique(unit_id, name) is
-- case-sensitive and would happily accept "Finance" beside "finance").
-- Returns what it added and what it skipped rather than failing the lot.
create or replace function admin_dept_add(p_unit_id uuid, p_names text[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_unit    record;
  v_name    text;
  v_order   int;
  v_added   text[] := '{}';
  v_skipped text[] := '{}';
  v_note    text := '';
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  select * into v_unit from org_units where id = p_unit_id;
  if not found then raise exception 'company or site not found'; end if;
  if p_names is null or array_length(p_names, 1) is null then
    raise exception 'enter at least one department name';
  end if;

  -- Trap 1: departments on a combined multi-site view are never reported.
  if exists (select 1 from org_units where parent_unit_id = p_unit_id and is_active) then
    v_note := format(' Note: %s has active sites, so it reports as a combined multi-site view — departments added here will not appear in reports. Add them to the individual sites instead.', v_unit.name);
  end if;

  select coalesce(max(sort_order), 0) into v_order
  from unit_departments where unit_id = p_unit_id;

  foreach v_name in array p_names loop
    v_name := btrim(v_name);
    continue when v_name = '';

    if exists (select 1 from unit_departments
               where unit_id = p_unit_id and lower(name) = lower(v_name))
       or lower(v_name) = any (select lower(x) from unnest(v_added) x) then
      v_skipped := v_skipped || v_name;
      continue;
    end if;

    v_order := v_order + 10;
    insert into unit_departments (unit_id, name, sort_order) values (p_unit_id, v_name, v_order);
    v_added := v_added || v_name;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'added',   coalesce(array_length(v_added, 1), 0),
    'skipped', to_jsonb(v_skipped),
    'msg', format('%s department(s) added to %s', coalesce(array_length(v_added, 1), 0), v_unit.name)
        || case when coalesce(array_length(v_skipped, 1), 0) > 0
                then format('. %s already existed and were skipped: %s',
                            array_length(v_skipped, 1), array_to_string(v_skipped, ', '))
                else '' end
        || case when v_note <> '' then '.' || v_note else '' end);
end;
$$;


-- ── 3. Copy another unit's list ──────────────────────────────
-- What the original seed did by hand, for the common case of a shared
-- department list across sites. Copies ACTIVE departments only, keeps
-- their order, and skips names the target already has.
create or replace function admin_dept_copy_from(p_target_unit_id uuid, p_source_unit_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_target record;
  v_source record;
  v_names  text[];
  v_res    jsonb;
begin
  if not is_admin() then raise exception 'not authorised'; end if;
  if p_target_unit_id = p_source_unit_id then
    raise exception 'pick a different company or site to copy from';
  end if;

  select * into v_target from org_units where id = p_target_unit_id;
  if not found then raise exception 'destination company or site not found'; end if;
  select * into v_source from org_units where id = p_source_unit_id;
  if not found then raise exception 'source company or site not found'; end if;
  if v_source.org_id <> v_target.org_id then
    raise exception 'both must belong to the same organisation';
  end if;

  select array_agg(name order by sort_order, name) into v_names
  from unit_departments where unit_id = p_source_unit_id and is_active;

  if v_names is null then
    raise exception '% has no active departments to copy', v_source.name;
  end if;

  v_res := admin_dept_add(p_target_unit_id, v_names);

  return jsonb_build_object('ok', true, 'added', v_res->'added', 'skipped', v_res->'skipped',
    'msg', format('Copied from %s — ', v_source.name) || (v_res->>'msg'));
end;
$$;


-- ── 4. Rename ────────────────────────────────────────────────
create or replace function admin_dept_rename(p_dept_id uuid, p_name text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_dept record;
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  select * into v_dept from unit_departments where id = p_dept_id;
  if not found then raise exception 'department not found'; end if;
  if length(v_name) < 2 then raise exception 'enter the department name'; end if;
  if exists (select 1 from unit_departments
             where unit_id = v_dept.unit_id and lower(name) = lower(v_name) and id <> p_dept_id) then
    raise exception '"%" already exists in this company or site', v_name;
  end if;

  update unit_departments set name = v_name where id = p_dept_id;
  return jsonb_build_object('ok', true, 'msg', 'Renamed to ' || v_name);
end;
$$;


-- ── 5. Activate / deactivate ─────────────────────────────────
-- Trap 2: report the members this strands out of the breakdown.
create or replace function admin_dept_set_active(p_dept_id uuid, p_is_active boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_dept    record;
  v_members int;
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  select * into v_dept from unit_departments where id = p_dept_id;
  if not found then raise exception 'department not found'; end if;

  update unit_departments set is_active = coalesce(p_is_active, true) where id = p_dept_id;
  select count(*) into v_members from profiles where department_id = p_dept_id;

  return jsonb_build_object('ok', true, 'member_count', v_members,
    'msg', format('%s %s', v_dept.name, case when p_is_active then 'reopened' else 'closed' end)
        || case when not p_is_active and v_members > 0
                then format('. %s member(s) are still on it and now fall out of the department breakdown entirely — move them to another department, or to Unassigned.', v_members)
                else '' end);
end;
$$;


-- ── 6. Reorder within the unit ───────────────────────────────
create or replace function admin_dept_move(p_dept_id uuid, p_direction text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_dept record;
  v_ids  uuid[];
  v_pos  int;
  v_swap int;
  v_tmp  uuid;
  i      int;
begin
  if not is_admin() then raise exception 'not authorised'; end if;
  if lower(coalesce(p_direction, '')) not in ('up', 'down') then
    raise exception 'direction must be up or down';
  end if;

  select * into v_dept from unit_departments where id = p_dept_id;
  if not found then raise exception 'department not found'; end if;

  select array_agg(id order by sort_order, name) into v_ids
  from unit_departments where unit_id = v_dept.unit_id;

  v_pos  := array_position(v_ids, p_dept_id);
  v_swap := case when lower(p_direction) = 'up' then v_pos - 1 else v_pos + 1 end;

  if v_swap < 1 or v_swap > array_length(v_ids, 1) then
    return jsonb_build_object('ok', true, 'msg', format('%s is already %s',
      v_dept.name, case when lower(p_direction) = 'up' then 'first' else 'last' end));
  end if;

  v_tmp         := v_ids[v_pos];
  v_ids[v_pos]  := v_ids[v_swap];
  v_ids[v_swap] := v_tmp;

  for i in 1 .. array_length(v_ids, 1) loop
    update unit_departments set sort_order = i * 10 where id = v_ids[i];
  end loop;

  return jsonb_build_object('ok', true, 'msg', format('%s moved %s', v_dept.name, lower(p_direction)));
end;
$$;


-- ── 7. Move this department's members somewhere else ─────────
-- p_to_dept_id null = Unassigned, which is a REAL reported bucket (see
-- trap 2). The destination must belong to the same unit, otherwise a
-- member would end up on a department their own site does not have.
create or replace function admin_dept_reassign_members(p_dept_id uuid, p_to_dept_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_dept    record;
  v_to      record;
  -- plain text, not v_to.name: with p_to_dept_id null the record is never
  -- assigned, and touching a field of an unassigned record raises 55000.
  v_to_name text := 'Unassigned';
  v_n       int;
begin
  if not is_admin() then raise exception 'not authorised'; end if;
  if p_dept_id = p_to_dept_id then raise exception 'pick a different department'; end if;

  select * into v_dept from unit_departments where id = p_dept_id;
  if not found then raise exception 'department not found'; end if;

  if p_to_dept_id is not null then
    select * into v_to from unit_departments where id = p_to_dept_id;
    if not found then raise exception 'destination department not found'; end if;
    if v_to.unit_id <> v_dept.unit_id then
      raise exception 'that department belongs to a different company or site';
    end if;
    v_to_name := v_to.name;
  end if;

  update profiles set department_id = p_to_dept_id where department_id = p_dept_id;
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'moved', v_n,
    'msg', format('%s member(s) moved from %s to %s', v_n, v_dept.name, v_to_name));
end;
$$;


-- ── 8. Delete an unused department ───────────────────────────
create or replace function admin_dept_delete(p_dept_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_dept record;
  v_n    int;
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  select * into v_dept from unit_departments where id = p_dept_id;
  if not found then raise exception 'department not found'; end if;

  select count(*) into v_n from profiles where department_id = p_dept_id;
  if v_n > 0 then
    raise exception 'cannot delete "%" — % member(s) are on it. Move them to another department (or to Unassigned) first, or just close it.', v_dept.name, v_n;
  end if;

  delete from unit_departments where id = p_dept_id;
  return jsonb_build_object('ok', true, 'msg', v_dept.name || ' deleted');
end;
$$;


-- ── 9. Grants ────────────────────────────────────────────────
revoke all on function admin_depts_overview(uuid)               from public, anon;
revoke all on function admin_dept_add(uuid, text[])             from public, anon;
revoke all on function admin_dept_copy_from(uuid, uuid)         from public, anon;
revoke all on function admin_dept_rename(uuid, text)            from public, anon;
revoke all on function admin_dept_set_active(uuid, boolean)     from public, anon;
revoke all on function admin_dept_move(uuid, text)              from public, anon;
revoke all on function admin_dept_reassign_members(uuid, uuid)  from public, anon;
revoke all on function admin_dept_delete(uuid)                  from public, anon;

grant execute on function admin_depts_overview(uuid)              to authenticated;
grant execute on function admin_dept_add(uuid, text[])            to authenticated;
grant execute on function admin_dept_copy_from(uuid, uuid)        to authenticated;
grant execute on function admin_dept_rename(uuid, text)           to authenticated;
grant execute on function admin_dept_set_active(uuid, boolean)    to authenticated;
grant execute on function admin_dept_move(uuid, text)             to authenticated;
grant execute on function admin_dept_reassign_members(uuid, uuid) to authenticated;
grant execute on function admin_dept_delete(uuid)                 to authenticated;


-- ── VERIFICATION ─────────────────────────────────────────────
-- SQL Editor (runs as postgres; is_admin() is false there, so every
-- function should REFUSE — that refusal is itself the check):
--   select admin_depts_overview('<jwaneng uuid>');   -- expect: not authorised
--
-- Browser console, logged in as an admin:
--   const org = (await sb.rpc('admin_orgs_overview')).data.find(o=>o.name==='Sedimosa');
--   const units = (await sb.rpc('admin_units_overview', {p_org_id: org.id})).data;
--   await sb.rpc('admin_depts_overview', {p_unit_id: units.find(u=>u.name==='Jwaneng').id});
-- ============================================================
