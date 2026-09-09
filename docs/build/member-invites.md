# Member invites — "Add members" on the Support screen (3 Sep 2026)

## Why

An MCM group filled in a paper attendance register (28 people, 15 with a
usable email) and asked for portal accounts. Until now the only way in was
self-registration plus an invite code, and the shortcut on the table was
"staff create the passwords and hand them out". This build makes that
shortcut unnecessary: staff add a list, each person receives Key Wellness's
invitation email, sets their own password, and lands already attached to the
right organisation, site and department.

## What was built

| Piece | File | Runs where |
|---|---|---|
| Migration | `supabase_member_invites.sql` | Supabase SQL editor — **applied to live 3 Sep** (via MCP, migration name `member_invites`) |
| Rollback | `migrations/rollback-member-invites.sql` | Supabase SQL editor |
| Live check | `tests/member-invites-verify-live.sql` | Supabase SQL editor, read-only — 12/12 pass on live |
| DB tests | `tests/member-invites-fixture.sql`, `tests/member-invites-tests.sql`, `tests/run-member-invites.sh` | local psql — 41 assertions, RLS enforced under `set role authenticated` |
| Edge Function | `supabase/functions/admin-support/index.ts` — new `send_invite` action | **deployed as v2, 3 Sep** |
| Function tests | `supabase/functions/admin-support/index.test.ts` — 7 new cases | `npm run test:edge` (20/20) |
| Screen | `ops.html` Support → **Add members** mode | test site after merge to `dev` |
| Landing | `index.html` — `type=invite` handled like `type=recovery` | live after merge to `main` |

### The flow

1. **Stage.** ops.html → `invite_stage(org, site, rows)` as the signed-in admin.
   Validates each line, refuses addresses that already have an account or a
   live invite, matches the department by name (case-insensitive; a miss
   stages the row with department blank and a warning, never blocks it),
   writes `member_invites` rows. Nothing is mailed.
2. **Send.** One `send_invite {invite_id}` call per person to admin-support.
   The function calls `support_can('send_invite')` then `invite_to_send(id)`
   — both as the caller — and only then `auth.admin.inviteUserByEmail()`.
   Outcome written by `invite_mark()`; every call audited in
   `support_actions` (action `send_invite`, address in `detail`).
3. **Accept.** The mail's link lands on index.html with `type=invite`. The
   member chooses a password (new `showSetPasswordForm()`; the SIGNED_IN
   handler holds the form up while `window._kwInviteLanding` is set).
   `handle_new_user()` finds the invite — by `invite_id` from the metadata,
   else by address — and fills `profiles.org_id / org_unit_id /
   department_id / first_name / last_name`, then marks the invite accepted.
   The person never sees the invite-code step.

### Rule 2 is intact

admin-support's header: *nothing addressable comes from the body*. The
invite is the action most tempted to break it. It does not: the body carries
an invite id; the address is read back from the database as the caller; a
body with `email` in it is still refused (tested).

### Budgets

Invites have their own limits in `support_can()` — 200 per admin per day,
30 per minute, 3 sends per invite (`invite_to_send` refuses the fourth) —
and are **excluded** from the 30/day reset budget and the 100/day team
budget, so a 40-person group cannot lock password resets for the rest of the
day (tested, 4c).

## Decisions

- **Staged-then-sent, not one batch call.** Each send is its own audited
  call; one bad address cannot take the others with it, and the ledger
  (`member_invites`) answers "who did we invite, did it arrive, did they take
  it" a month later.
- **Gate is `is_admin()`**, matching the live `support_*` functions. The repo's
  `supabase_support_audit.sql` still says `is_ops_admin()`; CLAUDE.md already
  marks that file stale.
- **No phone invites.** 13 of the 28 MCM people had no email. Creating a
  phone account for someone means choosing their password — the exact thing
  this build exists to avoid. The screen says so and gives the company code
  for phone self-registration instead.
- **Department miss does not block.** A misspelt department stages the row
  with department blank plus a warning. HR can fix a department later; a
  missing account cannot be fixed by anyone but us.
- **Yellow appears once on the screen** — a skipped line that needs a person
  to decide (fix or drop). Nothing else here is a decision.

## Verification

- Local: fixture → migration → migration again → 41 assertions → rollback →
  rollback again → zero invite objects left. PostgreSQL 16 locally (prod is
  17; nothing 17-only is used).
- Live: `tests/member-invites-verify-live.sql` 12/12 after apply.
- Edge Function: 20/20 Deno tests with the client stubbed (the sandbox
  could not reach deno.land, so the three remote imports were mapped to
  local shims for the run — the code under test is unchanged).
- Screen: headless render of ops.html Support → Add members with a stubbed
  backend — leaf sites only offered, five-line paste parsed (tabs and
  commas), 3 ready / 2 skipped, per-row send outcomes, zero JS errors.

## Not done / open

- **Not tested end-to-end with a real mail.** The first real send should be
  to a Key Wellness address: confirm the invite template arrives, the link
  lands on the set-password form, and the profile shows MCM + department.
- **Edge Function deployed from this session, not from the CLI.** The repo
  file is identical to what was deployed; `supabase functions deploy
  admin-support` from `dev` would produce v3 with no change.
- Pages 14–34 of the MCM register were not in the scan.
- `docs/build/00-live-schema-snapshot.md` does not yet list `member_invites`.
- Vault entry not written: `/workspace/vault` does not exist in this
  environment. The decision above should be copied there.
