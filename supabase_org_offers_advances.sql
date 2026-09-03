-- Key Wellness — which organisations run an employee advance programme
--
-- The Advance Recommendation writes a document headed with an employer's
-- programme and a payroll-deducted advance. Only some employers offer that:
-- Hollard does, most do not. Before this, the Report tab offered the feature
-- for every client of every organisation, and a blank employer silently
-- printed as "Hollard" (report.ts). Both produced a document asserting a
-- programme the client is not in.
--
-- offers_advances is the switch. It is false by default, so a new
-- organisation never inherits the feature by accident, and the gate lives in
-- advance_recommendation_create() — the UI hiding the button is a courtesy,
-- not the control.
--
-- Idempotent. Rollback: migrations/rollback-org-offers-advances.sql

begin;

-- ── 1. the column ─────────────────────────────────────────────────────
alter table public.organizations
  add column if not exists offers_advances boolean not null default false;

comment on column public.organizations.offers_advances is
  'Employer runs a payroll advance programme, so the Advance Recommendation '
  'report applies to their employees. Default false: a new organisation must '
  'be switched on deliberately. Enforced in advance_recommendation_create().';

-- ── 2. Hollard is the one that does, today ────────────────────────────
update public.organizations
   set offers_advances = true
 where lower(name) like 'hollard%'
   and offers_advances is distinct from true;

-- ── 3. advisor_org_options(): carry the flag to the pickers ───────────
-- Full body restated (it is short and this file now owns it).
create or replace function public.advisor_org_options()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not (is_advisor() or is_admin()) then
    raise exception 'not authorised';
  end if;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'org_id', o.id,
             'name',   o.name,
             'offers_advances', o.offers_advances,
             'units',  coalesce(u.units, '[]'::jsonb)
           ) order by o.name), '[]'::jsonb)
    into v_out
  from organizations o
  left join lateral (
    select jsonb_agg(jsonb_build_object('id', x.id, 'label', x.label)
                     order by x.label) as units
    from (
      select ou.id, kw_unit_label(ou.id) as label
      from org_units ou
      left join org_units par on par.id = ou.parent_unit_id
      where ou.org_id = o.id
        and ou.is_active
        and (par.id is null or par.is_active)          -- no orphan sites
        and not exists (select 1 from org_units c      -- leaves only
                         where c.parent_unit_id = ou.id and c.is_active)
    ) x
  ) u on true
  where o.is_active;

  return v_out;
end;
$$;
revoke execute on function public.advisor_org_options() from public, anon;
grant  execute on function public.advisor_org_options() to authenticated;

-- ── 4. advisor_clients_list(): add offers_advances to every row ───────
-- Patched by substitution on the LIVE definition rather than restated. The
-- body is sixty lines of booking sub-selects that have been amended by
-- several migrations; retyping it here is how a file goes stale and quietly
-- reverts somebody else's work. Asserts the substitution happened.
do $patch$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'advisor_clients_list';
  if v_def is null then raise exception 'advisor_clients_list() not found'; end if;

  if position('offers_advances' in v_def) > 0 then
    return;                                   -- already patched, nothing to do
  end if;

  v_new := replace(v_def,
    E'      o.name                                       as org_name,',
    E'      o.name                                       as org_name,\n'
    '      coalesce(o.offers_advances, false)            as offers_advances,');

  if v_new = v_def then
    raise exception 'advisor_clients_list(): could not find the org_name column to patch';
  end if;

  execute v_new;
end
$patch$;

-- ── 5. the gate itself lives in the database ──────────────────────────
-- advance_recommendation_create() is amended in
-- supabase_advance_recommendation.sql, which must be re-applied after this
-- file so the column exists when the new body is compiled.

commit;
