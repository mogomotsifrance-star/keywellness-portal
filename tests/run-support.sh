#!/bin/bash
# Key Wellness — member-support tests against a local PostgreSQL 17.
#
# Runs: fixture -> migration -> migration again (idempotency) -> assertions
#       -> rollback -> rollback again -> clean-slate verification.
#
# Access assertions run under `set role authenticated`, so RLS is enforced.
# See the header of tests/run-phase0.sh for the Linux/macOS and Windows recipes.
#   Windows:  PGUSER=postgres tests/run-support.sh 127.0.0.1 5433
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

$PSQL -d postgres -c "drop database if exists kwsupport" >/dev/null
$PSQL -d postgres -c "create database kwsupport"          >/dev/null

$PSQL -d kwsupport -f "$HERE/m5-fixture.sql"        >/dev/null
$PSQL -d kwsupport -f "$HERE/m5a-fixture-extra.sql" >/dev/null
echo "  fixture           ok"

$PSQL -d kwsupport -f "$ROOT/supabase_support_audit.sql" >/dev/null 2>&1
echo "  migration         ok"
$PSQL -d kwsupport -f "$ROOT/supabase_support_audit.sql" >/dev/null 2>&1
echo "  migration re-run  ok (idempotent)"

# ERROR and FATAL are in this pattern deliberately. Without them a test file
# that ABORTS part-way prints its notices, prints no summary, and reads as a
# pass to anyone skimming. That has happened twice on this project.
$PSQL -d kwsupport -f "$HERE/support-tests.sql" 2>&1 \
  | grep -E "PASS|FAIL|passed|ERROR|FATAL" | sed "s/^psql:[^ ]* //; s/^NOTICE:  //"

_kwout=$($PSQL -d kwsupport -f "$ROOT/migrations/rollback-support-audit.sql" 2>&1) || { echo "$_kwout" | grep -vE "NOTICE:|^$"; echo "  rollback          FAILED"; exit 1; }
echo "  rollback          ok"
_kwout=$($PSQL -d kwsupport -f "$ROOT/migrations/rollback-support-audit.sql" 2>&1) || { echo "$_kwout" | grep -vE "NOTICE:|^$"; echo "  rollback          FAILED"; exit 1; }
echo "  rollback re-run   ok (idempotent)"

LEFT=$($PSQL -d kwsupport -t -A -c "
  select (select count(*) from pg_tables
           where schemaname='public' and tablename='support_actions')
       + (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public'
             and p.proname in ('is_ops_admin','support_lookup','support_can',
                               'support_log','support_recent'))
       + (select count(*) from pg_policies
           where schemaname='public' and tablename='support_actions')")

if [ "$LEFT" = "0" ]; then
  echo "  rollback clean    ok (zero leftover objects)"
else
  echo "  rollback clean    FAILED — $LEFT objects left behind"; exit 1
fi
