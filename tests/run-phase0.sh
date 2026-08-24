#!/bin/bash
# Key Wellness — Phase 0 database tests against a local PostgreSQL 16.
#
# Runs: fixture -> migration -> migration again (idempotency) -> 47 assertions
#       -> Phase 0a -> its assertions
#       -> rollback -> rollback again -> clean-slate verification.
#
# Needs postgresql-16 binaries on PATH and a running local cluster. From a
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

$PSQL -d kwtest -f "$ROOT/migrations/rollback-org-account-phase0.sql" >/dev/null 2>&1
echo "  rollback          ok"
$PSQL -d kwtest -f "$ROOT/migrations/rollback-org-account-phase0.sql" >/dev/null 2>&1
echo "  rollback re-run   ok (idempotent)"

LEFT=$($PSQL -d kwtest -t -A -c "
  select (select count(*) from information_schema.columns
           where table_schema='public' and table_name='advisor_clients'
             and column_name in ('org_unit_id','no_org','org_mismatch'))
       + (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in
             ('kw_threshold','kw_dti_band','kw_is_over_indebted','kw_unit_label',
              'kw_validate_client_unit','kw_sync_advisor_client_org','admin_attribution_queue'))
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
