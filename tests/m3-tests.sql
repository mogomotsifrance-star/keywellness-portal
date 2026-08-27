-- ============================================================
-- Key Wellness — M3 tests
-- Run by tests/run-m3.sh against a local PostgreSQL 17.
--
-- ══ WHAT MAKES THESE DIFFERENT FROM EVERY OTHER SUITE ══════
--
-- Every booking on the live database today is service_line 'financial'. So
-- every function M3 touches returns BYTE-IDENTICAL results before and after,
-- and a suite run against live-shaped data would pass while proving nothing.
--
-- THESE TESTS SEED PSYCHOSOCIAL ROWS AND TWO COUNSELLORS. Karabo and Nicola
-- exist here so that the assertion which matters — a counsellor cannot read
-- the other counsellor's case — has something to be false about.
--
-- The cast:
--   Karabo    counsellor
--   Nicola    counsellor
--   Thato     financial advisor, and the TEAM LEAD
--   Lone      admin AND psychosocial admin
--   France    admin, NOT psychosocial admin        <- the boundary
--   Mpho      a member with one booking of each line
--   Boitumelo HR
-- ============================================================

set client_min_messages = notice;

drop table if exists _r;
create table _r (name text, ok boolean, detail text);
grant all on table _r to public;

create or replace function _chk(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $$
begin insert into _r values (p_name, coalesce(p_ok,false), p_detail); end $$;


-- ══ The cast ═══════════════════════════════════════════════

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000ca', 'karabo@keywellness.co.bw'),
  ('00000000-0000-0000-0000-0000000000cb', 'nicola@keywellness.co.bw'),
  ('00000000-0000-0000-0000-0000000000cc', 'thato@keywellness.co.bw'),
  ('00000000-0000-0000-0000-0000000000cd', 'mpho@example.com'),
  ('00000000-0000-0000-0000-0000000000ce', 'boitumelo@bopeu.co.bw')
on conflict (id) do nothing;

insert into counsellors (id, user_id, email, full_name) values
  ('0c000000-0000-0000-0000-0000000000da', '00000000-0000-0000-0000-0000000000ca',
   'karabo@keywellness.co.bw', 'Karabo'),
  ('0c000000-0000-0000-0000-0000000000db', '00000000-0000-0000-0000-0000000000cb',
   'nicola@keywellness.co.bw', 'Nicola')
on conflict (id) do nothing;

insert into admins (email) values ('france@keywealth.co.bw') on conflict do nothing;
insert into admins (email) values ('lone@keywellness.co.bw') on conflict do nothing;

-- Two caseload links, one each.
insert into counsellor_clients (id, counsellor_id, member_user_id, full_name) values
  ('0cc00000-0000-0000-0000-0000000000ea', '0c000000-0000-0000-0000-0000000000da',
   '00000000-0000-0000-0000-0000000000cd', 'Mpho'),
  ('0cc00000-0000-0000-0000-0000000000eb', '0c000000-0000-0000-0000-0000000000db',
   null, 'Another client')
on conflict (id) do nothing;

-- One booking per line per counsellor, plus a financial one.
insert into bookings (id, user_id, service, service_line, status, requested_date,
                      counsellor_id, counsellor_client_id)
values ('0b000000-0000-0000-0000-0000000000fa', '00000000-0000-0000-0000-0000000000cd',
        'Counselling', 'psychosocial', 'confirmed', current_date::text,
        '0c000000-0000-0000-0000-0000000000da', '0cc00000-0000-0000-0000-0000000000ea'),
       ('0b000000-0000-0000-0000-0000000000fb', null,
        'Counselling', 'psychosocial', 'confirmed', current_date::text,
        '0c000000-0000-0000-0000-0000000000db', '0cc00000-0000-0000-0000-0000000000eb')
on conflict (id) do nothing;

insert into bookings (id, user_id, service, service_line, status, requested_date)
values ('0b000000-0000-0000-0000-0000000000fc', '00000000-0000-0000-0000-0000000000cd',
        'Budget session', 'financial', 'confirmed', current_date::text)
on conflict (id) do nothing;

-- A note each. These are the most sensitive rows in the system.
insert into counselling_notes (id, counsellor_id, counsellor_client_id, booking_id, body)
values ('0a000000-0000-0000-0000-0000000000fa', '0c000000-0000-0000-0000-0000000000da',
        '0cc00000-0000-0000-0000-0000000000ea', '0b000000-0000-0000-0000-0000000000fa',
        'Karabo private note'),
       ('0a000000-0000-0000-0000-0000000000fb', '0c000000-0000-0000-0000-0000000000db',
        '0cc00000-0000-0000-0000-0000000000eb', '0b000000-0000-0000-0000-0000000000fb',
        'Nicola private note')
on conflict (id) do nothing;


-- ══ 1–4 · There is no Clinical Lead, anywhere ══════════════

select _chk('1  no is_clinical_lead() function exists',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
               where n.nspname='public' and p.proname='is_clinical_lead'));

