# M3 — counsellors and the confidentiality boundary

**Plan only. No SQL written, nothing applied. Revised 27 Aug 2026.**

M3 goes to a **Supabase branch first**, per the standing rule: rollback does not
undo a disclosure. The role × line × command matrix (§6) gets reported as a
plain-language table and merged only once that table is approved.

> **Revision, 27 Aug.** There is **no Clinical Lead role, permanently, by
> design.** Karabo and Nicola do not share notes or case files with each other
> unless one deliberately refers a case to the other. Every use of
> `is_clinical_lead()` is **removed, not defaulted** — see §3.

---

## 1. What this is for, in one paragraph

Key Wellness is adding counselling alongside financial advice. A counselling
booking is a different kind of fact from a budget session: it says something
about a person that they told **one** practitioner in confidence. M3 makes the
database enforce that — not the screens, not a convention, the database — so
that a person who should not see it **cannot**, whatever role they hold and
whatever page they open. Including the other counsellor.

---

## 2. The finding that changes the shape of this migration

The prompt scopes M3 as a `bookings` policy rewrite plus the same treatment for
other admin-ALL policies. That is necessary. **It is nowhere near sufficient**:

> **Almost nothing reads `bookings` through its policies.**

**Fifteen `SECURITY DEFINER` functions that any signed-in user may call read
`bookings` or `program_activities`.** A `SECURITY DEFINER` function runs as the
database owner and **never consults row-level security at all**. Three were
already recorded as owed; the other twelve were not.

| Function | Gated on | Why it leaks |
|---|---|---|
| `advisor_clients_list` | team lead, advisor | The **financial team lead** reads every client and their sessions |
| `advisor_client_detail` | team lead, advisor | Same, per client, including session history |
| `advisor_pending_responses` | team lead, advisor | Same, across the caseload |
| `admin_advisor_roster` | admin, team lead | Booking counts per advisor |
| `advisor_session_breakdown` | admin, **HR** | Aggregates sessions — folds counselling into HR-facing numbers |
| `session_source_trend` | admin, **HR** | Same |
| `booking_notify_payload` | admin | Returns a booking's member and address |
| `ops_timeline` | staff | Every session in a date window |
| `org_work_plan`, `contract_position` | staff | Every activity for an organisation |
| `activity_upsert` | admin | Writes activities of any line |

**So "the financial team lead cannot read a psychosocial booking" fails through
`advisor_clients_list` even if the policies are flawless.** That is the
difference between M3 being a policy rewrite and M3 being a policy rewrite plus
a systematic sweep.

Two more that need a decision rather than a fix:

- **`award_points` and `member_respond_booking` have no gate at all.** Written
  to act on the caller's own booking, so probably safe by construction — but
  "probably safe by construction" is the phrase that precedes an incident.
- **`_org_report_period_data`** feeds the reports HR reads. See §8.1.

---

## 3. There is no Clinical Lead, and nothing is left dormant

**Removed from this plan entirely — not built, not defaulted to false:**

- `is_clinical_lead()`
- `counsellors.is_clinical_lead`
- the clinical-lead read clause on `counselling_notes`
- the clinical-lead disjunct on the psychosocial `bookings` branch

The reason to delete rather than ship-and-disable: **a permission nobody uses is
a bug waiting to be flipped without anyone re-deriving why it existed.** A
dormant `is_clinical_lead` column reads, to whoever finds it in two years, like
a feature that was half-finished — not like a boundary someone decided against
on purpose. The absence has to be legible in the schema itself.

What this means concretely: **there is no read path, anywhere, by which one
counsellor sees another's notes or bookings.** Not an admin path, not a lead
path, not a break-glass path. §4 is the only sanctioned way a case moves
between them, and it moves by the referring counsellor **writing something
new**, never by granting sight of what they already wrote.

---

## 4. `counselling_referrals` — the only path between counsellors

```
counselling_referrals
  id
  counsellor_client_id
  from_counsellor_id
  to_counsellor_id
  note          text   -- freshly authored handover content
  created_at
  accepted_at   nullable
```

