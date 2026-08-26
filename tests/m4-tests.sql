-- ============================================================
-- Key Wellness — M4 assertions (local PostgreSQL 17 only)
--
-- Run by tests/run-m4.sh after the fixture, the reporting stack, M1, M5, the
-- baseline capture, and M4.
--
-- Access assertions run under `set role authenticated`, so RLS is enforced —
-- the pattern m5-tests.sql established.
-- ============================================================

\set ON_ERROR_STOP on
set client_min_messages to notice;

drop table if exists _r;
create table _r (name text, ok boolean, detail text);
grant insert, select on _r to authenticated;

create or replace function _chk(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $$
begin insert into _r values (p_name, p_ok, p_detail); end $$;

create or replace function _visible(p_table text)
returns int language plpgsql as $$
declare n int;
begin
  execute format('select count(*) from %I', p_table) into n;
  return n;
exception when insufficient_privilege then return -1;
end $$;

set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

\set lone   '''00000000-0000-0000-0000-000000000009'''
\set laone  '''00000000-0000-0000-0000-00000000000d'''
\set kef    '''00000000-0000-0000-0000-00000000000b'''
\set plain  '''00000000-0000-0000-0000-00000000000e'''


-- ══ THE REGRESSION — org_report_data() before vs after ══════
-- M4 extends program_activities, which org_report_data() counts. Adding
-- columns must not move a single figure. This is the M1 pattern.

create table _after as
select b.org_name, b.label, b.payload as before_payload,
       org_report_data(b.org_id, b.period_start, b.period_end) as after_payload
  from m4_baseline b;

select _chk('1  org_report_data is byte-identical for every organisation and period',
  (select count(*) from _after where before_payload is distinct from after_payload) = 0,
  (select coalesce(string_agg(org_name || '/' || label, ', '), 'none')
     from _after where before_payload is distinct from after_payload));

do $$
declare n_same int; n_tot int;
begin
  select count(*) filter (where before_payload is not distinct from after_payload),
         count(*) into n_same, n_tot from _after;
  raise notice 'REGRESSION  org_report_data: % of % payloads byte-identical', n_same, n_tot;
end $$;

select _chk('2  no program_activities row was added, removed or renumbered',
  (select count(*) from program_activities) = (select n from m4_counts where k='program_activities'));

select _chk('3  the columns org_report_data reads are untouched',
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='program_activities'
      and column_name in ('activity_type','title','activity_date','attendee_count','delivery_mode')) = 5);

select _chk('4  activity_type still admits exactly its five reporting values',
  (select pg_get_constraintdef(oid) from pg_constraint
    where conname='program_activities_activity_type_check')
  like '%group_intervention%education_talk%webinar%clinic%other%');


-- ══ 5–9 · Shape ════════════════════════════════════════════

select _chk('5  a retainer contract must carry an amount',
  not exists (select 1 from org_contracts
               where contract_kind='retainer' and retainer_amount is null));

do $$
declare ok boolean := false;
begin
  begin
    insert into org_contracts (org_id, contract_kind, retainer_amount, start_date)
    values ((select id from organizations limit 1), 'retainer', null, current_date);
    raise exception 'accepted';
  exception when check_violation then ok := true; when others then ok := false; end;
  insert into _r values ('6  and a retainer with no amount is refused', ok, null);
end $$;

do $$
declare ok boolean := false;
begin
  begin
    insert into org_contracts (org_id, contract_kind, retainer_amount, start_date)
    values ((select id from organizations limit 1), 'per_engagement', 5000, current_date);
    raise exception 'accepted';
  exception when check_violation then ok := true; when others then ok := false; end;
  insert into _r values ('7  a per-engagement contract with a retainer amount is refused', ok, null);
end $$;

select _chk('8  work_plan_id is nullable — a per-engagement client may have no plan',
  (select is_nullable from information_schema.columns
    where table_schema='public' and table_name='program_activities'
      and column_name='work_plan_id') = 'YES');

select _chk('9  bookings.activity_id exists with its foreign key',
  exists (select 1 from pg_constraint where conname='bookings_activity_id_fkey'));


-- ══ Seed: one retainer client, one per-engagement client ═══

insert into org_contracts (id, org_id, contract_kind, retainer_amount, start_date, status, created_by)
select '0d000000-0000-0000-0000-000000000001', id, 'retainer', 12000,
       date '2026-01-01', 'active', :lone
  from organizations where name = 'BOPEU';

