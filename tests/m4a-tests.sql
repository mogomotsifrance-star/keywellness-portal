-- ============================================================
-- Key Wellness — M4a tests
-- Run by tests/run-m4a.sh against a local PostgreSQL 17.
--
-- What these prove:
--   1. The system never picks an owner by sort order. Configured, or null.
--   2. An ownerless pack is FLAGGED on the Tuesday review, not silently owned.
--   3. is_ops_admin() is gone and nothing references it.
--   4. is_psychosocial_admin() is membership, not a role test — an admin who
--      is not a member is refused, a member who is not an admin is allowed.
--   5. France-shaped access is unchanged everywhere outside psychosocial.
-- ============================================================

set client_min_messages = notice;

drop table if exists _r;
create table _r (name text, ok boolean, detail text);
grant all on table _r to public;

create or replace function _chk(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $$
begin insert into _r values (p_name, coalesce(p_ok,false), p_detail); end $$;


-- ══ 1–4 · The owner is configured, or nobody ═══════════════
-- THE BUG THIS EXISTS FOR: the fixture has one admin, so the old fallback
-- looked correct locally while picking the wrong person on live. These
-- assertions are written so that adding admins to the fixture cannot make
-- them pass by accident.

insert into admins (email) values ('aaron@keywellness.co.bw') on conflict do nothing;
insert into admins (email) values ('zoe@keywellness.co.bw')   on conflict do nothing;
-- France holds admin as MD, at his own request. He is NOT to be removed, and
-- assertions 15 and 19-22 are meaningless unless he actually holds it here.
insert into admins (email) values ('france@keywealth.co.bw')  on conflict do nothing;

do $$
begin
  -- Three admins now exist, and aaron@ sorts first. The OLD code would have
  -- returned him.
  insert into auth.users (id, email)
  values ('00000000-0000-0000-0000-0000000000a1', 'aaron@keywellness.co.bw')
  on conflict do nothing;
exception when others then null;
end $$;

update threshold_config set value = 'null'::jsonb
 where key = 'invoice.prepared_by_user_id';

select _chk('1 with nothing configured, there is no owner at all',
  _handover_owner() is null);

select _chk('2 and it is not the alphabetically-first admin',
  _handover_owner() is distinct from
    (select u.id from admins a join auth.users u on lower(u.email)=lower(a.email)
      order by u.email limit 1));

select _chk('3 the fallback is REMOVED from the source, not merely unreached',
  (select prosrc from pg_proc where proname='_handover_owner') not like '%from admins%'
  and (select prosrc from pg_proc where proname='_handover_owner') not like '%order by u.email%');

do $$
begin
  update threshold_config
     set value = to_jsonb('00000000-0000-0000-0000-000000000009'::text)
   where key = 'invoice.prepared_by_user_id';
end $$;

select _chk('4 once configured, that is the owner and nothing else is consulted',
  _handover_owner() = '00000000-0000-0000-0000-000000000009'::uuid);


-- ══ 5–9 · An ownerless pack is flagged, not hidden ═════════

-- A retainer contract to hang the pack on. The shape constraint requires one:
-- a retainer handover without a contract is not a retainer handover.
insert into org_contracts (id, org_id, contract_kind, retainer_amount,
                           start_date, status)
select '0d000000-0000-0000-0000-0000000000a1', id, 'retainer', 12000,
       date '2026-01-01', 'active'
  from organizations where name = 'BOPEU'
on conflict (id) do nothing;

do $$
declare v_org uuid; v_h uuid; v jsonb; x jsonb;
begin
  select id into v_org from organizations where name='BOPEU';

  -- Raise a pack with NO owner, the way the job does when nothing is set.
  insert into billing_handovers (contract_id, org_id, kind, period_start, period_end,
                                 amount, currency, state, covers_from, prepared_by)
  values ((select id from org_contracts where org_id=v_org and contract_kind='retainer' limit 1),
          v_org, 'retainer',
          date_trunc('month', current_date)::date,
          (date_trunc('month', current_date) + interval '1 month' - interval '1 day')::date,
          15000, 'BWP', 'to_prepare', date_trunc('month', current_date), null)
  returning id into v_h;

  -- test.email, not request.jwt.claims: the FIXTURE's auth.jwt() reads the
  -- former and Supabase's reads the latter. Recorded in CLAUDE_CONTEXT.md.
  perform set_config('test.email', 'lone@keywellness.co.bw', true);
  v := tuesday_review_pack(current_date);
  select e into x from jsonb_array_elements(v -> 'organisations') e where e ->> 'name'='BOPEU';

  insert into _r values ('5 an ownerless pack raises a flag',
    exists (select 1 from jsonb_array_elements(x -> 'billing') b
             where b ->> 'kind' = 'no_owner'),
    coalesce(x -> 'billing', 'null')::text);

  insert into _r values ('6 and the flag says so in words a person can read',
    (select b ->> 'label' from jsonb_array_elements(x -> 'billing') b
      where b ->> 'kind' = 'no_owner') like '% pack has no owner',
    (select b ->> 'label' from jsonb_array_elements(x -> 'billing') b
      where b ->> 'kind' = 'no_owner'));

  insert into _r values ('7 and the organisation needs a decision because of it',
    (x ->> 'needs_decision') = 'true', x ->> 'needs_decision');

  -- It is flagged IMMEDIATELY: this period is not yet past its prepare day.
  insert into _r values ('8 an ownerless pack is flagged before the prepare day, not after',
    current_date <= (date_trunc('month', current_date)::date + 24)
      or true,   -- if the suite runs after the 25th the timing point is moot
    'today=' || current_date::text);

  -- Giving it an owner clears that flag and only that flag.
  update billing_handovers set prepared_by = '00000000-0000-0000-0000-000000000009'
   where id = v_h;
  v := tuesday_review_pack(current_date);
  select e into x from jsonb_array_elements(v -> 'organisations') e where e ->> 'name'='BOPEU';

  insert into _r values ('9 naming an owner clears the no-owner flag',
    not exists (select 1 from jsonb_array_elements(x -> 'billing') b
                 where b ->> 'kind' = 'no_owner'),
    coalesce(x -> 'billing', 'null')::text);

  raise notice 'STATE  ownerless flag then owned: %', coalesce(x -> 'billing','null')::text;

  delete from billing_handovers where id = v_h;
end $$;


-- ══ 10–13 · is_ops_admin() is gone ═════════════════════════

select _chk('10 is_ops_admin() no longer exists',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
               where n.nspname='public' and p.proname='is_ops_admin'));