**RLS:** insert by `from_counsellor` only; select by `from_counsellor` and
`to_counsellor`. Nobody else — no admin policy.

**The `note` is a new object the referring counsellor writes on purpose for the
handover. It is never a copy of, and never a pointer into, their existing
`counselling_notes` rows.** Those stay theirs, permanently, referral or not.

This distinction is the whole design and is easy to erode later, so it is worth
stating why: a referral that granted access to the original notes would make
the notes' author-only policy conditional on a row in another table, and the
boundary would then be only as strong as whoever can write that row. Making the
handover a **separately authored artefact** means the referring counsellor
decides, sentence by sentence, what crosses — which is what a clinical handover
is in the first place.

### Stopping here, deliberately

**I am not designing the accept flow until two things are decided**, because
both change the table's shape and one changes who can see what:

**4a · Does admin need to know a referral happened?** Lone reassigns future
bookings, so she plausibly needs to know a case moved. If yes: **the fact of
it, or the note content too?** My recommendation is **the fact only** — that
Karabo referred this client to Nicola on a date — with the note staying between
the two counsellors. That gives Lone everything she needs to route bookings and
nothing she needs to be trusted with. But it means a third read path on this
table, and I would rather you chose it than inherited it.

**4b · Does accepting a referral reassign `counsellor_clients` to the new
counsellor going forward, or do both retain a standing link?** A reassignment
is cleaner and matches "this is Nicola's client now". A standing link matches
"Karabo may still need to close things out". They differ in what happens to the
next booking that arrives, and in whether Karabo keeps reading new bookings for
that client — which is a confidentiality question, not a workflow one.

---

## 5. What gets built

**Tables**

- `counsellors` — `user_id`, `email`, `full_name`, `is_active`.
  **No `is_clinical_lead`.**
- `counsellor_clients` — the caseload, mirroring `advisor_clients`.
- `counselling_notes` — **author-only, no exception, ever.**
- `counselling_referrals` — §4.
- `theme_taxonomy` — seeded: work stress, relationships and family,
  bereavement, financial stress, substance use, trauma, other. A table, not a
  check constraint, because counsellors will revise it.
- `session_themes` — `booking_id`, `theme_key`.

**Columns on `bookings`**

- `counsellor_id`, `counsellor_client_id`, and a constraint that **at most one
  of `advisor_id` / `counsellor_id`** is set. A session has one practitioner.

**Functions**

- `is_counsellor()`, `current_counsellor_id()`. **No `is_clinical_lead()`.**

### The psychosocial branch, as it will read

```
(service_line = 'psychosocial' and counsellor_id = current_counsellor_id())
or is_psychosocial_admin()
```

A counsellor reads **only their own** bookings. `is_psychosocial_admin()`
already covers Lone and Michelle at the top level and is unaffected.

### `counselling_notes`, as it will read

Author only. No admin policy, no lead policy, no carve-out. An admin who needs
a note asks the author — which is the correct social process, not a gap.

---

## 6. The before/after matrix

Can this person SELECT a row of this line? **Karabo and Nicola are both listed,
because "a counsellor" as a single row hides the case this revision is about.**

| | Financial booking | Karabo's psychosocial booking | Nicola's psychosocial booking |
|---|---|---|---|
| **Member — own row** | yes → **yes** | yes → **yes** | yes → **yes** |
| **Member — another's** | no → **no** | no → **no** | no → **no** |
| **Advisor — booking is theirs** | yes → **yes** | n/a → **no** | n/a → **no** |
| **Advisor — client on caseload** | yes → **yes** | n/a → **no** | n/a → **no** |
| **Advisor — unrelated** | no → **no** | no → **no** | no → **no** |
| **Financial team lead** | yes (all) → **yes (all)** | yes (all) → **NO** | yes (all) → **NO** |
| **Karabo (counsellor)** | n/a → **no** | n/a → **YES** | n/a → **NO** |
| **Nicola (counsellor)** | n/a → **no** | n/a → **NO** | n/a → **YES** |
| **Lone / Michelle** | yes → **yes** | yes → **yes** | yes → **yes** |
| **France (admin)** | yes → **yes** | yes → **NO** | yes → **NO** |
| **Tshenolo (admin)** | yes → **yes** | yes → **NO** | yes → **NO** |
| **HR** | no → **no** | no → **no** | no → **no** |

