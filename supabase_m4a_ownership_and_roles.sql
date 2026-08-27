-- ============================================================
-- Key Wellness — M4a: ownership, and separating three ideas that
--                     were riding on one name
--
-- Run AFTER M4. Idempotent — safe to re-run.
-- Rollback: migrations/rollback-m4a-ownership-and-roles.sql
-- Tests:    tests/m4a-tests.sql   (local, PostgreSQL 17)
-- Verify:   tests/m4a-verify-live.sql (read-only, the SQL editor)
--
-- ══ WHAT THIS IS FOR, IN PLAIN LANGUAGE ════════════════════
--
-- Two problems, both found by applying M4 to the live database and diffing
-- the result against what had been predicted.
--
-- ── PROBLEM 1: THE SYSTEM CHOSE A PERSON BY ALPHABETICAL ORDER ──
--
-- _handover_owner() fell back to "the first admin by email" when nobody was
-- configured. On the live database that is france@keywealth.co.bw, because
-- france sorts before lone. So the default put Lone's invoice pack in
-- France's name. No local test caught it, and none could: the test fixture
-- has Lone as the only admin, so the fallback looked correct there.
--
-- Setting the configuration fixed today. It did not fix the fallback, which
-- would pick France again the moment the key is cleared, or the first time
-- this system is stood up anywhere else.
--
-- SO THE FALLBACK IS GONE. When no owner is configured, the pack is left
-- OWNERLESS and the Tuesday review says so — "August pack has no owner".
-- The system does not choose a person.
--
--   STANDING RULE FOR THE WHOLE SYSTEM:
--   NO OWNER IS EVER RESOLVED BY SORT ORDER.
--   Configured, or absent-and-flagged. Never guessed.
--
-- An unowned pack is a visible problem someone fixes in ten seconds. A pack
-- silently owned by the wrong person is an invisible one that surfaces when
-- the wrong person is asked why they did not do something they never knew
-- about.
--
-- ── PROBLEM 2: ONE NAME WAS CARRYING THREE DIFFERENT IDEAS ──
--
-- is_ops_admin() was vague enough to conflate three things that fail
-- separately and must be reasoned about separately:
--
--   ACCESS          — who may see. France holds admin as MD at his own
--                     request; Tshenolo holds it for testing and continuous
--                     build. NEITHER IS TO BE REMOVED. This is is_admin(),
--                     and it is unchanged.
--
--   OWNERSHIP       — who is assigned work and expected to act. Lone,
--                     Michelle, or a named practitioner. Never derived from a
--                     role, and never chosen by sort order. This is
--                     configuration, per problem 1.
--
--   CONFIDENTIALITY — who may NOT see, whatever role they hold. Psychosocial
--                     rows; France excluded. This is the new
--                     is_psychosocial_admin(), and it is MEMBERSHIP, not a
--                     role test.
--
-- So is_ops_admin() is replaced, not renamed in place:
--
--   * is_psychosocial_admin() is NEW, is membership of psychosocial_admins,
--     and is called by NOTHING YET. M3 wires it to psychosocial rows.
--   * All sixteen existing is_ops_admin() call sites move to is_admin().
--     Every one of them is an ordinary admin capability — billing writes,
--     work-plan writes, member support — and none touches psychosocial data.
--   * is_ops_admin() is dropped.
--
-- ══ WHAT WILL CHANGE, AND WHAT WILL NOT ════════════════════
-- Written BEFORE the apply, as the prediction to check the result against.
--
--   CHANGES NOTHING ABOUT WHO CAN DO WHAT, TODAY.
--     is_ops_admin() is currently DEFINED as `select is_admin()`. Pointing
--     its call sites at is_admin() is therefore a no-op in behaviour: the
--     same people can do exactly the same things before and after. What
--     changes is that the name no longer invites the confusion that produced
--     this migration.
--
--   CHANGES
--     A new table psychosocial_admins appears, holding TWO rows: Lone and
--     Michelle. A new function is_psychosocial_admin() appears, called by
--     nothing. is_ops_admin() disappears. Sixteen call sites read is_admin().
--     _handover_owner() loses its fallback. _billing_flags() gains a second
--     kind of flag, for an ownerless pack.
--
--   DOES NOT CHANGE
--     No booking, no member, no report, no handover. France and Tshenolo keep
--     every capability they have today. tuesday_review_pack()'s shape is
--     unchanged — 'billing' entries gain a 'kind' field and may now include a
--     no-owner entry, which is additive.
--
--   IF IT IS WRONG
--     The realistic failure is a policy that no longer matches anyone, which
--     shows up as an admin unable to write a contract. No data is damaged.
--     Undo with migrations/rollback-m4a-ownership-and-roles.sql, which puts
--     is_ops_admin() back and re-points every call site to it.
--
-- ── ONE DECISION THIS REVERSES, DELIBERATELY ────────────────
-- docs/build/admin-support.md records that "France's admin will lose this
-- capability when M3 lands", meaning member support. That was written when
-- is_ops_admin() was believed to be the confidentiality boundary. It is not:
-- member support reveals no psychosocial content — support_lookup returns an
-- address and a role list, nothing clinical. Member support is ORDINARY ADMIN
-- and stays with is_admin(). Corrected there as well as here.
-- ============================================================


