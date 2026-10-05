#!/usr/bin/env bash
# Key Wellness — consent form before finalise: database tests against a local PostgreSQL.
# fixture -> advance migration -> consent migration (x2, idempotent) -> assertions (RLS enforced)
#        -> rollback (x2) -> checks that finalising is ungated again and evidence was kept
# Usage: tests/run-advance-consent-db.sh [host_or_socket_dir] [port]   (PGUSER defaults to postgres)
set -e
HOST="${1:-/tmp/pgrun}"; PORT="${2:-5433}"; PGUSER="${PGUSER:-postgres}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
PSQL="psql -h $HOST -p $PORT -U $PGUSER -v ON_ERROR_STOP=1 -q"
DB=kw_advance_consent_test
$PSQL -d postgres -c "drop database if exists $DB" >/dev/null
$PSQL -d postgres -c "create database $DB" >/dev/null
$PSQL -d $DB -f "$HERE/advance-fixture.sql"
$PSQL -d $DB -c "alter table organizations add column if not exists offers_advances boolean not null default false"
$PSQL -d $DB -f "$ROOT/supabase_advance_recommendation.sql"
# kw_fn_backup exists live (RLS on, no policies); the fixture has to supply it.
$PSQL -d $DB -c "create table kw_fn_backup (id bigserial primary key, taken_at timestamptz not null default now(), tag text not null, proname text not null, identity_args text not null, definition text not null)"
$PSQL -d $DB -f "$ROOT/supabase_advance_consent.sql"
$PSQL -d $DB -f "$ROOT/supabase_advance_consent.sql"      # idempotent
BK=$($PSQL -d $DB -tA -c "select count(*) from kw_fn_backup where tag='advance-consent-gate'")
echo "backups after two runs: $BK (expect 1)"; [ "$BK" = "1" ]
OUT=$($PSQL -d $DB -f "$HERE/advance-consent-db-tests.sql" 2>&1) || { echo "$OUT" | grep -E "PASS|FAIL|ERROR"; echo "TESTS FAILED"; exit 1; }
echo "$OUT" | grep -E "PASS|FAIL|ERROR"
$PSQL -d $DB -f "$ROOT/migrations/rollback-advance-consent.sql" 2>&1 | grep -E "NOTICE|ERROR" || true
$PSQL -d $DB -f "$ROOT/migrations/rollback-advance-consent.sql" >/dev/null 2>&1   # idempotent
GATED=$($PSQL -d $DB -tA -c "select prosrc like '%advance_consents%' from pg_proc where proname='advance_recommendation_finalise'")
TRG=$($PSQL -d $DB -tA -c "select count(*) from pg_trigger where tgname='advance_recommendations_final_needs_consent'")
RPC=$($PSQL -d $DB -tA -c "select count(*) from pg_proc where proname='advance_consent_record'")
KEPT=$($PSQL -d $DB -tA -c "select count(*) from advance_consents")
echo "after rollback: finalise_gated=$GATED trigger=$TRG record_rpc=$RPC consent_rows_kept=$KEPT"
[ "$GATED" = "f" ] && [ "$TRG" = "0" ] && [ "$RPC" = "0" ] && [ "$KEPT" -gt 0 ] && echo "ROLLBACK CLEAN (evidence kept)" || { echo "ROLLBACK WRONG"; exit 1; }
# Rolled back, a draft finalises again with no form: proves Part 1 really ungated it.
$PSQL -d $DB -c "insert into advance_recommendations (client_id, version, status, input, computed, content) values ('c0000000-0000-4000-8000-000000000003', 1, 'draft', '{}', '{}', '{}')"
$PSQL -d $DB -c "update advance_recommendations set status='final' where client_id='c0000000-0000-4000-8000-000000000003'"
echo "after rollback: a draft finalises with no form again: OK"
