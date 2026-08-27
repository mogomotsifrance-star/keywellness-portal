# Deploy note — M1, M5, M5a, member support, `ops.html` and M4

**Written 26 Aug 2026, revised the same day. Nothing in this set has been
applied to Supabase.**

Six pieces of work have accumulated on `dev` since the last deploy. They are
one deploy, not six: `ops.html` is inert without the first three migrations,
and the migrations depend on each other in order.

| | What | Depends on |
|---|---|---|
| M1 | `service_line` + `session_format` columns | — |
| M5 | meetings, actions, reminders, `is_test`, `is_staff()` | — |
| M5a | `ops_timeline()` | M1 (`service_line`), M5 (`is_staff()`, `is_test`) |
| — | `ops.html`, `kw-session.js`, routing change | all three |
| support | member reset links and resends, `is_ops_admin()` | M5 (`is_staff()`) |
| M4 | contracts, rate card, work plans, invoice packs | M1, M5, `is_ops_admin()` |

M4 has **no user interface** and can be applied last or held back entirely —
nothing on any page calls it yet. It is in this deploy so the schema is in place
before the first month it needs to bill.

Every migration is idempotent and has a rollback that leaves zero objects.
Local test state at the time of writing, on PostgreSQL 17.6:

```
phase0 / 0a / 1   all passed        M1       22 passed, 0 failed
M5      45 passed, 0 failed         M5a      29 passed, 0 failed
support 28 passed, 0 failed         M4       50 passed, 0 failed
browser: 95 account · 37 picker · 19 routing · 38 ops
M4 regression: org_report_data 9 of 9 payloads byte-identical
```

---

## Before you start

**One account matters.** `actions.owner` references `auth.users` because
`notifications.user_id` does — you cannot remind a person who does not exist.

- **Lone** — confirm her account is the one in `admins`
  (`lone@keywellness.co.bw` is present and resolves). M4's invoice pack is
  owned by the first ops admin by email, which is her; V4 of
  `tests/m4-verify-live.sql` resolves it and prints the address before you
  apply anything.
- **Laone does not need an account.** An earlier draft of this note said she
  did, because an earlier draft of M4 gave her the invoice actions. She does not
  use the platform at all — no account, owns nothing, uploads nothing — and M4
  as built has no accountant user anywhere in it. See
  `docs/build/m4-contracts-workplans-invoices.md` section 2.
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

`pg_cron` **is already installed** — confirmed against the live database on
27 Aug 2026. An earlier version of this note, and M5's own header, said it was
not and told you to enable it and re-run the migration. **Both were wrong; that
step is gone.** The schedule is created on the first apply. Confirm it:

```sql
select jobname, schedule from cron.job where jobname = 'kw-action-reminders';
```

Expect `0 4 * * *` — 04:00 UTC, which is 06:00 in Gaborone, before the working
day rather than during it. If it returns nothing, the schedule block did not
run; re-running the migration is then safe and is the fix.

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

### 4 · The member support work

```
tests/support-verify-live.sql       run it, SAVE THE OUTPUT
supabase_support_audit.sql          apply
supabase functions deploy admin-support
tests/support-verify-live.sql       run again
```

`is_ops_admin()` ships here and is defined as *"`is_admin()` until M3 replaces
it"*. France's admin account therefore holds this capability today and **loses
it when M3 lands** — that is intended, and recorded in
`docs/build/admin-support.md`.

### 5 · M4 — contracts, work plans, invoices

Optional in this deploy: nothing calls it. Apply it if you want the schema in
place before the first month it bills.

```
tests/m4-verify-live.sql                       run it, SAVE THE OUTPUT
supabase_m4_contracts_workplans_billing.sql    apply
tests/m4-verify-live.sql                       run again, diff
```

**M4 is the first migration that replaces something already live.**
`tuesday_review_pack()` is running in production, and M4 rewrites it to add the
billing flag. **V0 of the verify file is therefore the block that matters** —
run it first and save it. The expected diff is that every organisation gains a
`billing` key, and `needs_decision` may turn true where a retainer period is
past its prepare day without Lone's confirmation. Everything else in that
payload must be identical.

`pg_cron` is installed, so M4's schedule block runs on the first apply — there
is no second run to remember. V8 confirms the job exists.

Expect: V1 all `PRESENT` and every `GONE` line reading `correctly absent`; V2
reporting `ok` for no-paid, no-overdue and no-scan/paid/due columns; V3's
columns present with `activity_type` unchanged; **V4's four counts identical**;
V5 resolving the owner to `lone@keywellness.co.bw` and `invoice.due_days`
`correctly absent`; V6 listing ten policies; V7 showing five ACLs of
`postgres=X/postgres` and **no `UNGATED` line**; V8 `transition-guarded`; V9
naming `kw-monthly-handovers`; V10 `(none)` for both, which is right because M4
creates no contracts.

Nothing else needs doing after the apply. M4 creates no contracts, no rates and
no invoices — the first pack appears on the 25th of the first month a retainer
contract exists, and **Lone marks it handed over herself**, through the SQL
editor until M7 gives her a button:

```sql
select handover_pack('<handover-uuid>');               -- read it; it is live
select handover_mark_handed_over('<handover-uuid>');   -- freeze it
select handover_confirm_invoiced('<handover-uuid>');   -- once Laone confirms
```

**The last one is Lone's record of her own follow-up, not a reading of Sage.**
Any screen showing it must read "Confirmed with Laone · 26 Aug", never a bare
"Invoiced".

### 6 · The front end

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

Roll back in reverse order — M4, then support, then M5a, M5, M1:

```
migrations/rollback-m4-contracts-workplans-billing.sql
migrations/rollback-support-audit.sql
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
- The **M4 rollback deletes contracts, work plans and billing handovers.**
  There is no backup table — unlike M1's `session_mode` these are whole rows,
  not an overwritten column. Export first:
  `select * from org_contracts; select * from billing_handovers; select * from work_plans;`
  It keeps every `program_activities` row (it drops the columns M4 added, not
  the rows), and it **puts `tuesday_review_pack()` back to its M5 body** so the
  Tuesday review keeps working instead of calling a helper that no longer
  exists.

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
- **No work-plan, contract, retainer-position, capacity or invoice screens.**
  M4 ships the schema in this deploy; **M7 builds the interface**. Those
  sections of `ops.html` render their label and say what is missing, and every
  M4 RPC is callable only from the SQL editor.
- **The daily view has no designed mobile layout yet.** It stacks below 900px,
  which is a reflow rather than a design; charter §9 asks for better and it is
  recorded as owed.
