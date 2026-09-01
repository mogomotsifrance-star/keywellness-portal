-- ============================================================
-- Key Wellness — M6 tests
--
-- Two things to prove, and they are different:
--   1. PHYSICAL BEHAVES LIKE FINANCIAL for visibility. It is not a secret.
--   2. NOTHING PSYCHOSOCIAL MOVED. M6 rewrites every predicate M3 wrote, so
--      the whole M3 matrix is re-run here rather than assumed to still hold.
-- ============================================================

set client_min_messages = notice;

drop table if exists _r;
create table _r (name text, ok boolean, detail text);
grant all on table _r to public;

create or replace function _chk(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $$
begin insert into _r values (p_name, coalesce(p_ok,false), p_detail); end $$;


-- ══ The cast and the three lines ═══════════════════════════

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000ca', 'karabo@keywellness.co.bw'),
  ('00000000-0000-0000-0000-0000000000cd', 'mpho@example.com')
on conflict (id) do nothing;

insert into counsellors (id, user_id, email, full_name) values
  ('0c000000-0000-0000-0000-0000000000da', '00000000-0000-0000-0000-0000000000ca',
   'karabo@keywellness.co.bw', 'Karabo')
on conflict (id) do nothing;

insert into admins (email) values ('france@keywealth.co.bw') on conflict do nothing;
insert into psychosocial_admins (email, full_name)
values ('lone@keywellness.co.bw','Lone') on conflict (email) do nothing;
insert into admins (email) values ('lone@keywellness.co.bw') on conflict do nothing;

insert into counsellor_clients (id, counsellor_id, member_user_id, full_name)
values ('0cc00000-0000-0000-0000-0000000000ea','0c000000-0000-0000-0000-0000000000da',
        '00000000-0000-0000-0000-0000000000cd','Mpho')
on conflict (id) do nothing;

-- One booking per line.
insert into bookings (id, user_id, service, service_line, status, requested_date)
values ('0b000000-0000-0000-0000-0000000000f1','00000000-0000-0000-0000-0000000000cd',
        'Budget session','financial','confirmed', current_date::text),
       ('0b000000-0000-0000-0000-0000000000f3','00000000-0000-0000-0000-0000000000cd',
        'Health screening','physical','confirmed', current_date::text)
on conflict (id) do nothing;

insert into bookings (id, user_id, service, service_line, status, requested_date,
                      counsellor_id, counsellor_client_id)
values ('0b000000-0000-0000-0000-0000000000f2','00000000-0000-0000-0000-0000000000cd',
        'Counselling','psychosocial','confirmed', current_date::text,
        '0c000000-0000-0000-0000-0000000000da','0cc00000-0000-0000-0000-0000000000ea')
on conflict (id) do nothing;


-- ══ 1–4 · The table is the source of truth ═════════════════

select _chk('1 three lines exist and physical is one of them',
  (select count(*) from service_lines where is_active) = 3
  and exists (select 1 from service_lines where key='physical'));

select _chk('2 physical is NOT confidential — a health screening is not a secret',
  not kw_line_is_confidential('physical'));

select _chk('3 psychosocial IS confidential, and financial is not',
  kw_line_is_confidential('psychosocial') and not kw_line_is_confidential('financial'));

-- THE DEFAULT THAT MATTERS. Forgetting to classify a line must hide rows, not
-- expose them: the first is complained about the same day, the second is not
-- noticed at all.
select _chk('4 an UNKNOWN line is treated as confidential — fail closed',
  kw_line_is_confidential('nutrition')
  and kw_line_is_confidential('')
  and kw_line_is_confidential(null) is not false);


-- ══ 5–9 · Physical behaves like financial, not like a secret ══

set role authenticated;
set session "test.email" = 'france@keywealth.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000f1';

select _chk('5 a plain admin reads a PHYSICAL booking',
  exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000f3'));

select _chk('6 and still reads a financial one',
  exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000f1'));

select _chk('7 and still CANNOT read a psychosocial one',
  not exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000f2'));

reset role;
set role authenticated;
set session "test.email" = 'karabo@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000ca';

select _chk('8 a counsellor reads her own psychosocial booking',
  exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000f2'));

select _chk('9 but NOT a physical one — physical is not hers, it is just not secret',
  not exists (select 1 from bookings where id='0b000000-0000-0000-0000-0000000000f3'));


-- ══ 10–12 · Nothing psychosocial moved ═════════════════════

reset role;
set role authenticated;
set session "test.email" = 'lone@keywellness.co.bw';
set session "test.uid"   = '00000000-0000-0000-0000-000000000009';

select _chk('10 a psychosocial admin reads all three lines',
  (select count(*) from bookings where id in
    ('0b000000-0000-0000-0000-0000000000f1',
     '0b000000-0000-0000-0000-0000000000f2',
     '0b000000-0000-0000-0000-0000000000f3')) = 3);

reset role;
set role authenticated;
set session "test.email" = 'mpho@example.com';
set session "test.uid"   = '00000000-0000-0000-0000-0000000000cd';

select _chk('11 the member reads their own rows on every line',
  (select count(*) from bookings where user_id='00000000-0000-0000-0000-0000000000cd') = 3);

reset role;

select _chk('12 no bookings policy names a line literally any more',
  not exists (select 1 from pg_policies
               where schemaname='public' and tablename='bookings'
                 and (coalesce(qual,'') ~ '''(financial|psychosocial|physical)'''
                   or coalesce(with_check,'') ~ '''(financial|psychosocial|physical)''')));


-- ══ 13–17 · The two reporting defects ══════════════════════

do $$
declare v_org uuid;
begin
  select id into v_org from organizations where name='BOPEU';

  insert into program_activities (id, org_id, activity_type, title, activity_date,
                                  attendee_count, service_line, state)
  values ('0f000000-0000-0000-0000-0000000000d1', v_org, 'education_talk',
          'DELIVERED financial talk', current_date, 0, 'financial', 'delivered'),
         ('0f000000-0000-0000-0000-0000000000d2', v_org, 'education_talk',
          'PLANNED financial talk', current_date, 0, 'financial', 'planned'),
         ('0f000000-0000-0000-0000-0000000000d3', v_org, 'group_intervention',
          'DELIVERED counselling group', current_date, 0, 'psychosocial', 'delivered'),
         ('0f000000-0000-0000-0000-0000000000d4', v_org, 'clinic',
          'DELIVERED health screening', current_date, 0, 'physical', 'delivered')
  on conflict (id) do nothing;
end $$;

do $$
declare j jsonb; v_titles text;
begin
  j := _org_report_period_data((select id from organizations where name='BOPEU'),
         (current_date - 30), (current_date + 30));

  select string_agg(a ->> 'title', ' | ')
    into v_titles
    from jsonb_array_elements(j -> 'program_activities' -> 'activities_list') a;

  -- DEFECT 1
  insert into _r values ('13 PLANNED activity is no longer reported as if it happened',
    coalesce(v_titles,'') not like '%PLANNED%', coalesce(v_titles,'(none)'));

  -- DEFECT 2
  insert into _r values ('14 psychosocial activity no longer reaches HR''s report',
    coalesce(v_titles,'') not like '%counselling group%', coalesce(v_titles,'(none)'));

  -- And the two that SHOULD be there.
  insert into _r values ('15 delivered financial work is still reported',
    coalesce(v_titles,'') like '%DELIVERED financial talk%', coalesce(v_titles,'(none)'));

  insert into _r values ('16 delivered PHYSICAL work IS reported — it is not confidential',
    coalesce(v_titles,'') like '%health screening%', coalesce(v_titles,'(none)'));

  insert into _r values ('17 so the count is 2, not 4',
    (j -> 'program_activities' ->> 'total_activities') = '2',
    j -> 'program_activities' ->> 'total_activities');

  raise notice 'STATE  reported activities: %', coalesce(v_titles,'(none)');
end $$;


-- ══ 18–19 · The definer functions carry it too ═════════════

select _chk('18 kw_can_see_booking names no line literally',
  (select prosrc from pg_proc where proname='kw_can_see_booking')
    !~ '''(financial|psychosocial|physical)''');

select _chk('19 kw_can_see_activity asks the confidentiality question',
  (select prosrc from pg_proc where proname='kw_can_see_activity')
    ~ 'kw_line_is_confidential');


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
    raise exception 'M6 assertions failed';
  end if;
end $$;
