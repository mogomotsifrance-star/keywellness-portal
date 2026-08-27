-- ============================================================
-- Rollback — M4a: ownership, and the three ideas separated
-- Reverses supabase_m4a_ownership_and_roles.sql completely.
--
-- Idempotent: safe to run twice. Leaves ZERO objects behind.
--
-- WHAT THIS PUTS BACK: is_ops_admin(), every call site pointing at it, the
-- alphabetical-order owner fallback, and the single-kind billing flag.
--
-- WHAT IT DELETES: psychosocial_admins and its two rows. That is a membership
-- list, not derived data — write it down before you run this if you intend to
-- re-apply.
--
-- ORDER: the function bodies and policies must stop referencing is_admin()
-- BEFORE is_psychosocial_admin() and psychosocial_admins go, and
-- is_ops_admin() must exist again BEFORE anything points at it.
-- ============================================================


-- ── 1. Put is_ops_admin() back ──────────────────────────────
create or replace function is_ops_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select is_admin();
$$;

grant execute on function is_ops_admin() to authenticated;


-- ── 2. Point the policies back at it ────────────────────────
drop policy if exists org_contracts_admin_write on org_contracts;
create policy org_contracts_admin_write on org_contracts for all
  using (is_ops_admin()) with check (is_ops_admin());

drop policy if exists contract_rates_admin_write on contract_rates;
create policy contract_rates_admin_write on contract_rates for all
  using (is_ops_admin()) with check (is_ops_admin());

drop policy if exists org_contacts_admin_write on org_contacts;
create policy org_contacts_admin_write on org_contacts for all
  using (is_ops_admin()) with check (is_ops_admin());

drop policy if exists work_plans_admin_write on work_plans;
create policy work_plans_admin_write on work_plans for all
  using (is_ops_admin()) with check (is_ops_admin());

drop policy if exists billing_handovers_read on billing_handovers;
create policy billing_handovers_read on billing_handovers
  for select using (is_ops_admin());

drop policy if exists billing_handovers_admin_write on billing_handovers;
create policy billing_handovers_admin_write on billing_handovers for all
  using (is_ops_admin()) with check (is_ops_admin());

drop policy if exists support_actions_admin_read on support_actions;
create policy support_actions_admin_read on support_actions
  for select using (is_ops_admin());


-- ── 3. Point the functions back at it ───────────────────────
-- Same mechanism as the migration, in the other direction. Only the gate
-- changes; the bodies come from their own definitions.

do $$
declare r record; v_def text; n int := 0;
begin
  for r in
    select p.oid, p.proname
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname in ('support_lookup','support_can','support_log','support_recent',
                         'handover_mark_handed_over','handover_confirm_invoiced',
                         'handover_cancel','work_plan_upsert','activity_upsert')
       and p.prosrc like '%is_admin%'
  loop
    v_def := replace(pg_get_functiondef(r.oid), 'is_admin()', 'is_ops_admin()');
    execute v_def;
    n := n + 1;
  end loop;
  raise notice 'M4a rollback: % function(s) pointed back at is_ops_admin().', n;
end $$;


-- ── 4. Restore the owner fallback ───────────────────────────
-- Including the alphabetical-order behaviour, because that is what M4 shipped
-- and a rollback restores what was there rather than an improved version.
-- If you are rolling back, set invoice.prepared_by_user_id explicitly.

create or replace function _handover_owner()
returns uuid
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare v_id uuid;
begin
  select nullif(value #>> '{}', '')::uuid into v_id
    from threshold_config where key = 'invoice.prepared_by_user_id';

  if v_id is not null and exists (select 1 from auth.users u where u.id = v_id) then
    return v_id;
  end if;

  select u.id into v_id
    from admins a join auth.users u on lower(u.email) = lower(a.email)
   order by u.email limit 1;

  return v_id;
end $$;

revoke all on function _handover_owner() from public, anon, authenticated;


-- ── 5. Restore the single-kind billing flag ─────────────────

create or replace function _billing_flags(p_org_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare v_day int;
begin
  select coalesce((value #>> '{}')::int, 25) into v_day
    from threshold_config where key = 'invoice.prepare_day';

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'handover_id', h.id,
             'period_start', h.period_start,
             'state', h.state,
             'label', to_char(h.period_start, 'FMMonth') || ' not confirmed invoiced'
           ) order by h.period_start)
      from billing_handovers h
     where h.org_id = p_org_id
       and h.kind = 'retainer'
       and h.state not in ('invoiced', 'cancelled')
       and current_date > (h.period_start + (coalesce(v_day, 25) - 1))
  ), '[]'::jsonb);
end $$;

revoke all on function _billing_flags(uuid) from public, anon, authenticated;


-- ── 6. Remove what M4a added ────────────────────────────────
drop function if exists is_psychosocial_admin();
drop table if exists psychosocial_admins;


-- ── 7. Clean-slate verification ─────────────────────────────

do $$
declare n int;
begin
  select
      (select count(*) from pg_tables where schemaname='public'
        and tablename = 'psychosocial_admins')
    + (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
        where ns.nspname='public' and p.proname = 'is_psychosocial_admin')
    into n;

  if n <> 0 then
    raise exception 'M4a rollback incomplete: % object(s) left behind', n;
  end if;

  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
                  where ns.nspname='public' and p.proname = 'is_ops_admin') then
    raise exception 'M4a rollback: is_ops_admin() was not restored';
  end if;

  select count(*) into n from pg_policies
   where schemaname='public'
     and (coalesce(qual,'') like '%is_ops_admin%'
       or coalesce(with_check,'') like '%is_ops_admin%');
  if n <> 7 then
    raise exception 'M4a rollback: expected 7 policies on is_ops_admin, found %', n;
  end if;

  raise notice 'M4a rollback clean: zero leftover objects, is_ops_admin() restored.';
end $$;