-- ── 1. psychosocial_admins — membership, not a role test ────
-- Roles in this system are table membership, not a column (CLAUDE.md, Roles &
-- Interfaces). This follows admins/advisors/employers exactly.

create table if not exists psychosocial_admins (
  email      text primary key,
  user_id    uuid references auth.users(id),
  full_name  text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

comment on table psychosocial_admins is
  'Who may see psychosocial data. NOT "who is an admin" and NOT "who may use '
  'the ops workspace" — those are is_admin() and is_staff(). France holds '
  'admin and is deliberately not here.';

alter table psychosocial_admins enable row level security;

-- SELECT-only under RLS, like admins and employers. Membership is changed by
-- hand or by a future admin RPC, never by the application.
drop policy if exists psychosocial_admins_staff_read on psychosocial_admins;
create policy psychosocial_admins_staff_read on psychosocial_admins
  for select using (is_staff());

revoke insert, update, delete on table psychosocial_admins from anon, authenticated;

-- Lone and Michelle. This migration DOES name people, unlike the others,
-- because membership is the entire content of the decision — "psychosocial
-- admin is Lone and Michelle" is not a configuration detail, it is the rule.
insert into psychosocial_admins (email, full_name)
values ('lone@keywellness.co.bw',   'Lone'),
       ('michelle@keywealth.co.bw', 'Michelle')
on conflict (email) do nothing;


-- ── 2. is_psychosocial_admin() ──────────────────────────────
-- Pure membership. Deliberately NOT `is_admin() and ...`: a confidentiality
-- boundary that is a subset of a role is one role change away from leaking.
--
-- Called by NOTHING in this migration. M3 wires it to psychosocial bookings
-- and counselling notes.

create or replace function is_psychosocial_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1 from psychosocial_admins p
     where p.is_active
       and (p.user_id = auth.uid()
         or lower(p.email) = lower(auth.jwt() ->> 'email'))
  );
$$;

grant execute on function is_psychosocial_admin() to authenticated;


-- ── 3. Re-point every is_ops_admin() call site to is_admin() ──
-- The POLICIES first, because a policy pins the function it calls and
-- is_ops_admin() cannot be dropped while one references it.

drop policy if exists org_contracts_admin_write on org_contracts;
create policy org_contracts_admin_write on org_contracts for all
  using (is_admin()) with check (is_admin());

drop policy if exists contract_rates_admin_write on contract_rates;
create policy contract_rates_admin_write on contract_rates for all
  using (is_admin()) with check (is_admin());

drop policy if exists org_contacts_admin_write on org_contacts;
create policy org_contacts_admin_write on org_contacts for all
  using (is_admin()) with check (is_admin());

drop policy if exists work_plans_admin_write on work_plans;
create policy work_plans_admin_write on work_plans for all
  using (is_admin()) with check (is_admin());

drop policy if exists billing_handovers_read on billing_handovers;
create policy billing_handovers_read on billing_handovers
  for select using (is_admin());

drop policy if exists billing_handovers_admin_write on billing_handovers;
create policy billing_handovers_admin_write on billing_handovers for all
  using (is_admin()) with check (is_admin());

drop policy if exists support_actions_admin_read on support_actions;
create policy support_actions_admin_read on support_actions
  for select using (is_admin());


-- Then the FUNCTIONS. Rewritten from their own definitions rather than
-- retyped: pg_get_functiondef() returns the exact CREATE OR REPLACE for each,
-- so the only thing that changes is the gate. Retyping nine bodies by hand to
-- alter one identifier in each is how a body quietly loses a line.
--
-- The list is explicit so this cannot run away across the schema.

do $$
declare
  r     record;
  v_def text;
  n     int := 0;