**Notes** — a separate and stricter table:

| | Karabo's note | Nicola's note |
|---|---|---|
| **Karabo** | **yes** | **no** |
| **Nicola** | **no** | **yes** |
| **Lone / Michelle** | **no** | **no** |
| **France / Tshenolo / HR / advisors** | **no** | **no** |

Note the asymmetry, which is deliberate: **Lone and Michelle read psychosocial
bookings but not notes.** They need to know a session happened, to schedule and
to bill. They do not need to know what was said.

Write access follows the booking shape: a counsellor writes their own
psychosocial rows, an advisor their own financial rows, a psychosocial admin
both, an ordinary admin financial only.

---

## 7. The `bookings` policies as they stand today

Nine policies, read from live — the repo's inventory is a comment, and
`supabase_cleanup_policies.sql` **was never applied**, which live confirms.

| Policy | Cmd | Predicate |
|---|---|---|
| `bookings_admin` | ALL | `auth.jwt()->>'email' IN (SELECT email FROM admins)` |
| `bookings_admin_all` | ALL | `is_admin()` |
| `bookings_own` | ALL | `user_id = auth.uid()` |
| `bookings_self` | ALL | `auth.uid() = user_id` |
| `bookings_advisor_select` | SELECT | own rows **OR `is_team_lead()`** OR caseload |
| `bookings_advisor_insert` | INSERT | own rows |
| `bookings_advisor_update` | UPDATE | own rows |
| `bookings_lead_update` | UPDATE | `is_team_lead()` |
| `bookings_member_respond` | UPDATE | own member rows |

Three defects:

1. **`bookings_admin` compares email without lowering it**, and grants ALL
   commands. A silent authorisation bug, not cosmetic. Fixed as it is replaced.
2. **`bookings_self` is an exact duplicate of `bookings_own`.** Dropped.
3. **`is_team_lead()` inside `bookings_advisor_select` grants the team lead
   every booking in the system** — the widest read on the table.

PostgreSQL **ORs** permissive policies, so dropping any one changes nothing
while the others stand. They are replaced **in one transaction**.

---

## 8. Scope, in the order agreed

1. **`bookings` policies** (§7)
2. **The definer-function sweep** (§2) — line-gate roughly a dozen functions
3. **The reporting split** (§8.1)
4. **The M4/M5 staff tables** (§8.2)
5. **The counsellor tables last**

**One dependency forces a single exception to that order:** `counsellors` and
`current_counsellor_id()` must exist before the `bookings` policies can name
them. So those two land first as bare scaffolding; everything else
counsellor-facing — notes, themes, referrals, taxonomy — comes last as agreed.

**8.1 · Reporting.** `_org_report_period_data` counts `bookings`. The day a
counselling booking exists it is counted in the totals HR reads, silently.
**Split by line**, with psychosocial exposed only through the
base-5-floored aggregate. Confirmed in scope.

**8.2 · The M4 and M5 tables.** `work_plans`, `org_contracts`, `org_contacts`,
`contract_rates`, `actions` and `meetings` are readable by `is_staff()` —
*every advisor*. Once a work plan carries counselling activities, a financial
advisor reads them.

> **A new question this revision surfaces.** M5 was written expecting
> `is_staff()` to gain `or is_counsellor()`. If it does, the leak runs **both
> ways**: counsellors would read `org_contracts`, `contract_rates` and
> `billing_handovers` — every client's commercial terms.
>
> **Recommendation:** counsellors join `is_staff()` (they are staff; they
> attend Tuesday; they need `meetings`, `actions` and `ops_timeline`), **but
> the commercial tables move off `is_staff()` onto `is_admin()`.** A counsellor
> has no business reading what a client pays. Flagged rather than assumed —
> it changes who reads four tables.

