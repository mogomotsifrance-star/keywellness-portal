# M4, amended — contracts, work plans, activities, billing handovers

**Plan only. No SQL written. 27 Aug 2026.**

This replaces the plan behind `supabase_m4_contracts_workplans_invoices.sql`,
which is committed on `dev` and **has never been applied to anything**. That is
what makes this cheap: it is a rewrite of files, not a migration of live data.

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
| `cancelled` | Reachable from any state. |

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

## 9. Three decisions I need before writing SQL

**9.1 · Does the handover keep a `due_date`?**
It existed only to derive `overdue`, which is gone. Recommend **deleting it**,
and `invoice.due_days` with it. But the *action* that tells Lone to hand the
pack over still needs a due date — recommend **month end**, which is a date we
actually know, rather than a payment term we are guessing at.

**9.2 · An activity for an organisation with no contract at all.**
Today a *missing rate* still raises the handover with a null amount plus an
action naming the gap. Should a *missing contract* behave the same way?
Recommend **yes** — raise it with a null amount and an action. Never lose
delivered work because the paperwork is behind.

**9.3 · Where the yellow flag is computed.**
Recommend extending **`tuesday_review_pack()`** rather than adding a separate
call, so the review screen keeps making one request and `needs_decision` stays
one concept. The cost is real and worth naming: **that function is already live
on the production database**, so M4 would replace it. It therefore needs its
own baseline, its own written prediction and its own assertion, under the
standing rule. Every other part of M4 only adds.

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
