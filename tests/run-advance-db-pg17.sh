#!/usr/bin/env bash
# Key Wellness — Advance Recommendation database tests on PostgreSQL 17.
#
# The cluster bootstrap moved to tests/pg17-cluster.sh on 3 Sep 2026, so the
# Debt Rehab Plan suite could use the same one instead of a second copy. This
# script does exactly what it did before; only the plumbing is shared.
#
# Usage: tests/run-advance-db-pg17.sh [port]   (default 5434)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/pg17-cluster.sh" "$HERE/run-advance-db.sh" "${1:-5434}"
