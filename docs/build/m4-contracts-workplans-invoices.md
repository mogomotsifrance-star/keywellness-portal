> ## SUPERSEDED — 27 Aug 2026
>
> **Do not build from this file.** It describes M4 as written on 26 Aug, when
> the plan still assumed this system produced invoices. It does not: **invoices
> are produced in Sage**, which we have no read of.
>
> What changed: `invoices` becomes `billing_handovers`; `paid`, `overdue`, the
> scan upload and the storage bucket are all deleted; `invoiced` comes back
> meaning "Lone confirmed with Laone that it exists", with a binding rule that
> the screen must say "Confirmed with Laone · 26 Aug" and never a bare
> "Invoiced".
>
> The current plan is **`docs/build/m4-billing-handovers-plan.md`**.
>
> This file is kept because §4 (the live pack and `covers_from`), §6
> (idempotency and the transition-guarded trigger) and §7 (the M3 obligation)
> survive the change unaltered, and the reasoning behind them is here.
>
> Nothing described in either file has been applied to any database.

# M4 — contracts, work plans, activities, invoices

**Built 26 Aug 2026 on `dev`. Not applied to Supabase.**

| | |
|---|---|
| Migration | `supabase_m4_contracts_workplans_invoices.sql` |
| Rollback | `migrations/rollback-m4-contracts-workplans-invoices.sql` |
| Tests | `tests/m4-tests.sql` — 50 assertions, run by `tests/run-m4.sh` |
| Live check | `tests/m4-verify-live.sql` — read-only, V1–V10 |
| Depends on | M1 (`service_line`), M5 (`is_staff()`, `actions`), the support work (`is_ops_admin()`) |
| Source | `docs/data-model-and-impact.md` §3, with the 26 Aug decisions in `CLAUDE_CONTEXT.md` §2 |

Local state at the time of writing, PostgreSQL 17.6:

```
REGRESSION  org_report_data: 9 of 9 payloads byte-identical
STATE       activity 1 = delivered, invoices = 1
STATE       monthly job: {"created": 1, "run_date": "2026-12-25",
                          "period_start": "2026-12-01", "period_end": "2026-12-31",
                          "prepare_day": 25, "already_present": 0,
                          "owner_unresolved": false}
STATE       live pack: 1 -> 2 activities after a late delivery
STATE       frozen pack: 2 activities, unchanged by a later delivery (2)
STATE       next pack contains: Delivered after handover
            50 passed, 0 failed.
            rollback clean    ok (zero leftover objects)
            activities kept   ok (the rollback dropped columns, not rows)
```

The other suites, re-run against the same server after M4 landed: phase0/0a/1
all passed, M1 22, M5 45, M5a 29, support 28. Nothing moved.

---

## 1. What was built

Five new tables and thirteen functions.

| | |
|---|---|
| `org_contracts` | one per client engagement. `contract_kind` is `retainer` or `per_engagement` |
| `contract_rates` | the rate card: `(contract_id, format, service_line) -> amount` |
| `org_contacts` | who to talk to at the client |
| `work_plans` | the agreed year of work for a retainer client |
| `invoices` | a *pack* — the numbers Lone hands to accounts, plus its state |

`program_activities` is **extended in place** and keeps its name. It gains
`work_plan_id` (nullable), `format`, `state`, `delivered_at`, `scheduled_at`,
`planned_month`, `planned_date`, `practitioner_kind`, `practitioner_id`,
`org_unit_id`, `webinar_id`, `notes`. `bookings` gains `activity_id`.

`docs/data-model-and-impact.md` §3 calls the extended table
`work_plan_activities`, and the same paragraph requires the old columns to keep
working so `org_report_data()` keeps counting. Both cannot happen through a
rename — `org_report_data` names `program_activities` directly. So: extended in
place, no view, `activity_type` untouched. `activity_type` is a **reporting
input** constrained to five values; the eight M4 delivery formats live in the
new `format` column, which nothing reads yet. The regression assertion above is
what holds that line, and V2 of the live check prints the `activity_type`
constraint so a future change to it is visible rather than silent.

---

## 2. There is no accountant in this system

The first draft of M4 had one. `invoice.accountant_user_id` pointed at Laone,
the invoice action was owned by her, there was a fallback for when she had no
account (raise the invoice anyway, and title the action *"…needs reassigning"*),
and the `invoices` read policy carried a second arm so that an action owner who
is not staff could still open the invoice her action was about.