select _chk('2  no is_clinical_lead column exists on any table',
  not exists (select 1 from information_schema.columns
               where table_schema='public' and column_name='is_clinical_lead'));

select _chk('3  no policy mentions a clinical lead',
  not exists (select 1 from pg_policies where schemaname='public'
               and (coalesce(qual,'') ilike '%clinical_lead%'
                 or coalesce(with_check,'') ilike '%clinical_lead%')));

select _chk('4  counselling_notes has exactly ONE policy, and it is the author',
  (select count(*) from pg_policies
    where schemaname='public' and tablename='counselling_notes') = 1
  and (select qual from pg_policies
        where schemaname='public' and tablename='counselling_notes')
      like '%current_counsellor_id%');


-- ══ 5–10 · Karabo and Nicola ═══════════════════════════════
-- THE ASSERTION THIS WHOLE REVISION IS ABOUT. Testing a counsellor against
-- France proves almost nothing — France is excluded by four other rules.
-- Nicola failing to read Karabo's case is what actually exercises the change.

set role authenticated;
set session "test.email" = 'karabo@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000ca';

select _chk('5  Karabo reads her own psychosocial booking',
  exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000fa'));

select _chk('6  Karabo CANNOT read Nicola''s psychosocial booking',
  not exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000fb'));

select _chk('7  Karabo cannot read a financial booking',
  not exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000fc'));

select _chk('8  Karabo reads her own note',
  exists (select 1 from counselling_notes where id='0a000000-0000-0000-0000-0000000000fa'));

select _chk('9  Karabo CANNOT read Nicola''s note',
  not exists (select 1 from counselling_notes where id='0a000000-0000-0000-0000-0000000000fb'));

set session "test.email" = 'nicola@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000cb';

select _chk('10 and the mirror: Nicola cannot read Karabo''s booking or note',
  not exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000fa')
  and not exists (select 1 from counselling_notes where id='0a000000-0000-0000-0000-0000000000fa'));


-- ══ 11–14 · The financial team lead ════════════════════════
-- Today is_team_lead() inside bookings_advisor_select grants EVERY booking.
-- Through the policies AND through each definer function separately, because
-- they fail separately.

reset role;
set role authenticated;
set session "test.email" = 'thato@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000cc';

select _chk('11 the team lead still reads financial bookings',
  exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000fc'));

select _chk('12 the team lead CANNOT read a psychosocial booking through the policies',
  not exists (select 1 from bookings where service_line='psychosocial'));

do $$
declare v jsonb; leaked boolean := false;
begin
  begin
    v := advisor_clients_list();
    leaked := v::text ilike '%psychosocial%' or v::text ilike '%Counselling%';
  exception when others then leaked := false;   -- refusing is also correct
  end;
  insert into _r values ('13 the team lead sees no psychosocial row through advisor_clients_list',
    not leaked, null);
end $$;

do $$
declare v jsonb; leaked boolean := false;
begin
  begin
    v := advisor_pending_responses();
    leaked := v::text ilike '%Counselling%';
  exception when others then leaked := false;
  end;
  insert into _r values ('14 nor through advisor_pending_responses', not leaked, null);
end $$;


-- ══ 15–19 · France and Lone ════════════════════════════════
-- Requirement (a): France cannot read psychosocial.
-- Requirement (b): everything else he reads today is UNCHANGED. (b) is the one
-- that gets skipped, because a migration that locks everything down passes (a)
-- perfectly.

reset role;
select set_config('test.n_financial',
  (select count(*)::text from bookings where service_line='financial'), false);

set role authenticated;
set session "test.email" = 'france@keywealth.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000f1';

select _chk('15 France reads EVERY financial booking, exactly as today',
  (select count(*) from bookings where service_line='financial')
    = current_setting('test.n_financial')::int,
  'france=' || (select count(*) from bookings where service_line='financial')::text
    || ' actual=' || current_setting('test.n_financial'));

select _chk('16 France CANNOT read any psychosocial booking',
  not exists (select 1 from bookings where service_line='psychosocial'));

select _chk('17 France cannot read any counselling note',
  not exists (select 1 from counselling_notes));

select _chk('18 France cannot read a counsellor caseload',
  not exists (select 1 from counsellor_clients));

reset role;
set role authenticated;
set session "test.email" = 'lone@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';

select _chk('19 Lone reads BOTH lines of bookings — she schedules and bills',
  exists (select 1 from bookings where service_line='psychosocial')
  and exists (select 1 from bookings where service_line='financial'));

select _chk('20 but Lone reads NO note — she needs to know a session happened, '
         || 'not what was said',
  not exists (select 1 from counselling_notes));


-- ══ 21–23 · HR, and the member ═════════════════════════════

reset role;
set role authenticated;
set session "test.email" = 'boitumelo@bopeu.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000ce';

select _chk('21 HR reads no booking row of either line',
  not exists (select 1 from bookings));

reset role;
set role authenticated;
set session "test.email" = 'mpho@example.com';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000cd';

select _chk('22 a member reads their OWN rows, both lines, exactly as today',
  exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000fc')
  and exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000fa'));

select _chk('23 and reads nobody else''s',
  not exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000fb'));


-- ══ 24–26 · Referrals grant nothing backward ═══════════════

reset role;
set role authenticated;
set session "test.email" = 'karabo@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000ca';

insert into counselling_referrals (id, counsellor_client_id, from_counsellor_id,
                                   to_counsellor_id, note)
values ('0f000000-0000-0000-0000-0000000000fa',
        '0cc00000-0000-0000-0000-0000000000ea',
        '0c000000-0000-0000-0000-0000000000da',
        '0c000000-0000-0000-0000-0000000000db',
        'Handover written for Nicola. Not a copy of my notes.');

reset role;
set role authenticated;
set session "test.email" = 'nicola@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000cb';

select _chk('24 the receiving counsellor reads the referral',
  exists (select 1 from counselling_referrals
           where id='0f000000-0000-0000-0000-0000000000fa'));

-- THE POINT OF THE WHOLE DESIGN.
select _chk('25 but reading a referral grants NO access to the referring '
         || 'counsellor''s notes',
  not exists (select 1 from counselling_notes
               where id='0a000000-0000-0000-0000-0000000000fa'));

reset role;
set role authenticated;
set session "test.email" = 'france@keywealth.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000f1';

select _chk('26 an admin who is not a party reads no referral',
  not exists (select 1 from counselling_referrals));


-- ══ 27–28 · Lone learns the FACT, never the note ═══════════

reset role;
set role authenticated;
set session "test.email" = 'lone@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';

do $$
declare v jsonb;
begin
  v := referral_fact_list();
  insert into _r values ('27 Lone sees that a referral happened, with both names',
    v::text ilike '%Karabo%' and v::text ilike '%Nicola%', v::text);
  insert into _r values ('28 and the note content is NOT in it',
    v::text not ilike '%Handover written%' and v::text not ilike '%Not a copy%',
    v::text);
end $$;


-- ══ 29–31 · Themes are floored, always ═════════════════════

select _chk('29 a theme count below five is withheld',
  (select (t ->> 'suppressed')::boolean
     from jsonb_array_elements(theme_counts()) t limit 1) is not false);

select _chk('30 nobody has a direct select on session_themes',
  (select count(*) from pg_policies
    where schemaname='public' and tablename='session_themes') = 1);

reset role;
set role authenticated;
set session "test.email" = 'boitumelo@bopeu.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000ce';

do $$
declare ok boolean := false;
begin
  begin
    perform theme_counts();
  exception when others then ok := sqlerrm like '%not authorised%';
  end;
  insert into _r values ('31 HR cannot call the theme RPC at all', ok, null);
end $$;


-- ══ 32–36 · The sweep held ═════════════════════════════════

reset role;

select _chk('32 every definer function reading bookings carries the predicate',
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.prosecdef
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and p.prosrc ~* '\mfrom\s+bookings\M|\mjoin\s+bookings\M'
       and p.prosrc !~* '\mkw_can_see_booking\M'
       and p.proname not in ('advisor_book_session','advisor_mark_response_seen',
                             'member_respond_booking','award_points',
                             'theme_counts')));

select _chk('33 every definer function reading program_activities carries its predicate',
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.prosecdef
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and p.prosrc ~* '\mfrom\s+program_activities\M|\mjoin\s+program_activities\M'
       and p.prosrc !~* '\mkw_can_see_activity\M'
       and p.proname not in ('kw_booking_drives_activity')));

select _chk('34 the predicates are not callable directly',
  not has_function_privilege('authenticated','kw_can_see_booking(bookings)','EXECUTE')
  and not has_function_privilege('anon','kw_can_see_booking(bookings)','EXECUTE'));

select _chk('35 the four legacy bookings policies are gone',
  (select count(*) from pg_policies where schemaname='public' and tablename='bookings'
    and policyname in ('bookings_admin','bookings_admin_all','bookings_self',
                       'bookings_advisor_select')) = 0);

select _chk('36 no bookings policy compares an email without lowering it',
  not exists (select 1 from pg_policies
               where schemaname='public' and tablename='bookings'
                 and coalesce(qual,'') like '%jwt() ->> ''email''%'
                 and coalesce(qual,'') not like '%lower%'));


-- ══ 37–38 · Reporting, and kw_unit_label ═══════════════════

-- EVERY overload, not "the" overload. _org_report_period_data exists twice,
-- and `select prosrc from ... where proname = ...` returns two rows — which is
-- the exact trap that made the migration patch the wrong one. An assertion
-- written the same careless way would have hidden it.
select _chk('37 no reporting overload still reads bookings unfiltered',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public'
                 and p.proname = '_org_report_period_data'
                 -- the ALIASED form the sweep targets: a looser pattern
                 -- matches the rewrite's own inner `from bookings where`
                 -- and fails against a correctly-filtered function.
                 and p.prosrc like '%from bookings b%'));

select _chk('37a and at least one of them carries the financial filter',
  exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and p.proname = '_org_report_period_data'
             and p.prosrc like '%service_line = ''financial''%'));

select _chk('38 kw_unit_label is no longer anon-callable (or is absent here)',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
               where n.nspname='public' and p.proname='kw_unit_label')
  or not has_function_privilege('anon','kw_unit_label(uuid)','EXECUTE'));


-- ══ 39 · The one-practitioner rule ═════════════════════════

do $$
declare ok boolean := false;
begin
  begin
    insert into bookings (user_id, service, service_line, advisor_id, counsellor_id)
    values ('00000000-0000-0000-0000-0000000000cd', 'Both', 'psychosocial',
            (select id from advisors limit 1), '0c000000-0000-0000-0000-0000000000da');
    raise exception 'accepted';
  exception when check_violation then ok := true; when others then ok := false;
  end;
  insert into _r values ('39 a booking cannot have both an advisor and a counsellor',
    ok, null);
end $$;


select _chk('38a row-level security is actually ENABLED on bookings',
  exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
           where n.nspname='public' and c.relname='bookings' and c.relrowsecurity));


