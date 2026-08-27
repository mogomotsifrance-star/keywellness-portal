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

-- The first confirmed attendance delivers it, and billing_handovers it.
update bookings set attended = true where id = '0b000000-0000-0000-0000-0000000000a1';

select _chk('11 the first confirmed attendance moves it scheduled -> delivered',
  (select state from program_activities where id='0f000000-0000-0000-0000-000000000001') = 'delivered');

select _chk('12 and raises exactly one engagement invoice at the rate-card amount',
  (select count(*) from billing_handovers where activity_id='0f000000-0000-0000-0000-000000000001') = 1
  and (select amount from billing_handovers where activity_id='0f000000-0000-0000-0000-000000000001') = 4500);

select _chk('13 with a to_prepare action attached, owned by an ops admin, naming Laone',
  (select state from billing_handovers where activity_id='0f000000-0000-0000-0000-000000000001') = 'to_prepare'
  and (select a.title from actions a join billing_handovers i on i.action_id = a.id
        where i.activity_id='0f000000-0000-0000-0000-000000000001') like 'Hand to Laone%'
  and (select a.owner from actions a join billing_handovers i on i.action_id = a.id
        where i.activity_id='0f000000-0000-0000-0000-000000000001')
      = '00000000-0000-0000-0000-000000000009'::uuid);

-- A second attendance must not re-deliver or re-invoice.
insert into bookings (id, user_id, requested_date, service, booked_by, activity_id, attended)
values ('0b000000-0000-0000-0000-0000000000a2',
        (select id from profiles where org_id = (select id from organizations where name='Sedimosa') limit 1),
        to_char(current_date, 'YYYY-MM-DD'), 'Talk', 'admin',
        '0f000000-0000-0000-0000-000000000001', true);

select _chk('14 a later attendance does not re-deliver or re-invoice',
  (select count(*) from billing_handovers where activity_id='0f000000-0000-0000-0000-000000000001') = 1);

do $$
declare n_before int; n_after int;
begin
  select count(*) into n_before from billing_handovers;
  update bookings set attended = true where id = '0b000000-0000-0000-0000-0000000000a1';
  select count(*) into n_after from billing_handovers;
  insert into _r values ('15 re-confirming the same booking raises nothing',
    n_after = n_before, n_before || ' -> ' || n_after);
  raise notice 'STATE  activity 1 = %, billing_handovers = %',
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
  and not exists (select 1 from billing_handovers where activity_id='0f000000-0000-0000-0000-000000000002'));


-- ══ 17–19 · The missing rate, and the missing accountant ═══

insert into program_activities (id, org_id, activity_type, title, activity_date,
                                attendee_count, service_line, format, state)
values ('0f000000-0000-0000-0000-000000000003',
        (select id from organizations where name='Sedimosa'),
        'other', 'Wellness day', current_date, 0, 'financial', 'wellness_day', 'planned');

-- Do the mutation FIRST, on its own line, then assert. Written as
--   activity_upsert(...) = 'delivered' and exists (select ... from billing_handovers)
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
    and exists (select 1 from billing_handovers where activity_id='0f000000-0000-0000-0000-000000000003'),
    v ->> 'state');
end $$;

select _chk('18 with a null amount rather than a guess',
  (select amount from billing_handovers where activity_id='0f000000-0000-0000-0000-000000000003') is null);

select _chk('19 and an action naming the format that has no rate',
  (select a.title from actions a join billing_handovers i on i.action_id=a.id
    where i.activity_id='0f000000-0000-0000-0000-000000000003') like '%no rate on file for wellness_day%');

-- Laone does not use the platform. Nothing may point at an accountant user.
select _chk('19a no invoice and no action references an accountant user',
  not exists (select 1 from threshold_config where key = 'invoice.accountant_user_id')
  and not exists (select 1 from billing_handovers i
                   where i.prepared_by is not null and not exists (
                     select 1 from admins a join auth.users u on lower(u.email)=lower(a.email)
                      where u.id = i.prepared_by))
  and not exists (select 1 from actions a
                   where a.title like 'Produce invoice%' or a.title like '%accountant%'));


-- ══ 20–25 · The monthly job, within-month ══════════════════
-- The pack is prepared in the LAST WEEK OF THE MONTH IT COVERS. Arrears means
-- within-month here, not previous-month.

