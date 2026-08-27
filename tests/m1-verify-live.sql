-- ============================================================
-- Key Wellness — M1 live verification (READ-ONLY)
--
-- Run this in the Supabase SQL Editor TWICE: once BEFORE applying
-- supabase_m1_service_line.sql and once AFTER. Save both outputs and diff
-- them. Every block returns a single text column called `line`.
--
-- READ-ONLY. V1–V5 are SELECTs. V6 is a DO block that only reads and emits
-- notices. Nothing here creates, alters, updates or drops anything, and
-- nothing writes to the database even transiently.
--
-- Deliberately NOT here: a probe that tries to write a bad service_line to
-- prove the CHECK rejects it. That would mean issuing an UPDATE against
-- production and relying on a rollback to undo it, and a verification script
-- should not be the thing that risks a row. Constraint rejection is proven
-- locally instead — tests/m1-tests.sql, assertions 9 and 10.
--
-- V1–V3 work before and after M1. V4–V6 are meaningful in both states; V6
-- says plainly when M1 has not been applied yet.
--
-- Why _org_report_period_data() and not org_report_data(): the wrapper gates
-- on `is_admin() or employer_org() = p_org_id`, and in the SQL editor
-- auth.jwt() is null, so the wrapper always raises 'not authorised'. The
-- wrapper adds only the authorisation gate and the previous_period join —
-- every figure comes from _org_report_period_data, which the editor can call
-- because it runs as postgres, the function's owner. V3 covers the
-- previous-period arithmetic explicitly.
-- ============================================================


-- ── V1 · Which state is this database in? ───────────────────
-- Run first. Tells you whether you are looking at a before or an after.
select 'service_line on bookings           : ' ||
       case when exists (select 1 from information_schema.columns
                          where table_schema='public' and table_name='bookings'
                            and column_name='service_line') then 'PRESENT' else 'absent' end as line
union all
select 'session_format on bookings         : ' ||
       case when exists (select 1 from information_schema.columns
                          where table_schema='public' and table_name='bookings'
                            and column_name='session_format') then 'PRESENT' else 'absent' end
union all
select '_m1_session_mode_backup            : ' ||
       case when to_regclass('public._m1_session_mode_backup') is not null
            then 'PRESENT' else 'absent' end
union all
select 'bookings rows                      : ' || count(*)::text from bookings;

-- Note: the backup table's ROW COUNT is reported by V6, not here. A
-- `select count(*) from _m1_session_mode_backup` inside a CASE would still
-- fail before M1 is applied — PostgreSQL resolves relation names when it
-- parses the statement, not when it evaluates the branch, so the guard does
-- not protect it. V6 reaches it through EXECUTE, which resolves at run time.


-- ── V2 · The session_type × session_mode matrix ─────────────
-- BEFORE : 'In-Person'/'Virtual' rows sit on session_mode NULL.
-- AFTER  : no 'In-Person'/'Virtual' row has a NULL mode; 'Individual' rows
--          still do, because 'Individual' is a format and carries no mode.
-- Row counts per pair must not change — only the mode moves.
select coalesce(session_type,'(null)') || '  x  ' || coalesce(session_mode,'(null mode)')
       || '   =  ' || count(*)::text || ' row(s)'
       || case when session_mode is null and session_type in ('In-Person','Virtual')
               then '   <-- M1 will normalise these' else '' end as line
  from bookings
 group by session_type, session_mode
 order by 1;


