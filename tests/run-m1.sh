#!/bin/bash
# Key Wellness — M1 database tests against a local PostgreSQL 17.
#
# Runs: fixture -> real reporting stack -> baseline capture -> migration
#       -> migration again (idempotency) -> assertions
#       -> rollback -> rollback again -> clean-slate verification.
#
# The baseline is captured by calling the REAL org_report_data() loaded from
# supabase_org_report_data_v4.sql, not a stand-in, so the regression check
# exercises the function that actually ships.
#
# Needs postgresql-17 binaries on PATH and a running local cluster. See the
# header of tests/run-phase0.sh for the Linux/macOS and Windows recipes.
#
#   Linux/macOS :  tests/run-m1.sh
#   Windows      :  PGUSER=postgres tests/run-m1.sh 127.0.0.1 5433
#
# Usage:  tests/run-m1.sh [host_or_socket_dir] [port]
set -e
HOST="${1:-/tmp/pgrun}"
PORT="${2:-5433}"
# $USER is empty in Git Bash; an empty -U swallows the next argument.
PGUSER="${PGUSER:-${USER:-$(whoami 2>/dev/null || echo postgres)}}"
# See run-phase0.sh: the repo's SQL is UTF-8 and psql on Windows would
# otherwise take client_encoding from the console codepage.
export PGCLIENTENCODING="${PGCLIENTENCODING:-UTF8}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PSQL="psql -h $HOST -p $PORT -U $PGUSER -v ON_ERROR_STOP=1 -q"

# ── Server version guard ─────────────────────────────────────
PG_MIN=17
PG_NUM=$($PSQL -d postgres -t -A -c "show server_version_num" 2>/dev/null || echo 0)
PG_MAJ=$(( PG_NUM / 10000 ))
if [ "$PG_MAJ" -lt "$PG_MIN" ]; then
  echo "  server version    FAILED — found PostgreSQL ${PG_MAJ:-unknown}, need >= $PG_MIN"
  echo "                    Production is 17.6. A pass on an older major proves nothing."
  exit 1
fi
echo "  server version    ok (PostgreSQL $PG_MAJ)"

$PSQL -d postgres -c "drop database if exists kwm1" >/dev/null
$PSQL -d postgres -c "create database kwm1"          >/dev/null

$PSQL -d kwm1 -f "$HERE/m1-fixture.sql" >/dev/null
echo "  fixture           ok"

# The real reporting stack. v4 defines _suppress_rate, both
# _org_report_period_data overloads, both org_report_data overloads,
# org_report_company_breakdown and publish_org_report.
$PSQL -d kwm1 -f "$ROOT/supabase_org_report_data_v4.sql" >/dev/null
echo "  reporting stack   ok (org_report_data v4, the live definition)"

# ── Baseline: what the report says BEFORE M1 ─────────────────
# org_report_data() gates on is_admin(), so act as the seeded admin.
$PSQL -d kwm1 >/dev/null <<'SQL'
set test.email = 'admin@keywellness.co.bw';

create table m1_baseline (
  org_id       uuid,
  org_name     text,
  period_label text,
  period_start date,
  period_end   date,
  payload      jsonb
);

insert into m1_baseline (org_id, org_name, period_label, period_start, period_end, payload)
select o.id, o.name, p.label, p.s, p.e,
       org_report_data(o.id, p.s, p.e)
  from organizations o
 cross join (values
     ('Q1 2026', date '2026-01-01', date '2026-03-31'),
     ('Q3 2026', date '2026-07-01', date '2026-09-30'),
     ('Apr-Jun 2026', date '2026-04-01', date '2026-06-30')
   ) as p(label, s, e);

create table m1_baseline_counts (k text primary key, n bigint);
insert into m1_baseline_counts values
  ('bookings',       (select count(*) from bookings)),
  ('points_events',  (select count(*) from points_events)),
  ('attended_true',  (select count(*) filter (where attended is true)  from bookings)),
  ('attended_false', (select count(*) filter (where attended is false) from bookings)),
  ('attended_null',  (select count(*) filter (where attended is null)  from bookings));