---

## 9. The second requirement, which is the one that gets skipped

- **(a) France cannot read psychosocial bookings or counselling notes.**
- **(b) France's ordinary admin access is unchanged everywhere else.**

(b) gets skipped because **a migration that locks everything down passes (a)
perfectly.** The matrix must prove he still sees what he sees today outside
psychosocial, measured against real counts — not against "returns without
error". `tests/m4a-tests.sql` assertions 18a–22 are the baseline, taken before
M3 moves anything.

---

## 10. Risk flags — unchanged by this revision

A flag creates an **action for Lone** saying a flag exists on a psychosocial
case, **with no content and no name**. It was already routed to Lone and never
to a clinical lead, so removing that role changes nothing here.

**Not built in M3.** Recorded as the interim.

---

## 11. `kw_unit_label(uuid)` and the anon sweep

Confirmed on live: **`SECURITY DEFINER`, callable by `anon`**, reading
`org_units`. **Revoke `anon` across the definer set**, with a **before/after
grant listing** so the change is visible rather than asserted.

---

## 12. What the tests must prove

Each a **separate assertion** — they fail separately.

**The counsellor boundary — the case this revision is about**

1. **A counsellor cannot read another counsellor's booking**, with **two seeded
   counsellors, Karabo and Nicola**, on the branch. Both directions.
2. **Nobody but a note's own author ever reads it**, tested **explicitly
   against the second counsellor** — not just against France. France failing to
   read a note proves almost nothing; Nicola failing to read Karabo's note is
   what actually exercises this change.
3. A counsellor cannot read a financial booking.
4. **No object named `is_clinical_lead` exists** — not a function, not a
   column. Asserted, so it cannot quietly return.

**The admin and lead boundary**

5. The financial team lead cannot read a psychosocial booking — **through the
   policies, and through `advisor_clients_list`, `advisor_client_detail` and
   `advisor_pending_responses` separately.** Four assertions, not one.
6. A Lone-type admin reads both lines' bookings — **and no notes.**
7. A France-type admin reads financial only — **and, separately, still reads
   everything else he reads today** (§9).
8. HR reads neither line directly.
9. HR's report numbers do not silently gain counselling sessions (§8.1).

**The rest**

10. The theme RPC withholds below five, always, with no internal bypass.
11. `ops_timeline`, `org_work_plan` and `contract_position` return no
    psychosocial rows to a France-type admin — the three recorded obligations,
    in their recorded wording.
12. Every other definer function in §2 gets its own assertion.
13. A referral's note is readable by the two counsellors named on it and nobody
    else; **and reading a referral grants no access to the referring
    counsellor's `counselling_notes`.**
14. `bookings` ends with the expected policy count and no duplicate.
15. The un-lowered email comparison is gone.
16. The anon grant listing is empty afterwards (§11).

---

## 13. How it reaches live

1. Apply on a **Supabase branch**, seeding **Karabo and Nicola**.
2. Run the full role × line × command matrix there.
3. Report it as a **plain-language table** — "France, psychosocial, SELECT:
   0 rows (was: all rows)" — never as SQL.
4. Merge only on approval.

---

## 14. Open before DDL

**14a · Does admin need to know a referral happened — the fact, or the note
too?** (§4a. Recommend: the fact only.)

**14b · Does accepting a referral reassign `counsellor_clients`, or do both
counsellors retain a standing link?** (§4b.)

**14c · Do counsellors join `is_staff()`, and do the commercial tables move to
`is_admin()`?** (§8.2. Recommend: yes and yes.)

Settled and not reopened: widened scope in the order at §8, reporting split by
line, no risk-flag build, Karabo and Nicola seeded on the branch, anon revoked
across the definer set with a before/after listing.