-- ══ 40–49 · The referral accept flow ══════════════════════
-- The referral from Karabo to Nicola already exists (assertions 24–26) and is
-- unaccepted. These walk it.
--
-- The assertions that matter here are the NEGATIVE ones. That acceptance works
-- is easy; that it grants nothing backward is the whole design, and 44–46 are
-- the ones to read.

-- Who may accept: only the counsellor it was sent to.
reset role;
set role authenticated;
set session "test.email" = 'karabo@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000ca';

do $$
declare ok boolean := false; msg text := '';
begin
  begin
    perform referral_accept('0f000000-0000-0000-0000-0000000000fa');
  exception when others then ok := sqlerrm like '%sent to can accept%'; msg := sqlerrm;
  end;
  insert into _r values ('40 the REFERRING counsellor cannot accept her own referral', ok, msg);
end $$;

reset role;
set role authenticated;
set session "test.email" = 'lone@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';

do $$
declare ok boolean := false; msg text := '';
begin
  begin
    perform referral_accept('0f000000-0000-0000-0000-0000000000fa');
  exception when others then ok := sqlerrm like '%only a counsellor%'; msg := sqlerrm;
  end;
  insert into _r values ('41 a psychosocial admin cannot accept on anyone''s behalf', ok, msg);
end $$;

