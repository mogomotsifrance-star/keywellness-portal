-- ============================================================
-- Key Wellness — Company/Unit RPCs for the admin dashboard
--
-- Backs the "Companies & Sites" sub-tab on the admin Organisations tab,
-- so the sub-org structure inside a client organisation (Sedimosa's
-- Debswana → Jwaneng / Orapa / DCC, MCM, DPF, Mmila …) can be built and
-- maintained without SQL. Companion to supabase_admin_orgs_rpcs.sql.
--
-- `org_units` already has an `org_units_admin_all` RLS policy, so an
-- admin *could* write to it directly from the browser. These RPCs exist
-- anyway, because the structure carries rules RLS cannot express — and
-- every one of them is a way to silently break something live:
--
--   1. TWO LEVELS ONLY. index.html's kwUnitLabel() reads a leaf's parent
--      as "the company" and the leaf as "the site". A third level would
--      be navigable but mislabelled everywhere it is displayed. So a
--      parent must itself be top-level, and a unit with children cannot
--      be demoted to a child.
--
--   2. MEMBERS SIT ON LEAVES. kwRenderUnitPicker() only lets a member
--      choose a leaf. Giving a company its first site therefore strands
--      any member already recorded directly against that company: they
--      keep their unit, but no new member can be placed there. Allowed —
--      restructuring is legitimate — but never silently: the RPC returns
--      the stranded count and the UI confirms it first.
--
--   3. A PARENT LOSES ITS DEPARTMENT BREAKDOWN. Per
--      org_report_department_breakdown(), a unit with active children is
--      a combined multi-site view and reports no departments. Adding a
--      first site to a company that has departments turns that reporting
--      off, so the RPC reports the department count too.
--
--   4. AN INACTIVE PARENT HIDES ACTIVE CHILDREN. The member picker walks
--      down from active top-level units, so an active site under an
--      inactive company is unreachable — invisible but still assignable
--      in reporting. Deactivation therefore cascades to children, and
--      reactivating a site under an inactive company is refused.
--
-- Run in the Supabase SQL Editor. Safe to re-run (CREATE OR REPLACE).
-- PRODUCTION-LIVE on apply; additive, admin-gated, nothing reads these
-- functions until admin.html ships.
-- ROLLBACK: migrations/rollback-admin-units-rpcs.sql
-- ============================================================


-- ── 0. Dependency probe ──────────────────────────────────────
-- Every table with an FK to org_units. Internal helper — owner-only.
create or replace function admin_unit_has_dependents(p_unit_id uuid)
returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles         where org_unit_id   = p_unit_id)
      or exists (select 1 from org_units        where parent_unit_id = p_unit_id)
      or exists (select 1 from unit_departments where unit_id       = p_unit_id)
      or exists (select 1 from hr_unit_scope    where unit_id       = p_unit_id)
      or exists (select 1 from org_reports      where unit_id       = p_unit_id);
$$;


-- ── 1. Overview — one organisation's whole structure ─────────
-- Flat array in tree order (each company followed by its own sites), so
-- the tab can render it indented without rebuilding the tree client-side.
create or replace function admin_units_overview(p_org_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',             u.id,
      'name',           u.name,
      'parent_unit_id', u.parent_unit_id,
      'parent_name',    p.name,
      'is_active',      u.is_active,
      'sort_order',     u.sort_order,
      'created_at',     u.created_at,
      'member_count', (select count(*) from profiles         pr where pr.org_unit_id   = u.id),
      'child_count',  (select count(*) from org_units        c  where c.parent_unit_id = u.id),
      'dept_count',   (select count(*) from unit_departments d  where d.unit_id = u.id and d.is_active),
      'hr_scope_count',(select count(*) from hr_unit_scope   h  where h.unit_id = u.id),
      'report_count', (select count(*) from org_reports      r  where r.unit_id = u.id),
      'deletable',    not admin_unit_has_dependents(u.id)
    ) order by
        coalesce(p.sort_order, u.sort_order),   -- group each company…
        coalesce(p.name, u.name),
        (u.parent_unit_id is not null),         -- …company first, then its sites
        u.sort_order, u.name)
    from org_units u
    left join org_units p on p.id = u.parent_unit_id
    where u.org_id = p_org_id), '[]'::jsonb);