All of it is gone. Laone does not use the platform: no account, owns nothing,
uploads nothing. The pack is owned by an **ops admin** —
`invoice.prepared_by_user_id` in `threshold_config`, null meaning "the first ops
admin by email", which today resolves to Lone. Handing the numbers to accounts
is her job now and stays her job.

Three consequences worth naming, because each removed something that looked
like a safety feature:

- **The missing-owner fallback went with it.** `_invoice_owner()` can still
  return null, but only if *no admin has an account at all*, which is a broken
  deployment rather than a case to design around. The job reports
  `owner_unresolved` in its return value and V4 of the live check resolves the
  owner to an email before you apply anything.
- **The read-policy arm went with it.** `invoices_read` is now `is_ops_admin()`
  alone. The arm protected nobody once the owner is an ops admin by
  construction, and *a policy clause that protects nobody is a claim about the
  system that is not true*. M5's `actions_staff_read` keeps the real version of
  that idea — `is_staff() or owner = auth.uid()` — where the owner genuinely can
  be someone who is not staff.
- **`tests/m5-verify-live.sql` said Laone needed an account "since M4 gives her
  the invoice actions".** That comment was written before this decision and is
  now corrected in place; the deploy note's precondition list drops her too.

Assertion 19a is the standing guard: no `invoice.accountant_user_id` key, no
invoice whose `prepared_by` is not an admin with an account, and no action
titled `Produce invoice%` or mentioning an accountant.

---

## 3. Billing: within-month arrears, and the alternative

**Decision: the pack is prepared in the last week of the month it covers.**
`_invoice_period()` returns the **current** month, and the job fires on
`invoice.prepare_day` (default 25). Arrears here means *within-month*, not
previous-month.

```sql
create or replace function _invoice_period(p_run_date date)
returns table (period_start date, period_end date)
language sql immutable as $$
  select date_trunc('month', p_run_date::timestamp)::date,
         (date_trunc('month', p_run_date::timestamp)
          + interval '1 month' - interval '1 day')::date;
$$;
```

**The alternative, recorded as instructed: billing in advance.** The 1st of the
month invoices the month about to start. It is the simpler shape — the pack is a
fixed retainer amount with no delivered work in it at all, so none of §4 exists:
no live contents, no `covers_from`, no freeze. It was not chosen because the
retainer pack is not only a number; it is the month's work, and a client who
receives the pack before the work happens receives a list of promises. Switching
later means changing `_invoice_period()` to return the *next* month and moving
`invoice.prepare_day` to 1. The rest of the machinery would then be dead weight
and should be removed rather than left inert.

A third shape — the 1st of the month invoicing the month just ended — was the
draft that went to review and was corrected. It is not the alternative; it is
simply wrong for this business, because it delays the invoice by up to a month
for no gain.

---

## 4. The pack is live, not a snapshot

This is the part that carries the most reasoning, so it gets the most words.

Work delivered between the prepare day (the 25th) and month end still belongs to
that month. If the pack were a snapshot taken on the 25th, six days of delivered
work would fall out of the world — invoiced in neither month, because the next
period starts on the 1st.

So the pack is **empty at creation** and **recomputes on read** until Lone marks
it handed over:

```sql
if i.kind = 'engagement' or i.state <> 'to_prepare' then
  return ... 'live', false, 'contents', i.narrative;      -- frozen
end if;
return ... 'live', true,
       'contents', _pack_contents(i.org_id, i.covers_from, now());
```

`invoice_hand_over()` computes the contents once, writes them to `narrative`,
stamps `handed_at`, and closes the action. From that moment the pack is frozen
and every later read returns the stored value.

**`covers_from` is what makes this safe.** The next pack starts at the previous
handover, not at the month boundary:

```sql
select coalesce(max(i.handed_at), v_start::timestamptz) into v_from
  from invoices i where i.contract_id = c.id and i.kind = 'retainer';
```

A pack therefore covers `(previous handover, this handover]`. **The calendar
month is only its label.** Nothing is dropped and nothing is counted twice, and
that is a property of the half-open interval rather than of anybody remembering
to check. Assertions 25a–25f are the four cases: recompute after a late
delivery, freeze on handover, a later delivery does not change the frozen pack,
that same delivery appears in the next pack, the earlier one does not appear
twice, and a pack cannot be handed over twice.

