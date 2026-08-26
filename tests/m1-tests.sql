-- ============================================================
-- Key Wellness — M1 assertions (local PostgreSQL 17 only)
--
-- Run by tests/run-m1.sh AFTER the fixture, the reporting stack, the
-- pre-migration baseline capture and supabase_m1_service_line.sql.
-- Emits PASS / FAIL lines and a count, in the style of tests/phase0-tests.sql.
--
-- The baseline table m1_baseline is written by run-m1.sh before the migration
-- and holds org_report_data()'s output per (organisation, period).
-- ============================================================

\set ON_ERROR_STOP on
set client_min_messages to notice;

-- org_report_data() gates on is_admin(), and the fixture's auth.jwt() reads
-- this setting. Set here rather than by the runner so the file works when
-- invoked directly with psql -f.
set test.email = 'admin@keywellness.co.bw';

create temporary table _r (name text, ok boolean, detail text);

create or replace function _chk(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $$
begin
  insert into _r values (p_name, p_ok, p_detail);
end $$;


-- ── 1–4 · service_line lands on all four tables, all financial ──

select _chk('1  every booking reads financial',
  (select count(*) from bookings where service_line <> 'financial') = 0,
  (select count(*)::text || ' non-financial' from bookings where service_line <> 'financial'));

select _chk('2  every program_activity reads financial',
  (select count(*) from program_activities where service_line <> 'financial') = 0);

select _chk('3  every org_report reads financial',
  (select count(*) from org_reports where service_line <> 'financial') = 0);

select _chk('4  every content_item reads financial',
  (select count(*) from content_items where service_line <> 'financial') = 0);


-- ── 5 · service_line is NOT NULL with the right default ─────

select _chk('5  service_line is not-null defaulted financial on all four',
  (select count(*) from information_schema.columns
    where table_schema='public'
      and table_name in ('bookings','program_activities','org_reports','content_items')
      and column_name='service_line'
      and is_nullable='NO'
      and column_default like '%financial%') = 4);


-- ── 6–8 · session_format ────────────────────────────────────

select _chk('6  every existing booking backfilled to one_on_one',
  (select count(*) from bookings where session_format is distinct from 'one_on_one') = 0);

select _chk('7  session_format is nullable (future rows may not know it yet)',
  (select is_nullable from information_schema.columns
    where table_schema='public' and table_name='bookings'
      and column_name='session_format') = 'YES');

-- Probe the constraint with each of the six values in turn, rolling every
-- write back. M3 and M4 write 'group', 'talk' and 'webinar' for real, so the
-- vocabulary needs to be genuinely accepted, not merely declared.
do $$
declare
  f       text;
  target  uuid := (select id from bookings limit 1);
  all_ok  boolean := true;
begin
  foreach f in array array['one_on_one','couple','group','talk','webinar','wellness_day'] loop
    begin
      update bookings set session_format = f where id = target;
      raise exception 'rollback the probe';
    exception
      when check_violation then all_ok := false;      -- a listed value was refused
      when others then
        if sqlerrm <> 'rollback the probe' then all_ok := false; end if;
    end;
  end loop;
  insert into _r values ('8  session_format accepts all six listed values', all_ok, null);
end $$;


-- ── 9–10 · The checks actually reject bad values ────────────
-- Each probe runs in its own subtransaction and is rolled back either way.

do $$
declare ok boolean := false;
begin
  begin
    update bookings set service_line = 'nonsense' where id = (select id from bookings limit 1);
    raise exception 'accepted';
  exception
    when check_violation then ok := true;
    when others then ok := false;
  end;
  insert into _r values ('9  service_line check rejects a bad value', ok, null);
end $$;

do $$
declare ok boolean := false;
begin
  begin
    update bookings set session_format = 'nonsense' where id = (select id from bookings limit 1);
    raise exception 'accepted';
  exception
    when check_violation then ok := true;
    when others then ok := false;
  end;
  insert into _r values ('10 session_format check rejects a bad value', ok, null);
end $$;


-- ── 11–14 · The session_type -> session_mode normalisation ──

select _chk('11 no In-Person/Virtual row still has a null mode',
  (select count(*) from bookings
    where session_mode is null and session_type in ('In-Person','Virtual')) = 0);

select _chk('12 In-Person mapped to physical',
  (select count(*) from bookings
    where session_type = 'In-Person' and session_mode <> 'physical') = 0);

select _chk('13 Virtual mapped to virtual',
  (select count(*) from bookings
    where session_type = 'Virtual' and session_mode <> 'virtual') = 0);

-- 'Individual' is a FORMAT. The two fixture rows carrying 'physical' had it
-- before M1 and must keep it; M1 must not have invented a mode for any other.
select _chk('14 Individual rows keep exactly the modes they arrived with',
  (select count(*) from bookings where session_type = 'Individual' and session_mode = 'physical') = 2
  and (select count(*) from bookings
        where session_type = 'Individual' and session_mode = 'virtual') = 0);


-- ── 15 · session_type is preserved, not deleted ─────────────

select _chk('15 session_type still exists and still holds its values',
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='bookings' and column_name='session_type') = 1
  and (select count(*) from bookings where session_type = 'In-Person')  = 14
  and (select count(*) from bookings where session_type = 'Virtual')    = 6
  and (select count(*) from bookings where session_type = 'Individual') = 2);


