# M5 — meetings, actions and reminders

**Built 26 Aug 2026 on `dev`. Prompt 2 of the operating-system pack.**
Migration M5 from `docs/data-model-and-impact.md` §3 and §4, against
`docs/operating-model.md` §4.4 and §5.

> **45 assertions green on PostgreSQL 17.6. Not applied to Supabase.**
> This is the first suite in the repo that actually enforces RLS — see §4.
> Two deploy preconditions have to be met before it is useful, and one of
> them is not what the pack assumes. See §6.

This is the migration that fixes the line in `operating-model.md` §0:
*"decisions are not recorded anywhere; each person has to remember their own
actions."* It ships before the confidentiality work because an action ledger
needs none of it.

---

## 1. What was built

| File | Purpose |
|---|---|
| `supabase_m5_meetings_actions.sql` | The migration. Idempotent |
| `migrations/rollback-m5-meetings-actions.sql` | Full reversal, zero leftover objects |
| `tests/m5-fixture.sql` | Local schema + seed, with real `authenticated` grants |
| `tests/m5-tests.sql` | 45 assertions, RLS enforced |
| `tests/run-m5.sh` | Harness |
| `tests/m5-verify-live.sql` | Read-only before/after for the SQL editor |
| `CLAUDE.md` | Sweep regex gains `is_staff` and the three M3 gates |

**Schema.** `organizations.is_test`; `meetings`; `actions`;
`action_reminders`. **Functions.** `is_staff()`, `_action_label()`,
`action_reminders_run()`, `tuesday_review_open()`, `tuesday_review_pack()`,
`action_upsert()`. **Policies.** Eight across `meetings` and `actions`; none
on `action_reminders`, by design.

---

## 2. Decisions

### 2.1 No decisions table

The task named "meetings, decisions, actions and reminders", but every
decision that matters produces an action, and `meetings.notes` carries the
rare one that does not. A table with no reader is speculation. **If "what did
we decide about X" ever gets asked, that is the signal to add it.**

### 2.2 Carried-forward is derived, not a fourth state

The state vocabulary stays `open | done | dropped`. Carrying an action creates
a successor and moves the predecessor to `dropped`; **carried** is derived as
`exists (select 1 from actions s where s.carried_from = a.id)`. Dropped *with*
a successor is carried; dropped *without* one is genuinely abandoned. Every
RPC returns the derived label so no screen re-derives it and gets it wrong.

That distinction is what makes the number `operating-model.md` §4.4 asks for
computable — *"what share of Tuesday actions are done by the next Tuesday"*:

```
completion_rate = done / (done + open + dropped-with-successor)
```

An action dropped on purpose is out of the denominator. Deciding not to do
something is not a failure to deliver. Assertion 33 pins it at 33.3% against a
seed of one done, one open, one carried and one abandoned.

### 2.3 `unique nulls not distinct` — the constraint that would have done nothing

A `tuesday_review` has `org_id` null, and **PostgreSQL treats NULLs as
DISTINCT in a unique constraint by default**. A plain
`unique (kind, held_on, org_id)` would have accepted ten reviews for the same
Tuesday while looking correct. `NULLS NOT DISTINCT` is PG15+; production is
17.6. This is what makes `tuesday_review_open()` idempotent and Prompt 3's
one-click empty state safe to double-click. Assertion 2 proves it.

### 2.4 The ledger is the memory; `notifications` is the delivery

Reminders are rows in `notifications`, as specified. But `notifications` has
no natural key to dedupe on and a member may read or delete one, so
`action_reminders (action_id, kind)` — primary key, nothing else — is what
makes "a double-fire writes nothing twice" true. The function writes the
ledger row first and only sends when the insert reports a row.

`action_reminders` has **RLS on and no policy**, so it is reachable only from
`SECURITY DEFINER` code. It is also explicitly revoked from `anon` and
`authenticated`: RLS with no policy already denies every row, but Supabase's
default privileges hand out a table grant on anything created in this schema,
and two independent locks means a policy added here by accident later does not
silently open it. Assertion 18 confirms not even an admin can read it.

### 2.5 Overdue fires once