do $$
declare v jsonb;
begin
  v := handovers_run_monthly(date '2026-12-25');
  insert into _r values ('20 the job covers the CURRENT month, not the previous one',
    (v ->> 'period_start') = '2026-12-01' and (v ->> 'period_end') = '2026-12-31', v::text);
  insert into _r values ('21 and raises one pack for the retainer contract',
    (v ->> 'created')::int = 1, v::text);
  raise notice 'STATE  monthly job: %', v::text;
end $$;

select _chk('22 it skips per-engagement contracts entirely',
  not exists (select 1 from billing_handovers
               where kind='retainer' and contract_id='0d000000-0000-0000-0000-000000000002'));

do $$
declare v jsonb;
begin
  v := handovers_run_monthly(date '2026-12-25');
  insert into _r values ('23 a second run raises nothing — the partial index refuses it',
    (v ->> 'created')::int = 0 and (v ->> 'already_present')::int = 1, v::text);
end $$;

do $$
declare v jsonb;
begin
  -- cron runs daily and the function decides, so the prepare day stays
  -- configurable without rescheduling.
  v := handovers_run_monthly(date '2026-12-14', true);
  insert into _r values ('24 on a day that is not the prepare day it does nothing',
    (v ->> 'skipped') = 'true', v::text);
end $$;

select _chk('25 the pack is created EMPTY — it is live, not a snapshot',
  (select narrative from billing_handovers
    where kind='retainer' and period_start = date '2026-12-01') = '{}'::jsonb);


-- ══ 25a–25f · THE LIVE PACK ════════════════════════════════
-- Against the CURRENT month, deliberately: pack contents are bounded by now(),
-- so a fixture date in the future falls outside every window and the pack
-- would read 0 for a reason that has nothing to do with the behaviour.

do $$
declare v_pack uuid; n_before int; n_after int; v jsonb; v_this date;
begin
  v_this := date_trunc('month', current_date)::date;
  perform handovers_run_monthly((v_this + 24));       -- the 25th of this month
  select id into v_pack from billing_handovers
   where kind='retainer' and period_start = v_this;

  v := handover_pack(v_pack);
  n_before := (v -> 'contents' ->> 'count')::int;

  insert into program_activities (id, org_id, activity_type, title, activity_date,
                                  attendee_count, service_line, format, state, delivered_at)
  values ('0f000000-0000-0000-0000-00000000000a',
          (select id from organizations where name='BOPEU'),
          'education_talk', 'Delivered after the prepare day', current_date, 30,
          'financial', 'talk', 'delivered', now());

  v := handover_pack(v_pack);
  n_after := (v -> 'contents' ->> 'count')::int;

  insert into _r values ('25a a pack recomputes when an activity is delivered after the prepare day',
    (v ->> 'live') = 'true' and n_after = n_before + 1, n_before || ' -> ' || n_after);
  raise notice 'STATE  live pack: % -> % activities after a late delivery', n_before, n_after;
end $$;

do $$
declare v_pack uuid; v jsonb; n_frozen int; n_later int; v_this date;
begin
  v_this := date_trunc('month', current_date)::date;
  select id into v_pack from billing_handovers
   where kind='retainer' and period_start = v_this;

  v := handover_mark_handed_over(v_pack);
  n_frozen := (v -> 'contents' ->> 'count')::int;

  insert into _r values ('25b marking it handed over freezes it and closes the action',
    (v ->> 'state') = 'handed_over'
    and (select state from billing_handovers where id = v_pack) = 'handed_over'
    and (select a.state from actions a join billing_handovers i on i.action_id = a.id
          where i.id = v_pack) = 'done',
    n_frozen::text);

  insert into program_activities (id, org_id, activity_type, title, activity_date,
                                  attendee_count, service_line, format, state, delivered_at)
  values ('0f000000-0000-0000-0000-00000000000b',
          (select id from organizations where name='BOPEU'),
          'education_talk', 'Delivered after handover', current_date, 12,
          'financial', 'talk', 'delivered', clock_timestamp());
  -- clock_timestamp(), not now(): now() is TRANSACTION-START time, so a row
  -- inserted after handover_mark_handed_over() in the same block would carry exactly
  -- handed_at and the strict '> covers_from' boundary would drop it — from both
  -- packs. Real deliveries land in later transactions; the test must too.

  v := handover_pack(v_pack);
  n_later := (v -> 'contents' ->> 'count')::int;

  insert into _r values ('25c and a later delivery does not change it',
    (v ->> 'live') = 'false' and n_later = n_frozen, n_frozen || ' -> ' || n_later);
  raise notice 'STATE  frozen pack: % activities, unchanged by a later delivery (%)',
    n_frozen, n_later;
