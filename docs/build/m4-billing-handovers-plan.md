# M4, amended — contracts, work plans, activities, billing handovers

**BUILT 27 Aug 2026 on `dev`. Not applied to any database.**

This replaced the plan behind the old
`supabase_m4_contracts_workplans_invoices.sql`, which had never been applied to
anything — which is what made the rewrite cheap: files, not live data. That
file and its rollback are now deleted; the current pair is
`supabase_m4_contracts_workplans_billing.sql` and
`migrations/rollback-m4-contracts-workplans-billing.sql`.

Local state, PostgreSQL 17.6:

```
REGRESSION  org_report_data: 9 of 9 payloads byte-identical
STATE       activity 1 = delivered, billing_handovers = 1
STATE       monthly job: created 1, period 2026-12-01..2026-12-31, prepare_day 25
STATE       live pack: 1 -> 2 activities after a late delivery
STATE       frozen pack: 2 activities, unchanged by a later delivery
STATE       next pack contains: Delivered after handover
STATE       Tuesday flag: f -> t  (June not confirmed invoiced)
            66 passed, 0 failed.
            rollback clean    ok (zero leftover objects)
            activities kept   ok (the rollback dropped columns, not rows)
```

Every other suite, re-run afterwards: phase0/0a/1 passed, M1 22, M5 45,
M5a 29, support 28, Edge Function 13. Nothing moved.

---

## 1. What this is for, in one paragraph

Key Wellness does work for client organisations. Some pay a monthly retainer;
some are billed per engagement at prices agreed up front. At the end of every
month somebody has to tell Laone what to invoice. Today that is Lone's memory
and a spreadsheet. M4 makes it a record: what was agreed, what was delivered,
what was handed to Laone, and when.

---

## 2. The change that drives everything else

**Invoices are produced in Sage. This system never produces one, and never
sees one.**

So the table is not called `invoices`. It is called **`billing_handovers`**,
and a row is *the handover* rather than the invoice — "here is the work we did
for BOPEU in August; please invoice it."

Four things follow, and each one removes something the previous plan had:

- **No `paid` state.** We have no read of Sage. A stale "paid" is worse than no
  "paid", because a wrong answer gets acted on and a missing one gets checked.
- **No `overdue`.** Same reason. Whether an invoice is overdue is a fact about
  a document we cannot see.
- **No scan upload, no storage bucket, no bucket policy.** The document lives
  in Sage. Storing a photocopy here would create a second version of the truth.
- **`invoiced` survives, but it means something narrower** — see §3.

---

## 3. The states, and the one wording rule

```
to_prepare  ──▶  handed_over  ──▶  invoiced
                                              cancelled, from any state
```

| State | What it actually means |
|---|---|
| `to_prepare` | The month's work is still accumulating. Nobody has done anything yet. |
| `handed_over` | Lone has given Laone the numbers. The contents freeze at this moment. |
| `invoiced` | **Lone has confirmed with Laone that the invoice exists in Sage.** Recorded as `invoice_confirmed_by` and `invoice_confirmed_at`. |
| `cancelled` | Reachable from any state. **Keeps the confirmation if there was one.** |

### Cancelling does not erase the confirmation

If Lone confirmed the invoice and the handover is cancelled afterwards, **an
invoice very likely exists in Sage and needs a credit note.** Clearing
`invoice_confirmed_by` / `invoice_confirmed_at` would destroy the only trace of
it at exactly the moment she needs to chase it.

> **We record what happened, not what is currently true.**

So the state reads `cancelled`, and the confirmation stays beside it with the
reason. `handover_cancel()` returns `was_confirmed` and `confirmed_at` so the
caller knows it is looking at the case that needs a human.

The check constraint says this as a rule rather than leaving it to behaviour:
`invoiced` **requires** a confirmation, `to_prepare` and `handed_over`
**forbid** one, and `cancelled` allows either. Four assertions cover it,
including the reverse — a handover cancelled *before* anyone confirmed anything
must not acquire a confirmation out of nowhere.

**This is an M7 obligation too.** A handover that reads *cancelled, but was
confirmed on 26 Aug* is not the same thing as a handover that was cancelled
before it ever went anywhere, and the screen must not show them identically.

`invoiced` was cut from the previous plan and is now back. The objection to it
was that a status nobody owns goes stale — which is right, and is exactly why
`paid` is still refused. But **Lone owns this one.** She already has the
conversation with Laone; the flag is her record of her own follow-up, not a
mirror of Sage's state.

### The wording rule, binding

> The screen reads **"Confirmed with Laone · 26 Aug"**, never a bare
> **"Invoiced"**.

The system does not know an invoice exists. It knows Lone said so, and when.
**Any label implying first-hand knowledge of Sage is a defect.**

One already exists: **`ops.html` line 641 reads "Invoices produced"**. That is
the claim we cannot make. It becomes "Confirmed with Laone" when M7 builds the
section.

---

## 4. When the pack is prepared

**In the last week of the month it covers, for that same month.** Not the 1st,
and not the previous month.

- `invoice.prepare_day` in `threshold_config`, default **25**.
- The scheduled job runs **daily** and the function decides whether today is
  the prepare day, so the day stays configurable without touching the schedule.

## 5. The pack is live, not a snapshot

Created **empty** on the 25th, and recomputed every time it is read — so work
delivered on the 28th still counts. Lone marking it handed over **freezes** the
contents at that moment, and the next month's pack **starts from that moment**
rather than from the 1st.

