-- ============================================================
-- Key Wellness — M1: service-line columns
-- From docs/data-model-and-impact.md §2.3 and §4.
--
-- Run in the Supabase SQL Editor. Idempotent — safe to re-run.
-- Rollback: migrations/rollback-m1-service-line.sql
-- Tests:    tests/m1-tests.sql   (local, PostgreSQL 17)
-- Verify:   tests/m1-verify-live.sql (read-only, this editor)
--
-- WHAT THIS DOES
--   1. service_line ('financial' | 'psychosocial'), defaulted to 'financial',
--      on bookings, program_activities, org_reports and content_items.
--   2. session_format on bookings, backfilled to 'one_on_one'.
--   3. Stops session_type carrying two meanings: where session_mode is null
--      and session_type holds a MODE ('In-Person' / 'Virtual'), the mode moves
--      into session_mode normalised to 'physical' / 'virtual'.
--      session_type is NOT deleted.
--
-- WHAT THIS DOES NOT DO
--   No function is created, replaced or dropped. No policy is touched. No
--   grant or revoke. Nothing reads or writes 'psychosocial' yet — that arrives
--   with M3.
--
-- ── TWO THINGS TO KNOW BEFORE APPLYING ──────────────────────
--
-- (a) The session_mode backfill is NOT reversible by dropping a column, so
--     step 4 records the previous value of every row it will change into
--     _m1_session_mode_backup. The rollback restores from it and drops it.
--     Recomputing the old state instead would be wrong: two Test Co rows
--     already carry session_mode='physical' legitimately, and blanket-nulling
--     by session_type would destroy them.
--
-- (b) org_report_data()'s `sessions.mode_split` is built from
--     bookings.session_mode (supabase_org_report_data_v4.sql, mode_counts CTE:
--     `count(*) filter (where attended is true) ... where session_mode is not
--     null`). Filling session_mode therefore changes what a RECOMPUTED report
--     returns. Measured by calling _org_report_period_data() against live
--     data on 25 Aug 2026 — every affected period, BEFORE:
--
--       Test Co   Q1 2026 (Jan–Mar)      insufficient_cohort — no figures
--       Test Co   Q3 2026 (Jul–Sep)      mode_split {"physical": withheld}
--       Test Co   Q3 previous (Apr–Jun)  mode_split {}
--       Sedimosa  Q3 2026 (Jul–Sep)      mode_split {}
--       BOPEU     every period           insufficient_cohort (2 members < 5)
--
--     AFTER, each mode_split gains the keys its rows now carry: Test Co Q3
--     gains "virtual", Test Co Apr–Jun gains "physical", Sedimosa Q3 gains
--     both. EVERY one of those cells is WITHHELD. mode_counts counts only
--     `attended is true`; the entire database holds exactly ONE such booking
--     (Test Co, Virtual, 2026-07-22); and _suppress_count withholds anything
--     below 3. So no cell anywhere acquires a number.
--
--     total_booked, total_attended, monthly_trend and
--     attendance_confirmation_coverage_pct do not read session_mode and are
--     byte-identical throughout.
--
--     The PUBLISHED Q3 report is unaffected either way: publish_org_report()
--     froze it into org_reports.data_snapshot, and HR reads the snapshot.
--
--     So: no issued report changes and no figure changes — some recomputed
--     mode_splits gain withheld keys. That is session_mode finally holding
--     the mode, which is the point of the migration. It is not a regression,
--     but it IS a change in a function's output, so tests/m1-tests.sql
--     asserts precisely this and nothing looser: everything outside
--     mode_split identical, and every new mode_split key suppressed with a
--     null value.
--
-- (c) bookings carries an AFTER UPDATE trigger, trg_award_session_attended.
--     Its body is guarded on `new.attended is true AND old.attended is
--     distinct from true`. Step 5 and step 6 never write `attended`, so
--     new.attended = old.attended and the guard is false in every case:
--     if attended was already true the second clause fails; otherwise the
--     first does. points_events cannot grow. (Belt and braces: points_events
--     also has UNIQUE (user_id, event_type, ref_id).)
-- ============================================================


-- ── 1. service_line on the four tables ──────────────────────
-- add column ... if not exists with a non-volatile default does not rewrite
-- the table on PG11+, so this is cheap even once these tables are large.

alter table bookings           add column if not exists service_line text not null default 'financial';
alter table program_activities add column if not exists service_line text not null default 'financial';
alter table org_reports        add column if not exists service_line text not null default 'financial';
alter table content_items      add column if not exists service_line text not null default 'financial';


