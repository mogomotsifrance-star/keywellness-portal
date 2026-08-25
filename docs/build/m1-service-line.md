# M1 — service-line columns

**Built 25–26 Aug 2026 on `dev`. Prompt 1 of the operating-system pack.**
Migration M1 from `docs/data-model-and-impact.md` §2.3 and §4 — the first
schema change of the two-service-line build.

> **Not applied to Supabase. Not yet executed locally either** — this machine
> has no PostgreSQL and no Docker, so `tests/run-m1.sh` has never been run.
> See *Verification status* below before deploying. Everything that could be
> verified without a local server has been, against the live database,
> read-only.

---

## 1. What was built

| File | Purpose |
|---|---|
| `supabase_m1_service_line.sql` | The migration. Idempotent |
| `migrations/rollback-m1-service-line.sql` | Full reversal, zero leftover objects |
| `tests/m1-fixture.sql` | Local schema + seed, `bookings` built from the live snapshot |
| `tests/m1-tests.sql` | 22 assertions |
| `tests/run-m1.sh` | Harness: fixture → reporting stack → baseline → migrate ×2 → assert → roll back ×2 → verify clean |
| `tests/m1-verify-live.sql` | Read-only before/after for the SQL editor |
| `tests/run-phase0.sh` | Moved to PostgreSQL 17 |

**Schema change.** `service_line text not null default 'financial'` with a
`check (service_line in ('financial','psychosocial'))` on `bookings`,
`program_activities`, `org_reports` and `content_items`. `session_format text`
with a six-value check on `bookings`, backfilled to `'one_on_one'`. The mode
moves out of `session_type` into `session_mode`, normalised to
`physical`/`virtual`. `session_type` is not deleted.

No function is created, replaced or dropped. No policy, grant or revoke is
touched. Nothing writes `'psychosocial'` yet — that is M3.

---

## 2. Decisions

### 2.1 The harness moved to PostgreSQL 17, and now refuses to run on 16

Production is **17.6.1** (`00-live-schema-snapshot.md` §1). The harness
targeted 16, so every migration would have been validated on a different major
version from the one it lands on. `tests/run-phase0.sh` and `tests/run-m1.sh`
both now read `server_version_num` and **exit 1 below 17** rather than passing
quietly on the wrong engine. A comment would not have held; a guard does.

### 2.2 The session_mode backfill is recorded, because it is not reversible

Dropping a column reverses a column. It does not reverse an `UPDATE`. So the
migration writes every row it is about to change into `_m1_session_mode_backup`
(booking id + previous mode), and the rollback restores from it and drops the
table.

The obvious alternative — rollback by setting `session_mode = null where
session_type in ('In-Person','Virtual')` — is **wrong**, and live data proves
it: two Test Co `In-Person` rows already carry `session_mode = 'physical'`
legitimately, set before M1. Recomputing would destroy them. The backup table
is the only way the rollback can tell "M1 put this here" from "this was always
here".

### 2.3 `'Individual'` is a format, not a mode

`session_type` holds three values live: `In-Person`, `Virtual`, `Individual`.
The first two are modes and move. `Individual` is a format and carries no mode,
so those rows keep `session_mode` null unless they already had one — and two of
them did. Assertion 14 pins this.

### 2.4 The fixture does not mirror live, deliberately

Live is a poor regression bed: BOPEU has 2 members so every period returns
`insufficient_cohort`, and three of the four issued Test Co report periods
return it too. A before/after comparison over those is vacuous — null equals
null proves nothing.

The fixture therefore gives each organisation 8 members created well before the
earliest period, so every period computes real figures. What it **does** mirror
exactly is the shape M1 acts on: the live `session_type` × `session_mode`
distribution (12 In-Person/null, 6 Virtual/null, 2 In-Person/physical,
2 Individual/physical) and exactly one `attended = true` row on a `Virtual`
booking.

### 2.5 The live verification does not write, at all

An earlier draft of `m1-verify-live.sql` proved the CHECK constraints by
attempting a bad `UPDATE` and relying on a rollback. That was removed. A script
whose job is to verify production should not be the thing that risks a row.
Constraint rejection is proven locally instead — assertions 9, 10 and 8.

---