That is what `covers_from` is for: a pack covers **(previous handover, this
handover]**. The calendar month is only its label. Nothing is dropped and
nothing is counted twice — and that is a property of the arithmetic, not of
anyone remembering to check.

## 6. Who owns it

**Lone.** `invoice.prepared_by_user_id` in `threshold_config`, defaulting to
the first ops admin, which is her.

**There is no accountant user anywhere in this system.** Laone does not use the
platform: no account, owns nothing, uploads nothing. The previous plan had an
`invoice.accountant_user_id`, a fallback for when she had no account, and a
read-policy arm so a non-staff owner could open her own invoice. All three are
gone.

## 7. Not every client is on retainer

`org_contracts.contract_kind` is `retainer` or `per_engagement`. Per-engagement
prices are known in advance, so each contract carries a **rate card**
(`format × service_line → amount`).

- The monthly job sweeps **retainers only**.
- A per-engagement activity raises its handover the moment it is **delivered**.
- **An organisation can have no active retainer and still have activities and
  handovers.**

## 8. The yellow flag Lone asked for

A retainer period **past its prepare day with no invoiced confirmation**
surfaces on the Tuesday review as **needs a decision**, reading:

> August not confirmed invoiced

This goes in the **ops assertion suite**, not only the screen. A flag that
exists only in the UI is a flag that stops working the first time the UI is
rebuilt.

---

## 9. The three decisions, as taken (27 Aug 2026)

**9.1 · The handover keeps NO date.** `due_date` is gone and `invoice.due_days`
with it — the migration actively deletes that config key, so a database that
had it does not keep a stale one. The *action* that tells Lone to hand the pack
over is due at **month end**: `period_end` for a retainer, and the end of the
month the work was delivered in for an engagement. Both are dates this system
set and therefore knows.

**9.2 · An organisation with no contract at all still gets a handover** — blank
amount, plus an action reading *"— no contract on file for this organisation"*.
Same treatment as a missing rate. Delivered work is never lost because the
paperwork is behind.

  One guard came out of building it, which the plan had not anticipated: if the
  organisation has **no per-engagement contract but an active retainer**, the
  activity belongs in the monthly pack and `_handover_for_activity()` returns
  without raising anything. Without that check the work would be handed over
  twice — once on delivery and once in the month's pack.

**9.3 · The flag extends `tuesday_review_pack()`.** So the review screen keeps
making one request and `needs_decision` stays one concept. That function is
live, so it carries its own baseline (V0 of the live check), its own written
prediction, and six assertions of its own — including that handing the numbers
over does **not** clear the flag and only Lone's confirmation does.

The rollback restores its M5 body exactly, and refuses to finish if the
restored function still calls `_billing_flags`.

---

## 10. What gets renamed

| Old | New |
|---|---|
| `invoices` | `billing_handovers` |
| `invoices_run_monthly()` | `handovers_run_monthly()` |
| `invoice_pack()` | `handover_pack()` |
| `invoice_hand_over()` | `handover_mark_handed_over()` |
| `invoice_mark_invoiced()` | `handover_confirm_invoiced()` |
| `invoice_mark_paid()` | **deleted** |
| `_invoice_period()` | `_handover_period()` |
| `_invoice_owner()` | `_handover_owner()` |
| `_invoice_for_activity()` | `_handover_for_activity()` |
| `invoices.scan_path` | **deleted** |
| the `invoice-scans` bucket and its policy | **deleted** |
| every derivation of `paid` or `overdue` | **deleted** |

The config keys keep their `invoice.` prefix (`invoice.prepare_day`,
`invoice.prepared_by_user_id`) because that is what they are *about*, and
renaming them buys nothing.

Files that change: the migration, its rollback, `tests/m4-tests.sql`,
`tests/m4-verify-live.sql`, `tests/run-m4.sh`, `tests/m4-baseline.sql`,
`tests/m4-fixture-extra.sql`, and the old build record
`docs/build/m4-contracts-workplans-invoices.md`, which is superseded by this.

---

## 11. What breaks if this is wrong, and how to undo it

**Almost nothing that exists today can break.** M4 adds tables and columns and
changes no existing row. Booking counts, reporting figures and published
reports are untouched, and the regression assertion against
`org_report_data()` is what holds that line.

**The one exception is `tuesday_review_pack()`**, if decision 9.3 goes the way
I recommend. That function is live. If the billing block is wrong, the Tuesday
review screen shows a wrong flag or fails to load. Nobody's data is damaged,
but Lone's Tuesday morning is. Hence its own prediction and its own assertion.

**To undo:** the rollback drops everything M4 created and restores
`tuesday_review_pack()` to its M5 body. It **deletes contracts, work plans and
handovers** — there is no backup table, because unlike M1's `session_mode`
these are whole rows rather than an overwritten column, so export first. It
keeps every `program_activities` row: M4 adds columns to that table, and the
rollback drops the columns rather than the rows.

---

## 12. What M4 still does not do

- **No screens.** M4 is schema and functions. M7 builds the interface, and
  until then Lone marks a pack handed over from the SQL editor.
- **No read of Sage.** There is no integration and none is planned here.
- **HR cannot read contracts.** Deferred by decision.
- **No psychosocial anything** — M3. And the obligation M4 inherits stands:
  `org_work_plan()` and `contract_position()` are `SECURITY DEFINER` and bypass
  row-level security, so **M3 must gate psychosocial rows inside them**, with
  the named tests "a France-type admin calling `org_work_plan` sees no
  psychosocial rows" and the same for `contract_position`.