end $$;

do $$
declare v_next uuid; v jsonb; v_titles text; v_next_month date;
begin
  -- The next pack starts where the last handover left off. Its label is the
  -- next calendar month; its WINDOW is (handed_at, now()].
  v_next_month := (date_trunc('month', current_date) + interval '1 month')::date;
  perform handovers_run_monthly((v_next_month + 24));
  select id into v_next from billing_handovers
   where kind='retainer' and period_start = v_next_month;

  v := handover_pack(v_next);
  select string_agg(x ->> 'title', ', ')
    into v_titles from jsonb_array_elements(v -> 'contents' -> 'delivered') x;

  insert into _r values ('25d the later delivery lands in the NEXT period''s pack',
    coalesce(v_titles, '') like '%Delivered after handover%', coalesce(v_titles, '(empty)'));
  insert into _r values ('25e and nothing is counted twice',
    coalesce(v_titles, '') not like '%Delivered after the prepare day%',
    coalesce(v_titles, '(empty)'));
  raise notice 'STATE  next pack contains: %', coalesce(v_titles, '(empty)');
end $$;

do $$
declare v_pack uuid; ok boolean := false;
begin
  select id into v_pack from billing_handovers
   where kind='retainer' and period_start = date_trunc('month', current_date)::date;
  begin
    perform handover_mark_handed_over(v_pack);
  exception when others then ok := sqlerrm = 'this pack has already been handed over';
  end;
  insert into _r values ('25f a pack cannot be handed over twice', ok, null);
end $$;


-- ══ 25g–25j · Lone's confirmation ══════════════════════════
-- 'invoiced' means LONE CONFIRMED WITH LAONE THAT THE INVOICE EXISTS. It is
-- not a reading of Sage, and there is no state after it.

do $$
declare v_pack uuid; v jsonb; v_at timestamptz;
begin
  select id into v_pack from billing_handovers
   where kind='retainer' and period_start = date_trunc('month', current_date)::date;

  v := handover_confirm_invoiced(v_pack);
  insert into _r values ('25g a handed-over pack records Lone''s confirmation',
    (v ->> 'state') = 'invoiced'
    and (v ->> 'already_confirmed') = 'false'
    and (select invoice_confirmed_at from billing_handovers where id = v_pack) is not null
    and (select invoice_confirmed_by from billing_handovers where id = v_pack) is not null,
    v::text);
  select invoice_confirmed_at into v_at from billing_handovers where id = v_pack;

  -- Confirming twice is somebody checking, not an error.
  v := handover_confirm_invoiced(v_pack);
  insert into _r values ('25h confirming twice is not an error and does not move the moment',
    (v ->> 'already_confirmed') = 'true'
    and (select invoice_confirmed_at from billing_handovers where id = v_pack) = v_at,
    v::text);
end $$;

do $$
declare v_next uuid; ok boolean := false; msg text := '';
begin
  select id into v_next from billing_handovers
   where kind='retainer'
     and period_start = (date_trunc('month', current_date) + interval '1 month')::date;
  begin
    perform handover_confirm_invoiced(v_next);
  exception when others then ok := sqlerrm like '%handed to Laone%'; msg := sqlerrm;
  end;
  insert into _r values ('25i Laone cannot confirm an invoice for numbers she has not been given',
                         ok, msg);
end $$;

-- Cancelling, from any state, and only with a reason.
do $$
declare v_pack uuid; v jsonb; ok boolean := false; msg text := '';
begin
  select id into v_pack from billing_handovers
   where kind='retainer' and period_start = date_trunc('month', current_date)::date;

  begin
    perform handover_cancel(v_pack, '   ');
  exception when others then ok := sqlerrm like '%say why%'; msg := sqlerrm;
  end;
  insert into _r values ('25j cancelling with no reason is refused', ok, msg);

  -- From 'invoiced', which is the furthest state there is.
  v := handover_cancel(v_pack, 'client disputed the August figures');
  insert into _r values ('25k cancelled is reachable from any state, and clears the confirmation',
    (v ->> 'state') = 'cancelled'
    and (select invoice_confirmed_at from billing_handovers where id = v_pack) is null
    and (select cancel_reason from billing_handovers where id = v_pack) like '%disputed%',
    v::text);
end $$;


-- ══ 25l–25o · Nothing here knows what Sage holds ═══════════
-- The rule these enforce: invoices are produced in Sage, this system never
-- sees one, and no column or state may claim otherwise.