## 3. The one thing that changes: `mode_split`

**M1 changes the output of `org_report_data()`.** This is the finding of the
build and it needs to be understood before deploying.

`_org_report_period_data` builds `sessions.mode_split` from
`bookings.session_mode`:

```sql
mode_counts as (
  select session_mode, count(*) filter (where attended is true) as attended_cnt
  from period_bookings
  where session_mode is not null
  group by session_mode
)
```

Filling `session_mode` therefore changes what a **recomputed** report returns.
Measured by calling `_org_report_period_data()` against live data on 25 Aug
2026 — every affected period, before:

| Organisation | Period | `sessions.mode_split` before |
|---|---|---|
| Test Co | Q1 2026 (Jan–Mar) | *insufficient_cohort — no figures at all* |
| Test Co | Q3 2026 (Jul–Sep) | `{"physical": {value:null, suppressed:true}}` |
| Test Co | Q3 previous (Mar 31–Jun 30) | `{}` |
| Sedimosa | Q3 2026 (Jul–Sep) | `{}` |
| BOPEU | every period | *insufficient_cohort (2 members, floor is 5)* |

After, each `mode_split` gains the keys its rows now carry: Test Co Q3 gains
`virtual`, Test Co Mar–Jun gains `physical`, Sedimosa Q3 gains both.

**Every one of those cells is withheld.** `mode_counts` counts only
`attended is true`; the entire database holds exactly **one** such booking
(Test Co, Virtual, created 2026-07-22); and `_suppress_count` withholds
anything below 3. So no cell anywhere acquires a number.

`total_booked`, `total_attended`, `monthly_trend` and
`attendance_confirmation_coverage_pct` do not read `session_mode` and are
byte-identical throughout.

**No issued report changes.** The one published report (Test Co Q3) was frozen
into `org_reports.data_snapshot` by `publish_org_report()`, and
`org_reports_hr_read` serves HR the snapshot. The other three are drafts.

### Why the tests do not assert byte-equality

Prompt 1 asks for "identical figures before and after". That holds for
**figures** and not for **bytes**, and the difference is worth stating plainly
rather than papering over: filling `session_mode` is what M1 is *for*, and
`mode_split` reads `session_mode`, so it moves by design. Asserting byte
equality would either fail honestly or force the test to be weakened somewhere
less visible.

So assertions 19–21 say exactly what is true, and nothing looser:

- **19** — everything outside `sessions.mode_split` is byte-identical.
- **20** — `mode_split` only ever *gains* keys; no existing key is removed or has its value changed.
- **21** — every gained key is `suppressed: true`, i.e. carries no number.

---

## 4. What the tests prove

`tests/run-m1.sh` → 22 assertions.

| # | Assertion |
|---|---|
| 1–4 | `service_line` reads `'financial'` on every row of all four tables |
| 5 | The column is NOT NULL and defaulted `'financial'` on all four |
| 6 | Every existing booking backfilled to `one_on_one` |
| 7 | `session_format` stays nullable |
| 8 | The check accepts all six listed formats (each probed, each rolled back) |
| 9–10 | The `service_line` and `session_format` checks reject a bad value |
| 11 | No `In-Person`/`Virtual` row still has a null mode |
| 12–13 | `In-Person` → `physical`, `Virtual` → `virtual` |
| 14 | `Individual` rows keep exactly the modes they arrived with |
| 15 | `session_type` still exists and still holds its values |
| 16 | `points_events` did not grow — the trigger did not fire |
| 17 | `attended` true/false/null counts unchanged |
| 18 | No booking gained or lost |
| 19–21 | The `mode_split` regression check above |
| 22 | Re-running the migration did not double the backup table |

The harness then rolls back twice and asserts: zero leftover objects;
`session_mode` restored to 18 null / 4 physical / 0 virtual; and
`org_report_data()` byte-identical to the pre-migration baseline again.

### The trigger, and why it cannot fire

`bookings` carries `trg_award_session_attended` AFTER UPDATE, and M1 issues two
UPDATEs. Its body is guarded:

```sql
if new.attended is true and (old.attended is distinct from true) and new.user_id is not null
```