-- ── V3 · Reporting figures for every period that matters ────
-- The regression check. Diff this block before against after.
--
-- EXPECTED DIFF: `mode_split` gains keys, and every gained key reads
-- {"value": null, "suppressed": true}. total_booked, total_attended,
-- monthly_trend and attendance_confirmation_coverage_pct must be IDENTICAL.
-- Anything else changing is a fault — stop and roll back.
--
-- Covers all three organisations, every issued report period, and each
-- period's previous window (the one org_report_data computes for comparison).
with report_periods as (
  select distinct r.org_id, r.period_label, r.period_start, r.period_end
    from org_reports r
),
with_previous as (
  select org_id, period_label, period_start, period_end from report_periods
  union all
  select org_id,
         period_label || ' [previous window]',
         (period_start - 1) - (period_end - period_start),
         (period_start - 1)
    from report_periods
),
all_periods as (
  select * from with_previous
  union all
  -- Sedimosa and BOPEU have no reports of their own; check the current
  -- quarter for them so the two live organisations are covered too.
  select o.id, 'Q3 2026 [no report; live check]', date '2026-07-01', date '2026-09-30'
    from organizations o
)
select o.name || ' | ' || p.period_label
       || ' | ' || p.period_start || '..' || p.period_end
       || ' | sessions=' || coalesce(
            (_org_report_period_data(p.org_id, p.period_start, p.period_end) -> 'sessions')::text,
            'NULL (insufficient_cohort)')
       as line
  from all_periods p
  join organizations o on o.id = p.org_id
 order by o.name, p.period_start, p.period_label;


-- ── V4 · The trigger did not fire ───────────────────────────
-- trg_award_session_attended is AFTER UPDATE on bookings and M1 issues two
-- UPDATEs. Its guard (`new.attended is true AND old.attended is distinct
-- from true`) cannot be satisfied by a write that never touches attended,
-- so this total must be identical before and after.
select 'points_events rows                 : ' || count(*)::text
    || '   |  of event_type session_attended: '
    || count(*) filter (where event_type = 'session_attended')::text as line
  from points_events;


-- ── V5 · Attendance is untouched ────────────────────────────
-- Must be identical before and after.
select 'attended true/false/null           : '
    || count(*) filter (where attended is true)::text || ' / '
    || count(*) filter (where attended is false)::text || ' / '
    || count(*) filter (where attended is null)::text as line
  from bookings;


-- ── V6 · Post-apply assertions (AFTER only) ─────────────────
-- Before M1 this reports that and skips; after M1 every line must read OK.
do $$
declare
  n_backup int;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='bookings'
                    and column_name='service_line') then
    raise notice 'M1 not applied yet — the checks below are skipped.';
    return;
  end if;

  -- EXECUTE, not a plain select: the relation may not exist, and a plain
  -- select would fail to parse rather than fall through.
  if to_regclass('public._m1_session_mode_backup') is not null then
    execute 'select count(*) from _m1_session_mode_backup' into n_backup;
    raise notice 'rows M1 normalised (backup)      : %', n_backup;
  else
    raise notice 'rows M1 normalised (backup)      : backup table absent — '
                 'either M1 has not run or the rollback has';
  end if;

  raise notice 'every booking financial          : %',
    case when (select count(*) from bookings where service_line <> 'financial') = 0
         then 'OK' else 'FAIL' end;

  raise notice 'every booking has a format       : %',
    case when (select count(*) from bookings where session_format is null) = 0
         then 'OK' else 'FAIL' end;

  raise notice 'every format is one_on_one       : %',
    case when (select count(*) from bookings where session_format <> 'one_on_one') = 0
         then 'OK' else 'FAIL (expected only if something already wrote another format)' end;

  raise notice 'no mode left in session_type     : %',
    case when (select count(*) from bookings
                where session_mode is null and session_type in ('In-Person','Virtual')) = 0
         then 'OK' else 'FAIL' end;

  raise notice 'Individual rows carry no mode    : %',
    case when (select count(*) from bookings
                where session_type = 'Individual' and session_mode is null)
              = (select count(*) from bookings where session_type = 'Individual')
         then 'OK'
         else 'CHECK — an Individual row has a mode; legitimate if it was set '
              'before M1 (two Test Co rows were), a fault otherwise' end;

  raise notice 'mode vocabulary respected        : %',
    case when (select count(*) from bookings
                where session_mode is not null
                  and session_mode not in ('physical','virtual')) = 0
         then 'OK' else 'FAIL' end;

  raise notice 'other three tables defaulted     : %',
    case when (select count(*) from program_activities where service_line <> 'financial')
             + (select count(*) from org_reports        where service_line <> 'financial')
             + (select count(*) from content_items      where service_line <> 'financial') = 0
         then 'OK' else 'FAIL' end;
end $$;