SQL
echo "  baseline captured ok ($($PSQL -d kwm1 -t -A -c 'select count(*) from m1_baseline') org/period payloads)"

# ── The migration, twice ─────────────────────────────────────
$PSQL -d kwm1 -f "$ROOT/supabase_m1_service_line.sql" >/dev/null 2>&1
echo "  migration         ok"
$PSQL -d kwm1 -f "$ROOT/supabase_m1_service_line.sql" >/dev/null 2>&1
echo "  migration re-run  ok (idempotent)"

# ── Assertions ───────────────────────────────────────────────
# m1-tests.sql sets test.email itself, so it also runs standalone.
# ERROR and FATAL are in this pattern deliberately. Without them a test file
# that ABORTS part-way prints its notices, prints no summary, and reads as a
# pass to anyone skimming. That has happened twice on this project.
$PSQL -d kwm1 -f "$HERE/m1-tests.sql" 2>&1 \
  | grep -E "PASS|FAIL|passed|ERROR|FATAL" | sed "s/^psql:[^ ]* //; s/^NOTICE:  //"

# ── Rollback, twice ──────────────────────────────────────────
_kwout=$($PSQL -d kwm1 -f "$ROOT/migrations/rollback-m1-service-line.sql" 2>&1) || { echo "$_kwout" | grep -vE "NOTICE:|^$"; echo "  rollback          FAILED"; exit 1; }
echo "  rollback          ok"
_kwout=$($PSQL -d kwm1 -f "$ROOT/migrations/rollback-m1-service-line.sql" 2>&1) || { echo "$_kwout" | grep -vE "NOTICE:|^$"; echo "  rollback          FAILED"; exit 1; }
echo "  rollback re-run   ok (idempotent)"

# ── Clean slate + the data is genuinely back ─────────────────
LEFT=$($PSQL -d kwm1 -t -A -c "
  select (select count(*) from information_schema.columns
           where table_schema='public'
             and ((table_name in ('bookings','program_activities','org_reports','content_items')
                   and column_name='service_line')
               or (table_name='bookings' and column_name='session_format')))
       + (select count(*) from pg_constraint
           where conname in ('bookings_service_line_check',
                             'program_activities_service_line_check',
                             'org_reports_service_line_check',
                             'content_items_service_line_check',
                             'bookings_session_format_check'))
       + (select count(*) from pg_tables
           where schemaname='public' and tablename='_m1_session_mode_backup')")

if [ "$LEFT" = "0" ]; then
  echo "  rollback clean    ok (zero leftover objects)"
else
  echo "  rollback clean    FAILED — $LEFT objects left behind"; exit 1
fi

# session_mode must be back to exactly the pre-migration distribution:
# 18 rows null again, and the 4 that legitimately held 'physical' still do.
RESTORED=$($PSQL -d kwm1 -t -A -c "
  select case when
      (select count(*) from bookings where session_mode is null) = 18
  and (select count(*) from bookings where session_mode = 'physical') = 4
  and (select count(*) from bookings where session_mode = 'virtual') = 0
    then 'ok' else 'FAILED' end")

if [ "$RESTORED" = "ok" ]; then
  echo "  session_mode      ok (restored from backup, the 4 pre-existing kept)"
else
  echo "  session_mode      FAILED — not restored to the pre-migration state"; exit 1
fi

# And the report is byte-identical to the baseline once more.
SAME=$($PSQL -d kwm1 -t -A -c "
  set test.email = 'admin@keywellness.co.bw';
  select case when count(*) = 0 then 'ok' else 'FAILED' end
    from m1_baseline b
   where b.payload is distinct from org_report_data(b.org_id, b.period_start, b.period_end)")

if [ "$SAME" = "ok" ]; then
  echo "  report after r/b  ok (byte-identical to the baseline)"
else
  echo "  report after r/b  FAILED — the rollback did not restore the figures"; exit 1
fi
