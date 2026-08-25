-- ============================================================
-- Rollback — M1: service-line columns
-- Reverses supabase_m1_service_line.sql completely.
--
-- Idempotent: safe to run twice. Leaves ZERO objects behind — no columns,
-- no constraints, no tables, and bookings.session_mode restored to exactly
-- what it held before M1.
--
-- ORDER MATTERS. Step 1 must run BEFORE step 3 drops session_format, and
-- before _m1_session_mode_backup is dropped. Restoring session_mode is the
-- only part of this rollback that is not a DROP, and it is the only part
-- that can lose data if skipped.
-- ============================================================


-- ── 1. Restore bookings.session_mode ────────────────────────
-- The backup holds one row per booking M1 overwrote, with the value it had
-- before (in practice null — M1 only touched rows where session_mode was
-- null — but restore what was recorded rather than assuming).
--
-- Rows that already carried a session_mode were never backed up and are not
-- touched here. That is the point of the backup table: blanket-nulling by
-- session_type would destroy the two Test Co rows that legitimately hold
-- 'physical'.
--
-- Guarded on the table existing so this file also runs cleanly against a
-- database where M1 never got as far as step 4.

do $$
begin
  if to_regclass('public._m1_session_mode_backup') is not null then
    update bookings b
       set session_mode = k.prev_session_mode
      from _m1_session_mode_backup k
     where k.booking_id = b.id;

    raise notice 'M1 rollback: session_mode restored on % row(s).',
      (select count(*) from _m1_session_mode_backup);
  end if;
end $$;


-- ── 2. Drop the backup table ────────────────────────────────
drop table if exists _m1_session_mode_backup;


-- ── 3. Drop the constraints, then the columns ───────────────
-- Dropping a column drops its constraints too, but naming them explicitly
-- keeps the rollback readable and makes it correct even if a column was
-- dropped by hand first.

alter table bookings           drop constraint if exists bookings_service_line_check;
alter table program_activities drop constraint if exists program_activities_service_line_check;
alter table org_reports        drop constraint if exists org_reports_service_line_check;
alter table content_items      drop constraint if exists content_items_service_line_check;
alter table bookings           drop constraint if exists bookings_session_format_check;

alter table bookings           drop column if exists session_format;
alter table bookings           drop column if exists service_line;
alter table program_activities drop column if exists service_line;
alter table org_reports        drop column if exists service_line;
alter table content_items      drop column if exists service_line;


-- ── 4. Clean-slate verification ─────────────────────────────
-- Mirrors the tail of tests/run-phase0.sh: prove nothing survived.

do $$
declare
  n int;
begin
  select
      (select count(*) from information_schema.columns
        where table_schema = 'public'
          and ((table_name in ('bookings','program_activities','org_reports','content_items')
                and column_name = 'service_line')
            or (table_name = 'bookings' and column_name = 'session_format')))
    + (select count(*) from pg_constraint
        where conname in ('bookings_service_line_check',
                          'program_activities_service_line_check',
                          'org_reports_service_line_check',
                          'content_items_service_line_check',
                          'bookings_session_format_check'))
    + (select count(*) from pg_tables
        where schemaname = 'public' and tablename = '_m1_session_mode_backup')
    into n;

  if n <> 0 then
    raise exception 'M1 rollback incomplete: % object(s) left behind', n;
  end if;

  raise notice 'M1 rollback clean: zero leftover objects.';
end $$;