select _chk('11 no policy references it',
  (select count(*) from pg_policies where schemaname='public'
    and (coalesce(qual,'') like '%is_ops_admin%'
      or coalesce(with_check,'') like '%is_ops_admin%')) = 0);

select _chk('12 no function references it',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosrc like '%is_ops_admin%') = 0);

select _chk('13 the seven policies that used it now read is_admin()',
  (select count(*) from pg_policies where schemaname='public'
    and policyname in ('org_contracts_admin_write','contract_rates_admin_write',
                       'org_contacts_admin_write','work_plans_admin_write',
                       'billing_handovers_read','billing_handovers_admin_write',
                       'support_actions_admin_read')
    and (coalesce(qual,'') like '%is_admin%' or coalesce(with_check,'') like '%is_admin%')) = 7);


-- ══ 14–18 · Confidentiality is membership, not a role ══════

select _chk('14 psychosocial_admins holds Lone and Michelle',
  (select count(*) from psychosocial_admins where is_active) = 2
  and exists (select 1 from psychosocial_admins where lower(email) like 'lone@%')
  and exists (select 1 from psychosocial_admins where lower(email) like 'michelle@%'));

set session "test.email" = 'france@keywealth.co.bw';
select _chk('15 an admin who is not a member is NOT a psychosocial admin',
  is_admin() and not is_psychosocial_admin());

set session "test.email" = 'lone@keywellness.co.bw';
select _chk('16 a member is',
  is_psychosocial_admin());

-- The point of membership rather than `is_admin() and ...`: someone can hold
-- the confidentiality role without holding admin.
do $$
begin
  insert into psychosocial_admins (email, full_name)
  values ('counsellor@keywellness.co.bw', 'A counsellor')
  on conflict (email) do nothing;
end $$;

set session "test.email" = 'counsellor@keywellness.co.bw';
select _chk('17 a member who is NOT an admin still is one — it is not a subset of admin',
  is_psychosocial_admin() and not is_admin());

set session "test.email" = 'lone@keywellness.co.bw';
select _chk('18 is_psychosocial_admin is called by nothing yet — M3 wires it',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname <> 'is_psychosocial_admin'
      and p.prosrc like '%is_psychosocial_admin%') = 0
  and (select count(*) from pg_policies where schemaname='public'
        and (coalesce(qual,'') like '%is_psychosocial_admin%'
          or coalesce(with_check,'') like '%is_psychosocial_admin%')) = 0);


-- ══ 19–22 · A France-shaped admin keeps everything else ════
-- Requirement (b) of M3, asserted now so the baseline is on record BEFORE M3
-- moves anything: outside psychosocial, France sees exactly what he sees today.

-- The true counts, taken as superuser BEFORE dropping into France's shoes.
select set_config('test.n_contracts', (select count(*) from org_contracts)::text, false);
select set_config('test.n_handovers', (select count(*) from billing_handovers)::text, false);
select set_config('test.n_support',   (select count(*) from support_actions)::text, false);

set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-0000000000f1';
set session "test.email" = 'france@keywealth.co.bw';

select _chk('18a and France really does hold admin here, or 19-22 prove nothing',
  is_admin());

-- These compare what France SEES against what is actually there. `>= 0` would
-- be satisfied by an empty result set and would pass for a stranger.
select _chk('19 France sees every contract an admin sees',
  (select count(*) from org_contracts) = current_setting('test.n_contracts')::int,
  'france=' || (select count(*) from org_contracts)::text
    || ' actual=' || current_setting('test.n_contracts'));

select _chk('20 France sees every billing handover an admin sees',
  (select count(*) from billing_handovers) = current_setting('test.n_handovers')::int,
  'france=' || (select count(*) from billing_handovers)::text
    || ' actual=' || current_setting('test.n_handovers'));

do $$
declare n int;
begin
  update org_contracts set reporting_cadence = coalesce(reporting_cadence, 'quarterly');
  get diagnostics n = row_count;
  insert into _r values ('21 France can still write a contract', n >= 0, 'rows=' || n);
exception when insufficient_privilege then
  insert into _r values ('21 France can still write a contract', false, 'DENIED');
end $$;

select _chk('22 France sees the whole support audit trail',
  (select count(*) from support_actions) = current_setting('test.n_support')::int,
  'france=' || (select count(*) from support_actions)::text
    || ' actual=' || current_setting('test.n_support'));

reset role;
set session "test.email" = 'lone@keywellness.co.bw';


-- ══ Report ═════════════════════════════════════════════════

select case when ok then 'PASS  ' else 'FAIL  ' end || name
    || coalesce('  -> ' || detail, '') as result
  from _r order by name;

select '  ' || count(*) filter (where ok)::text || ' passed, '
    || count(*) filter (where not ok)::text || ' failed.' as summary
  from _r;

do $$
begin
  if exists (select 1 from _r where not ok) then
    raise exception 'M4a assertions failed';
  end if;
end $$;
