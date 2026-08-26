-- ============================================================
-- Key Wellness — M5a assertions (local PostgreSQL 17 only)
--
-- Run by tests/run-m5a.sh after m5-fixture.sql + m5a-fixture-extra.sql,
-- the M5 migration and the M5a migration.
--
-- Access assertions run under `set role authenticated`, so RLS applies —
-- the pattern established by tests/m5-tests.sql.
--
-- Window under test: 2026-08-24 .. 2026-08-30.
-- ============================================================

\set ON_ERROR_STOP on
set client_min_messages to notice;

drop table if exists _r;
create table _r (name text, ok boolean, detail text);
grant insert, select on _r to authenticated;

create or replace function _chk(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $$
begin insert into _r values (p_name, p_ok, p_detail); end $$;

-- is_staff() reads auth.jwt(), not the database role, so even the assertions
-- that run as postgres need an identity or every ops_timeline() call raises
-- 'not authorised'. The role blocks below override this and restore it after.
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

-- Setup: Test Co is the test organisation.
update organizations set is_test = true where name = 'Test Co';

-- Convenience: every item the window returns, flattened, for the org branch.
create or replace view _tl as
select o ->> 'name'  as org_name,
       i ->> 'kind'  as kind,
       i ->> 'title' as title,
       i ->> 'on_date' as on_date,
       i ->> 'service_line' as service_line,
       i ->> 'state' as state,
       i ->> 'practitioner' as practitioner,
       i ->> 'mode' as mode
  from jsonb_array_elements(
         (select ops_timeline(date '2026-08-24', date '2026-08-30') -> 'organisations')) o,
       jsonb_array_elements(o -> 'items') i;
grant select on _tl to authenticated;


-- Snapshot of what the ADMIN sees, materialised now while the admin identity
-- is set. Assertion 19 compares the advisor's live result against this. An
-- earlier version compared the advisor's _tl to _tl — but _tl is a view over
-- ops_timeline(), so it re-evaluates under the current identity and both
-- sides were the advisor's. The assertion passed and proved nothing.
drop table if exists _expected;
create table _expected as select count(*)::int as n from _tl;
grant select on _expected to authenticated;


-- ══ 1–3 · The defensive date cast ═══════════════════════════

select _chk('1  a well-formed date parses',
  _ops_as_date('2026-08-26') = date '2026-08-26');

select _chk('2  text that is not a date at all returns null',
  _ops_as_date('next Tuesday') is null and _ops_as_date('') is null
  and _ops_as_date(null) is null);

-- The one a regex alone would get wrong: to_date() rolls month 13 over into
-- the following year instead of refusing it.
select _chk('3  a date-shaped value that is not a real date returns null, not a rolled-over one',
  _ops_as_date('2026-13-45') is null);


-- ══ 4–9 · What the window contains ══════════════════════════

select _chk('4  a booking inside the window appears, attributed via the member profile',
  exists (select 1 from _tl where org_name='BOPEU' and kind='booking'
                              and title='Budget Planning Session' and on_date='2026-08-26'));

select _chk('5  a booking outside the window does not',
  not exists (select 1 from _tl where title='Follow-up'));

select _chk('6  an activity appears against its organisation',
  exists (select 1 from _tl where org_name='Sedimosa' and kind='activity'
                              and title='Debt awareness talk' and on_date='2026-08-25'));

select _chk('7  a webinar appears from content_items',
  exists (select 1 from _tl where org_name='BOPEU' and kind='webinar'
                              and title='Managing debt' and on_date='2026-08-28'));

select _chk('8  a lesson is not a webinar and never appears',
  not exists (select 1 from _tl where title='A lesson, not a webinar'));

select _chk('9  the practitioner and mode come through for a session',
  exists (select 1 from _tl where title='Budget Planning Session'
                              and practitioner='Kefilwe' and mode='physical'
                              and state='attended'));


-- ══ 10–12 · The exclusions ══════════════════════════════════

select _chk('10 nothing belonging to a test organisation appears, of any kind',
  not exists (select 1 from _tl where org_name='Test Co')
  and not exists (select 1 from _tl where title like 'Test Co%'));

select _chk('11 Test Co is not even listed as an organisation',
  not exists (
    select 1 from jsonb_array_elements(
                    ops_timeline(date '2026-08-24', date '2026-08-30') -> 'organisations') o
     where o ->> 'name' = 'Test Co'));

select _chk('12 an inactive organisation is excluded too',
  not exists (
    select 1 from jsonb_array_elements(
                    ops_timeline(date '2026-08-24', date '2026-08-30') -> 'organisations') o
     where o ->> 'name' = 'Closed Co'));


-- ══ 13–15 · The awkward rows ════════════════════════════════

select _chk('13 an unparseable requested_date falls back to created_at',
  exists (select 1 from _tl where title='Ad-hoc chat' and on_date='2026-08-25'));

-- The row that would otherwise appear on a plausible but invented date.
select _chk('14 a month-13 date falls back to created_at, not to 2027-02-14',
  exists (select 1 from _tl where title='Typo booking' and on_date='2026-08-27'));

select _chk('15 a session with no organisation lands in the unassigned bucket, not lost',
  exists (
    select 1 from jsonb_array_elements(
                    ops_timeline(date '2026-08-24', date '2026-08-30') -> 'unassigned') i
     where i ->> 'title' = 'Unattributed session')
  and not exists (select 1 from _tl where title='Unattributed session'));


-- ══ 16–17 · Service line ════════════════════════════════════
-- M1 put the column there; M5a carries it through so the page can draw the
-- 9px marker. The psychosocial row is visible to every staff member TODAY,
-- which is correct now and is precisely what M3 has to change.

select _chk('16 the service line is carried through for the marker',
  (select service_line from _tl where title='Budget Planning Session') = 'financial'
  and (select service_line from _tl where title='Counselling session') = 'psychosocial');

select _chk('17 a psychosocial booking is currently visible to any staff member — M3''s job',
  exists (select 1 from _tl where org_name='Sedimosa' and service_line='psychosocial'));


-- ══ 18–22 · Gate and grants (RLS enforced) ══════════════════

set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';
select _chk('18 an admin may call it',
  jsonb_typeof(ops_timeline(date '2026-08-24', date '2026-08-30') -> 'organisations') = 'array');
reset role;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

-- The reason this is a function: an advisor gets the SAME answer, not the
-- subset bookings_advisor_select would allow.
set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000b';
set session "test.email" = 'kefilwe@keywealth.co.bw';
select _chk('19 an advisor sees the same timeline as an admin, not their own slice',
  (select count(*) from jsonb_array_elements(
     ops_timeline(date '2026-08-24', date '2026-08-30') -> 'organisations') o,
     jsonb_array_elements(o -> 'items') i) = (select n from _expected)
  and (select n from _expected) = 6,
  'advisor sees ' || (select count(*) from jsonb_array_elements(
     ops_timeline(date '2026-08-24', date '2026-08-30') -> 'organisations') o,
     jsonb_array_elements(o -> 'items') i)::text
  || ', admin snapshot ' || (select n from _expected)::text);
reset role;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000e';
set session "test.email" = 'member@example.test';
do $$
declare ok boolean := false;
begin
  begin
    perform ops_timeline(date '2026-08-24', date '2026-08-30');
  exception when others then ok := sqlerrm = 'not authorised';
  end;
  insert into _r values ('20 a member is refused', ok, null);
end $$;
reset role;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

set role authenticated;
set session "test.uid"   = '00000000-0000-0000-0000-00000000000f';
set session "test.email" = 'hr@bopeu.test';
do $$
declare ok boolean := false;
begin
  begin
    perform ops_timeline(date '2026-08-24', date '2026-08-30');
  exception when others then ok := sqlerrm = 'not authorised';
  end;
  insert into _r values ('21 an HR user is refused', ok, null);
end $$;
reset role;
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';
set session "test.email" = 'lone@keywellness.co.bw';

do $$
declare ok boolean := false;
begin
  begin
    perform ops_timeline(date '2026-08-30', date '2026-08-24');
  exception when others then ok := sqlerrm = 'p_to must not be before p_from';
  end;
  insert into _r values ('22 an inverted window is refused', ok, null);
end $$;


-- ══ 23–24 · The REVOKE rule ═════════════════════════════════

select _chk('23 the date helper is not callable by anon or authenticated',
  not has_function_privilege('authenticated', '_ops_as_date(text)', 'EXECUTE')
  and not has_function_privilege('anon', '_ops_as_date(text)', 'EXECUTE'));

select _chk('24 ops_timeline is callable by authenticated and gated inside',
  has_function_privilege('authenticated', 'ops_timeline(date, date)', 'EXECUTE'));


-- ══ 25 · An empty window is empty, not broken ═══════════════

select _chk('25 a window with nothing in it returns organisations with empty item lists',
  (select bool_and(jsonb_array_length(o -> 'items') = 0)
     from jsonb_array_elements(
            ops_timeline(date '2027-01-01', date '2027-01-07') -> 'organisations') o));


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
    raise exception 'M5a assertions failed';
  end if;
end $$;
