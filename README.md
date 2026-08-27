# keywellness-portal

Static HTML site — no build step, no runtime dependencies. Open any page directly.

**Tests:** `npm install` once (pulls Playwright and a headless Chromium), then
`npm test` runs the browser smoke suites against a stubbed Supabase client.
Database tests are separate: `tests/run-phase0.sh` against a local PostgreSQL 16.

See `CLAUDE.md` for the portal as built and `CLAUDE_CONTEXT.md` for the operating
system being built on top of it.
