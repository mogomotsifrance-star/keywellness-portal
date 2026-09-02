#!/usr/bin/env bash
# Advance Recommendation — unit checks on compute.ts, then the headless
# browser run against the real advisor.html.
set -e
cd "$(dirname "$0")/.."
# A machine with a pre-installed Chromium (PLAYWRIGHT_BROWSERS_PATH) can point
# the test at it instead of downloading one: PW_CHROMIUM=/path/to/chrome
if [ -z "$PW_CHROMIUM" ] && [ -x /opt/pw-browsers/chromium ]; then export PW_CHROMIUM=/opt/pw-browsers/chromium; fi
node tests/advance-recommendation.test.mjs
npx -y esbuild tests/ar-entry.ts --bundle --format=iife --global-name=__AR --log-level=warning --outfile=tests/.ar-browser.js
node tests/smoke-advance.js
