-- Rollback: organizations.offers_advances and the gate that reads it.
--
-- Run BEFORE re-applying an older supabase_advance_recommendation.sql, or the
-- create() body will still reference a column that no longer exists.
-- Idempotent.

begin;

-- 1. drop the gate from advance_recommendation_create() by restoring the
--    pre-gate checks. Substitution on the live body, so any later amendment
--    to the rest of the function survives.
do $patch$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='advance_recommendation_create';
  if v_def is null or position('offers_advances' in v_def) = 0 then
    return;                                    -- not applied, or already gone
  end if;

  v_new := regexp_replace(v_def,
    E'\\n  -- The report names an employer.*?end if;\\n(?=\\n)', '', 'ns');
  v_new := replace(v_new, E'  v_org     uuid;\n', '');
  v_new := replace(v_new, E'  v_offers  boolean;\n', '');
  v_new := replace(v_new,
    'select advisor_id, org_id into v_owner, v_org from advisor_clients',
    'select advisor_id into v_owner from advisor_clients');

  if position('offers_advances' in v_new) > 0 then
    raise exception 'rollback: could not strip the offers_advances gate';
  end if;
  execute v_new;
end
$patch$;

-- 2. drop the column from advisor_clients_list()
do $patch$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='advisor_clients_list';
  if v_def is null or position('offers_advances' in v_def) = 0 then return; end if;
  v_new := regexp_replace(v_def, E'\\n *coalesce\\(o\\.offers_advances, false\\) *as offers_advances,', '', 'n');
  if position('offers_advances' in v_new) > 0 then
    raise exception 'rollback: could not strip offers_advances from advisor_clients_list()';
  end if;
  execute v_new;
end
$patch$;

-- 3. advisor_org_options() without the flag
create or replace function public.advisor_org_options()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not (is_advisor() or is_admin()) then
    raise exception 'not authorised';
  end if;
  select coalesce(jsonb_agg(
           jsonb_build_object('org_id', o.id, 'name', o.name,
                              'units', coalesce(u.units, '[]'::jsonb))
           order by o.name), '[]'::jsonb)
    into v_out
  from organizations o
  left join lateral (
    select jsonb_agg(jsonb_build_object('id', x.id, 'label', x.label) order by x.label) as units
    from (
      select ou.id, kw_unit_label(ou.id) as label
      from org_units ou
      left join org_units par on par.id = ou.parent_unit_id
      where ou.org_id = o.id and ou.is_active
        and (par.id is null or par.is_active)
        and not exists (select 1 from org_units c where c.parent_unit_id = ou.id and c.is_active)
    ) x
  ) u on true
  where o.is_active;
  return v_out;
end;
$$;
revoke execute on function public.advisor_org_options() from public, anon;
grant  execute on function public.advisor_org_options() to authenticated;

-- 4. finally the column
alter table public.organizations drop column if exists offers_advances;

commit;
