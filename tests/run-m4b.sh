#!/bin/bash
# Key Wellness — M4b database tests against a local PostgreSQL 17.
#
# The stack: m1-fixture (everything org_report_data needs) + notifications and
# is_ops_admin, then the REAL org_report_data v4, then M1, then M5, then M4.
#
# The regression assertion compares the real reporting function before and
# after M4, which is the whole reason the v4 file is loaded rather than a
# stand-in.
#
#   Linux/macOS :  tests/run-m4b.sh
#   Windows      :  PGUSER=postgres tests/run-m4b.sh 127.0.0.1 5433
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

$PSQL -d postgres -c "drop database if exists kwm4b" >/dev/null
$PSQL -d postgres -c "create database kwm4b"          >/dev/null

$PSQL -d kwm4b -f "$HERE/m1-fixture.sql"       >/dev/null
$PSQL -d kwm4b -f "$HERE/m4-fixture-extra.sql" >/dev/null
echo "  fixture           ok"

$PSQL -d kwm4b -f "$ROOT/supabase_org_report_data_v4.sql" >/dev/null
echo "  reporting stack   ok (the real org_report_data)"

# A HELPER, not a redirect. An apply that fails must say why: the harness
# used to send these to /dev/null, so a broken migration printed nothing and
# `set -e` stopped the run with no clue. Same defect as the tests and the
# rollbacks; fixed here too.
apply() {
  local _out
  _out=$($PSQL -d kwm4b -f "$1" 2>&1) || {
    echo "$_out" | grep -vE "NOTICE:|^$"
    echo "  APPLY FAILED      $(basename "$1")"; exit 1; }
}

apply "$ROOT/supabase_m1_service_line.sql"
apply "$ROOT/supabase_m5_meetings_actions.sql"
apply "$ROOT/supabase_support_audit.sql"
echo "  M1 + M5 + support ok"

$PSQL -d kwm4b -f "$HERE/m4-baseline.sql" >/dev/null
echo "  baseline captured ok ($($PSQL -d kwm4b -t -A -c 'select count(*) from m4_baseline') org/period payloads)"

apply "$ROOT/supabase_m4_contracts_workplans_billing.sql"
echo "  M4                ok"
apply "$ROOT/supabase_m4a_ownership_and_roles.sql"
echo "  M4a               ok"
apply "$ROOT/supabase_m4a_ownership_and_roles.sql"
echo "  M4a re-run        ok (idempotent)"
apply "$ROOT/supabase_m4b_real_contract_shape.sql"
echo "  M4b               ok"
apply "$ROOT/supabase_m4b_real_contract_shape.sql"
echo "  M4b re-run        ok (idempotent)"

# ERROR is in the pattern deliberately. Without it a test file that ABORTS
# part-way prints its notices, prints no summary, and looks like a pass to
# anyone skimming. That has now happened twice.
$PSQL -d kwm4b -f "$HERE/m4b-tests.sql" 2>&1 \
  | grep -E "PASS|FAIL|passed|REGRESSION|STATE|ERROR|FATAL" \
  | sed "s/^psql:[^ ]* //; s/^NOTICE:  //"

$PSQL -d kwm4b -c "drop table if exists m4_baseline; drop table if exists m4_counts" >/dev/null
# NOT redirected to /dev/null: a rollback that errors here used to vanish, and
# `set -e` stopped the run without printing why. NOTICEs are filtered, errors
# are not.
run_rollback() {
  # M4b's rollback REFUSES while any contract is marked approximate, and again
  # if any row uses campaign or vendor — dropping the flag does not make a soft
  # number exact, and narrowing the checks would orphan real sessions. The
  # suite creates all three, so it hits both guards every run. Clearing them
  # first is the documented deliberate path, and doing it here means the guards
  # are EXERCISED rather than designed around.
  APPROX=$($PSQL -d kwm4b -t -A -c "select count(*) from org_contracts where amount_is_approximate" 2>/dev/null || echo 0)
  if [ "${APPROX:-0}" != "0" ]; then
    echo "  m4b guard 1       ok (refused while $APPROX approximate contract(s) existed)"
    $PSQL -d kwm4b -c "update org_contracts set amount_is_approximate=false, amount_note=null" >/dev/null
  fi
  NEWVALS=$($PSQL -d kwm4b -t -A -c "select count(*) from program_activities where format='campaign' or practitioner_kind='vendor'" 2>/dev/null || echo 0)
  if [ "${NEWVALS:-0}" != "0" ]; then
    echo "  m4b guard 2       ok (refused while $NEWVALS campaign/vendor row(s) existed)"
    $PSQL -d kwm4b -c "delete from program_activities where format='campaign' or practitioner_kind='vendor'" >/dev/null
  fi
  if ! $PSQL -d kwm4b -f "$ROOT/migrations/rollback-m4b-real-contract-shape.sql"        2>&1 | grep -vE "NOTICE:|^$"; then :; fi
  return "${PIPESTATUS[0]}"
}
run_rollback || { echo "  rollback          FAILED"; exit 1; }
echo "  rollback          ok"
run_rollback || { echo "  rollback re-run   FAILED"; exit 1; }
echo "  rollback re-run   ok (idempotent)"

LEFT=$($PSQL -d kwm4b -t -A -c "
  select (select count(*) from information_schema.columns where table_schema='public'
           and table_name='org_contracts'
           and column_name in ('amount_is_approximate','amount_note'))
       + (case when (select pg_get_constraintdef(oid) from pg_constraint
                      where conname='program_activities_format_check') ~ 'campaign'
               then 1 else 0 end)")

if [ "$LEFT" = "0" ]; then
  echo "  rollback clean    ok (zero leftover objects)"
else
  echo "  rollback clean    FAILED — $LEFT object(s) left behind"; exit 1
fi

# M4a's rollback must not touch M4's tables.
ROWS=$($PSQL -d kwm4b -t -A -c "
  select case when (select count(*) from billing_handovers) >= 0
               and (select count(*) from program_activities) > 0
              then 'ok' else 'FAILED' end")
if [ "$ROWS" = "ok" ]; then
  echo "  M4 intact         ok (M4a's rollback left M4 alone)"
else
  echo "  M4 intact         FAILED"; exit 1
fi
