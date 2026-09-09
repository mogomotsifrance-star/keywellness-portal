#!/usr/bin/env bash
# Key Wellness — Advance Recommendation database tests on PostgreSQL 17.
#
# tests/run-advance-db.sh needs a 17 cluster to talk to, and the house has
# no guarantee that one is installed. Distro packages are the better answer
# where they exist; where they do not (a container with only 16, or one that
# cannot reach apt.postgresql.org) this fetches the official 17.6 server
# binaries from npm — registry.npmjs.org is reachable almost everywhere a
# build runs — starts a throwaway cluster, runs the suite, and stops it.
#
# Linux x64 only. psql comes from PATH; a 16 client against a 17 server is
# fine. Usage: [SUITE=run-rehab-db.sh] tests/run-advance-db-pg17.sh [port]   (default 5434)
set -e
PORT="${1:-5434}"
PGVER=17.6.0-beta.15
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
BASE="${TMPDIR:-/tmp}/kw-pg17"
SOCK="$BASE/run"

command -v psql >/dev/null || { echo "psql not on PATH"; exit 1; }

# Postgres refuses to run as root, so when we are root we hand the cluster to
# the postgres user — and keep it outside any root-only directory so it can
# actually be reached.
RUNAS=""
if [ "$(id -u)" = "0" ]; then
  id postgres >/dev/null 2>&1 || { echo "running as root and there is no postgres user to drop to"; exit 1; }
  RUNAS="postgres"
fi

rm -rf "$BASE"; mkdir -p "$BASE/pkg" "$BASE/data" "$SOCK"
echo "→ fetching PostgreSQL $PGVER server binaries from npm"
( cd "$BASE/pkg" && npm init -y >/dev/null 2>&1 && npm i --no-audit --no-fund --silent "@embedded-postgres/linux-x64@$PGVER" >/dev/null )
cp -r "$BASE/pkg/node_modules/@embedded-postgres/linux-x64/native" "$BASE/native"
BIN="$BASE/native/bin"
[ -x "$BIN/initdb" ] || { echo "no initdb in the npm package — layout changed?"; exit 1; }

[ -n "$RUNAS" ] && chown -R "$RUNAS":"$RUNAS" "$BASE" "$SOCK"
run() { if [ -n "$RUNAS" ]; then su "$RUNAS" -c "$1"; else bash -c "$1"; fi; }

run "$BIN/initdb -D $BASE/data -U postgres --auth=trust" >/dev/null
run "$BIN/pg_ctl -D $BASE/data -o '-p $PORT -k $SOCK -h \"\"' -l $BASE/pg.log start" >/dev/null
trap 'run "$BIN/pg_ctl -D $BASE/data stop" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 30); do pg_isready -h "$SOCK" -p "$PORT" >/dev/null 2>&1 && break; sleep 1; done
echo "→ $(psql -h "$SOCK" -p "$PORT" -U postgres -tAc 'select version()' | cut -c1-40)"

# SUITE picks the suite to run on the cluster: the Advance Recommendation's by
# default, or SUITE=run-rehab-db.sh for the Debt Rehab Plan's.
PGUSER=postgres "$HERE/${SUITE:-run-advance-db.sh}" "$SOCK" "$PORT"