end;
$$;


-- ── 2. Create a company or a site ────────────────────────────
-- p_parent_unit_id null = a company (top level); otherwise a site under
-- that company. New units go to the end of their sibling group.
create or replace function admin_unit_create(
  p_org_id         uuid,
  p_name           text,
  p_parent_unit_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_name    text := btrim(coalesce(p_name, ''));
  v_id      uuid;
  v_order   int;
  v_parent  record;
  v_msg     text;
  v_note    text := '';
begin
  if not is_admin() then raise exception 'not authorised'; end if;
  if not exists (select 1 from organizations where id = p_org_id) then
    raise exception 'organisation not found';
  end if;
  if length(v_name) < 2 then raise exception 'enter the company or site name'; end if;
  if exists (select 1 from org_units where org_id = p_org_id and lower(name) = lower(v_name)) then
    raise exception '"%" already exists in this organisation', v_name;
  end if;

  if p_parent_unit_id is not null then
    select * into v_parent from org_units where id = p_parent_unit_id;
    if not found then raise exception 'parent company not found'; end if;
    if v_parent.org_id <> p_org_id then
      raise exception 'that company belongs to a different organisation';
    end if;
    -- Rule 1: two levels only.
    if v_parent.parent_unit_id is not null then
      raise exception '"%" is already a site. Sites cannot have sites of their own — pick a company instead.', v_parent.name;
    end if;

    -- Rules 2 and 3: report what giving this company its first site costs.
    if not exists (select 1 from org_units where parent_unit_id = v_parent.id) then
      v_note := (select case when count(*) > 0
                   then format(' %s member(s) are recorded directly against %s — they keep it, but new members must now choose a site.',
                               count(*), v_parent.name) else '' end
                 from profiles where org_unit_id = v_parent.id)
             || (select case when count(*) > 0
                   then format(' %s now reports as a combined multi-site view, so its %s department(s) no longer appear in reports.',
                               v_parent.name, count(*)) else '' end
                 from unit_departments where unit_id = v_parent.id and is_active);
    end if;
  end if;

  select coalesce(max(sort_order), 0) + 10 into v_order
  from org_units
  where org_id = p_org_id
    and coalesce(parent_unit_id, '00000000-0000-0000-0000-000000000000'::uuid)
      = coalesce(p_parent_unit_id, '00000000-0000-0000-0000-000000000000'::uuid);

  insert into org_units (org_id, parent_unit_id, name, is_active, sort_order)
  values (p_org_id, p_parent_unit_id, v_name, true, v_order)
  returning id into v_id;

  v_msg := case when p_parent_unit_id is null
                then format('Company "%s" added', v_name)
                else format('Site "%s" added under %s', v_name, v_parent.name) end;

  return jsonb_build_object('ok', true, 'id', v_id,
                            'msg', v_msg || case when v_note <> '' then '.' || v_note else '' end,
                            'note', nullif(btrim(v_note), ''));
end;
$$;


-- ── 3. Rename and/or move a unit ─────────────────────────────
-- p_parent_unit_id null promotes the unit to a company; a uuid makes it
-- a site of that company. is_active is deliberately NOT here — cascade
-- rules live in admin_unit_set_active().
create or replace function admin_unit_update(
  p_unit_id        uuid,
  p_name           text,
  p_parent_unit_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_name   text := btrim(coalesce(p_name, ''));
  v_unit   record;
  v_parent record;
  v_order  int;
  v_note   text := '';
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  select * into v_unit from org_units where id = p_unit_id;
  if not found then raise exception 'company or site not found'; end if;

  if length(v_name) < 2 then raise exception 'enter the company or site name'; end if;
  if exists (select 1 from org_units
             where org_id = v_unit.org_id and lower(name) = lower(v_name) and id <> p_unit_id) then
    raise exception '"%" already exists in this organisation', v_name;
  end if;

  if p_parent_unit_id is distinct from v_unit.parent_unit_id then
    if p_parent_unit_id = p_unit_id then
      raise exception 'a company cannot be its own parent';
    end if;
    -- Rule 1, the other direction: a unit with sites cannot become a site.
    if exists (select 1 from org_units where parent_unit_id = p_unit_id) then
      raise exception '"%" has its own sites. Move or remove those first.', v_unit.name;
    end if;

    if p_parent_unit_id is not null then
      select * into v_parent from org_units where id = p_parent_unit_id;
      if not found then raise exception 'parent company not found'; end if;
      if v_parent.org_id <> v_unit.org_id then
        raise exception 'that company belongs to a different organisation';
      end if;
      if v_parent.parent_unit_id is not null then
        raise exception '"%" is already a site. Sites cannot have sites of their own.', v_parent.name;
      end if;
      -- Rule 4 again: an active site under a closed company is unreachable.
      if not v_parent.is_active and v_unit.is_active then
        raise exception 'cannot move "%" under "%" — that company is closed, so the site would be invisible to members. Reopen it first, or close "%" too.',
          v_unit.name, v_parent.name, v_unit.name;
      end if;

      if not exists (select 1 from org_units where parent_unit_id = v_parent.id) then
        v_note := (select case when count(*) > 0
                     then format(' %s member(s) recorded directly against %s keep it, but new members must now choose a site.',
                                 count(*), v_parent.name) else '' end
                   from profiles where org_unit_id = v_parent.id);
      end if;
    end if;

    -- Land at the end of the new sibling group.
    select coalesce(max(sort_order), 0) + 10 into v_order
    from org_units
    where org_id = v_unit.org_id
      and coalesce(parent_unit_id, '00000000-0000-0000-0000-000000000000'::uuid)
        = coalesce(p_parent_unit_id, '00000000-0000-0000-0000-000000000000'::uuid)
      and id <> p_unit_id;
  else
    v_order := v_unit.sort_order;
  end if;

  update org_units
     set name = v_name, parent_unit_id = p_parent_unit_id, sort_order = v_order
   where id = p_unit_id;

  return jsonb_build_object('ok', true,
                            'msg', 'Saved' || case when v_note <> '' then '.' || v_note else '' end,
                            'note', nullif(btrim(v_note), ''));
end;
$$;


-- ── 4. Activate / deactivate ─────────────────────────────────
-- Rule 4: deactivating a company takes its sites with it (an active site
-- under an inactive company is unreachable in the member picker), and a
-- site cannot be reactivated while its company is closed.
create or replace function admin_unit_set_active(p_unit_id uuid, p_is_active boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_unit    record;
  v_kids    int := 0;
  v_stuck   int := 0;
  v_msg     text;
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  select * into v_unit from org_units where id = p_unit_id;
  if not found then raise exception 'company or site not found'; end if;

  if p_is_active then
    if v_unit.parent_unit_id is not null
       and exists (select 1 from org_units where id = v_unit.parent_unit_id and not is_active) then
      raise exception 'reopen the company above "%" first — a site under a closed company is invisible to members', v_unit.name;
    end if;
    update org_units set is_active = true where id = p_unit_id;
    select count(*) into v_stuck from org_units where parent_unit_id = p_unit_id and not is_active;
    v_msg := format('%s reopened', v_unit.name)
          || case when v_stuck > 0
                  then format('. %s of its site(s) are still closed — reopen those individually.', v_stuck)
                  else '' end;
  else
    update org_units set is_active = false where parent_unit_id = p_unit_id and is_active;
    get diagnostics v_kids = row_count;
    update org_units set is_active = false where id = p_unit_id;
    v_msg := format('%s closed', v_unit.name)
          || case when v_kids > 0 then format(', along with its %s site(s)', v_kids) else '' end;
  end if;

  return jsonb_build_object('ok', true, 'msg', v_msg);
end;
$$;


-- ── 5. Reorder within the sibling group ──────────────────────
-- p_direction 'up' | 'down'. Renumbers the whole sibling group 10,20,30…
-- so ties (everything created before this migration defaulted to 0)
-- resolve deterministically instead of no-opping.
create or replace function admin_unit_move(p_unit_id uuid, p_direction text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_unit  record;
  v_ids   uuid[];
  v_pos   int;
  v_swap  int;
  v_tmp   uuid;
  i       int;
begin
  if not is_admin() then raise exception 'not authorised'; end if;
  if lower(coalesce(p_direction, '')) not in ('up', 'down') then
    raise exception 'direction must be up or down';
  end if;

  select * into v_unit from org_units where id = p_unit_id;
  if not found then raise exception 'company or site not found'; end if;

  select array_agg(id order by sort_order, name) into v_ids
  from org_units
  where org_id = v_unit.org_id
    and coalesce(parent_unit_id, '00000000-0000-0000-0000-000000000000'::uuid)
      = coalesce(v_unit.parent_unit_id, '00000000-0000-0000-0000-000000000000'::uuid);

  v_pos  := array_position(v_ids, p_unit_id);
  v_swap := case when lower(p_direction) = 'up' then v_pos - 1 else v_pos + 1 end;

  if v_swap < 1 or v_swap > array_length(v_ids, 1) then
    return jsonb_build_object('ok', true, 'msg', format('%s is already %s',
      v_unit.name, case when lower(p_direction) = 'up' then 'first' else 'last' end));
  end if;

  v_tmp           := v_ids[v_pos];
  v_ids[v_pos]    := v_ids[v_swap];
  v_ids[v_swap]   := v_tmp;

  for i in 1 .. array_length(v_ids, 1) loop
    update org_units set sort_order = i * 10 where id = v_ids[i];
  end loop;

  return jsonb_build_object('ok', true, 'msg', format('%s moved %s', v_unit.name, lower(p_direction)));
end;
$$;


-- ── 6. Delete an empty unit ──────────────────────────────────
-- Only when nothing references it — members, sites, departments, an HR
-- manager's scope or a published report. Everything else gets closed.
create or replace function admin_unit_delete(p_unit_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if not is_admin() then raise exception 'not authorised'; end if;

  select name into v_name from org_units where id = p_unit_id;
  if not found then raise exception 'company or site not found'; end if;

  if admin_unit_has_dependents(p_unit_id) then
    raise exception 'cannot delete "%" — members, sites, departments, an HR manager''s scope or a published report still reference it. Close it instead.', v_name;
  end if;

  delete from org_units where id = p_unit_id;
  return jsonb_build_object('ok', true, 'msg', v_name || ' deleted');
end;
$$;


-- ── 7. Grants ────────────────────────────────────────────────
revoke all on function admin_unit_has_dependents(uuid)        from public, anon, authenticated;
revoke all on function admin_units_overview(uuid)             from public, anon;
revoke all on function admin_unit_create(uuid, text, uuid)    from public, anon;
revoke all on function admin_unit_update(uuid, text, uuid)    from public, anon;
revoke all on function admin_unit_set_active(uuid, boolean)   from public, anon;
revoke all on function admin_unit_move(uuid, text)            from public, anon;
revoke all on function admin_unit_delete(uuid)                from public, anon;

grant execute on function admin_units_overview(uuid)           to authenticated;
grant execute on function admin_unit_create(uuid, text, uuid)  to authenticated;
grant execute on function admin_unit_update(uuid, text, uuid)  to authenticated;
grant execute on function admin_unit_set_active(uuid, boolean) to authenticated;
grant execute on function admin_unit_move(uuid, text)          to authenticated;
grant execute on function admin_unit_delete(uuid)              to authenticated;


-- ── VERIFICATION ─────────────────────────────────────────────
-- SQL Editor (runs as postgres; is_admin() is false there, so every
-- function should REFUSE — that refusal is itself the check):
--   select admin_units_overview('<sedimosa uuid>');   -- expect: not authorised
--
-- Browser console, logged in as an admin:
--   const org = (await sb.rpc('admin_orgs_overview')).data.find(o=>o.name==='Sedimosa');
--   await sb.rpc('admin_units_overview', {p_org_id: org.id});
-- ============================================================