select _chk('25l there is no paid state and no overdue state, and never may be',
  (select pg_get_constraintdef(oid) from pg_constraint
    where conname='billing_handovers_state_check') !~* '\mpaid\M'
  and (select pg_get_constraintdef(oid) from pg_constraint
    where conname='billing_handovers_state_check') !~* '\moverdue\M');

select _chk('25m the handover carries no scan, no paid date and no due date',
  not exists (select 1 from information_schema.columns
               where table_schema='public' and table_name='billing_handovers'
                 and column_name in ('scan_path','paid_at','due_date')));

select _chk('25n there is no function to mark a handover paid',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
               where n.nspname='public'
                 and p.proname in ('invoice_mark_paid','handover_mark_paid')));

-- A DO block, because PostgreSQL PARSES storage.buckets whether or not a
-- to_regclass guard in the same expression ever reaches it, and there is no
-- storage schema on a plain database. Same trap as tests/m4-verify-live.sql.
do $$
declare n int := 0;
begin
  if to_regclass('storage.buckets') is not null then
    execute $q$ select count(*) from storage.buckets where id = 'invoice-scans' $q$ into n;
  end if;
  insert into _r values ('25n2 there is no invoice-scans bucket', n = 0, 'buckets=' || n);
end $$;

-- The action tells Lone to hand the numbers to Laone, and is due at MONTH END
-- because that is a date we know. The handover itself has no date.
select _chk('25o the handover action is due at month end and names Laone',
  exists (select 1 from actions a
           join billing_handovers h on h.action_id = a.id
          where h.kind = 'retainer'
            and a.title like '%to Laone%'
            and a.due_date = h.period_end));


-- ══ 26–28 · contract_position, two shapes ══════════════════

select _chk('26 a retainer client reports delivered against the period',
  (contract_position((select id from organizations where name='BOPEU')) ->> 'kind') = 'retainer'
  and (contract_position((select id from organizations where name='BOPEU')) -> 'retainer_amount') is not null);

