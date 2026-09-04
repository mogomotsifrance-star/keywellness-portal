#!/usr/bin/env bash
# Key Wellness — Debt Rehab Plan database tests against a local PostgreSQL.
# AR fixture -> rehab fixture extra -> migration -> migration again (idempotent)
#   -> assertions (RLS enforced) -> rollback -> rollback again -> clean-slate check
# Usage: tests/run-rehab-db.sh [host_or_socket_dir] [port]   (PGUSER defaults to postgres)
set -e
HOST="${1:-/tmp/pgrun}"; PORT="${2:-5433}"; PGUSER="${PGUSER:-postgres}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
PSQL="psql -h $HOST -p $PORT -U $PGUSER -v ON_ERROR_STOP=1 -q"
DB=kw_rehab_test
$PSQL -d postgres -c "drop database if exists $DB" >/dev/null
$PSQL -d postgres -c "create database $DB" >/dev/null
$PSQL -d $DB -f "$HERE/advance-fixture.sql"
$PSQL -d $DB -f "$HERE/rehab-fixture-extra.sql"
$PSQL -d $DB -f "$ROOT/supabase_debt_rehab_plan.sql"
$PSQL -d $DB -f "$ROOT/supabase_debt_rehab_plan.sql"      # idempotent
$PSQL -d $DB -f "$HERE/rehab-db-tests.sql" 2>&1 | grep -E "PASS|FAIL|ERROR" || true
$PSQL -d $DB -f "$ROOT/migrations/rollback-debt-rehab-plan.sql"
$PSQL -d $DB -f "$ROOT/migrations/rollback-debt-rehab-plan.sql"  # idempotent
LEFT=$($PSQL -d $DB -tA -c "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'debt_rehab_plan_%'")
TBL=$($PSQL -d $DB -tA -c "select count(*) from pg_tables where tablename='debt_rehab_plans'")
POL=$($PSQL -d $DB -tA -c "select count(*) from pg_policies where tablename='debt_rehab_plans'")
NOTES=$($PSQL -d $DB -tA -c "select count(*) from advisor_notes where origin='system'")
echo "after rollback: functions=$LEFT tables=$TBL policies=$POL timeline_notes_kept=$NOTES"
[ "$LEFT" = "0" ] && [ "$TBL" = "0" ] && [ "$POL" = "0" ] && echo "ROLLBACK CLEAN" || { echo "ROLLBACK LEFT OBJECTS"; exit 1; }
