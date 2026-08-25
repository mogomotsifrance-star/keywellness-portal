#!/bin/bash
# Key Wellness — Phase 0 database tests against a local PostgreSQL 17.
#
# Runs: fixture -> migration -> migration again (idempotency) -> 47 assertions
#       -> Phase 0a -> its assertions -> Phase 1 -> its assertions
#       -> rollback -> rollback again -> clean-slate verification.
#
# VERSION: production is PostgreSQL 17.6 (docs/build/00-live-schema-snapshot.md).
# This harness targeted 16 until 25 Aug 2026, which meant every migration was
# validated on a different major version from the one it landed on. It now
# refuses to run on anything below 17 rather than passing quietly on the wrong
# engine — see PG_MIN below.
#
# Needs postgresql-17 binaries on PATH and a running local cluster. From a
# clean container:
#   initdb -D /tmp/pgdata -A trust -U "$USER"
#   pg_ctl -D /tmp/pgdata -o '-k /tmp/pgrun -p 5433' -l /tmp/pg.log start
#
# Usage:  tests/run-phase0.sh [host_dir] [port]
set -e
HOST="${1:-/tmp/pgrun}"
PORT="${2:-5433}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PSQL="psql -h $HOST -p $PORT -U $USER -v ON_ERROR_STOP=1 -q"

# ── Server version guard ─────────────────────────────────────
PG_MIN=17
PG_NUM=$($PSQL -d postgres -t -A -c "show server_version_num" 2>/dev/null || echo 0)
PG_MAJ=$(( PG_NUM / 10000 ))
if [ "$PG_MAJ" -lt "$PG_MIN" ]; then
  echo "  server version    FAILED — found PostgreSQL ${PG_MAJ:-unknown}, need >= $PG_MIN"
  echo "                    Production is 17.6. A pass on an older major proves nothing."
  exit 1
fi
echo "  server version    ok (PostgreSQL $PG_MAJ)"

$PSQL -d postgres -c "drop database if exists kwtest" >/dev/null
$PSQL -d postgres -c "create database kwtest"          >/dev/null

$PSQL -d kwtest -f "$HERE/phase0-fixture.sql"                >/dev/null
echo "  fixture           ok"
$PSQL -d kwtest -f "$ROOT/supabase_org_account_phase0.sql"   >/dev/null 2>&1
echo "  migration         ok"
$PSQL -d kwtest -f "$ROOT/supabase_org_account_phase0.sql"   >/dev/null 2>&1
echo "  migration re-run  ok (idempotent)"

$PSQL -d kwtest -f "$HERE/phase0-tests.sql" 2>&1 \
  | grep -E "PASS|FAIL|ERROR|passed" | sed "s/^psql:[^ ]* //; s/^NOTICE:  //"

$PSQL -d kwtest -f "$ROOT/supabase_org_account_phase0a_picker.sql" >/dev/null 2>&1
echo "  phase 0a          ok"
$PSQL -d kwtest -f "$ROOT/supabase_org_account_phase0a_picker.sql" >/dev/null 2>&1
echo "  phase 0a re-run   ok (idempotent)"

$PSQL -d kwtest -f "$HERE/phase0a-tests.sql" 2>&1 \
  | grep -E "PASS|FAIL|ERROR|passed" | sed "s/^psql:[^ ]* //; s/^NOTICE:  //"

$PSQL -d kwtest -f "$ROOT/supabase_org_account_phase1_indicators.sql" >/dev/null 2>&1
echo "  phase 1           ok"
$PSQL -d kwtest -f "$ROOT/supabase_org_account_phase1_indicators.sql" >/dev/null 2>&1
echo "  phase 1 re-run    ok (idempotent)"

$PSQL -d kwtest -f "$HERE/phase1-tests.sql" 2>&1 \
  | grep -E "PASS|FAIL|ERROR|passed" | sed "s/^psql:[^ ]* //; s/^NOTICE:  //"

$PSQL -d kwtest -f "$ROOT/migrations/rollback-org-account-phase1-indicators.sql" >/dev/null 2>&1
$PSQL -d kwtest -f "$ROOT/migrations/rollback-org-account-phase0a-picker.sql"     >/dev/null 2>&1
$PSQL -d kwtest -f "$ROOT/migrations/rollback-org-account-phase0.sql"             >/dev/null 2>&1
echo "  rollback          ok"
$PSQL -d kwtest -f "$ROOT/migrations/rollback-org-account-phase1-indicators.sql" >/dev/null 2>&1
$PSQL -d kwtest -f "$ROOT/migrations/rollback-org-account-phase0a-picker.sql"     >/dev/null 2>&1
$PSQL -d kwtest -f "$ROOT/migrations/rollback-org-account-phase0.sql"             >/dev/null 2>&1
echo "  rollback re-run   ok (idempotent)"

LEFT=$($PSQL -d kwtest -t -A -c "
  select (select count(*) from information_schema.columns
           where table_schema='public' and table_name='advisor_clients'
             and column_name in ('org_unit_id','no_org','org_mismatch'))
       + (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in
             ('kw_threshold','kw_dti_band','kw_is_over_indebted','kw_unit_label',
              'kw_validate_client_unit','kw_sync_advisor_client_org','admin_attribution_queue',
              'advisor_org_options','admin_org_indicators','_org_indicator_counts',
              '_org_indicator_catalogue','_jsonb_array_pos'))
       + (select count(*) from pg_constraint
           where conname in ('advisor_clients_org_required','advisor_clients_unit_needs_org'))
       + (select count(*) from pg_trigger
           where tgname in ('trg_validate_client_unit','trg_sync_advisor_client_org'))
       + (select count(*) from threshold_config
           where key like 'indicator.%' or key like 'panel3.%')")

if [ "$LEFT" = "0" ]; then
  echo "  rollback clean    ok (zero leftover objects)"
else
  echo "  rollback clean    FAILED — $LEFT objects left behind"; exit 1
fi
