-- ============================================================
-- Key Wellness — M5 assertions (local PostgreSQL 17 only)
--
-- Run by tests/run-m5.sh after the fixture and the migration.
-- Emits PASS / FAIL lines and a count, like tests/phase0-tests.sql.
--
-- RLS IS ENFORCED HERE. Access assertions run under `set role authenticated`,
-- which is not the table owner, so PostgreSQL applies the policies. Assertions
-- that set up data run as postgres. Every block says which it is.
-- ============================================================

\set ON_ERROR_STOP on
set client_min_messages to notice;

-- A real table, not a temporary one: half these assertions run under
-- `set role authenticated`, and a temp table owned by postgres is not
-- writable by another role without wrestling the per-session temp schema.
-- The database is thrown away by the harness anyway.
drop table if exists _r;
create table _r (name text, ok boolean, detail text);
grant insert, select on _r to authenticated;

create or replace function _chk(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $$
begin insert into _r values (p_name, p_ok, p_detail); end $$;

-- Counts rows visible to the CURRENT role. Deliberately NOT security definer:
-- the whole point is that RLS applies to whoever is calling. A permission
-- error returns -1 so a denied read is distinguishable from an empty one.
create or replace function _visible(p_table text)
returns int language plpgsql as $$
declare n int;
begin
  execute format('select count(*) from %I', p_table) into n;
  return n;
exception when insufficient_privilege then return -1;
end $$;

-- People, by uuid, so the assertions read as sentences.
\set lone     '''00000000-0000-0000-0000-000000000009'''
\set michelle '''00000000-0000-0000-0000-00000000000a'''
\set kefilwe  '''00000000-0000-0000-0000-00000000000b'''
\set katlo    '''00000000-0000-0000-0000-00000000000c'''
\set laone    '''00000000-0000-0000-0000-00000000000d'''
\set member   '''00000000-0000-0000-0000-00000000000e'''
\set hr       '''00000000-0000-0000-0000-00000000000f'''
\set bopeu    '''0a000000-0000-0000-0000-0000000000b0'''
\set sedimosa '''0a000000-0000-0000-0000-0000000000d0'''
\set testco   '''0a000000-0000-0000-0000-0000000000c0'''


-- ══ Setup, as postgres ══════════════════════════════════════
-- Test Co is flagged, which is also the assertion that the column works.
update organizations set is_test = true where id = :testco;

-- Last week's meeting and this week's, plus a spread of actions.
insert into meetings (id, kind, held_on, org_id, created_by, attendees) values
  ('0e000000-0000-0000-0000-000000000001', 'tuesday_review', date '2026-08-18', null, :lone,
   array[:lone::uuid, :kefilwe::uuid]);

insert into actions (id, title, owner, due_date, state, org_id, meeting_id, created_by, done_at) values
  -- last week, BOPEU: one done, one open, one carried, one abandoned
  ('0c000000-0000-0000-0000-000000000001','Send BOPEU report',   :kefilwe, date '2026-08-20','done',   :bopeu, '0e000000-0000-0000-0000-000000000001', :lone, now()),
  ('0c000000-0000-0000-0000-000000000002','Book BOPEU webinar',  :kefilwe, date '2026-08-21','open',   :bopeu, '0e000000-0000-0000-0000-000000000001', :lone, null),
  ('0c000000-0000-0000-0000-000000000003','Chase BOPEU HR',      :lone,    date '2026-08-21','dropped',:bopeu, '0e000000-0000-0000-0000-000000000001', :lone, null),
  ('0c000000-0000-0000-0000-000000000004','Idea we abandoned',   :lone,    date '2026-08-21','dropped',:bopeu, '0e000000-0000-0000-0000-000000000001', :lone, null),
  -- the successor that makes #3 "carried" rather than abandoned
  ('0c000000-0000-0000-0000-000000000005','Chase BOPEU HR',      :lone,    date '2026-08-28','open',   :bopeu, null, :lone, null),
  -- Sedimosa, and one with no organisation at all
  ('0c000000-0000-0000-0000-000000000006','Sedimosa flyer',      :kefilwe, date '2026-08-27','open',   :sedimosa, null, :lone, null),
  ('0c000000-0000-0000-0000-000000000007','Fix the printer',     :michelle,date '2026-08-27','open',   null, null, :lone, null),
  -- Test Co, which must never surface
  ('0c000000-0000-0000-0000-000000000008','Test Co thing',       :lone,    date '2026-08-27','open',   :testco, null, :lone, null),
  -- Laone owns one. She is not staff.
  ('0c000000-0000-0000-0000-000000000009','Produce August invoices', :laone, date '2026-09-01','open', :bopeu, null, :lone, null);

update actions set carried_from = '0c000000-0000-0000-0000-000000000003'
 where id = '0c000000-0000-0000-0000-000000000005';


-- ══ 1–6 · Shape and constraints (postgres) ══════════════════

select _chk('1  organizations.is_test exists and defaults false',
  (select count(*) from organizations where not is_test) = 3
  and (select count(*) from organizations where is_test) = 1);

do $$
declare ok boolean := false;
begin
  begin
    insert into meetings (kind, held_on, org_id, created_by)
    values ('tuesday_review', date '2026-08-18', null,
            '00000000-0000-0000-0000-000000000009');
    raise exception 'accepted';
  exception when unique_violation then ok := true; when others then ok := false;
  end;
  insert into _r values ('2  a second tuesday_review on one date is refused (NULLS NOT DISTINCT)', ok, null);
end $$;

do $$
declare ok boolean := false;
begin
  begin
    insert into meetings (kind, held_on, created_by)
    values ('workshop', date '2026-08-19', '00000000-0000-0000-0000-000000000009');
    raise exception 'accepted';
  exception when check_violation then ok := true; when others then ok := false;
  end;
  insert into _r values ('3  an unknown meeting kind is refused', ok, null);
end $$;

do $$
declare ok boolean := false;
begin
  begin
    update actions set state = 'nonsense'
     where id = '0c000000-0000-0000-0000-000000000002';
    raise exception 'accepted';
  exception when check_violation then ok := true; when others then ok := false;
  end;
  insert into _r values ('4  an unknown action state is refused', ok, null);
end $$;

do $$
declare ok boolean := false;
begin
  begin
    -- done without done_at breaks the agreement constraint
    update actions set state = 'done', done_at = null
     where id = '0c000000-0000-0000-0000-000000000002';
    raise exception 'accepted';
  exception when check_violation then ok := true; when others then ok := false;
  end;
  insert into _r values ('5  state=done with no done_at is refused', ok, null);
end $$;

do $$
declare ok boolean := false;
begin
  begin
    update actions set carried_from = id
     where id = '0c000000-0000-0000-0000-000000000002';
    raise exception 'accepted';
  exception when check_violation then ok := true; when others then ok := false;
  end;
  insert into _r values ('6  an action cannot carry from itself', ok, null);
end $$;


-- ══ 7–15 · RLS, as `authenticated` ══════════════════════════
-- Every block below sets the role AND the identity, then resets.

-- 7 admin reads everything
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';
select _chk('7  an admin reads all meetings and all actions',
  _visible('meetings') = 1 and _visible('actions') = 9);
reset role;

-- 8 advisor reads everything
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000b';
set session "test.email" = 'kefilwe@keywealth.co.bw';
select _chk('8  an advisor reads all meetings and all actions',
  _visible('meetings') = 1 and _visible('actions') = 9);
reset role;

-- 9 member reads neither
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000e';
set session "test.email" = 'member@example.test';
select _chk('9  a member reads no meeting and no action',
  _visible('meetings') = 0 and _visible('actions') = 0);
reset role;

-- 10 HR reads neither
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000f';
set session "test.email" = 'hr@bopeu.test';
select _chk('10 an HR user reads no meeting and no action',
  _visible('meetings') = 0 and _visible('actions') = 0);
reset role;

-- 11 THE ONE THAT MATTERS: an owner who is not staff.
-- Laone owns exactly one action and is neither admin nor advisor. She must see
-- that action and nothing else, or she gets a reminder she cannot open.
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000d';
set session "test.email" = 'laone@keywellness.co.bw';
select _chk('11 an owner who is not staff reads exactly their own action',
  _visible('actions') = 1
  and (select count(*) from actions where owner = '00000000-0000-0000-0000-00000000000d'::uuid) = 1);
select _chk('12 and still reads no meetings',
  _visible('meetings') = 0);
reset role;

-- 13 owner can update their own
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000d';
set session "test.email" = 'laone@keywellness.co.bw';
do $$
declare n int;
begin
  update actions set title = 'Produce August invoices (edited)'
   where id = '0c000000-0000-0000-0000-000000000009';
  get diagnostics n = row_count;
  insert into _r values ('13 the owner can update their own action', n = 1, 'rows=' || n);
end $$;
reset role;

-- 14 creator can update an action they do not own
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';
do $$
declare n int;
begin
  update actions set due_date = date '2026-08-22'
   where id = '0c000000-0000-0000-0000-000000000002';   -- owned by Kefilwe, created by Lone
  get diagnostics n = row_count;
  insert into _r values ('14 the creator can update an action owned by someone else', n = 1, 'rows=' || n);
end $$;
reset role;

-- 15 an uninvolved staff member cannot update
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000c';
set session "test.email" = 'katlo@keywealth.co.bw';
do $$
declare n int;
begin
  update actions set title = 'Katlo was here'
   where id = '0c000000-0000-0000-0000-000000000009';   -- Laone's, created by Lone
  get diagnostics n = row_count;
  insert into _r values ('15 an uninvolved staff member cannot update it', n = 0, 'rows=' || n);
end $$;
reset role;

-- 16 non-admin cannot delete; 17 admin can
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000b';
set session "test.email" = 'kefilwe@keywealth.co.bw';
do $$
declare n int;
begin
  delete from actions where id = '0c000000-0000-0000-0000-000000000007';
  get diagnostics n = row_count;
  insert into _r values ('16 an advisor cannot delete an action', n = 0, 'rows=' || n);
end $$;
reset role;

set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';
do $$
declare n int;
begin
  delete from actions where id = '0c000000-0000-0000-0000-000000000008';   -- the Test Co one
  get diagnostics n = row_count;
  insert into _r values ('17 an admin can delete an action', n = 1, 'rows=' || n);
end $$;
reset role;

-- put it back for the pack assertions
insert into actions (id, title, owner, due_date, state, org_id, created_by)
values ('0c000000-0000-0000-0000-000000000008','Test Co thing',
        '00000000-0000-0000-0000-000000000009', date '2026-08-27','open',
        '0a000000-0000-0000-0000-0000000000c0','00000000-0000-0000-0000-000000000009');

-- 18 nobody reads the ledger, admin included
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';
select _chk('18 not even an admin reads action_reminders directly',
  _visible('action_reminders') <= 0);
reset role;


-- ══ 19–27 · Reminders (postgres; the function is definer-only) ══
-- p_today drives the clock. Due dates in the seed sit around 2026-08-27.

select _chk('19 an action due in exactly 3 days produces one due_in_3',
  ((action_reminders_run(date '2026-08-24') -> 'sent' ->> 'due_in_3')::int) >= 1);

select _chk('20 the reminder is addressed to the owner, not the creator',
  exists (select 1 from notifications n
           where n.type = 'action_due_in_3'
             and n.user_id = '00000000-0000-0000-0000-00000000000b'::uuid));

do $$
declare before_n int; after_n int; res jsonb;
begin
  select count(*) into before_n from notifications;
  res := action_reminders_run(date '2026-08-24');
  select count(*) into after_n from notifications;
  insert into _r values ('21 running it again the same day writes nothing',
    after_n = before_n and (res ->> 'skipped_already_sent')::int > 0,
    'before=' || before_n || ' after=' || after_n);
end $$;

select _chk('22 the ledger holds exactly one row per (action, kind)',
  (select count(*) from action_reminders where kind = 'due_in_3')
    = (select count(distinct action_id) from action_reminders where kind = 'due_in_3'));

select _chk('23 due tomorrow produces due_tomorrow',
  ((action_reminders_run(date '2026-08-26') -> 'sent' ->> 'due_tomorrow')::int) >= 1);

select _chk('25 overdue fires once',
  ((action_reminders_run(date '2026-09-05') -> 'sent' ->> 'overdue')::int) >= 1);

do $$
declare res jsonb;
begin
  res := action_reminders_run(date '2026-09-06');
  insert into _r values ('26 and does not fire again the next day',
    (res -> 'sent' ->> 'overdue')::int = 0, res::text);
end $$;

-- 24 · the boundary either side of three days.
-- This needs an action of its own, and it has to run AFTER the overdue
-- assertions. An earlier version asserted on the aggregate count for
-- 2026-08-25 and failed, because the seed happens to hold an action due
-- 2026-08-28 -- exactly three days out -- so the run was correct and the
-- assertion was measuring the wrong thing.
insert into actions (id, title, owner, due_date, state, created_by)
values ('0c00000b-0000-0000-0000-00000000002a', 'Boundary probe',
        '00000000-0000-0000-0000-00000000000b', date '2026-10-10', 'open',
        '00000000-0000-0000-0000-000000000009');

do $$
declare res jsonb;
begin
  res := action_reminders_run(date '2026-10-08');   -- two days out
  insert into _r values ('24 two days out produces no reminder for that action',
    not exists (select 1 from action_reminders
                 where action_id = '0c00000b-0000-0000-0000-00000000002a'::uuid),
    res::text);

  res := action_reminders_run(date '2026-10-07');   -- three days out
  insert into _r values ('24b three days out produces exactly one due_in_3 for it',
    (select count(*) from action_reminders
      where action_id = '0c00000b-0000-0000-0000-00000000002a'::uuid
        and kind = 'due_in_3') = 1,
    res::text);
end $$;

select _chk('27 done and dropped actions are never reminded',
  not exists (
    select 1 from action_reminders r join actions a on a.id = r.action_id
     where a.state <> 'open'));

select _chk('28 unrelated notification types are untouched',
  (select count(*) from notifications where type = 'booking_received') = 0
  and (select count(*) from notifications where type like 'action\_%') > 0);


-- ══ 29–36 · The RPCs ════════════════════════════════════════

-- 29–33 the pack, as an admin under RLS
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

select _chk('29 the pack lists the active, non-test organisations only',
  (select jsonb_array_length(tuesday_review_pack(date '2026-08-25') -> 'organisations')) = 2,
  (select (tuesday_review_pack(date '2026-08-25') -> 'organisations')::text));

select _chk('30 Test Co never appears in the roll-call',
  not exists (
    select 1 from jsonb_array_elements(
                    tuesday_review_pack(date '2026-08-25') -> 'organisations') o
     where o ->> 'name' = 'Test Co'));

select _chk('31 last week''s carried action is labelled carried, not dropped',
  exists (
    select 1 from jsonb_array_elements(
                    tuesday_review_pack(date '2026-08-25') -> 'organisations') o,
                  jsonb_array_elements(o -> 'last_week') a
     where a ->> 'id' = '0c000000-0000-0000-0000-000000000003'
       and a ->> 'label' = 'carried'));

select _chk('32 the abandoned one is still labelled dropped',
  exists (
    select 1 from jsonb_array_elements(
                    tuesday_review_pack(date '2026-08-25') -> 'organisations') o,
                  jsonb_array_elements(o -> 'last_week') a
     where a ->> 'id' = '0c000000-0000-0000-0000-000000000004'
       and a ->> 'label' = 'dropped'));

-- done=1; denominator = done 1 + open 1 + dropped-with-successor 1 = 3 -> 33.3
select _chk('33 completion_rate counts carried in the denominator and abandoned out of it',
  (tuesday_review_pack(date '2026-08-25') ->> 'completion_rate')::numeric = 33.3,
  (tuesday_review_pack(date '2026-08-25') ->> 'completion_rate'));

-- Names the action rather than counting the bucket. A bare count is brittle:
-- an earlier version asserted "= 1" and broke the moment the reminder block
-- added a probe action that also had no organisation.
select _chk('34 an action with no organisation lands in the unassigned bucket',
  exists (
    select 1 from jsonb_array_elements(
                    tuesday_review_pack(date '2026-08-25') #> '{unassigned,open_now}') a
     where a ->> 'id' = '0c000000-0000-0000-0000-000000000007'));

reset role;

-- 35 a member cannot call the pack at all
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000e';
set session "test.email" = 'member@example.test';
do $$
declare ok boolean := false;
begin
  begin
    perform tuesday_review_pack(date '2026-08-25');
  exception when others then ok := sqlerrm = 'not authorised';
  end;
  insert into _r values ('35 a member calling the pack is refused', ok, null);
end $$;
reset role;

-- 36–37 tuesday_review_open is idempotent
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';
do $$
declare a jsonb; b jsonb;
begin
  a := tuesday_review_open(date '2026-08-25');
  b := tuesday_review_open(date '2026-08-25');
  insert into _r values ('36 tuesday_review_open twice returns the same meeting',
    (a ->> 'meeting_id') = (b ->> 'meeting_id')
    and (a ->> 'created') = 'true' and (b ->> 'created') = 'false',
    'a=' || (a ->> 'created') || ' b=' || (b ->> 'created'));

  insert into _r values ('37 and offers last week''s still-open actions to carry',
    jsonb_array_length(a -> 'carry_candidates') = 1
    and (a -> 'carry_candidates' -> 0 ->> 'id') = '0c000000-0000-0000-0000-000000000002',
    (a -> 'carry_candidates')::text);
end $$;
reset role;

-- 38–40 action_upsert
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';
do $$
declare v jsonb; w jsonb;
begin
  v := action_upsert('A new action', '00000000-0000-0000-0000-00000000000b'::uuid,
                     date '2026-09-10', p_org_id => '0a000000-0000-0000-0000-0000000000d0');
  insert into _r values ('38 action_upsert inserts and stamps created_by',
    (v ->> 'state') = 'open'
    and (select created_by from actions where id = (v ->> 'id')::uuid)
        = '00000000-0000-0000-0000-000000000009'::uuid, v::text);

  w := action_upsert('A new action', '00000000-0000-0000-0000-00000000000b'::uuid,
                     date '2026-09-10', p_id => (v ->> 'id')::uuid, p_state => 'done');
  insert into _r values ('39 marking it done sets done_at in the same statement',
    (w ->> 'state') = 'done' and (w ->> 'done_at') is not null, w::text);

  -- carrying: the successor is created and the predecessor drops, together
  w := action_upsert('Chase BOPEU HR again', '00000000-0000-0000-0000-000000000009'::uuid,
                     date '2026-09-03',
                     p_carried_from => '0c000000-0000-0000-0000-000000000002'::uuid);
  -- The label is derived inline here rather than by calling _action_label:
  -- that helper is revoked from authenticated (assertion 44), so a test
  -- running as authenticated must not depend on it. This is the derivation
  -- the helper performs.
  insert into _r values ('40 carrying forward drops the predecessor and links the successor',
    (select state from actions where id = '0c000000-0000-0000-0000-000000000002') = 'dropped'
    and (w ->> 'carried_from') = '0c000000-0000-0000-0000-000000000002'
    and exists (select 1 from actions s
                 where s.carried_from = '0c000000-0000-0000-0000-000000000002'::uuid)
    and (w ->> 'label') = 'open');
end $$;
reset role;

-- 41 a staff member cannot edit an action they neither own nor created
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000c';
set session "test.email" = 'katlo@keywealth.co.bw';
do $$
declare ok boolean := false;
begin
  begin
    perform action_upsert('hijack', '00000000-0000-0000-0000-00000000000c'::uuid,
                          date '2026-09-09',
                          p_id => '0c000000-0000-0000-0000-000000000009'::uuid);
  exception when others then ok := sqlerrm = 'not authorised';
  end;
  insert into _r values ('41 action_upsert refuses an edit by an uninvolved staff member', ok, null);
end $$;
reset role;


-- ══ 42 · The sweep ══════════════════════════════════════════
-- No new SECURITY DEFINER function may be reachable by anon or authenticated
-- without an internal gate. is_staff() is the new gate name, so the CLAUDE.md
-- regex gains it — see the build record.

select _chk('42 no ungated SECURITY DEFINER function is reachable by anon or authenticated',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
      and pg_get_function_result(p.oid) <> 'trigger'
      and (has_function_privilege('anon', p.oid, 'EXECUTE')
        or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
      and p.proname in ('is_staff','_action_label','action_reminders_run',
                        'tuesday_review_open','tuesday_review_pack','action_upsert')
      and not (p.prosrc ~* '\mis_admin\M|\mis_advisor\M|\mis_staff\M'
            or p.prosrc ~* 'auth\.uid\(\)|auth\.jwt\(\)')) = 0);

select _chk('43 the reminder writer is callable by nobody but its owner',
  not has_function_privilege('authenticated',
        'action_reminders_run(date)', 'EXECUTE')
  and not has_function_privilege('anon',
        'action_reminders_run(date)', 'EXECUTE'));

select _chk('44 the label helper is revoked too',
  not has_function_privilege('authenticated', '_action_label(uuid, text)', 'EXECUTE'));


-- ══ Report ══════════════════════════════════════════════════

select case when ok then 'PASS  ' else 'FAIL  ' end || name
    || coalesce('  -> ' || detail, '') as result
  from _r order by name;

select '  ' || count(*) filter (where ok)::text || ' passed, '
    || count(*) filter (where not ok)::text || ' failed.' as summary
  from _r;

do $$
begin
  if (select count(*) from _r where not ok) > 0 then
    raise exception 'M5 assertions failed';
  end if;
end $$;
