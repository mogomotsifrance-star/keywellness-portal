#!/bin/bash
# Key Wellness — M5a database tests against a local PostgreSQL 17.
#
# M5a builds on M5 (it is gated by is_staff() and excludes is_test), so the
# run stacks both migrations: fixture -> M5 -> M5a -> assertions -> roll back
# M5a -> roll back M5 -> verify clean.
#
# See the header of tests/run-phase0.sh for the Linux/macOS and Windows recipes.
#   Windows:  PGUSER=postgres tests/run-m5a.sh 127.0.0.1 5433
#
# Usage:  tests/run-m5a.sh [host_or_socket_dir] [port]
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
  echo "  server version    FAILED — found PostgreSQL ${PG_MAJ:-unknown}, need >= $PG_MIN"
  exit 1
fi
echo "  server version    ok (PostgreSQL $PG_MAJ)"

$PSQL -d postgres -c "drop database if exists kwm5a" >/dev/null
$PSQL -d postgres -c "create database kwm5a"          >/dev/null

$PSQL -d kwm5a -f "$HERE/m5-fixture.sql"        >/dev/null
$PSQL -d kwm5a -f "$HERE/m5a-fixture-extra.sql" >/dev/null
echo "  fixture           ok (m5 + the three content tables, as M1 leaves them)"

$PSQL -d kwm5a -f "$ROOT/supabase_m5_meetings_actions.sql" >/dev/null 2>&1
echo "  M5                ok"
$PSQL -d kwm5a -f "$ROOT/supabase_m5a_ops_timeline.sql"    >/dev/null 2>&1
echo "  M5a               ok"
$PSQL -d kwm5a -f "$ROOT/supabase_m5a_ops_timeline.sql"    >/dev/null 2>&1
echo "  M5a re-run        ok (idempotent)"

# ERROR and FATAL are in this pattern deliberately. Without them a test file
# that ABORTS part-way prints its notices, prints no summary, and reads as a
# pass to anyone skimming. That has happened twice on this project.
$PSQL -d kwm5a -f "$HERE/m5a-tests.sql" 2>&1 \
  | grep -E "PASS|FAIL|passed|ERROR|FATAL" | sed "s/^psql:[^ ]* //; s/^NOTICE:  //"

# The view exists only for the assertions; drop it so the leftover check is
# about the migration, not the test scaffolding.
$PSQL -d kwm5a -c "drop view if exists _tl; drop view if exists _tl2; drop table if exists _expected" >/dev/null

_kwout=$($PSQL -d kwm5a -f "$ROOT/migrations/rollback-m5a-ops-timeline.sql" 2>&1) || { echo "$_kwout" | grep -vE "NOTICE:|^$"; echo "  rollback          FAILED"; exit 1; }
echo "  rollback M5a      ok"
_kwout=$($PSQL -d kwm5a -f "$ROOT/migrations/rollback-m5a-ops-timeline.sql" 2>&1) || { echo "$_kwout" | grep -vE "NOTICE:|^$"; echo "  rollback          FAILED"; exit 1; }
echo "  rollback re-run   ok (idempotent)"

LEFT=$($PSQL -d kwm5a -t -A -c "
  select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname in ('ops_timeline','_ops_as_date')")

if [ "$LEFT" = "0" ]; then
  echo "  rollback clean    ok (zero leftover objects)"
else
  echo "  rollback clean    FAILED — $LEFT objects left behind"; exit 1
fi

# M5 must still roll back cleanly underneath it.
_kwout=$($PSQL -d kwm5a -f "$ROOT/migrations/rollback-m5-meetings-actions.sql" 2>&1) || { echo "$_kwout" | grep -vE "NOTICE:|^$"; echo "  rollback          FAILED"; exit 1; }
echo "  rollback M5       ok (the stack unwinds in order)"