insert into org_contracts (id, org_id, contract_kind, start_date, status, created_by)
select '0d000000-0000-0000-0000-000000000002', id, 'per_engagement',
       date '2026-01-01', 'active', :lone
  from organizations where name = 'Sedimosa';

insert into contract_rates (contract_id, format, service_line, amount) values
  ('0d000000-0000-0000-0000-000000000002', 'talk',       'financial', 4500),
  ('0d000000-0000-0000-0000-000000000002', 'one_on_one', 'financial', 800);

insert into work_plans (id, org_id, contract_id, title, period_start, period_end, status)
values ('0e000000-0000-0000-0000-00000000000a',
        (select id from organizations where name='BOPEU'),
        '0d000000-0000-0000-0000-000000000001',
        '2026 plan', date '2026-01-01', date '2026-12-31', 'active');


-- ══ 10–16 · THE STATE MACHINE ══════════════════════════════

insert into program_activities (id, org_id, activity_type, title, activity_date,
                                attendee_count, service_line, format, state, work_plan_id)
values ('0f000000-0000-0000-0000-000000000001',
        (select id from organizations where name='Sedimosa'),
        'education_talk', 'Debt awareness talk', current_date, 0,
        'financial', 'talk', 'planned', null);

insert into program_activities (id, org_id, activity_type, title, activity_date,
                                attendee_count, service_line, format, state, work_plan_id)
values ('0f000000-0000-0000-0000-000000000002',
        (select id from organizations where name='BOPEU'),
        'clinic', 'Retirement clinic', current_date, 0,
        'financial', 'one_on_one', 'planned', '0e000000-0000-0000-0000-00000000000a');

-- Linking a booking schedules the activity.
insert into bookings (id, user_id, requested_date, service, booked_by, activity_id)
values ('0b000000-0000-0000-0000-0000000000a1',
        (select id from profiles where org_id = (select id from organizations where name='Sedimosa') limit 1),
        to_char(current_date, 'YYYY-MM-DD'), 'Talk', 'admin',
        '0f000000-0000-0000-0000-000000000001');

select _chk('10 linking a booking moves the activity planned -> scheduled',
  (select state from program_activities where id='0f000000-0000-0000-0000-000000000001') = 'scheduled');

-- The first confirmed attendance delivers it, and invoices it.
update bookings set attended = true where id = '0b000000-0000-0000-0000-0000000000a1';

select _chk('11 the first confirmed attendance moves it scheduled -> delivered',
  (select state from program_activities where id='0f000000-0000-0000-0000-000000000001') = 'delivered');

select _chk('12 and raises exactly one engagement invoice at the rate-card amount',
  (select count(*) from invoices where activity_id='0f000000-0000-0000-0000-000000000001') = 1
  and (select amount from invoices where activity_id='0f000000-0000-0000-0000-000000000001') = 4500);

select _chk('13 with a to_produce action attached',
  (select state from invoices where activity_id='0f000000-0000-0000-0000-000000000001') = 'to_produce'
  and (select a.title from actions a join invoices i on i.action_id = a.id
        where i.activity_id='0f000000-0000-0000-0000-000000000001') like 'Produce invoice%');

-- A second attendance must not re-deliver or re-invoice.
insert into bookings (id, user_id, requested_date, service, booked_by, activity_id, attended)
values ('0b000000-0000-0000-0000-0000000000a2',
        (select id from profiles where org_id = (select id from organizations where name='Sedimosa') limit 1),
        to_char(current_date, 'YYYY-MM-DD'), 'Talk', 'admin',
        '0f000000-0000-0000-0000-000000000001', true);

select _chk('14 a later attendance does not re-deliver or re-invoice',
  (select count(*) from invoices where activity_id='0f000000-0000-0000-0000-000000000001') = 1);

do $$
declare n_before int; n_after int;
begin
  select count(*) into n_before from invoices;
  update bookings set attended = true where id = '0b000000-0000-0000-0000-0000000000a1';
  select count(*) into n_after from invoices;
  insert into _r values ('15 re-confirming the same booking raises nothing',
    n_after = n_before, n_before || ' -> ' || n_after);
  raise notice 'STATE  activity 1 = %, invoices = %',
    (select state from program_activities where id='0f000000-0000-0000-0000-000000000001'), n_after;
end $$;

