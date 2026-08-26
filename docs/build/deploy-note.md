# Deploy note — M1, M5, M5a and `ops.html`

**Written 26 Aug 2026. Nothing in this set has been applied to Supabase.**

Four pieces of work have accumulated on `dev` since the last deploy. They are
one deploy, not four: `ops.html` is inert without all three migrations, and the
migrations depend on each other in order.

| | What | Depends on |
|---|---|---|
| M1 | `service_line` + `session_format` columns | — |
| M5 | meetings, actions, reminders, `is_test`, `is_staff()` | — |
| M5a | `ops_timeline()` | M1 (`service_line`), M5 (`is_staff()`, `is_test`) |
| — | `ops.html`, `kw-session.js`, routing change | all three |

Every migration is idempotent and has a rollback that leaves zero objects.
Local test state at the time of writing, on PostgreSQL 17.6:

```
phase0 / 0a / 1   all passed        M1    22 passed, 0 failed
M5    45 passed, 0 failed           M5a   29 passed, 0 failed
browser: 95 account · 37 picker · 19 routing · 38 ops
```

---

## Before you start

**Two accounts are still missing.** `actions.owner` references `auth.users`
because `notifications.user_id` does — you cannot remind a person who does not
exist.

- **Laone** has no account. Without one she cannot own M4's invoice actions or
  receive a reminder about one. M5 works without her; M4 does not.
- **Lone** — confirm her account is the one in `admins`
  (`lone@keywellness.co.bw` is present and resolves).
- Michelle was granted admin on 26 Aug. Nothing further needed.
- `kramontshonyana@debswana.bw` is an active advisor with **no account** and
  therefore cannot own an action. Decide whether to create one or deactivate
  the advisor row.

---

## The order

### 1 · M1 — service-line columns

```
tests/m1-verify-live.sql      run it, SAVE THE OUTPUT
supabase_m1_service_line.sql  apply
tests/m1-verify-live.sql      run again, diff against the saved output
```

Expect the apply to end with `M1 applied: 18 row(s) had session_mode
normalised.`

**Expected diff:** `sessions.mode_split` gains keys, and **every gained key is
withheld** (`{"value": null, "suppressed": true}`). `total_booked`,
`total_attended`, `monthly_trend` and `attendance_confirmation_coverage_pct`
must be **identical**. Anything else moving is a fault — roll back and stop.

`V6` will report `CHECK` on *"Individual rows carry no mode"*. That is correct:
two Test Co rows carried `session_mode = 'physical'` before M1 and keep it.

Rollback: `migrations/rollback-m1-service-line.sql`. It restores `session_mode`
from `_m1_session_mode_backup` — do not drop that table by hand before rolling
back, or the restore has nothing to read.

### 2 · M5 — meetings, actions, reminders

```
tests/m5-verify-live.sql            run it, SAVE THE OUTPUT
supabase_m5_meetings_actions.sql    apply
```

Then, by hand — the migration deliberately names no organisation:

```sql
update organizations set is_test = true where name = 'Test Co';
```

Without it the first screen Lone opens has a test organisation in the
roll-call, and `ops_timeline` cannot exclude what is not flagged.

**Then enable `pg_cron`** — Database → Extensions — **and re-run
`supabase_m5_meetings_actions.sql`.** The schedule block is a guarded no-op
until the extension exists, so without this second run **no reminder ever
fires**. Confirm:

```sql
select jobname, schedule from cron.job where jobname = 'kw-action-reminders';
```

Expect `0 4 * * *` — 04:00 UTC, which is 06:00 in Gaborone, before the working
day rather than during it.

Run `tests/m5-verify-live.sql` again: eight policies across `meetings` and
`actions`, **zero** on `action_reminders`, both helpers not public, all three
RPCs callable, Test Co flagged.

### 3 · M5a — `ops_timeline()`

```
tests/m5a-verify-live.sql        run it, SAVE THE OUTPUT
supabase_m5a_ops_timeline.sql    apply
tests/m5a-verify-live.sql        run again
```

Expect: both functions present; `_ops_as_date` **not** reachable by `anon` or
`authenticated`; `ops_timeline` reachable; V5 lists BOPEU and Sedimosa and
**not Test Co**; V6 reports **zero** psychosocial rows.

V4–V6 set `request.jwt.claims` with `set_config(..., true)` — transaction-local,
discarded at commit, writes nothing. Without it the SQL editor has no JWT,
`is_staff()` is false, and every call raises `not authorised`.

### 4 · The front end

```bash
git checkout dev && git pull && git push origin dev
```

Cloudflare Pages serves the test site from `dev`. **Do not merge to `main`
until the test site has been walked.**

---

## Walking the test site

1. Sign in as **Lone**. If she holds only admin, she lands on `ops.html`. If
   she also holds another hat, she gets the chooser — pick *Ops Workspace*.
2. The roll-call lists **BOPEU and Sedimosa**, numbered, and **not Test Co**.
3. Start a real Tuesday review. The button says *Start Tuesday's review*;
   pressing it twice is safe and the second press resumes rather than forking.
4. Type an action, press Enter. Reload. It is still there.
5. Press **Ctrl-K**, type a client name, press Enter — the roll-call jumps.
6. Open **Today**. The reminders count in the top bar goes to zero.
7. Sign in as **France** and confirm he can open ops and read last week's
   actions.

---

## If something is wrong

Roll back in reverse order — M5a, then M5, then M1:

```
migrations/rollback-m5a-ops-timeline.sql
migrations/rollback-m5-meetings-actions.sql
migrations/rollback-m1-service-line.sql
```

Each verifies itself and raises if anything survives. Two things to know:

- The **M5 rollback deletes the reminder notifications it wrote** (only those —
  it identifies them through the ledger) and drops `organizations.is_test`, so
  re-applying M5 later means re-running the Test Co update.
- The **M1 rollback restores `session_mode` from its backup table.** Rolling
  back M1 after weeks of new bookings restores only the 18 rows M1 touched;
  anything written since is untouched, which is correct.

`ops.html` degrades rather than breaking if the migrations are absent: it
loads, gates correctly, and its RPC calls fail.

---

## What this deploy does not do

- **No psychosocial data is visible or writable.** M3 has not been built.
- **`ops_timeline` bypasses RLS and is not yet gated by service line.** Harmless
  today — every booking is financial — and it is M3's first obligation. See
  `docs/build/m5a-ops-timeline.md` §4.
- **`admin.html` is unchanged** and still reachable from the "Other interfaces"
  link inside ops. Its own switcher still points at itself; Prompt 11 retires it.
- **No work plans, contracts, retainer position, capacity or invoices** — M4
  and M7. Those sections render their label and say what is missing.
- **The daily view has no designed mobile layout yet.** It stacks below 900px,
  which is a reflow rather than a design; charter §9 asks for better and it is
  recorded as owed.
