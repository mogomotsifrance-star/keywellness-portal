#!/bin/bash
# Key Wellness — M5 database tests against a local PostgreSQL 17.
#
# Runs: fixture -> migration -> migration again (idempotency) -> assertions
#       -> rollback -> rollback again -> clean-slate verification.
#
# Unlike run-phase0.sh, the access assertions here run under
# `set role authenticated`, so row-level security is actually enforced rather
# than bypassed by the superuser. See the header of tests/m5-fixture.sql.
#
# Needs postgresql-17 binaries on PATH and a running local cluster. See the
# header of tests/run-phase0.sh for the Linux/macOS and Windows recipes.
#
#   Linux/macOS :  tests/run-m5.sh
#   Windows      :  PGUSER=postgres tests/run-m5.sh 127.0.0.1 5433
#
# Usage:  tests/run-m5.sh [host_or_socket_dir] [port]
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
  echo "                    Production is 17.6. A pass on an older major proves nothing."
  exit 1
fi
echo "  server version    ok (PostgreSQL $PG_MAJ)"

$PSQL -d postgres -c "drop database if exists kwm5" >/dev/null
$PSQL -d postgres -c "create database kwm5"          >/dev/null

$PSQL -d kwm5 -f "$HERE/m5-fixture.sql" >/dev/null
echo "  fixture           ok"

$PSQL -d kwm5 -f "$ROOT/supabase_m5_meetings_actions.sql" >/dev/null 2>&1
echo "  migration         ok"
$PSQL -d kwm5 -f "$ROOT/supabase_m5_meetings_actions.sql" >/dev/null 2>&1
echo "  migration re-run  ok (idempotent)"

$PSQL -d kwm5 -f "$HERE/m5-tests.sql" 2>&1 \
  | grep -E "PASS|FAIL|passed" | sed "s/^psql:[^ ]* //; s/^NOTICE:  //"

$PSQL -d kwm5 -f "$ROOT/migrations/rollback-m5-meetings-actions.sql" >/dev/null 2>&1
echo "  rollback          ok"
$PSQL -d kwm5 -f "$ROOT/migrations/rollback-m5-meetings-actions.sql" >/dev/null 2>&1
echo "  rollback re-run   ok (idempotent)"

LEFT=$($PSQL -d kwm5 -t -A -c "
  select (select count(*) from pg_tables
           where schemaname='public'
             and tablename in ('meetings','actions','action_reminders'))
       + (select count(*) from information_schema.columns
           where table_schema='public' and table_name='organizations'
             and column_name='is_test')
       + (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public'
             and p.proname in ('is_staff','_action_label','action_reminders_run',
                               'tuesday_review_open','tuesday_review_pack',
                               'action_upsert','kw_touch_actions'))
       + (select count(*) from pg_policies
           where schemaname='public'
             and tablename in ('meetings','actions','action_reminders'))")

if [ "$LEFT" = "0" ]; then
  echo "  rollback clean    ok (zero leftover objects)"
else
  echo "  rollback clean    FAILED — $LEFT objects left behind"; exit 1
fi

# The rollback removes the notifications it wrote, and nothing else.
NOTES=$($PSQL -d kwm5 -t -A -c "
  select case when (select count(*) from notifications where type like 'action\_%') = 0
              then 'ok' else 'FAILED' end")

if [ "$NOTES" = "ok" ]; then
  echo "  notifications     ok (reminder rows removed with the ledger)"
else
  echo "  notifications     FAILED — stale reminder notifications survived"; exit 1
fi
