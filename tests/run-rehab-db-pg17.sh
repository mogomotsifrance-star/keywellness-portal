#!/usr/bin/env bash
# Key Wellness — Debt Rehab Plan database tests on PostgreSQL 17.
# Uses the shared throwaway-cluster bootstrap; see tests/pg17-cluster.sh.
# Usage: tests/run-rehab-db-pg17.sh [port]   (default 5435)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/pg17-cluster.sh" "$HERE/run-rehab-db.sh" "${1:-5435}"