select _chk('27 a per-engagement client reports value HANDED OVER, not invoiced',
  (contract_position((select id from organizations where name='Sedimosa')) ->> 'kind') = 'per_engagement'
  and (contract_position((select id from organizations where name='Sedimosa')) -> 'handed_over_value') is not null
  and (contract_position((select id from organizations where name='Sedimosa')) -> 'confirmed_value') is not null
  -- The word we cannot honestly use is gone from the payload entirely.
  and (contract_position((select id from organizations where name='Sedimosa')) -> 'invoiced_value') is null
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
select _chk('31 an ops admin reads contracts and billing_handovers',
  _visible('org_contracts') > 0 and _visible('billing_handovers') > 0);
reset role;
set session "test.uid" = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

set role authenticated;
set session "test.uid" = '00000000-0000-0000-0000-00000000000b';
set session "test.email" = 'kefilwe@keywealth.co.bw';
select _chk('32 an advisor reads contracts and work plans',
  _visible('org_contracts') > 0 and _visible('work_plans') > 0);
select _chk('33 but not billing_handovers — money is not a practitioner concern',
  _visible('billing_handovers') <= 0);
reset role;
set session "test.uid" = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

set role authenticated;
set session "test.uid" = '00000000-0000-0000-0000-00000000000e';
set session "test.email" = 'plainmember@example.test';
select _chk('34 a member reads none of it',
  _visible('org_contracts') <= 0 and _visible('work_plans') <= 0
  and _visible('billing_handovers') <= 0 and _visible('contract_rates') <= 0);
reset role;
set session "test.uid" = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

-- There is no accountant user, so there is no non-staff invoice owner and the
-- read policy is ops-admin only. An earlier draft carried an action-owner arm
-- for Laone; it protected nobody once she left the platform, so it went.
set role authenticated;
set session "test.uid" = '00000000-0000-0000-0000-00000000000d';
set session "test.email" = 'laone@keywellness.co.bw';
select _chk('35 someone with no role reads no billing_handovers at all',
  _visible('billing_handovers') <= 0);
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


-- ══ 38–39 · The Tuesday-review flag, and the sweep ═════════

-- The four states, and only those four. 'sent' was always wrong -- the system
-- never sends. 'paid' and 'overdue' describe a document in Sage.
select _chk('38 the states are exactly to_prepare, handed_over, invoiced, cancelled',
  (select pg_get_constraintdef(oid) from pg_constraint
    where conname='billing_handovers_state_check')
    like '%to_prepare%handed_over%invoiced%cancelled%');

-- ── The flag Lone asked for ────────────────────────────────
-- A retainer period past its prepare day with no invoiced confirmation must
-- reach the TUESDAY REVIEW as needs-a-decision, not only the screen.
do $$
declare v_org uuid; v_pack uuid; v jsonb; x jsonb; v_before boolean; v_after boolean;
begin
  select id into v_org from organizations where name='BOPEU';

  -- Before: no late retainer period, so BOPEU is not flagged for billing.
  delete from billing_handovers where org_id = v_org and kind = 'retainer';
  v := tuesday_review_pack(current_date);
  select e into x from jsonb_array_elements(v -> 'organisations') e
   where e ->> 'name' = 'BOPEU';
  v_before := jsonb_array_length(x -> 'billing') > 0;
  insert into _r values ('38a with no late period, the Tuesday review shows no billing flag',
    not v_before, coalesce(x -> 'billing', 'null')::text);

  -- A retainer period from two months ago, never confirmed.
  insert into billing_handovers (contract_id, org_id, kind, period_start, period_end,
                                 amount, currency, state, covers_from)
  values ((select id from org_contracts where org_id = v_org and contract_kind='retainer' limit 1),
          v_org, 'retainer',
          (date_trunc('month', current_date) - interval '2 months')::date,
          (date_trunc('month', current_date) - interval '1 month' - interval '1 day')::date,
          15000, 'BWP', 'to_prepare',
          (date_trunc('month', current_date) - interval '2 months'));

  v := tuesday_review_pack(current_date);
  select e into x from jsonb_array_elements(v -> 'organisations') e
   where e ->> 'name' = 'BOPEU';
  v_after := jsonb_array_length(x -> 'billing') > 0;

  insert into _r values ('38b a period past its prepare day with no confirmation is flagged',
    v_after, coalesce(x -> 'billing', 'null')::text);
  insert into _r values ('38c and it says which month, in words a person can read',
    (x -> 'billing' -> 0 ->> 'label') like '%not confirmed invoiced%',
    x -> 'billing' -> 0 ->> 'label');
  insert into _r values ('38d and it makes the organisation need a decision',
    (x ->> 'needs_decision') = 'true', x ->> 'needs_decision');
  raise notice 'STATE  Tuesday flag: % -> %  (%)', v_before, v_after,
    coalesce(x -> 'billing' -> 0 ->> 'label', '(none)');
end $$;

-- Confirming it clears the flag. Nothing else does.
do $$
declare v_org uuid; v_pack uuid; v jsonb; x jsonb;
begin
  select id into v_org from organizations where name='BOPEU';
  select id into v_pack from billing_handovers
   where org_id = v_org and kind='retainer'
     and period_start = (date_trunc('month', current_date) - interval '2 months')::date;

  perform handover_mark_handed_over(v_pack);
  v := tuesday_review_pack(current_date);
  select e into x from jsonb_array_elements(v -> 'organisations') e where e ->> 'name'='BOPEU';
  insert into _r values ('38e handing the numbers over does NOT clear the flag',
    jsonb_array_length(x -> 'billing') > 0, coalesce(x -> 'billing','null')::text);

  perform handover_confirm_invoiced(v_pack);
  v := tuesday_review_pack(current_date);
  select e into x from jsonb_array_elements(v -> 'organisations') e where e ->> 'name'='BOPEU';
  insert into _r values ('38f only Lone''s confirmation clears it',
    jsonb_array_length(x -> 'billing') = 0, coalesce(x -> 'billing','null')::text);
end $$;

-- The rest of the M5 payload must be untouched by that change.
select _chk('39 tuesday_review_pack keeps every key M5 returned',
  (select tuesday_review_pack(current_date)) ?& array['as_of','meeting_id',
    'previous_meeting_id','completion_rate','organisations','unassigned']);

select _chk('40 no M4 function is reachable ungated by anon or authenticated',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prokind='f' and p.prosecdef
      and pg_get_function_result(p.oid) <> 'trigger'
      and (has_function_privilege('anon', p.oid, 'EXECUTE')
        or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
      and p.proname in ('_handover_period','_handover_owner','_pack_contents',
                        '_handover_for_activity','handovers_run_monthly','handover_pack',
                        'handover_mark_handed_over','handover_confirm_invoiced','handover_cancel',
                        '_billing_flags',
                        'contract_position','org_work_plan','work_plan_upsert',
                        'activity_upsert')
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