### The boundary is strict, and the test had to earn that

`_pack_contents` uses `> p_from` and `<= p_to`. Half-open in that direction is
the only choice that cannot double-count: `handed_at` itself belongs to the pack
that was just handed over.

The first version of assertion 25d failed, and it failed for a reason worth
recording. It inserted the post-handover activity with `delivered_at = now()` in
the same `DO` block as the handover — and **`now()` is transaction-start time**,
so the row landed at *exactly* `handed_at` and the strict boundary excluded it
from both packs. The behaviour was right; the test was measuring a moment that
cannot occur in life, where deliveries land in later transactions. It uses
`clock_timestamp()` now, with the reason written beside it.

---

## 5. States: `to_prepare → handed_to_accounts → invoiced → paid`

Plus `cancelled`. There is no `sent` state, and there never should have been:
**the system never sends anything, and now nobody inside it does either.** Lone
hands the numbers to accounts; accounts invoice the client.

Assertion 38 asserts the *absence* of `sent` and of `overdue` in the check
constraint, which is the only way to keep a removed state removed.

**Overdue is derived, never stored:** `state = 'invoiced' and due_date <
current_date`. A stored overdue flag needs a job to maintain it and is wrong
between runs — the same reasoning as M5's carried-forward label.

### The scan is evidence, not a trigger

The scan upload was a state trigger in the draft. It is now optional evidence
Lone attaches at the `invoiced` step. Writing the test for that exposed a real
gap: `invoice_mark_invoiced` required `state = 'handed_to_accounts'`, so a scan
that arrived *after* the pack was marked invoiced — which is the normal case,
since the paperwork rarely reaches her the same day — could not be filed at all.
The function now accepts a second call on an already-invoiced pack, attaches the
scan, and **leaves `invoiced_at` where it was**:

```sql
if i.state not in ('handed_to_accounts', 'invoiced') then
  raise exception 'a pack must be handed to accounts before it is invoiced';
end if;
update invoices
   set state = 'invoiced',
       invoiced_at = coalesce(invoiced_at, now()),   -- does not move
       scan_path   = coalesce(p_scan_path, scan_path);
```

Scans live in a **private** `invoice-scans` bucket. V10 of the live check fails
loudly if it is public.

---

## 6. Idempotency, and the trigger guard

Two partial unique indexes, not job bookkeeping:

```sql
create unique index if not exists invoices_one_per_retainer_period
  on invoices (contract_id, period_start) where kind = 'retainer';
create unique index if not exists invoices_one_per_activity
  on invoices (activity_id) where kind = 'engagement';
```

Both jobs are re-runnable because **the database refuses the duplicate**, not
because the job remembers. Same shape as M5's `unique nulls not distinct`.
Assertion 23 runs the monthly job twice and expects `created: 0,
already_present: 1`.

Cron runs **daily** and the function decides whether today is the prepare day.
That keeps `invoice.prepare_day` configurable through `threshold_config` without
rescheduling cron. Assertion 24 covers the skip.

`trg_booking_drives_activity` fires on `AFTER INSERT OR UPDATE OF activity_id,
attended` and is **guarded on the transition**, never on any update.
`docs/build/m1-service-line.md` records why: a column backfill fires every
`AFTER UPDATE` trigger on `bookings` — M1's backfill fired
`trg_award_session_attended` 22 times, and was safe only because that trigger is
transition-guarded. An unguarded version here would invoice the entire back
catalogue the next time anyone migrates a column on `bookings`. V7 of the live
check asserts the guard is present.

**First confirmed attendance delivers the activity.** A per-engagement activity
that is delivered raises its invoice immediately. A format with no rate on the
card still produces an invoice — with a null amount and an action naming the
gap. Never block the delivery of real work because billing metadata is missing.

---

## 7. The obligation this creates for M3

Recorded in the same words as `docs/build/m5a-ops-timeline.md` §4, because it is
the same obligation and the wording is the test.

