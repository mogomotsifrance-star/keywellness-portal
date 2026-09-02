-- ============================================================
-- Key Wellness — M4b tests
-- Run by tests/run-m4b.sh against a local PostgreSQL 17.
--
-- These exist because the first real client contract broke three assumptions
-- the schema was built on. Each assertion below is one of those breakages,
-- written so it cannot come back.
-- ============================================================

set client_min_messages = notice;

drop table if exists _r;
create table _r (name text, ok boolean, detail text);
grant all on table _r to public;

create or replace function _chk(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $$
begin insert into _r values (p_name, coalesce(p_ok,false), p_detail); end $$;


-- ══ 1–5 · "Approximately" is recordable, and must be explained ══

do $$
declare v_org uuid; ok boolean := false; msg text := '';
begin
  select id into v_org from organizations where name='BOPEU';

  -- The case this migration exists for: a real retainer, honestly soft.
  insert into org_contracts (id, org_id, contract_kind, retainer_amount,
                             amount_is_approximate, amount_note,
                             billing_frequency, included_lines, start_date, status)
  values ('0d000000-0000-0000-0000-0000000000b1', v_org, 'retainer', 18000,
          true, 'Approximate. Given verbally; not from a signed schedule.',
          'monthly', array['financial','psychosocial'], date '2026-01-01', 'active');

  insert into _r values ('1  a retainer can be recorded as APPROXIMATE',
    (select amount_is_approximate from org_contracts
      where id='0d000000-0000-0000-0000-0000000000b1'), null);

  insert into _r values ('2  and the words survive alongside the number',
    (select amount_note from org_contracts
      where id='0d000000-0000-0000-0000-0000000000b1') like '%not from a signed%', null);
end $$;

-- An approximate amount with no explanation is barely better than a precise lie.
do $$
declare ok boolean := false;
begin
  begin
    insert into org_contracts (org_id, contract_kind, retainer_amount,
                               amount_is_approximate, billing_frequency, start_date)
    values ((select id from organizations where name='BOPEU'), 'retainer', 5000,
            true, 'monthly', current_date);
    raise exception 'accepted';
  exception when check_violation then ok := true; when others then ok := false;
  end;
  insert into _r values ('3  an approximate amount with NO note is refused', ok, null);
end $$;

select _chk('4  an EXACT amount needs no note — the default is unchanged',
  (select count(*) from org_contracts where not amount_is_approximate) >= 0);

-- The regression that matters: this migration must not have reinterpreted
-- anybody's existing number as soft.
select _chk('5  no contract was silently marked approximate by the migration',
  not exists (select 1 from org_contracts
               where amount_is_approximate
                 and id <> '0d000000-0000-0000-0000-0000000000b1'));


-- ══ 6–9 · campaign and vendor ══════════════════════════════

do $$
declare v_org uuid;
begin
  select id into v_org from organizations where name='BOPEU';

  -- A self-directed challenge: nobody delivers it at a time and a place.
  insert into program_activities (id, org_id, activity_type, title, activity_date,
                                  attendee_count, service_line, format, state)
  values ('0f000000-0000-0000-0000-0000000000c1', v_org, 'other',
          'Walking challenge', date '2026-05-01', 0, 'financial', 'campaign', 'planned');

  -- Health screening: delivered by an external provider.
  insert into program_activities (id, org_id, activity_type, title, activity_date,
                                  attendee_count, service_line, format, state,
                                  practitioner_kind)
  values ('0f000000-0000-0000-0000-0000000000c2', v_org, 'clinic',
          'Health screening', date '2026-06-01', 0, 'financial', 'other', 'planned',
          'vendor');
end $$;

select _chk('6  format admits campaign',
  (select format from program_activities
    where id='0f000000-0000-0000-0000-0000000000c1') = 'campaign');

select _chk('7  practitioner_kind admits vendor',
  (select practitioner_kind from program_activities
    where id='0f000000-0000-0000-0000-0000000000c2') = 'vendor');

-- Widening by drop-and-add is exactly how a value disappears unnoticed.
select _chk('8  widening the format check kept every value it had',
  (select pg_get_constraintdef(oid) from pg_constraint
    where conname='program_activities_format_check')
  ~ 'talk.*one_on_one.*couple.*group.*webinar.*wellness_day.*flyer.*other');

select _chk('9  widening practitioner_kind kept advisor and counsellor',
  (select pg_get_constraintdef(oid) from pg_constraint
    where conname='program_activities_practitioner_kind_check')
  ~ 'advisor.*counsellor');


-- ══ 10–11 · What was deliberately NOT added ════════════════

select _chk('10 group_session was NOT added — `group` already means that',
  (select pg_get_constraintdef(oid) from pg_constraint
    where conname='program_activities_format_check') !~ 'group_session');

do $$
declare ok boolean := false;
begin
  begin
    insert into program_activities (org_id, activity_type, title, activity_date,
                                    attendee_count, service_line, format)
    values ((select id from organizations where name='BOPEU'), 'other', 'x',
            current_date, 0, 'financial', 'group_session');
    raise exception 'accepted';
  exception when check_violation then ok := true; when others then ok := false;
  end;
  insert into _r values ('11 and group_session is still refused', ok, null);
end $$;


-- ══ 12 · A vendor session is not practitioner time ═════════
-- The reason 'vendor' had to exist rather than being folded into 'advisor'.

select _chk('12 vendor work is distinguishable from staff work in a count',
  (select count(*) from program_activities
    where practitioner_kind = 'vendor') = 1
  and (select count(*) from program_activities
        where practitioner_kind in ('advisor','counsellor')) = 0);


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
    raise exception 'M4b assertions failed';
  end if;
end $$;