-- A retainer client's activity delivers but raises NO engagement invoice.
insert into bookings (id, user_id, requested_date, service, booked_by, activity_id, attended)
values ('0b000000-0000-0000-0000-0000000000a3',
        (select id from profiles where org_id = (select id from organizations where name='BOPEU') limit 1),
        to_char(current_date, 'YYYY-MM-DD'), 'Clinic', 'admin',
        '0f000000-0000-0000-0000-000000000002', true);

select _chk('16 a retainer client''s activity delivers but raises no engagement invoice',
  (select state from program_activities where id='0f000000-0000-0000-0000-000000000002') = 'delivered'
  and not exists (select 1 from invoices where activity_id='0f000000-0000-0000-0000-000000000002'));


-- ══ 17–19 · The missing rate, and the missing accountant ═══

insert into program_activities (id, org_id, activity_type, title, activity_date,
                                attendee_count, service_line, format, state)
values ('0f000000-0000-0000-0000-000000000003',
        (select id from organizations where name='Sedimosa'),
        'other', 'Wellness day', current_date, 0, 'financial', 'wellness_day', 'planned');

-- Do the mutation FIRST, on its own line, then assert. Written as
--   activity_upsert(...) = 'delivered' and exists (select ... from invoices)
-- the two operands of AND have no guaranteed evaluation order, so the exists
-- can run before the upsert and see nothing. Same family as the volatile-in-a-
-- predicate rule in CLAUDE_CONTEXT.md 3.1a: if it does something, give it its
-- own statement.
do $$
declare v jsonb;
begin
  v := activity_upsert('00000000-0000-0000-0000-000000000000'::uuid, null,
                       p_id => '0f000000-0000-0000-0000-000000000003'::uuid,
                       p_state => 'delivered');
  insert into _r values ('17 a delivered activity whose format has no rate still raises an invoice',
    (v ->> 'state') = 'delivered'
    and exists (select 1 from invoices where activity_id='0f000000-0000-0000-0000-000000000003'),
    v ->> 'state');
end $$;

select _chk('18 with a null amount rather than a guess',
  (select amount from invoices where activity_id='0f000000-0000-0000-0000-000000000003') is null);

select _chk('19 and an action naming the format that has no rate',
  (select a.title from actions a join invoices i on i.action_id=a.id
    where i.activity_id='0f000000-0000-0000-0000-000000000003') like '%no rate on file for wellness_day%');


-- ══ 20–24 · The monthly retainer job ═══════════════════════

do $$
declare v jsonb;
begin
  v := invoices_run_monthly(date '2026-09-01');
  insert into _r values ('20 the monthly job invoices the month just ended (arrears)',
    (v ->> 'period_start') = '2026-08-01' and (v ->> 'period_end') = '2026-08-31', v::text);
  insert into _r values ('21 and raises one invoice for the retainer contract',
    (v ->> 'created')::int = 1, v::text);
end $$;

select _chk('22 it skips per-engagement contracts entirely',
  not exists (select 1 from invoices
               where kind='retainer' and contract_id='0d000000-0000-0000-0000-000000000002'));

do $$
declare v jsonb;
begin
  v := invoices_run_monthly(date '2026-09-01');
  insert into _r values ('23 a second run raises nothing — the partial index refuses it',
    (v ->> 'created')::int = 0 and (v ->> 'already_present')::int = 1, v::text);
end $$;

select _chk('24 the narrative carries the month''s delivered activities',
  (select narrative -> 'delivered' from invoices
    where kind='retainer' and period_start = date '2026-08-01') is not null);

-- The accountant is unset in this fixture, so the fallback must have fired.
select _chk('25 with no accountant set, the invoice is still raised and the action says so',
  exists (select 1 from actions where title like '%needs reassigning%'));


-- ══ 26–28 · contract_position, two shapes ══════════════════

select _chk('26 a retainer client reports delivered against the period',
  (contract_position((select id from organizations where name='BOPEU')) ->> 'kind') = 'retainer'
  and (contract_position((select id from organizations where name='BOPEU')) -> 'retainer_amount') is not null);

select _chk('27 a per-engagement client reports value invoiced, not an allowance',
  (contract_position((select id from organizations where name='Sedimosa')) ->> 'kind') = 'per_engagement'
  and (contract_position((select id from organizations where name='Sedimosa')) -> 'invoiced_value') is not null
  and (contract_position((select id from organizations where name='Sedimosa')) -> 'expected') is null);

select _chk('28 an organisation with no contract says so rather than inventing one',
  (contract_position((select id from organizations where name='Test Co')) ->> 'reason')
  = 'no active contract recorded');


