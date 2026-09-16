-- rollback-admin-unit-create-toplevel.sql
-- Restores admin_unit_create() exactly as it stood before
-- supabase_fix_admin_unit_create_toplevel.sql — bug included.
--
-- Reverting reinstates the defect: creating a COMPANY (p_parent_unit_id null)
-- raises 'record "v_parent" is not assigned yet' and creates nothing. Only
-- revert if the fix is shown to have broken the site path, and expect client
-- onboarding through admin.html → Organisations → Companies & Sites to stop
-- working again.
--
-- Body captured from live via pg_get_functiondef on 10 Sep 2026, pre-fix.

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
    if v_parent.parent_unit_id is not null then
      raise exception '"%" is already a site. Sites cannot have sites of their own — pick a company instead.', v_parent.name;
    end if;

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
$function$;