`org_work_plan()` and `contract_position()` are `SECURITY DEFINER` and therefore
**bypass row-level security**. Today that is harmless: every activity is
financial. The moment counselling work appears on a work plan, France — a
Key Wellness admin who is not a counsellor — can read it through these two
functions no matter what policies M3 writes on `bookings` or
`program_activities`, because a `SECURITY DEFINER` function runs as `postgres`
and never consults them.

**M3 must gate psychosocial rows inside these functions**, not only in the
policies, and must ship a named test for each:

> a France-type admin calling `org_work_plan` sees no psychosocial rows
>
> a France-type admin calling `contract_position` sees no psychosocial rows

That is now three functions carrying the obligation: `ops_timeline()`,
`org_work_plan()`, `contract_position()`.

---

## 8. What the tests prove, and what they do not

50 assertions. They prove the logic, the state machine, idempotency under
re-run, the RLS shape under `set role authenticated`, that no `_`-prefixed
helper is reachable by `anon` or `authenticated` (assertion 40), that
`org_report_data()` returns byte-identical payloads before and after, and that
the rollback leaves zero objects while keeping every `program_activities` row.

They do **not** prove schema fidelity. **The fixture is a reconstruction** —
`CLAUDE_CONTEXT.md` §3.2 — assembled from the live snapshot rather than dumped
from it, so a column that exists on live and not in the fixture is invisible to
the whole suite. The Supabase-branch decision is still deferred to M3.

Two harness faults were found and fixed while getting to green, both of which
had been hiding results rather than producing false ones:

- **The rollback ran with its output redirected to `/dev/null`.** It was failing
  — `work_plans` cannot be dropped while `program_activities.work_plan_id`
  references it — and `set -e` stopped the run without printing why, so the
  `rollback clean` and `activities kept` checks silently never ran. The column
  is now dropped with its parent table, and the harness prints rollback errors.
  `DROP ... CASCADE` would have been the wrong fix: it would have taken the
  column silently and left the rest of the rollback looking as though it had
  done the work.
- **A `DO` block's exception handler swallowed the assertion before it.** In
  PL/pgSQL an exception rolls back to the start of the block *containing the
  handler*, so assertion 25g's own result row disappeared along with the failure
  it was catching, and the suite reported one fewer test without reporting a
  failure. The second call is now in its own inner block.

---

## 9. Deploy

M4 goes **after** M1, M5, M5a and the support work. Sequence:

```
tests/m4-verify-live.sql                          run it, SAVE THE OUTPUT
supabase_m4_contracts_workplans_invoices.sql      apply
tests/m4-verify-live.sql                          run again, diff
```

Then, if `pg_cron` was enabled during the M5 deploy, **re-run the migration
once** — the schedule block is a guarded no-op until the extension exists, and
without the second run no pack is ever prepared. V8 reports which case you are
in.

Expected diff: everything in V1 and V2 flips to `PRESENT`; V3's three counts are
**identical**; V4 resolves the owner to a real email; V5 lists ten policies with
`invoices_read` reading `is_ops_admin()` and nothing else; V6 shows four ACLs
reading `postgres=X/postgres` and no `UNGATED` line; V7 says
`transition-guarded`; V9 reads `(none)` for both lines, which is correct because
M4 creates no contracts; V10 says private.

To name a different preparer:

```sql
update threshold_config
   set value = to_jsonb('<user-uuid>'::text)
 where key = 'invoice.prepared_by_user_id';
```

Rolling back deletes contracts, work plans and invoices — there is no backup
table, because unlike M1's `session_mode` these are whole rows. Export first.
The bucket is kept if it holds any file.

---

## 10. What is NOT done

- **No user interface.** M4 is schema and RPCs only. `ops.html` renders its
  contracts, work-plan and capacity sections as labels saying what is missing;
  M7 builds them. `invoice_pack()`, `invoice_hand_over()`,
  `invoice_mark_invoiced()` and `invoice_mark_paid()` have no caller yet, so
  **Lone marks the pack handed over herself** — through the SQL editor until M7
  gives her a button.
- **HR cannot read contracts.** Deferred by decision; `employer.html` is
  untouched and the policies are staff-only.
- **No decisions table.** Deferred with M5.
- **No psychosocial anything.** M3, with §7 above as its first obligation.
- **The rate card has no editor**, so rates are inserted by hand until M7. A
  missing rate is designed for rather than prevented: the invoice is raised with
  a null amount and an action names the gap.