begin
  for r in
    select p.oid, p.proname
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname in ('support_lookup','support_can','support_log','support_recent',
                         'handover_mark_handed_over','handover_confirm_invoiced',
                         'handover_cancel','work_plan_upsert','activity_upsert')
       and p.prosrc like '%is_ops_admin%'
  loop
    v_def := replace(pg_get_functiondef(r.oid), 'is_ops_admin()', 'is_admin()');
    execute v_def;
    n := n + 1;
    raise notice 'M4a: % re-pointed to is_admin()', r.proname;
  end loop;
  raise notice 'M4a: % function(s) re-pointed.', n;
end $$;


-- ── 4. is_ops_admin() is gone ───────────────────────────────
-- The name was the problem. Keeping it as an alias would keep the problem.

drop function if exists is_ops_admin();


-- ── 5. _handover_owner() — configured, or nobody ────────────
-- THE FALLBACK IS REMOVED. See problem 1 in the header.

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

  -- Configured AND real, or nobody. There is deliberately no `else pick
  -- someone`: an owner chosen by sort order is a wrong owner that nobody can
  -- see is wrong. An ownerless pack is flagged on the Tuesday review instead.
  if v_id is not null and exists (select 1 from auth.users u where u.id = v_id) then
    return v_id;
  end if;

  return null;
end $$;

revoke all on function _handover_owner() from public, anon, authenticated;


-- ── 6. _billing_flags() — two things can be wrong ───────────
-- (a) a retainer period past its prepare day that Lone has not confirmed;
-- (b) a pack with no owner at all.
--
-- Both reach the Tuesday review as needs-a-decision. A pack can carry both,
-- and should: they are two different problems with two different fixes.

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
    select jsonb_agg(f order by f ->> 'period_start', f ->> 'kind')
      from (
        -- (a) Late, and not confirmed with Laone.
        select jsonb_build_object(
                 'handover_id',  h.id,
                 'period_start', h.period_start,
                 'state',        h.state,
                 'kind',         'not_confirmed',
                 'label', to_char(h.period_start, 'FMMonth') || ' not confirmed invoiced'
               ) as f
          from billing_handovers h
         where h.org_id = p_org_id
           and h.kind = 'retainer'
           and h.state not in ('invoiced', 'cancelled')
           and current_date > (h.period_start + (coalesce(v_day, 25) - 1))

        union all

        -- (b) Nobody owns it. Flagged IMMEDIATELY, not after the prepare day:
        -- an ownerless pack is wrong the moment it exists.
        select jsonb_build_object(
                 'handover_id',  h.id,
                 'period_start', h.period_start,
                 'state',        h.state,
                 'kind',         'no_owner',
                 'label', to_char(h.period_start, 'FMMonth') || ' pack has no owner'
               )
          from billing_handovers h
         where h.org_id = p_org_id
           and h.kind = 'retainer'
           and h.state not in ('invoiced', 'cancelled')
           and h.prepared_by is null
      ) t
  ), '[]'::jsonb);
end $$;

revoke all on function _billing_flags(uuid) from public, anon, authenticated;


-- ── 7. Post-conditions ──────────────────────────────────────

do $$
declare n int;
begin
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname = 'is_ops_admin') then
    raise exception 'M4a: is_ops_admin() still exists';
  end if;

  select count(*) into n from pg_policies
   where schemaname = 'public'
     and (coalesce(qual,'') like '%is_ops_admin%'
       or coalesce(with_check,'') like '%is_ops_admin%');
  if n <> 0 then
    raise exception 'M4a: % policy/policies still reference is_ops_admin', n;
  end if;

  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prosrc like '%is_ops_admin%';
  if n <> 0 then
    raise exception 'M4a: % function(s) still reference is_ops_admin', n;
  end if;

  -- The fallback must be gone, not merely unused.
  if (select prosrc from pg_proc where proname = '_handover_owner') like '%from admins%' then
    raise exception 'M4a: _handover_owner still falls back to the admins table';
  end if;

  if (select count(*) from psychosocial_admins where is_active) < 2 then
    raise exception 'M4a: psychosocial_admins should hold Lone and Michelle';
  end if;

  raise notice 'M4a applied. Ownership is CONFIGURED OR ABSENT — never chosen '
               'by sort order. is_ops_admin() is gone; access is is_admin() '
               '(France and Tshenolo unchanged) and confidentiality is '
               'is_psychosocial_admin() (Lone and Michelle), which M3 wires up.';
end $$;
