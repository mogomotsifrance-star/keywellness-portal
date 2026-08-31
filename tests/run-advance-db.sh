#!/usr/bin/env bash
# Key Wellness — Advance Recommendation database tests against a local PostgreSQL.
# fixture -> migration -> migration again (idempotent) -> assertions (RLS enforced)
#        -> rollback -> rollback again -> clean-slate check
# Usage: tests/run-advance-db.sh [host_or_socket_dir] [port]   (PGUSER defaults to postgres)
set -e
HOST="${1:-/tmp/pgrun}"; PORT="${2:-5433}"; PGUSER="${PGUSER:-postgres}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
PSQL="psql -h $HOST -p $PORT -U $PGUSER -v ON_ERROR_STOP=1 -q"
DB=kw_advance_test
$PSQL -d postgres -c "drop database if exists $DB" >/dev/null
$PSQL -d postgres -c "create database $DB" >/dev/null
$PSQL -d $DB -f "$HERE/advance-fixture.sql"
$PSQL -d $DB -f "$ROOT/supabase_advance_recommendation.sql"
$PSQL -d $DB -f "$ROOT/supabase_advance_recommendation.sql"      # idempotent
$PSQL -d $DB -f "$HERE/advance-db-tests.sql" 2>&1 | grep -E "PASS|FAIL|ERROR" || true
$PSQL -d $DB -f "$ROOT/migrations/rollback-advance-recommendation.sql"
$PSQL -d $DB -f "$ROOT/migrations/rollback-advance-recommendation.sql"  # idempotent
LEFT=$($PSQL -d $DB -tA -c "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'advance_recommendation_%'")
TBL=$($PSQL -d $DB -tA -c "select count(*) from pg_tables where tablename='advance_recommendations'")
NOTES=$($PSQL -d $DB -tA -c "select count(*) from advisor_notes where origin='system'")
echo "after rollback: functions=$LEFT tables=$TBL timeline_notes_kept=$NOTES"
[ "$LEFT" = "0" ] && [ "$TBL" = "0" ] && echo "ROLLBACK CLEAN" || { echo "ROLLBACK LEFT OBJECTS"; exit 1; }
