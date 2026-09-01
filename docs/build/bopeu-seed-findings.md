# BOPEU's real programme — what the first real data found

**1 Sep 2026. The seed is written and tested locally. It is NOT applied to
live, and §3 is why.**

Source: "Bopeu workplan revised.docx", uploaded 27 Aug 2026 — nineteen rows,
verbatim. File: `seed-bopeu-2026.sql`. Idempotent, run twice locally:

```
BOPEU: 19 activities (9 delivered, 10 planned), 9 psychosocial.
BOPEU: 6 rows carry a PLACEHOLDER service line; 3 of them are PHYSICAL/MEDICAL
       and NEED A DECISION before being marked delivered.
```

---

## 1. Two things the document needs that the schema cannot say

### 1.1 · The programme has three pillars. The schema has two service lines.

`service_line` admits `financial` and `psychosocial`. BOPEU's programme also has
**Physical** and **Medical / Physical** rows — the health screening and the two
wellness challenges. There is no service line for them, and neither available
value is true:

| | consequence |
|---|---|
| `psychosocial` | hides them from France and from HR reporting, because M3 treats that line as confidential. A health screening is not confidential clinical content, and it would disappear **invisibly**. |
| `financial` | puts them in HR's financial session totals. Wrong, but **visible** and correctable. |

Recorded as `financial`, marked `[PLACEHOLDER-LINE] [NEEDS-DECISION]` in
`notes`, on the same reasoning as the ownership rule: a visible wrong is fixed
in ten seconds; an invisible one surfaces months later. **All three are state
`planned`**, so nothing counts them as delivered yet and the decision can be
taken first.

**Adding a third service line is not a seed's business.** It touches M3's
confidentiality boundary and every policy and definer function built on the
two-way split.

### 1.2 · Four rows are "Psychosocial & Financial". A row has one line.

Recorded as `psychosocial` — all four titles **lead** with the psychosocial
content and carry the financial part as a clause.

**Deliberately not split into two rows.** `org_report_data` counts
`program_activities` as touchpoints, so splitting one delivered session into two
would double-count it: one real session becoming two in every figure BOPEU is
ever shown. The pillar as given is preserved in `notes` instead.

---

## 2. What was left deliberately empty

- **`account_manager` — NULL.** "Lone, presumably" is not a confirmation, and
  the standing rule is that ownership is never guessed.
- **`practitioner_kind` — NULL everywhere except the health screening
  (`vendor`).** The document does not say who delivered any session. Guessing
  advisor-vs-counsellor from the pillar would put names against work nobody
  recorded.
- **`attendee_count` — 0 everywhere.** NOT NULL forces a number; the document
  records none. 0 means "not recorded" and keeps every attendance figure
  honestly empty rather than invented.
- **`document_url` — NULL.** The .docx is not in this repository.
- **Status taken from the document, not the calendar.** 9 Completed →
  `delivered`, 10 Planned → `planned`. **The two past-dated Planned rows
  (12 Aug, 26 Aug) are NOT flipped.** "The date has passed" is an inference,
  not a record.

---

## 3. TWO REPORTING DEFECTS, FOUND BY THE FIRST REAL DATA

Both are in `_org_report_period_data`'s `program_activities` block. Neither is
visible with the one activity live currently holds. Both appear the moment
BOPEU's nineteen rows exist.

### 3.1 · Planned work is reported as if it happened

```
reported total_activities, BOPEU Q3 : 8
actually DELIVERED in Q3            : 4
```

The block counts every activity in the window regardless of `state`. Four of
the eight are `planned` — including two the document itself still marks Planned
even though the date has passed. **HR's report would show work that has not
been done.**

### 3.2 · Psychosocial activities appear in HR's report

```
psychosocial rows appearing in HR's Q3 report : 4
```

M3's reporting split filtered the **bookings** read by `service_line =
'financial'`. It did not filter the **program_activities** read. So counselling
group sessions — with their titles, which name the topic — land in the
organisation report HR reads.

That is an **incomplete M3**, not a missing M2 feature. M3's stated scope
included the reporting split; I implemented it for one of the two tables it
needed to cover.

**Live exposure today: none.** Live holds one activity, `financial`, so nothing
is leaking now.

---

## 4. Why the seed is not applied to live

Applying it would create **nine psychosocial activities**, and **four of them
would appear in HR's Q3 report immediately** by §3.2.

So the order has to be:

1. Decide the third service line (§1.1), or confirm `financial` as the
   placeholder.
2. Fix §3.2 — filter `program_activities` by service line in the report.
3. Fix §3.1 — count delivered activities, not planned ones.
4. *Then* seed BOPEU.

Steps 2 and 3 are a small migration against a live function, so they get a
baseline and a written prediction first, like everything else.

---

## 5. What Task 1.4's regression can and cannot show

**BOPEU has two members.** On live, `org_report_data` returns
`insufficient_cohort` for every quarter of 2026 — before any of this. The
`sessions` block will not move when nineteen activities are added, because it
counts **bookings**, and because the base-5 cohort floor fires first.

So a no-change regression on `sessions` is **correct and proves nothing about
whether the activities landed**. The `program_activities` block is where they
show up — which is exactly where both defects live.

It also means **Lone cannot get a BOPEU report out of this system today**,
however complete the programme record is. If a BOPEU report is expected, that
is a conversation about the floor, not something more data fixes.