Neither UPDATE writes `attended`, so `new.attended = old.attended` and the
guard is unsatisfiable: if `attended` was already true the second clause is
false, and otherwise the first is. `points_events` also has
`UNIQUE (user_id, event_type, ref_id)` as a second line of defence. Assertion
16 and live block V4 both pin the count anyway.

---

## 5. Verification status — read before deploying

**Executed and passing:**

- `tests/m1-verify-live.sql` blocks **V1–V5**, run read-only against the live
  project through the Supabase MCP connection. V1 had a real bug on the first
  attempt — `select count(*) from _m1_session_mode_backup` inside a `CASE`
  fails before M1 is applied, because PostgreSQL resolves relation names at
  parse time, not when it evaluates the branch. Fixed (the count moved to V6,
  which reaches it through `EXECUTE`) and re-run clean.
- The before-figures in §3, captured by calling the real
  `_org_report_period_data()` on live data.
- Live baseline counts: `bookings` 22, `points_events` 177 (1 of type
  `session_attended`), `attended` 1 true / 1 false / 20 null,
  `session_type × session_mode` = 12 In-Person/null, 6 Virtual/null,
  2 In-Person/physical, 2 Individual/physical → **18 rows to normalise**.

**NOT executed:**

- `tests/run-m1.sh` and all 22 assertions.
- `tests/run-phase0.sh` on 17 — Prompt 1 asks for the existing phase0/phase1
  suites to be re-run on 17 and the result recorded. That has not happened.

**Why:** this machine has neither PostgreSQL nor Docker. The SQL harness has
never been runnable in this environment; `run-phase0.sh` has only ever been run
elsewhere. Shipping SQL that has not been executed is exactly what the
migration discipline exists to prevent, so **this is a gap, not a formality.**

**To close it,** one of:

1. Install PostgreSQL 17 locally, then `tests/run-m1.sh` and
   `tests/run-phase0.sh`. Cleanest, and it makes the discipline real for every
   later migration.
2. Run it in CI, or on any machine that already has 17.
3. A Supabase branch — a real PG17 copy — then delete it. Costs money and
   needs explicit approval; it is also the only option that tests against the
   real schema rather than a fixture.

Until then, treat every assertion in §4 as *written but unproven*.

---

## 6. What is NOT done

- **`session_type` is not retired.** `index.html`'s booking form and
  `advisor_book_session()` still write it; the column keeps its values.
  Retiring it touches three files and is its own change
  (`docs/data-model-and-impact.md` §5.5).
- **Nothing writes `'psychosocial'`.** M1 only makes the column exist.
- **No reporting RPC takes `p_service_line`.** That is M2, and it must land
  before any psychosocial row reaches a report, or a financial report will
  silently count counselling sessions.
- **`bookings.activity_id`, `counsellor_id`, `counsellor_client_id`** are not
  added here — M4 and M3 respectively.
- **`org_reports.due_date`** (`§2.1`, "the states become due → draft → review →
  published") is not added. M1 adds only `service_line` to that table.
- **`content_items.presenter`, `attendee_count`, `topic_id`** are not added —
  they belong with the webinar work in M6.
- `_m1_session_mode_backup` is left in place after apply, by design: it is what
  makes the rollback honest. Drop it once M1 is settled.

---

## 7. Deploy order

1. **Close the verification gap first** (§5). Do not apply on the strength of
   unexecuted tests.
2. Run `tests/m1-verify-live.sql` in the SQL editor. **Save the output** —
   V3 is the before-figures the after-run is diffed against.
3. Apply `supabase_m1_service_line.sql` in the SQL editor. It ends with a
   `raise notice` naming how many rows were normalised; expect **18**.
4. Run `tests/m1-verify-live.sql` again. Diff against step 2:
   - V2: no `In-Person`/`Virtual` row on a null mode; per-pair row counts unchanged.
   - V3: `mode_split` gains keys, all withheld; every other figure identical.
   - V4, V5: identical.
   - V6: every line `OK`, except `Individual rows carry no mode`, which
     reports `CHECK` — the two pre-existing `Individual`/`physical` rows are
     expected and correct.
5. If anything else moved, apply `migrations/rollback-m1-service-line.sql` and
   stop.

No front-end change ships with M1. No page reads `service_line` or
`session_format` yet.