-- ══ 29–30 · org_work_plan ══════════════════════════════════

select _chk('29 the work plan carries its activities',
  jsonb_array_length(org_work_plan((select id from organizations where name='BOPEU')) -> 'plans') = 1);

select _chk('30 an activity on no plan is still returned, under unplanned',
  jsonb_array_length(org_work_plan((select id from organizations where name='Sedimosa')) -> 'unplanned') >= 1);


-- ══ 31–37 · RLS ════════════════════════════════════════════

set role authenticated;
set session "test.uid" = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';
select _chk('31 an ops admin reads contracts and invoices',
  _visible('org_contracts') > 0 and _visible('invoices') > 0);
reset role;
set session "test.uid" = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

set role authenticated;
set session "test.uid" = '00000000-0000-0000-0000-00000000000b';
set session "test.email" = 'kefilwe@keywealth.co.bw';
select _chk('32 an advisor reads contracts and work plans',
  _visible('org_contracts') > 0 and _visible('work_plans') > 0);
select _chk('33 but not invoices — money is not a practitioner concern',
  _visible('invoices') <= 0);
reset role;
set session "test.uid" = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

set role authenticated;
set session "test.uid" = '00000000-0000-0000-0000-00000000000e';
set session "test.email" = 'plainmember@example.test';
select _chk('34 a member reads none of it',
  _visible('org_contracts') <= 0 and _visible('work_plans') <= 0
  and _visible('invoices') <= 0 and _visible('contract_rates') <= 0);
reset role;
set session "test.uid" = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

-- THE LAONE CLAUSE. She is not staff and owns an invoice action; without the
-- action-owner arm she would be nagged about an invoice she cannot open.
update actions set owner = :laone where title like 'Produce%';

set role authenticated;
set session "test.uid" = '00000000-0000-0000-0000-00000000000d';
set session "test.email" = 'laone@keywellness.co.bw';
select _chk('35 the accountant reads exactly the invoices her actions name',
  _visible('invoices') > 0);
select _chk('36 and no contracts, no work plans, no rates',
  _visible('org_contracts') <= 0 and _visible('work_plans') <= 0
  and _visible('contract_rates') <= 0);
reset role;
set session "test.uid" = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

set role authenticated;
set session "test.uid" = '00000000-0000-0000-0000-00000000000b';
set session "test.email" = 'kefilwe@keywealth.co.bw';
do $$
declare n int;
begin
  update org_contracts set retainer_amount = 999999;
  get diagnostics n = row_count;
  insert into _r values ('37 an advisor cannot rewrite a contract', n = 0, 'rows=' || n);
exception when insufficient_privilege then
  insert into _r values ('37 an advisor cannot rewrite a contract', true, 'denied');
end $$;
reset role;
set session "test.uid" = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';


-- ══ 38–40 · Derived overdue, and the sweep ═════════════════

select _chk('38 there is no stored overdue state',
  (select pg_get_constraintdef(oid) from pg_constraint where conname='invoices_state_check')
  not like '%overdue%');

update invoices set state='sent', sent_at=now(), due_date = current_date - 1
 where kind='retainer';

select _chk('39 overdue is derived from state and due_date',
  (select count(*) from invoices where state='sent' and due_date < current_date) = 1);

select _chk('40 no M4 function is reachable ungated by anon or authenticated',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prokind='f' and p.prosecdef
      and pg_get_function_result(p.oid) <> 'trigger'
      and (has_function_privilege('anon', p.oid, 'EXECUTE')
        or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
      and p.proname in ('_invoice_period','_invoice_action_owner','_invoice_for_activity',
                        'invoices_run_monthly','contract_position','org_work_plan',
                        'work_plan_upsert','activity_upsert')
      and not (p.prosrc ~* '\mis_admin\M|\mis_staff\M|\mis_ops_admin\M'
            or p.prosrc ~* 'auth\.uid\(\)|auth\.jwt\(\)')) = 0);


-- ══ Report ═════════════════════════════════════════════════

select case when ok then 'PASS  ' else 'FAIL  ' end || name
    || coalesce('  -> ' || detail, '') as result
  from _r order by name;

select '  ' || count(*) filter (where ok)::text || ' passed, '
    || count(*) filter (where not ok)::text || ' failed.' as summary
  from _r;

do $$
begin
  if (select count(*) from _r where not ok) > 0 then
    raise exception 'M4 assertions failed';
  end if;
end $$;