A daily nag trains people to ignore it. A standing overdue list belongs on the
daily view, which is a screen, not a message. Assertions 25 and 26.

### 2.6 04:00 UTC

06:00 in Gaborone — before the working day, not during it. The function
computes against the **Gaborone** date, not UTC, so a reminder fires on a
Botswana day.

---

## 3. The read policy Laone would have been locked out of

`actions_staff_read` is **`is_staff() or owner = auth.uid()`**, not
`is_staff()`.

Laone, the accountant, owns the invoice actions M4 creates. She is neither
admin nor advisor, so `is_staff()` is false for her. With the plain staff
predicate she would have received a reminder notification about an action she
could not open — the system nagging someone about work it refuses to show
them. The extra clause gives an owner-who-is-not-staff exactly their own
actions and nothing else: assertions 11 and 12 check both halves, that she
sees her one action and that she still sees no meetings.

Whether Laone gets a proper role is M4's question. M5 just must not lock her
out.

---

## 4. This is the first suite that actually enforces RLS

`tests/phase0-tests.sql` runs everything as `postgres`. Postgres is a
superuser, so it **bypasses row-level security entirely**. That suite drives
`test.email` to steer `is_admin()` and `current_advisor_id()`, so it genuinely
tests the `SECURITY DEFINER` functions' internal gates — but any policy
assertion it appears to make is vacuous.

M5 is mostly policies. "A member reads neither", "an uninvolved staff member
cannot update" — worth nothing unless RLS applies to the caller. So
`m5-fixture.sql` grants the `authenticated` role real table privileges and
`m5-tests.sql` does `set role authenticated` before every access assertion.
`authenticated` is not the table owner, so PostgreSQL applies the policies.

The build preamble has said "tests run locally against PostgreSQL 17 with RLS
enforced" all along. Until now that was aspirational. **M3's confidentiality
boundary depends on this pattern**, so it is worth having established it here,
on a migration where the cost of getting it wrong is low.

---

## 5. What the tests prove

`tests/run-m5.sh` → 45 assertions, then rollback twice and verify clean.

| # | Group |
|---|---|
| 1–6 | `is_test` defaults false; a second Tuesday review on one date is refused; unknown meeting kind and action state refused; `state='done'` with no `done_at` refused; an action cannot carry from itself |
| 7–12 | **RLS**: admin reads all; advisor reads all; member reads neither; HR reads neither; **an owner who is not staff reads exactly their own action and no meetings** |
| 13–17 | Owner can update their own; creator can update one they do not own; an uninvolved staff member cannot; an advisor cannot delete; an admin can |
| 18 | Not even an admin reads `action_reminders` |
| 19–28 | Reminders: due-in-3 fires; addressed to the **owner**, not the creator; a second run the same day writes nothing; one ledger row per (action, kind); due-tomorrow fires; the boundary either side of three days; overdue fires **once** and not again; done and dropped are never reminded; unrelated notification types untouched |
| 29–37 | The pack: active non-test orgs only; **Test Co never appears**; carried labelled carried; abandoned labelled dropped; `completion_rate` = 33.3; the unassigned bucket; a member is refused; `tuesday_review_open` twice returns the same meeting and offers last week's open actions |
| 38–41 | `action_upsert` inserts and stamps `created_by`; done sets `done_at`; carrying drops the predecessor and links the successor in one call; an uninvolved staff member is refused |
| 42–44 | No new `SECURITY DEFINER` function is reachable ungated; the reminder writer and the label helper are revoked from `anon` and `authenticated` |

Then: rollback leaves zero objects, runs twice cleanly, and **removes the
reminder notifications it wrote** — a reminder about an action that no longer
exists is noise, and once the ledger is dropped there is no way to identify
them. Notifications of any other type are untouched.

### Four bugs the run exposed

1. **`_r` as a temp table.** Half the assertions run as `authenticated`, which
   cannot write a temp table owned by `postgres`. Made a real table with an
   explicit grant.
2. **Assertion 40 called `_action_label` as `authenticated`** — which is
   revoked, exactly as assertion 44 asserts. The test was wrong, not the code;
   it now derives the label inline.
