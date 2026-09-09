#!/bin/bash
# Key Wellness — member-invites database tests against a local PostgreSQL.
#
# fixture -> migration -> migration again (idempotency) -> assertions
#         -> rollback -> rollback again -> clean-slate check
#
# Access assertions run under `set role authenticated` so RLS is enforced.
# Production is PostgreSQL 17; 16 is accepted here because nothing in this
# migration uses a 17-only feature, but a pass on 16 is a pass with an asterisk.
#
#   tests/run-member-invites.sh [host_or_socket_dir] [port]
set -e
HOST="${1:-/tmp/pgrun}"
PORT="${2:-5433}"
PGUSER="${PGUSER:-${USER:-$(whoami 2>/dev/null || echo postgres)}}"
export PGCLIENTENCODING="${PGCLIENTENCODING:-UTF8}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PSQL="psql -h $HOST -p $PORT -U $PGUSER -v ON_ERROR_STOP=1 -q"
DB=kwinvites

PG_NUM=$($PSQL -d postgres -t -A -c "show server_version_num" 2>/dev/null || echo 0)
echo "  server version    PostgreSQL $(( PG_NUM / 10000 ))"

$PSQL -d postgres -c "drop database if exists $DB" >/dev/null
$PSQL -d postgres -c "create database $DB"          >/dev/null

$PSQL -d $DB -f "$HERE/member-invites-fixture.sql"   >/dev/null && echo "  fixture           ok"
$PSQL -d $DB -f "$ROOT/supabase_member_invites.sql"  >/dev/null && echo "  migration         ok"
$PSQL -d $DB -f "$ROOT/supabase_member_invites.sql"  >/dev/null && echo "  migration (again) ok — idempotent"
$PSQL -d $DB -f "$HERE/member-invites-tests.sql" 2>&1 | grep -E "PASS|FAIL|all passed" | sed 's/^NOTICE:  /  /;s/^psql:.*FAIL/  FAIL/'
$PSQL -d $DB -f "$ROOT/migrations/rollback-member-invites.sql" >/dev/null && echo "  rollback          ok"
$PSQL -d $DB -f "$ROOT/migrations/rollback-member-invites.sql" >/dev/null && echo "  rollback (again)  ok — idempotent"

LEFT=$($PSQL -d $DB -t -A -c "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'invite_%'
  union all select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='member_invites'" | paste -sd+ | bc)
if [ "$LEFT" = "0" ]; then echo "  clean slate       ok — zero invite objects left"; else echo "  clean slate       FAILED ($LEFT objects left)"; exit 1; fi
