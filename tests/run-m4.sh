#!/bin/bash
# Key Wellness — M4 database tests against a local PostgreSQL 17.
#
# The stack: m1-fixture (everything org_report_data needs) + notifications and
# is_ops_admin, then the REAL org_report_data v4, then M1, then M5, then M4.
#
# The regression assertion compares the real reporting function before and
# after M4, which is the whole reason the v4 file is loaded rather than a
# stand-in.
#
#   Linux/macOS :  tests/run-m4.sh
#   Windows      :  PGUSER=postgres tests/run-m4.sh 127.0.0.1 5433
set -e
HOST="${1:-/tmp/pgrun}"
PORT="${2:-5433}"
PGUSER="${PGUSER:-${USER:-$(whoami 2>/dev/null || echo postgres)}}"
export PGCLIENTENCODING="${PGCLIENTENCODING:-UTF8}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PSQL="psql -h $HOST -p $PORT -U $PGUSER -v ON_ERROR_STOP=1 -q"

PG_MIN=17
PG_NUM=$($PSQL -d postgres -t -A -c "show server_version_num" 2>/dev/null || echo 0)
PG_MAJ=$(( PG_NUM / 10000 ))
if [ "$PG_MAJ" -lt "$PG_MIN" ]; then
  echo "  server version    FAILED — found PostgreSQL ${PG_MAJ:-unknown}, need >= $PG_MIN"; exit 1
fi
echo "  server version    ok (PostgreSQL $PG_MAJ)"

$PSQL -d postgres -c "drop database if exists kwm4" >/dev/null
$PSQL -d postgres -c "create database kwm4"          >/dev/null

$PSQL -d kwm4 -f "$HERE/m1-fixture.sql"       >/dev/null
$PSQL -d kwm4 -f "$HERE/m4-fixture-extra.sql" >/dev/null
echo "  fixture           ok"

$PSQL -d kwm4 -f "$ROOT/supabase_org_report_data_v4.sql" >/dev/null
echo "  reporting stack   ok (the real org_report_data)"

$PSQL -d kwm4 -f "$ROOT/supabase_m1_service_line.sql"     >/dev/null 2>&1
$PSQL -d kwm4 -f "$ROOT/supabase_m5_meetings_actions.sql" >/dev/null 2>&1
echo "  M1 + M5           ok"

$PSQL -d kwm4 -f "$HERE/m4-baseline.sql" >/dev/null
echo "  baseline captured ok ($($PSQL -d kwm4 -t -A -c 'select count(*) from m4_baseline') org/period payloads)"

$PSQL -d kwm4 -f "$ROOT/supabase_m4_contracts_workplans_billing.sql" >/dev/null 2>&1
echo "  M4                ok"
$PSQL -d kwm4 -f "$ROOT/supabase_m4_contracts_workplans_billing.sql" >/dev/null 2>&1
echo "  M4 re-run         ok (idempotent)"

# ERROR is in the pattern deliberately. Without it a test file that ABORTS
# part-way prints its notices, prints no summary, and looks like a pass to
# anyone skimming. That has now happened twice.
$PSQL -d kwm4 -f "$HERE/m4-tests.sql" 2>&1 \
  | grep -E "PASS|FAIL|passed|REGRESSION|STATE|ERROR|FATAL" \
  | sed "s/^psql:[^ ]* //; s/^NOTICE:  //"

$PSQL -d kwm4 -c "drop table if exists m4_baseline; drop table if exists m4_counts" >/dev/null
# NOT redirected to /dev/null: a rollback that errors here used to vanish, and
# `set -e` stopped the run without printing why. NOTICEs are filtered, errors
# are not.
run_rollback() {
  if ! $PSQL -d kwm4 -f "$ROOT/migrations/rollback-m4-contracts-workplans-billing.sql"        2>&1 | grep -vE "NOTICE:|^$"; then :; fi
  return "${PIPESTATUS[0]}"
}
run_rollback || { echo "  rollback          FAILED"; exit 1; }
echo "  rollback          ok"
run_rollback || { echo "  rollback re-run   FAILED"; exit 1; }
echo "  rollback re-run   ok (idempotent)"

LEFT=$($PSQL -d kwm4 -t -A -c "
  select (select count(*) from pg_tables where schemaname='public'
           and tablename in ('org_contracts','contract_rates','org_contacts','work_plans','billing_handovers'))
       + (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in ('_handover_period','_handover_owner',
             '_pack_contents','_handover_for_activity','kw_booking_drives_activity',
             'handovers_run_monthly','handover_pack','handover_mark_handed_over',
             'handover_confirm_invoiced','handover_cancel','_billing_flags',
             'contract_position','org_work_plan','work_plan_upsert','activity_upsert'))
       + (select count(*) from information_schema.columns where table_schema='public'
           and table_name='program_activities' and column_name in ('work_plan_id','format','state'))
       + (select count(*) from information_schema.columns where table_schema='public'
           and table_name='bookings' and column_name='activity_id')")

if [ "$LEFT" = "0" ]; then
  echo "  rollback clean    ok (zero leftover objects)"
else
  echo "  rollback clean    FAILED — $LEFT objects left behind"; exit 1
fi

# The rows survive. M4 only added columns to program_activities, so the
# rollback must drop the columns and leave every row org_report_data counts.
ROWS=$($PSQL -d kwm4 -t -A -c "
  select case when (select count(*) from program_activities) > 0 then 'ok' else 'FAILED' end")
if [ "$ROWS" = "ok" ]; then
  echo "  activities kept   ok (the rollback dropped columns, not rows)"
else
  echo "  activities kept   FAILED — program_activities rows were lost"; exit 1
fi