-- Nicola accepts.
reset role;
set role authenticated;
set session "test.email" = 'nicola@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000cb';

do $$
declare v jsonb;
begin
  v := referral_accept('0f000000-0000-0000-0000-0000000000fa');
  insert into _r values ('42 the receiving counsellor accepts, and gets a new link',
    (v ->> 'already_accepted') = 'false'
    and (v ->> 'link_id') is not null
    and (v ->> 'closed_link_id') = '0cc00000-0000-0000-0000-0000000000ea',
    v::text);
  raise notice 'STATE  accept: %', v::text;
end $$;

select _chk('43 accepting twice is not an error and opens no second link',
  ((referral_accept('0f000000-0000-0000-0000-0000000000fa')) ->> 'already_accepted') = 'true'
  and (select count(*) from counsellor_clients
        where counsellor_id = current_counsellor_id() and is_active) = 2);
--                                                                      ^ Nicola's
--   own pre-existing link plus the one she just received. Not three.


-- ── 44–46 · NOTHING FLOWS BACKWARD ─────────────────────────
-- Nicola has now accepted the case. She still cannot see anything Karabo
-- wrote. This is the whole point of the design and the reason a referral
-- carries a freshly authored note instead of a pointer.

select _chk('44 after accepting, Nicola STILL cannot read Karabo''s note',
  not exists (select 1 from counselling_notes
               where id = '0a000000-0000-0000-0000-0000000000fa'));

