# M5a — `ops_timeline()`

**Built 26 Aug 2026 on `dev`. A dependency of Prompt 3, split out rather than
smuggled into the page.**

> **25 assertions green on PostgreSQL 17.6. Not applied to Supabase.**
> One `SECURITY DEFINER` read behind the Tuesday review's *Since last Tuesday*
> and *Coming up* sections and the daily view's centre column.

Prompt 3 is a UI prompt, so new SQL in it needs saying out loud. This is why
it exists rather than the page reading three tables directly.

---

## 1. What was built

| File | Purpose |
|---|---|
| `supabase_m5a_ops_timeline.sql` | `_ops_as_date()`, `ops_timeline()`. Idempotent |
| `migrations/rollback-m5a-ops-timeline.sql` | Drops both. No table, no column, nothing to restore |
| `tests/m5a-fixture-extra.sql` | `bookings`, `program_activities`, `content_items` as M1 leaves them, loaded on top of `m5-fixture.sql` |
| `tests/m5a-tests.sql` | 25 assertions |
| `tests/run-m5a.sh` | Stacks M5 → M5a, then unwinds both |
| `tests/m5a-verify-live.sql` | Read-only before/after |

`ops_timeline(p_from date, p_to date) returns jsonb` — per organisation, the
bookings, activities and webinars in a window, each carrying its
`service_line`, practitioner, mode, format and state. Plus an `unassigned`
bucket. Gated by `is_staff()`. Depends on M1 (`service_line`) and M5
(`is_staff()`, `organizations.is_test`).

---

## 2. Why a function and not three page queries

**An advisor would otherwise see a smaller world, silently.**
`bookings_advisor_select` limits an advisor to their own bookings and their
caseload; `program_activities_admin_all` is admin-only. A practitioner opening
`ops.html` would get a partial timeline with nothing on the page to say so —
the worst kind of wrong, because it looks complete. One definer read gives
every staff member the same answer. Assertion 19 pins it.

**`bookings.requested_date` is `text`.** Date filtering belongs in SQL behind
a defensive cast, not in JavaScript against a column that can hold anything.
Live currently holds `'2099-12-31'` — valid, but a booking a lifetime away.

**Test organisations are excluded inside the function, not on the page.** A
caller cannot forget to filter, and the next surface that calls this inherits
the exclusion for free. Assertions 10–11.

---

## 3. `_ops_as_date` — the shape matters

A regex alone is not enough:

```sql
to_date('2026-13-45', 'YYYY-MM-DD')   -- 2027-02-14, silently
```

`to_date()` is lenient and **rolls invalid dates over** rather than refusing
them, so a typo would become a plausible-looking date sitting in the middle of
the Tuesday screen. Casting inside an exception block is the only version that
returns null for input that merely *looks* like a date:

```sql
if p_text is null or p_text !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
return p_text::date;
exception when others then return null;
```

Assertion 3 is the one that would fail on the regex-only version. When the
date is unusable the item falls back to `created_at::date` rather than
vanishing — a session with a mistyped date is still a session that happened.

---

## 4. The obligation this creates for M3

**`ops_timeline` is `SECURITY DEFINER`. It runs as `postgres` and bypasses
row-level security entirely.**

Today that is harmless: every booking is `service_line = 'financial'`, so
there is nothing any staff member should not see. **M3 changes that.** The
moment counselling bookings exist, the confidentiality boundary M3 builds into
the `bookings` *policies* does not apply here, because this function never
consults them. France would read every counselling booking through
`ops_timeline()` while the policy meant to stop him sits unused.

This is the same shape as the finding in
`00-live-schema-snapshot.md` §11 F6 — a boundary that looks enforced but is
routed around. There it was permissive policies ORing together; here it is a
definer function skipping them.

**M3 must therefore:**

1. Gate psychosocial rows **inside `ops_timeline()`**, using whichever
   mechanism it picks for the admin split (`admins.lines`, `ops_admins`, or
   `is_ops_admin()`).
2. Include this assertion, by name:
   **"a France-type admin calling `ops_timeline()` sees no psychosocial rows"**.

