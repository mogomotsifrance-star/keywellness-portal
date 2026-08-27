# M1 — service-line columns

**Built 25–26 Aug 2026 on `dev`. Prompt 1 of the operating-system pack.**
Migration M1 from `docs/data-model-and-impact.md` §2.3 and §4 — the first
schema change of the two-service-line build.

> **Tests green on PostgreSQL 17.6 — the same minor as production.
> Not applied to Supabase.** Phase 0, Phase 0a, Phase 1 and M1's 22 assertions
> all pass locally, and the rollback restores the reporting figures
> byte-for-byte. §5 has the run, the three bugs it exposed, and the deploy
> steps.

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

### 2.4 The fixture is a reconstruction, not a copy of production

**Stated plainly because it bounds what these tests prove.**
`tests/m1-fixture.sql` is a hand-written stand-in: 12 tables of the 38 that
exist live, and only the columns the reporting path under test actually reads.
`profiles` carries 12 of its 45 live columns; the others are irrelevant to M1.
Table definitions and constraints are transcribed from
`docs/build/00-live-schema-snapshot.md`, which is itself a point-in-time
reading of 25 Aug 2026. **If live drifts, the fixture does not follow.**

It also does not mirror live *data*, deliberately. Live is a poor regression
bed: BOPEU has 2 members so every period returns `insufficient_cohort`, and
three of the four issued Test Co report periods return it too. A before/after
comparison over those is vacuous — null equals null proves nothing. The fixture
therefore gives each organisation 8 members created well before the earliest
period, so every period computes real figures and assertions 19–21 have
something to bite on.

What it **does** mirror exactly is the shape M1 acts on: the live
`session_type` × `session_mode` distribution (12 In-Person/null, 6
Virtual/null, 2 In-Person/physical, 2 Individual/physical) and exactly one
`attended = true` row on a `Virtual` booking.

**What that means for confidence.** A green local run proves the migration's
logic, its idempotency, and that the rollback is complete and lossless. It does
**not** prove the migration meets the real schema — nothing local can, because
the fixture is the thing being trusted. `tests/m1-verify-live.sql` closes that
gap at deploy time by diffing the real database before against after.

**Testing against a real schema copy** — a Supabase branch — was considered and
**deferred to M3** (see §5).

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

### The accepted criterion

**Decision (Tshenolo, 26 Aug 2026): the `mode_split` handling and assertions
19–21 are the acceptance criterion for M1, in place of "identical figures".**
Prompt 1's wording stands for everything else; where it and assertions 19–21
differ, 19–21 govern. Any later change that moves a reporting figure must be
measured and stated the same way rather than assumed benign.

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

## 5. Verification status — green on PostgreSQL 17.6

### The environment

PostgreSQL **17.6** — the same minor as production — installed locally on
26 Aug 2026 as portable binaries: no installer, no admin rights, nothing added
to PATH, the registry or Windows services.

| | |
|---|---|
| Binaries | `C:\Users\Tshenolo M\pgsql17\pgsql\bin` (EDB zip, 17.6-1 win-x64) |
| Cluster | `C:\Users\Tshenolo M\pgdata17` — trust auth, superuser `postgres`, UTF8 |
| Listening | `127.0.0.1:5433` |
| Installer zip | `C:\Users\Tshenolo M\pg17dl\pg17.zip` — deletable |

Start it, then run both suites:

```bash
export PATH="/c/Users/Tshenolo M/pgsql17/pgsql/bin:$PATH"
pg_ctl -D "C:/Users/Tshenolo M/pgdata17" -o "-p 5433 -h 127.0.0.1" -l "C:/Users/Tshenolo M/pgdata17/pg.log" start
PGUSER=postgres bash tests/run-phase0.sh 127.0.0.1 5433
PGUSER=postgres bash tests/run-m1.sh     127.0.0.1 5433
```

To remove it entirely: stop the server, delete those three directories.

### Results — 26 Aug 2026