-- ── 16–17 · The trigger did not fire ────────────────────────
-- run-m1.sh records the pre-migration totals in m1_baseline_counts.

select _chk('16 points_events did not grow',
  (select count(*) from points_events)
    = (select n from m1_baseline_counts where k = 'points_events'));

select _chk('17 attended is untouched',
  (select count(*) filter (where attended is true) from bookings)
    = (select n from m1_baseline_counts where k = 'attended_true')
  and (select count(*) filter (where attended is false) from bookings)
    = (select n from m1_baseline_counts where k = 'attended_false')
  and (select count(*) filter (where attended is null) from bookings)
    = (select n from m1_baseline_counts where k = 'attended_null'));


-- ── 18 · row count is unchanged ─────────────────────────────

select _chk('18 no booking gained or lost',
  (select count(*) from bookings) = (select n from m1_baseline_counts where k = 'bookings'));


-- ── 19–21 · THE REGRESSION CHECK ────────────────────────────
-- org_report_data() before vs after, per organisation and period.
--
-- 19 asserts everything OUTSIDE sessions.mode_split is byte-identical.
-- 20 asserts the only difference inside mode_split is ADDED keys.
-- 21 asserts every added key is withheld — no cell acquires a number.
--
-- This is deliberately not "the whole payload is identical". Filling
-- session_mode is what M1 is FOR, and mode_split reads session_mode, so it
-- moves by design. Asserting byte-equality would either fail or force the
-- test to be weakened somewhere less visible. See docs/build/m1-service-line.md.

-- mode_split occurs TWICE in the payload: org_report_data returns
-- `v_current || {previous_period: v_previous}`, and both halves carry a
-- sessions.mode_split. Both move, so both are excluded in 19 and both are
-- checked in 20 and 21. An earlier version of 19 stripped only the current
-- half and failed on Sedimosa/Q3 for the previous half — the criterion has
-- to cover every occurrence, not the first one.
create temporary table _after as
select b.org_name, b.period_label, b.payload as before_payload,
       org_report_data(b.org_id, b.period_start, b.period_end) as after_payload
  from m1_baseline b;

create temporary table _splits as
select a.org_name, a.period_label, p.loc,
       coalesce(a.before_payload #> p.path, '{}'::jsonb) as before_ms,
       coalesce(a.after_payload  #> p.path, '{}'::jsonb) as after_ms
  from _after a
 cross join (values
   ('current',  array['sessions','mode_split']),
   ('previous', array['previous_period','sessions','mode_split'])
 ) as p(loc, path);

select _chk('19 everything outside mode_split is identical',
  (select count(*) from _after
    where (before_payload #- '{sessions,mode_split}' #- '{previous_period,sessions,mode_split}')
       is distinct from
          (after_payload  #- '{sessions,mode_split}' #- '{previous_period,sessions,mode_split}')) = 0,
  (select string_agg(org_name || '/' || period_label, ', ') from _after
    where (before_payload #- '{sessions,mode_split}' #- '{previous_period,sessions,mode_split}')
       is distinct from
          (after_payload  #- '{sessions,mode_split}' #- '{previous_period,sessions,mode_split}')));

select _chk('20 mode_split only ever gains keys, never loses or changes one',
  (select count(*) from _splits s,
     lateral (select key, value from jsonb_each(s.before_ms)) b
    where s.after_ms -> b.key is distinct from b.value) = 0,
  (select string_agg(distinct s.org_name || '/' || s.period_label || '/' || s.loc, ', ')
     from _splits s, lateral (select key, value from jsonb_each(s.before_ms)) b
    where s.after_ms -> b.key is distinct from b.value));

select _chk('21 every key mode_split gained is withheld, not a number',
  (select count(*) from _splits s,
     lateral (select key, value from jsonb_each(s.after_ms)) x
    where s.before_ms -> x.key is null
      and (x.value ->> 'suppressed') is distinct from 'true') = 0,
  (select string_agg(distinct s.org_name || '/' || s.period_label || '/' || s.loc || ':' || x.key, ', ')
     from _splits s, lateral (select key, value from jsonb_each(s.after_ms)) x
    where s.before_ms -> x.key is null
      and (x.value ->> 'suppressed') is distinct from 'true'));


-- ── 22 · idempotency left the data alone ────────────────────
-- run-m1.sh applies the migration twice. The backup table must still hold one
-- row per normalised booking, not two passes' worth.

select _chk('22 re-running the migration did not double up the backup',
  (select count(*) from _m1_session_mode_backup) = 18);


-- ── Report ──────────────────────────────────────────────────

select case when ok then 'PASS  ' else 'FAIL  ' end || name
    || coalesce('  -> ' || detail, '') as result
  from _r order by name;

select '  ' || count(*) filter (where ok)::text || ' passed, '
    || count(*) filter (where not ok)::text || ' failed.' as summary
  from _r;

do $$
begin
  if (select count(*) from _r where not ok) > 0 then
    raise exception 'M1 assertions failed';
  end if;
end $$;