-- ── 2. The service_line checks ──────────────────────────────
-- Guarded by name so a re-run is a no-op rather than a duplicate-object error.

do $$
declare
  t text;
begin
  foreach t in array array['bookings','program_activities','org_reports','content_items'] loop
    if not exists (
      select 1 from pg_constraint where conname = t || '_service_line_check'
    ) then
      execute format(
        'alter table %I add constraint %I check (service_line in (%L, %L))',
        t, t || '_service_line_check', 'financial', 'psychosocial');
    end if;
  end loop;
end $$;


-- ── 3. session_format on bookings ───────────────────────────
-- Nullable: a row whose format is genuinely unknown should say so rather than
-- be forced into a wrong bucket. Every row that exists today IS a one-to-one,
-- so step 5 fills them all; the column stays nullable for what comes next.

alter table bookings add column if not exists session_format text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'bookings_session_format_check') then
    alter table bookings add constraint bookings_session_format_check
      check (session_format in
        ('one_on_one','couple','group','talk','webinar','wellness_day'));
  end if;
end $$;


-- ── 4. Record what step 6 is about to overwrite ─────────────
-- Rollback restores from this table and then drops it, so it leaves nothing
-- behind. Populated ONLY with the rows step 6 will actually change.

create table if not exists _m1_session_mode_backup (
  booking_id        uuid primary key,
  prev_session_mode text,
  backed_up_at      timestamptz not null default now()
);

comment on table _m1_session_mode_backup is
  'M1 only. Pre-migration bookings.session_mode for rows the session_type '
  'normalisation overwrites. migrations/rollback-m1-service-line.sql restores '
  'from this table and drops it. Safe to drop once M1 is settled.';

insert into _m1_session_mode_backup (booking_id, prev_session_mode)
select b.id, b.session_mode
  from bookings b
 where b.session_mode is null
   and b.session_type in ('In-Person', 'Virtual')
on conflict (booking_id) do nothing;

-- Not granted to anybody. It holds no personal data (a booking id and a mode),
-- but there is no reason for a client to read it.
revoke all on table _m1_session_mode_backup from public, anon, authenticated;


-- ── 5. Backfill session_format ──────────────────────────────
-- Every existing row is a one-to-one session. `where session_format is null`
-- makes the re-run a no-op and stops a later, deliberately-set value from
-- being stamped back to one_on_one.

update bookings
   set session_format = 'one_on_one'
 where session_format is null;


-- ── 6. Move the mode out of session_type ────────────────────
-- 'Individual' is a FORMAT, not a mode: those rows carry no mode and keep
-- session_mode null. bookings_session_mode_check only admits
-- 'physical'/'virtual', which is why the normalisation is mandatory rather
-- than cosmetic — writing 'In-Person' through would be rejected.
--
-- session_type is deliberately left in place. index.html's booking form and
-- advisor_book_session() still write it; retiring it is its own change.

update bookings
   set session_mode = case session_type
                        when 'In-Person' then 'physical'
                        when 'Virtual'   then 'virtual'
                      end
 where session_mode is null
   and session_type in ('In-Person', 'Virtual');


-- ── 7. Post-conditions ──────────────────────────────────────
-- Cheap assertions so a bad apply fails loudly here rather than surfacing as
-- a wrong number in a report weeks later. Every step above is idempotent, so
-- if this raises, fix the cause and re-run the whole file.

do $$
declare
  n_bad_line   int;
  n_bad_format int;
  n_bad_mode   int;
  n_leftover   int;
begin
  select count(*) into n_bad_line from bookings where service_line <> 'financial';
  if n_bad_line > 0 then
    raise exception 'M1: % booking(s) are not financial after backfill', n_bad_line;
  end if;

  select count(*) into n_bad_format from bookings where session_format is null;
  if n_bad_format > 0 then
    raise exception 'M1: % booking(s) have no session_format after backfill', n_bad_format;
  end if;

  -- Nothing may have landed outside the mode vocabulary.
  select count(*) into n_bad_mode
    from bookings
   where session_mode is not null and session_mode not in ('physical','virtual');
  if n_bad_mode > 0 then
    raise exception 'M1: % booking(s) carry an invalid session_mode', n_bad_mode;
  end if;

  -- Every row we set out to normalise has been normalised.
  select count(*) into n_leftover
    from bookings
   where session_mode is null and session_type in ('In-Person','Virtual');
  if n_leftover > 0 then
    raise exception 'M1: % booking(s) still carry a mode in session_type', n_leftover;
  end if;

  raise notice 'M1 applied: % row(s) had session_mode normalised.',
    (select count(*) from _m1_session_mode_backup);
end $$;