3. **Assertion 24 was measuring the wrong thing.** It asserted that no
   `due_in_3` fired on 2026-08-25, but the seed holds an action due 2026-08-28
   — exactly three days out. The run was correct. Rewritten against a
   dedicated probe action and moved after the overdue block so the clocks do
   not interfere.
4. **The rollback dropped `is_staff()` before the tables**, and PostgreSQL
   refuses to drop a function a live policy depends on. Tables now go first.

Assertion 34 was also tightened from a bucket count to naming the action it
expects — the count broke the moment the probe from bug 3 landed in the same
bucket, which is exactly the brittleness a count invites.

---

## 6. Deploy preconditions — one is not what the pack assumes

**`actions.owner` references `auth.users`**, because `notifications.user_id`
does. You cannot remind a person who does not exist.

Checked against live on 26 Aug 2026:

| Person | In `admins`? | Account? | Can own an action? |
|---|---|---|---|
| **Lone** | yes | yes | yes |
| **Michelle** | **yes — granted 26 Aug 2026** | yes | yes |
| **Laone** | no | not found | **no** |
| France | yes (×2 emails) | yes | yes |
| `kramontshonyana@debswana.bw` (advisor) | — | **no account** | **no** |

**Michelle — resolved 26 Aug 2026.** She previously held no role in the
database at all, so `is_staff()` was false and the workspace built for her was
invisible to her. Granted admin through the dashboard. Recorded because the
audit that found it is the kind worth repeating: the pack asserted a role the
database did not have.

Still outstanding:



1. **Lone and Laone accounts** — Tshenolo's, treated as deploy preconditions.
   Laone especially: without an account she cannot own M4's invoice actions or
   receive a reminder about one.
2. Decide whether `kramontshonyana@debswana.bw` needs an account or should be
   deactivated. Today that advisor cannot own an action.

---

## 7. What is NOT done

- **Reminders fire into a void until Prompt 3 gives staff a notification
  surface.** `notifications` today is read only by the member portal's
  notification centre. `ops.html` must show staff notifications, or an action
  reminder is written, delivered, and never seen. **This is a Prompt 3
  requirement**, recorded here so it is not lost between the two.
- **pg_cron is not installed**, so nothing is scheduled yet. The migration's
  schedule block is a guarded no-op; enable the extension and **re-run the
  migration** for it to take effect.
- **No decisions table** (§2.1).
- **`actions.activity_id` has no FK** — `work_plan_activities` does not exist.
  M4 adds the constraint rather than M5 guessing at it.
- **No UI.** `ops.html` is Prompt 3. The three RPCs exist and are tested, but
  nothing calls them.
- **`action_upsert` cannot clear `org_id` or `meeting_id`** — a null parameter
  means "leave alone". Nothing needs to yet, and a sentinel now would be a
  guess.
- **No attendee validation.** `meetings.attendees` is `uuid[]`; PostgreSQL
  cannot foreign-key an array element, and a trigger to check each one is not
  worth it until something reads them.

---

## 8. Deploy order

1. Run `tests/m5-verify-live.sql` in the SQL editor. **Save the output** —
   V2 is the account audit, V4 the before-totals.
2. Settle the preconditions in §6, at least Michelle's role.
3. Apply `supabase_m5_meetings_actions.sql`. It ends with a notice naming
   whether pg_cron was found.
4. Flag the test organisation — the migration deliberately names no
   organisation, so this is by hand:
   ```sql
   update organizations set is_test = true where name = 'Test Co';
   ```
   Without it the first screen Lone opens has a test organisation in the
   roll-call.
5. Enable **pg_cron** (Database → Extensions), then **re-run step 3** so the
   schedule block takes effect. Confirm with
   `select * from cron.job where jobname = 'kw-action-reminders';`
6. Run `tests/m5-verify-live.sql` again and diff against step 1. Expect: the
   three tables present, eight policies on meetings+actions, zero on
   `action_reminders`, both helpers not public, all three RPCs callable,
   Test Co flagged, and **every total in V4 unchanged**.
7. If anything else moved, apply the rollback and stop.

Note that the rollback drops `organizations.is_test`, so re-applying M5 later
means re-running step 4.
