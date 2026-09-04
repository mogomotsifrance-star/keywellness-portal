#!/usr/bin/env bash
# can_manage_advisor() NULL hole: show it on the transcribed gate, apply the
# fix twice, show it closed, roll back twice, show it open again.
# Usage: tests/run-can-manage-fix.sh [host_or_socket_dir] [port]
set -e
HOST="${1:-/tmp/pgrun}"; PORT="${2:-5433}"; PGUSER="${PGUSER:-postgres}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
PSQL="psql -h $HOST -p $PORT -U $PGUSER -v ON_ERROR_STOP=1 -q"
DB=kw_cma_test
$PSQL -d postgres -c "drop database if exists $DB" >/dev/null
$PSQL -d postgres -c "create database $DB" >/dev/null
$PSQL -d $DB -f "$HERE/advance-fixture.sql"
$PSQL -d $DB -c "alter table organizations add column if not exists offers_advances boolean not null default false"
$PSQL -d $DB -f "$ROOT/supabase_advance_recommendation.sql" >/dev/null
$PSQL -d $DB -v fixed=false -f "$HERE/can-manage-fix-tests.sql" 2>&1 | grep -E "PASS|FAIL|ERROR"
$PSQL -d $DB -f "$ROOT/supabase_fix_can_manage_advisor_null.sql"
$PSQL -d $DB -f "$ROOT/supabase_fix_can_manage_advisor_null.sql"   # idempotent
$PSQL -d $DB -v fixed=true -f "$HERE/can-manage-fix-tests.sql" 2>&1 | grep -E "PASS|FAIL|ERROR"
$PSQL -d $DB -f "$ROOT/migrations/rollback-fix-can-manage-advisor-null.sql"
$PSQL -d $DB -f "$ROOT/migrations/rollback-fix-can-manage-advisor-null.sql"
$PSQL -d $DB -v fixed=false -f "$HERE/can-manage-fix-tests.sql" 2>&1 | grep -E "PASS|FAIL|ERROR"
echo "ROLLBACK RESTORES ORIGINAL"
