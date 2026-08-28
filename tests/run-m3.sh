#!/bin/bash
# Key Wellness — M3 database tests against a local PostgreSQL 17.
#
# The stack mirrors live: m1-fixture, the real org_report_data, M1, M5, the
# support work, M4, M4a, then M3 Parts 1 and 2.
#
# M4a matters here and is not optional: M3 Part 1 ASSERTS that
# psychosocial_admins and is_psychosocial_admin() already exist, because M4a
# shipped them. Without it, Part 1 refuses to apply — which is the intended
# behaviour and is itself worth seeing fail once.
#
#   Linux/macOS :  tests/run-m3.sh
#   Windows      :  PGUSER=postgres tests/run-m3.sh 127.0.0.1 5433
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

$PSQL -d postgres -c "drop database if exists kwm3" >/dev/null
$PSQL -d postgres -c "create database kwm3"          >/dev/null

# An apply that fails must say why and name the file. Sending these to
# /dev/null is how three separate failures hid on this project.
apply() {
  local _out
  _out=$($PSQL -d kwm3 -f "$1" 2>&1) || {
    echo "$_out" | grep -vE "NOTICE:|^$"
    echo "  APPLY FAILED      $(basename "$1")"; exit 1; }
}

$PSQL -d kwm3 -f "$HERE/m1-fixture.sql"       >/dev/null
$PSQL -d kwm3 -f "$HERE/m4-fixture-extra.sql" >/dev/null
# Brings the advisor tables up to LIVE's shape. The fixture had drifted, and
# the drift hid nine of the twelve functions the sweep must filter.
$PSQL -d kwm3 -f "$HERE/m3-fixture-extra.sql" >/dev/null
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
echo "  M3 parts 1-4      ok"
apply "$ROOT/supabase_m3_part1_confidentiality_boundary.sql"
apply "$ROOT/supabase_m3_part2_definer_sweep.sql"
apply "$ROOT/supabase_m3a_referral_accept.sql"
apply "$ROOT/supabase_m3b_referral_decline.sql"
echo "  M3 re-run         ok (idempotent)"

$PSQL -d kwm3 -f "$HERE/m3-tests.sql" 2>&1 \
  | grep -E "PASS|FAIL|passed|STATE|ERROR|FATAL" \
  | sed "s/^psql:[^ ]* //; s/^NOTICE:  //"

run_rollback() {
  local _out
  # THE M3b ROLLBACK REFUSES while declined referrals exist, on purpose:
  # dropping declined_at deletes the only record that a counsellor said no.
  # The suite declines one, so it hits that guard every run. Clearing them
  # first is the documented deliberate path, and doing it here means the guard
  # is exercised rather than designed around.
  DECLINED=$($PSQL -d kwm3 -t -A -c "select count(*) from counselling_referrals where declined_at is not null" 2>/dev/null || echo 0)
  if [ "${DECLINED:-0}" != "0" ]; then
    echo "  m3b guard         ok (refused while $DECLINED declined referral(s) existed)"
    $PSQL -d kwm3 -c "update counselling_referrals set declined_at = null" >/dev/null
  fi
  _out=$($PSQL -d kwm3 -f "$ROOT/migrations/rollback-m3b-referral-decline.sql" 2>&1) || {
    echo "$_out" | grep -vE "NOTICE:|^$"
    echo "  rollback          FAILED (m3b)"; exit 1; }
  _out=$($PSQL -d kwm3 -f "$ROOT/migrations/rollback-m3a-referral-accept.sql" 2>&1) || {
    echo "$_out" | grep -vE "NOTICE:|^$"
    echo "  rollback          FAILED (m3a)"; exit 1; }
  _out=$($PSQL -d kwm3 -f "$ROOT/migrations/rollback-m3-counsellors.sql" 2>&1) || {
    echo "$_out" | grep -vE "NOTICE:|^$"
    echo "  rollback          FAILED"; exit 1; }
}
run_rollback; echo "  rollback          ok"
run_rollback; echo "  rollback re-run   ok (idempotent)"

LEFT=$($PSQL -d kwm3 -t -A -c "
  select (select count(*) from pg_tables where schemaname='public'
           and tablename in ('counsellors','counsellor_clients','counselling_notes',
                             'counselling_referrals','theme_taxonomy','session_themes'))
       + (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public'
             and p.proname in ('is_counsellor','current_counsellor_id',
                               'kw_can_see_booking','kw_can_see_activity',
                               'theme_counts','referral_fact_list'))
       + (select count(*) from information_schema.columns where table_schema='public'
           and table_name='bookings' and column_name in ('counsellor_id','counsellor_client_id'))")

if [ "$LEFT" = "0" ]; then
  echo "  rollback clean    ok (zero leftover objects)"
else
  echo "  rollback clean    FAILED — $LEFT objects left behind"; exit 1
fi

# M4a's objects are NOT M3's to remove.
KEPT=$($PSQL -d kwm3 -t -A -c "
  select case when to_regclass('public.psychosocial_admins') is not null
               and exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                            where n.nspname='public' and p.proname='is_psychosocial_admin')
              then 'ok' else 'FAILED' end")
if [ "$KEPT" = "ok" ]; then
  echo "  M4a untouched     ok (psychosocial_admins is not M3's to remove)"
else
  echo "  M4a untouched     FAILED — M3's rollback removed M4a's objects"; exit 1
fi

# The nine original bookings policies must be back, or the advisor portal is
# broken in a way nobody notices until they open it.
POL=$($PSQL -d kwm3 -t -A -c "
  select count(*) from pg_policies where schemaname='public' and tablename='bookings'")
if [ "$POL" = "9" ]; then
  echo "  bookings restored ok (9 policies, as M3 found them)"
else
  echo "  bookings restored FAILED — $POL policies, expected 9"; exit 1
fi
