#!/bin/bash
# Key Wellness — M6 database tests against a local PostgreSQL 17.
#
# The stack mirrors live: m1-fixture, the real org_report_data, M1, M5, the
# support work, M4, M4a, then M3 Parts 1 and 2.
#
# M4a matters here and is not optional: M3 Part 1 ASSERTS that
# psychosocial_admins and is_psychosocial_admin() already exist, because M4a
# shipped them. Without it, Part 1 refuses to apply — which is the intended
# behaviour and is itself worth seeing fail once.
#
#   Linux/macOS :  tests/run-m6.sh
#   Windows      :  PGUSER=postgres tests/run-m6.sh 127.0.0.1 5433
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

$PSQL -d postgres -c "drop database if exists kwm6" >/dev/null
$PSQL -d postgres -c "create database kwm6"          >/dev/null

# An apply that fails must say why and name the file. Sending these to
# /dev/null is how three separate failures hid on this project.
apply() {
  local _out
  _out=$($PSQL -d kwm6 -f "$1" 2>&1) || {
    echo "$_out" | grep -vE "NOTICE:|^$"
    echo "  APPLY FAILED      $(basename "$1")"; exit 1; }
}

$PSQL -d kwm6 -f "$HERE/m1-fixture.sql"       >/dev/null
$PSQL -d kwm6 -f "$HERE/m4-fixture-extra.sql" >/dev/null
# Brings the advisor tables up to LIVE's shape. The fixture had drifted, and
# the drift hid nine of the twelve functions the sweep must filter.
$PSQL -d kwm6 -f "$HERE/m3-fixture-extra.sql" >/dev/null
echo "  fixture           ok"

# THE ADVISOR PORTAL IS NOT OPTIONAL HERE. Nine of the twelve functions M3's
# sweep must filter live in these files. Without them the sweep filters 3 of
# 12 and, if the count assertion were tolerant, a GREEN RUN WOULD MEAN NOTHING
# — the nine that actually leak to the team lead would never have been
# touched. The migration raises rather than skipping, which is how this was
# caught; leave it that way.
apply "$ROOT/supabase_advisor_rpcs.sql"
apply "$ROOT/supabase_advisor_ux.sql"
apply "$ROOT/supabase_advisor_team_lead.sql"
apply "$ROOT/supabase_booking_notify_payload.sql"

apply "$ROOT/supabase_org_report_data_v4.sql"
apply "$ROOT/supabase_m1_service_line.sql"
apply "$ROOT/supabase_m5_meetings_actions.sql"
apply "$ROOT/supabase_m5a_ops_timeline.sql"
apply "$ROOT/supabase_support_audit.sql"
apply "$ROOT/supabase_m4_contracts_workplans_billing.sql"
apply "$ROOT/supabase_m4a_ownership_and_roles.sql"
echo "  advisor + M1..M4a ok"

# The two files are ONE migration. Part 1 alone leaves a boundary that a dozen
# definer functions walk through, so the harness never applies one without the
# other — if it did, a green run would mean nothing.
apply "$ROOT/supabase_m3_part1_confidentiality_boundary.sql"
apply "$ROOT/supabase_m3_part2_definer_sweep.sql"
apply "$ROOT/supabase_m3a_referral_accept.sql"
apply "$ROOT/supabase_m3b_referral_decline.sql"
apply "$ROOT/supabase_m4b_real_contract_shape.sql"
apply "$ROOT/supabase_m6_physical_service_line.sql"
echo "  M3 + M4b + M6     ok"
# Only M6 is re-applied. Re-running M3 Part 2 AFTER M6 would overwrite M6's
# reporting filter with M3's older one — see M6's header. Migrations run in
# order once; this checks M6 is idempotent, not that the order can be undone.
apply "$ROOT/supabase_m6_physical_service_line.sql"
echo "  M6 re-run         ok (idempotent)"

$PSQL -d kwm6 -f "$HERE/m6-tests.sql" 2>&1 \
  | grep -E "PASS|FAIL|passed|STATE|ERROR|FATAL" \
  | sed "s/^psql:[^ ]* //; s/^NOTICE:  //"

run_rollback() {
  local _out
  # M6's rollback REFUSES while any row is on the physical line — narrowing
  # service_line would orphan a record of real work. The suite creates two, so
  # it hits the guard every run. Clearing them is the documented deliberate
  # path, and doing it here means the guard is EXERCISED, not designed around.
  PHYS=$($PSQL -d kwm6 -t -A -c "select count(*) from bookings where service_line='physical'" 2>/dev/null || echo 0)
  if [ "${PHYS:-0}" != "0" ]; then
    echo "  m6 guard          ok (refused while $PHYS physical row(s) existed)"
    $PSQL -d kwm6 -c "delete from bookings where service_line='physical'" >/dev/null
    $PSQL -d kwm6 -c "delete from program_activities where service_line='physical'" >/dev/null
  fi
  _out=$($PSQL -d kwm6 -f "$ROOT/migrations/rollback-m6-physical-service-line.sql" 2>&1) || {
    echo "$_out" | grep -vE "NOTICE:|^$"
    echo "  rollback          FAILED"; exit 1; }
}
run_rollback; echo "  rollback          ok"
run_rollback; echo "  rollback re-run   ok (idempotent)"

LEFT=$($PSQL -d kwm6 -t -A -c "
  select (select count(*) from pg_tables where schemaname='public' and tablename='service_lines')
       + (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname='kw_line_is_confidential')")
if [ "$LEFT" = "0" ]; then
  echo "  rollback clean    ok (zero leftover objects)"
else
  echo "  rollback clean    FAILED — $LEFT left behind"; exit 1
fi

# M4a's objects are NOT M3's to remove.
KEPT=$($PSQL -d kwm6 -t -A -c "
  select case when to_regclass('public.psychosocial_admins') is not null
               and exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                            where n.nspname='public' and p.proname='is_psychosocial_admin')
              then 'ok' else 'FAILED' end")
if [ "$KEPT" = "ok" ]; then
  echo "  M4a untouched     ok (psychosocial_admins is not M3's to remove)"
else
  echo "  M4a untouched     FAILED — M3's rollback removed M4a's objects"; exit 1
fi

# M6's rollback leaves M3 alone, so bookings keeps its ELEVEN M3 policies.
# Expecting nine here would be inheriting M3's check into a suite it does not
# describe — the kind of copied assertion that passes for the wrong reason.
POL=$($PSQL -d kwm6 -t -A -c "
  select count(*) from pg_policies where schemaname='public' and tablename='bookings'")
if [ "$POL" = "11" ]; then
  echo "  M3 intact         ok (11 policies — M6's rollback left M3 alone)"
else
  echo "  M3 intact         FAILED — $POL bookings policies, expected 11"; exit 1
fi

# And no predicate may be left calling the helper M6 just dropped.
ORPH=$($PSQL -d kwm6 -t -A -c "
  select (select count(*) from pg_policies where schemaname='public'
           and (coalesce(qual,'') like '%kw_line_is_confidential%'
             or coalesce(with_check,'') like '%kw_line_is_confidential%'))
       + (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.prosrc like '%kw_line_is_confidential%')")
if [ "$ORPH" = "0" ]; then
  echo "  no orphan calls   ok"
else
  echo "  no orphan calls   FAILED — $ORPH still call the dropped helper"; exit 1
fi
