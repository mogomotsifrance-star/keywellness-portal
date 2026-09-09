#!/usr/bin/env bash
# Debt Rehab Plan — unit checks on compute-rehab.ts, then the headless
# browser run against the real advisor.html.
set -e
cd "$(dirname "$0")/.."
if [ -z "$PW_CHROMIUM" ] && [ -x /opt/pw-browsers/chromium ]; then export PW_CHROMIUM=/opt/pw-browsers/chromium; fi
node tests/debt-rehab-plan.test.mjs
npx -y esbuild tests/drp-entry.ts --bundle --format=iife --global-name=__DRP --log-level=warning --outfile=tests/.drp-browser.js
node tests/smoke-rehab.js