select _chk('45 nor Karabo''s booking for the same client',
  not exists (select 1 from bookings
               where id = '0b000000-0000-0000-0000-0000000000fa'));

select _chk('46 nor Karabo''s now-closed caseload row',
  not exists (select 1 from counsellor_clients
               where id = '0cc00000-0000-0000-0000-0000000000ea'));


-- ── 47–48 · The old link stays Karabo's ────────────────────
reset role;
set role authenticated;
set session "test.email" = 'karabo@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000ca';

select _chk('47 Karabo still reads her own note and booking after handing over',
  exists (select 1 from counselling_notes where id='0a000000-0000-0000-0000-0000000000fa')
  and exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000fa'));

select _chk('48 and her caseload row is CLOSED, not deleted and not repointed',
  exists (select 1 from counsellor_clients
           where id = '0cc00000-0000-0000-0000-0000000000ea'
             and counsellor_id = '0c000000-0000-0000-0000-0000000000da'
             and not is_active
             and ended_at is not null));


-- ── 49 · Lone learns the fact, and still not the note ──────
reset role;
set role authenticated;
set session "test.email" = 'lone@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';

do $$
declare v jsonb;
begin
  v := referral_fact_list();
  insert into _r values ('49 Lone sees the referral was ACCEPTED, with a date and no note',
    v::text ilike '%accepted_on%'
    and (v -> 0 ->> 'accepted_on') is not null
    and v::text not ilike '%Handover written%',
    v::text);
end $$;


-- ══ Report ═════════════════════════════════════════════════

reset role;

select case when ok then 'PASS  ' else 'FAIL  ' end || name
    || coalesce('  -> ' || detail, '') as result
  from _r order by name;

select '  ' || count(*) filter (where ok)::text || ' passed, '
    || count(*) filter (where not ok)::text || ' failed.' as summary
  from _r;

do $$
begin
  if exists (select 1 from _r where not ok) then
    raise exception 'M3 assertions failed';
  end if;
end $$;
