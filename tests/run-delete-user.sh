#!/bin/bash
# Key Wellness — account-deletion tests against a local PostgreSQL 17.
#
# Runs: fixtures -> migration -> migration again (idempotency) -> assertions
#       -> rollback -> rollback again -> clean-slate verification.
#
# See the header of tests/run-phase0.sh for the Linux/macOS and Windows recipes.
#   Windows:  PGUSER=postgres tests/run-delete-user.sh 127.0.0.1 5433
#
# NOTHING HERE TOUCHES SUPABASE. The fixtures reconstruct the slice of the live
# schema this feature walks — every foreign key with its real delete rule — in
# a throwaway local database.
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

$PSQL -d postgres -c "drop database if exists kwdeluser" >/dev/null
$PSQL -d postgres -c "create database kwdeluser"          >/dev/null

$PSQL -d kwdeluser -f "$HERE/m5-fixture.sql"              >/dev/null
$PSQL -d kwdeluser -f "$HERE/m5a-fixture-extra.sql"       >/dev/null
$PSQL -d kwdeluser -f "$ROOT/supabase_support_audit.sql"  >/dev/null 2>&1
$PSQL -d kwdeluser -f "$HERE/delete-user-fixture-extra.sql" >/dev/null
echo "  fixture           ok"

$PSQL -d kwdeluser -f "$ROOT/supabase_admin_delete_user.sql" >/dev/null 2>&1
echo "  migration         ok"
$PSQL -d kwdeluser -f "$ROOT/supabase_admin_delete_user.sql" >/dev/null 2>&1
echo "  migration re-run  ok (idempotent)"

# ERROR and FATAL are in this pattern deliberately. Without them a test file
# that ABORTS part-way prints its notices, prints no summary, and reads as a
# pass to anyone skimming. That has happened twice on this project.
$PSQL -d kwdeluser -f "$HERE/delete-user-tests.sql" 2>&1 \
  | grep -E "PASS|FAIL|passed|ERROR|FATAL" | sed "s/^psql:[^ ]* //; s/^NOTICE:  //"

# The rollback runs against a database in which two accounts have ALREADY been
# deleted, which is the state that matters: it must keep actor_email and leave
# actor nullable, because rows now depend on both. A rollback that only works
# on an unused feature is not a rollback.
_kwout=$($PSQL -d kwdeluser -f "$ROOT/migrations/rollback-admin-delete-user.sql" 2>&1) \
  || { echo "$_kwout" | grep -vE "NOTICE:|^$"; echo "  rollback          FAILED"; exit 1; }
echo "  rollback          ok"
_kwout=$($PSQL -d kwdeluser -f "$ROOT/migrations/rollback-admin-delete-user.sql" 2>&1) \
  || { echo "$_kwout" | grep -vE "NOTICE:|^$"; echo "  rollback          FAILED"; exit 1; }
echo "  rollback re-run   ok (idempotent)"

LEFT=$($PSQL -d kwdeluser -t -A -c "
  select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and p.proname in ('admin_user_delete','admin_user_delete_preview',
                               '_admin_user_refs','_admin_user_delete_plan'))")
if [ "$LEFT" = "0" ]; then
  echo "  rollback clean    ok (all four functions dropped)"
else
  echo "  rollback clean    FAILED — $LEFT function(s) left behind"; exit 1
fi

# What the rollback must NOT do, having been run over a live deletion: throw
# away the only surviving record of who performed those support actions.
KEPT=$($PSQL -d kwdeluser -t -A -c "
  select (select count(*) from information_schema.columns
           where table_schema='public' and table_name='support_actions'
             and column_name='actor_email')
       + (select count(*) from support_actions
           where actor is null and actor_email is not null)")
if [ "$KEPT" -ge 3 ]; then
  echo "  audit preserved   ok (actor_email kept for rows whose account is gone)"
else
  echo "  audit preserved   FAILED — the rollback discarded audit identities"; exit 1
fi