```
tests/run-phase0.sh                    tests/run-m1.sh
  server version    ok (PG 17)           server version    ok (PostgreSQL 17)
  fixture           ok                   fixture           ok
  migration         ok                   reporting stack   ok (org_report_data v4)
  migration re-run  ok (idempotent)      baseline captured ok (9 payloads)
  All Phase 0 tests passed.               migration         ok
  phase 0a          ok                   migration re-run  ok (idempotent)
  phase 0a re-run   ok (idempotent)        22 passed, 0 failed.
  All Phase 0a tests passed.              rollback          ok
  phase 1           ok                   rollback re-run   ok (idempotent)
  phase 1 re-run    ok (idempotent)      rollback clean    ok (zero leftover)
  All Phase 1 tests passed.               session_mode      ok (restored, 4 kept)
  rollback          ok                   report after r/b  ok (byte-identical)
  rollback re-run   ok (idempotent)
  rollback clean    ok (zero leftover)
```

Phase 0's 47 assertions, Phase 0a, Phase 1's 37 and M1's 22 — all green on the
engine production actually runs.

### Three bugs the run exposed

None would have been found by reading the SQL.

**1. Phase 0 and 0a failed on 17 — for an encoding reason, not a logic one.**
Assertions `8b` and `9h` compare `kw_unit_label()` against
`'Head Office Co — Gaborone'`. Both failed, and because the harness runs with
`ON_ERROR_STOP=1`, phase 0 and 0a **aborted** at that point — the suites had
not completed at all. An earlier reading of only the tail of the output missed
this and reported them as passing; they were not.

The stored label came back as `Head Office Co â€" Gaborone`: the UTF-8 em dash
`E2 80 94` read as Windows-1252 and re-encoded. psql on Windows can take
`client_encoding` from the console codepage, and every `.sql` file in this repo
is UTF-8. Both harnesses now carry
`export PGCLIENTENCODING="${PGCLIENTENCODING:-UTF8}"`, after which all three
phase suites pass with nothing set by the caller.

Two further Windows fixes went in alongside: `$USER` is empty in Git Bash and
an empty `-U` swallows the next argument, so `PGUSER` now falls back to
`whoami`; and the headers document the TCP recipe, because Windows builds have
no Unix sockets.

*A false lead worth recording.* A grep for `\x97` reported a "CP1252 em dash"
in seven repo SQL files. That byte is the second half of UTF-8 `×` (`C3 97`).
The files were always fine — the grep was wrong, not the repo.

**2. Assertion 19 was under-specified, and only running it showed that.**
It failed on Sedimosa/Q3. `org_report_data` returns
`v_current || {previous_period: v_previous}`, so `sessions.mode_split` appears
**twice** — once for the current period and once inside `previous_period`.
Assertion 19 stripped only the first, so the previous period's `mode_split`
change registered as a difference *outside* `mode_split`.

Verified before changing anything: with both paths excluded the two payloads
are identical, and the previous-period `mode_split` went `{}` →
`{"physical": {"value": null, "suppressed": true}}` — a withheld key, exactly
as §3 describes. Assertions 19, 20 and 21 now cover both occurrences.

This **tightened** the criterion rather than loosening it: 20 and 21 previously
did not examine the previous-period half at all, so two of the four affected
`mode_split` cells were going unchecked.

**3. A fixture gap.** `_org_report_period_data` reads
`profiles.live_cat_scores` and `profiles.live_score_at`; the first draft of the
fixture had neither. Caught immediately by `ON_ERROR_STOP`, fixed by adding the
six `profiles` columns the reporting path reads.

### The Supabase-branch question — deferred to M3

A Supabase branch is an ephemeral copy of the **real** schema, which is the one
thing a local fixture cannot be (§2.4). It was not needed here: M1 is additive,
touches no function or policy, and its single behavioural consequence was
measured directly against live, read-only.

**M3 is a different proposition.** It rewrites the `bookings` RLS policies and
carries the confidentiality boundary — France must not see who booked
counselling — and permissive policies OR together, so the property under test
is the *union* of nine live policies. A hand-written reconstruction of those
nine is exactly the kind of artefact that can be subtly wrong in the direction
of passing.

**Decision: revisit the branch at M3, and budget for it.** Not needed for M1,
M5 or M4.

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