Assertion 17 exists to make the gap visible now rather than at M3: it asserts
that a psychosocial booking *is* currently returned to any staff member, and
its name says whose job that is. When M3 lands, that assertion should be
inverted, not deleted.

The same question applies to every definer RPC M3 does not personally rewrite.
`tuesday_review_pack` reads only `actions`, which carry no service line yet —
but M4 links actions to activities, and an action title can name a client. Worth
a second look at M3 time.

---

## 5. What the tests prove

`tests/run-m5a.sh` → 25 assertions, then unwind M5a and M5 in order.

| # | Group |
|---|---|
| 1–3 | The date cast: a real date parses; text returns null; **a date-shaped non-date returns null, not a rolled-over one** |
| 4–9 | A booking in the window appears, attributed through the member's profile; one outside does not; activities and webinars appear; a lesson never does; practitioner, mode and state come through |
| 10–12 | Nothing from a test organisation appears, of any kind; Test Co is not even listed; an inactive organisation is excluded |
| 13–15 | An unparseable date falls back to `created_at`; a month-13 date does too, rather than becoming 2027-02-14; a session with no organisation lands in `unassigned` rather than being lost |
| 16–17 | The service line carries through for the 9px marker; **a psychosocial row is currently visible to any staff member — M3's job** |
| 18–22 | An admin may call it; **an advisor gets the same answer, not their own slice**; a member is refused; an HR user is refused; an inverted window is refused |
| 23–24 | `_ops_as_date` is revoked from `anon` and `authenticated`; `ops_timeline` is callable and gated inside |
| 25 | An empty window returns organisations with empty item lists, not an error |

Access assertions run under `set role authenticated`, so RLS applies — the
pattern M5 established.

### One test that was proving nothing

Assertion 19 originally compared the advisor's `ops_timeline()` result against
`_tl`, a **view over `ops_timeline()`**. A view re-evaluates under the current
identity, so both sides of the comparison were the advisor's — it passed and
asserted nothing. It now compares against `_expected`, a table materialised
while the admin identity is set, and additionally pins the literal count at 6.

The failure mode is worth remembering: a helper view that wraps the function
under test cannot be the baseline for that function.

---

## 6. Deploy

Order: **M1 → M5 → M5a**. M5a will not apply without `is_staff()` and
`organizations.is_test`.

1. Run `tests/m5a-verify-live.sql`, save the output. V3 shows every distinct
   `requested_date` on live and what the cast makes of it — all currently
   parse; `2099-12-31` is valid, just distant.
2. Apply `supabase_m5a_ops_timeline.sql`.
3. Run the verification again. Expect: both functions present; `_ops_as_date`
   **not** reachable by `anon` or `authenticated`; `ops_timeline` reachable;
   V5 lists BOPEU and Sedimosa and **not Test Co**; V6 reports zero
   psychosocial rows.
4. If V5 shows Test Co, `is_test` was never set — run the M5 deploy note's
   update. The exclusion is inside the function, but it can only exclude what
   is flagged.

**Note on the verification script.** V4–V6 call a function gated by
`is_staff()`, and the SQL editor runs as `postgres` with no JWT, so
`is_staff()` is false and every call would raise `not authorised`. Each block
therefore sets `request.jwt.claims` with `set_config(..., true)` —
transaction-local, discarded at commit, writes nothing. That is exactly how
`auth.jwt()` reads identity on Supabase:

```sql
auth.jwt() = coalesce(nullif(current_setting('request.jwt.claim',  true),''),
                      nullif(current_setting('request.jwt.claims', true),''))::jsonb
```

Confirmed against live before writing the script.

---

## 7. What is NOT done

- **No psychosocial gate** (§4). Deliberate, and M3's job.
- **No work-plan link.** Once M4 exists, items should carry their
  `work_plan_activity_id` so the review can say "on the plan" versus "extra".
  Adding it now would be guessing at a column that does not exist.
- **No pagination or cap.** Three organisations and 22 bookings; a window
  returns tens of rows. This will need a cap long before it needs pagination,
  and neither yet.
- **`unassigned` covers sessions only** — activities and webinars require an
  `org_id`, so they cannot be unattributed.
- **No caching.** The page calls it twice per load. At this size that is
  cheaper than reasoning about staleness during a live meeting.
