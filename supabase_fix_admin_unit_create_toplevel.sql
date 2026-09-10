-- supabase_fix_admin_unit_create_toplevel.sql
-- admin_unit_create() cannot create a company. It never could.
--
-- THE BUG. The success message reads:
--
--   v_msg := case when p_parent_unit_id is null
--                 then format('Company "%s" added', v_name)
--                 else format('Site "%s" added under %s', v_name, v_parent.name) end;
--
-- `v_parent` is a `record`, and it is only assigned inside the
-- `if p_parent_unit_id is not null` block above. PL/pgSQL hands the whole CASE
-- expression to the SQL executor with every referenced variable substituted —
-- INCLUDING the branch that is not taken. So creating a top-level unit, where
-- that block never runs, dies on the last line before returning:
--
--   ERROR: 55000: record "v_parent" is not assigned yet
--
-- The row is already inserted by then, but the exception rolls the whole
-- function back, so nothing is created and the caller sees only the error.
--
-- WHAT THIS BREAKS TODAY. Creating a COMPANY from admin.html → Organisations →
-- Companies & Sites, which CLAUDE.md documents as the supported way to onboard a
-- client ("no SQL editor"). Adding a SITE under an existing company works fine —
-- that path assigns v_parent — which is presumably why this survived: Sedimosa's
-- eight top-level units predate these RPCs, so nobody had created a company
-- through the dashboard since.
--
-- Found 10 Sep 2026 while seeding Test Co for the P0 first-session walk, which
-- needs exactly this call.
--
-- WHAT CHANGES. One new local, `v_parent_name text`, assigned inside the branch
-- that already reads the parent, and used in the message instead of the record
-- field. Every other line is byte-identical to the live body as read via
-- pg_get_functiondef on 10 Sep 2026 — read first, substituted, not retyped.
--
-- WHAT DOES NOT CHANGE. Behaviour on the site path, every guard (two-level
-- limit, cross-org check, name collision, the stranding and department-reporting
-- notes), the return shape, the SECURITY DEFINER and search_path settings, the
-- is_admin() gate, and the grants.
--
-- WHAT BREAKS IF IT IS WRONG. Creating a site under a company would report the
-- wrong parent name in its confirmation. The guards themselves are untouched, so
-- a wrong message is the worst case, not a wrong tree.
--
-- HOW TO UNDO. migrations/rollback-admin-unit-create-toplevel.sql restores the
-- body exactly as it is above, bug included.

create or replace function public.admin_unit_create(
  p_org_id uuid,
  p_name text,
  p_parent_unit_id uuid default null::uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_name        text := btrim(coalesce(p_name, ''));
  v_id          uuid;
  v_order       int;
  v_parent      record;
  -- THE FIX: the message below must not reach into a record that is only
  -- assigned on the other branch. Capturing the name as plain text keeps the
  -- CASE expression safe to substitute whichever branch is taken.
  v_parent_name text;
  v_msg         text;
  v_note        text := '';
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
    if v_parent.parent_unit_id is not null then
      raise exception '"%" is already a site. Sites cannot have sites of their own — pick a company instead.', v_parent.name;
    end if;
    v_parent_name := v_parent.name;

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
                else format('Site "%s" added under %s', v_name, v_parent_name) end;

  return jsonb_build_object('ok', true, 'id', v_id,
                            'msg', v_msg || case when v_note <> '' then '.' || v_note else '' end,
                            'note', nullif(btrim(v_note), ''));
end;
$function$;

-- Grants are unchanged by create-or-replace, but restate the intent: this is a
-- top-level RPC gated by is_admin() INSIDE the body, so authenticated is correct.
revoke execute on function public.admin_unit_create(uuid, text, uuid) from public, anon;
grant  execute on function public.admin_unit_create(uuid, text, uuid) to authenticated;
