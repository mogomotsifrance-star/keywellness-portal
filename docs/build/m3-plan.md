# M3 — counsellors and the confidentiality boundary

**Plan only. No SQL written, nothing applied. 27 Aug 2026.**

M3 goes to a **Supabase branch first**, per the standing rule: rollback does not
undo a disclosure. The role × line × command matrix gets reported as a
plain-language table and merged only once that table is approved.

---

## 1. What this is for, in one paragraph

Key Wellness is adding counselling alongside financial advice. A counselling
booking is a different kind of fact from a budget session: it says something
about a person that they told one practitioner in confidence. M3 makes the
database enforce that — not the screens, not a convention, the database — so
that a person who should not see who booked counselling **cannot**, whatever
role they hold and whatever page they open.

---

## 2. The finding that changes the shape of this migration

The prompt says to rewrite the `bookings` policies and to give the same
treatment to "every other admin-ALL policy that could leak a psychosocial row".
That is necessary. **It is nowhere near sufficient**, and the reason is worth
stating plainly before anything else:

> **Almost nothing reads `bookings` through its policies.**

I counted what actually reaches those two tables on the live database.
**Fifteen `SECURITY DEFINER` functions that any signed-in user may call read
`bookings` or `program_activities`.** A `SECURITY DEFINER` function runs as the
database owner and **never consults row-level security at all**. So a perfect
set of policies on `bookings` would leave every one of these wide open.

Three were already recorded as owed (`ops_timeline`, `org_work_plan`,
`contract_position`). The other twelve were not. The ones that matter most:

| Function | Gated on | Why it leaks |
|---|---|---|
| `advisor_clients_list` | team lead, advisor | The **financial team lead** reads every client and their sessions |
| `advisor_client_detail` | team lead, advisor | Same, per client, including session history |
| `advisor_pending_responses` | team lead, advisor | Same, across the whole caseload |
| `admin_advisor_roster` | admin, team lead | Booking counts per advisor |
| `advisor_session_breakdown` | admin, **HR** | Aggregates sessions — would fold counselling into HR-facing numbers |
| `session_source_trend` | admin, **HR** | Same |
| `booking_notify_payload` | admin | Returns a booking's member and address |
| `ops_timeline` | staff | Every session in a date window |
| `org_work_plan`, `contract_position` | staff | Every activity for an organisation |
| `activity_upsert` | admin | Writes activities of any line |

**So the required assertion "the financial team lead cannot read a psychosocial
booking" fails through `advisor_clients_list` even if the policies are
flawless.** That single fact is the difference between M3 being a policy
rewrite and M3 being a policy rewrite *plus a systematic sweep of every
definer function that touches these tables*.

Two more that need a decision rather than a fix:

- **`award_points` and `member_respond_booking` have no gate at all.** They are
  written to act on the caller's own booking, so they are probably safe by
  construction — but "probably safe by construction" is exactly the phrase that
  precedes an incident, and M3 should prove it rather than assume it.
- **`_org_report_period_data`** feeds the organisation reports HR reads. If
  counselling sessions land in `bookings`, they will be counted in HR's session
  totals unless the reporting functions split by line. See §8.

---

## 3. The mechanism — already decided, and why

The prompt asks me to propose an admin-split mechanism and recommend one.
**That decision is already made and shipped in M4a**, so this is a record of
the reasoning rather than an open question:

**`is_psychosocial_admin()` — membership of `psychosocial_admins`, holding Lone
and Michelle.**

| Option | Why not |
|---|---|
| `admins.lines` column | Keys off the same row that grants ordinary admin. Editing one thing changes two, and CLAUDE.md's rule is that roles are table membership, not a column. |
| Split `is_admin()` itself | Would change what "admin" means everywhere at once — including the fourteen places that have nothing to do with counselling. That is the conflation M4a just finished undoing. |
| **Separate membership table** | **Chosen.** A person can hold it without holding admin, and hold admin without holding it. The boundary does not move when a role does. |

Deliberately **not** `is_admin() and is_member_of(...)`: a confidentiality
boundary defined as a subset of a role is one role change away from leaking.

**France holds admin and is not a member — that is the whole point.** He keeps
every other admin capability. See §9 for the second requirement that protects
that.

---

## 4. What gets built

**Tables**

- `counsellors` — `user_id`, `email`, `full_name`, `is_active`,
  `is_clinical_lead`. **Nobody is clinical lead**; the column exists so the
  notes policy can name it, and stays false for everyone.
- `counsellor_clients` — the caseload, mirroring `advisor_clients`.
- `counselling_notes` — author-only. No admin policy at all.
- `theme_taxonomy` — seeded: work stress, relationships and family,
  bereavement, financial stress, substance use, trauma, other. Counsellors
  will revise it, so it is a table and not a check constraint.
- `session_themes` — `booking_id`, `theme_key`.

**Columns on `bookings`**

- `counsellor_id`, `counsellor_client_id`, and a constraint that **at most one
  of `advisor_id` / `counsellor_id`** is set. A session has one practitioner.

**Functions**

- `is_counsellor()`, `current_counsellor_id()`, `is_clinical_lead()`.
- `is_staff()` gains `or is_counsellor()` — the one line M5 was written to
  leave room for.

---

## 5. The `bookings` policies as they stand today

Nine policies. Read from the live database, not from the repo — the repo's
inventory is a comment, and `supabase_cleanup_policies.sql` **was never
applied**, which the live state confirms.

| Policy | Cmd | Predicate |
|---|---|---|
| `bookings_admin` | ALL | `auth.jwt()->>'email' IN (SELECT email FROM admins)` |
| `bookings_admin_all` | ALL | `is_admin()` |
| `bookings_own` | ALL | `user_id = auth.uid()` |
| `bookings_self` | ALL | `auth.uid() = user_id` |
| `bookings_advisor_select` | SELECT | own advisor rows **OR `is_team_lead()`** OR caseload |
| `bookings_advisor_insert` | INSERT | own advisor rows |
| `bookings_advisor_update` | UPDATE | own advisor rows |
| `bookings_lead_update` | UPDATE | `is_team_lead()` |
| `bookings_member_respond` | UPDATE | own member rows |

Three defects visible in that table:

1. **`bookings_admin` compares email without lowering it.** `Lone@…` would not
   match `lone@…`. It grants ALL commands, so this is a silent
   authorisation bug, not a cosmetic one. Fixed as it is replaced.
2. **`bookings_self` is an exact duplicate of `bookings_own`.** Dropped.
3. **`is_team_lead()` inside `bookings_advisor_select` grants the team lead
   every booking in the system** — the single widest read on the table.

Because PostgreSQL **ORs** permissive policies, dropping any one of these
changes nothing while the others stand. They must be replaced **in one
transaction**.

---

## 6. The before/after matrix

Read as: can this person SELECT a row of this line?

| | Financial booking | Psychosocial booking |
|---|---|---|
| **Member (own row)** | yes → **yes** | yes → **yes** |
| **Member (someone else's)** | no → **no** | no → **no** |
| **Advisor — booking is theirs** | yes → **yes** | n/a → **no** |
| **Advisor — client on caseload** | yes → **yes** | n/a → **no** |
| **Advisor — unrelated row** | no → **no** | no → **no** |
| **Financial team lead** | **yes (all) → yes (all)** | **yes (all) → NO** |
| **Counsellor — booking is theirs** | n/a → **no** | n/a → **yes** |
| **Counsellor — unrelated psychosocial row** | n/a → **no** | n/a → **no** |
| **Clinical lead** | n/a → **no** | n/a → **yes (all)** — nobody holds it |
| **Lone / Michelle (admin + psychosocial)** | yes → **yes** | yes → **yes** |
| **France (admin, not psychosocial)** | yes → **yes** | **yes → NO** |
| **Tshenolo (admin, not psychosocial)** | yes → **yes** | **yes → NO** |
| **HR** | no → **no** | no → **no** |

The two cells that change are the two the migration exists for: **the financial
team lead** and **a France-type admin** lose psychosocial rows. Everything else
is unchanged, and §9 is what proves it.

Write access follows the same shape: a counsellor writes their own psychosocial
rows, an advisor their own financial rows, a psychosocial admin both, an
ordinary admin financial only.

---

## 7. `counselling_notes` and `session_themes`

**Notes are author-only.** Readable and writable by the counsellor who wrote
them, plus `is_clinical_lead()` once anyone holds it. **No admin policy at
all** — not for Lone, not for France, not for the person who owns the database.
An admin who needs a note has to ask the author, which is the correct social
process and not a gap.

**Themes are aggregate-only.** No direct `SELECT` for anyone but the author.
Everything else goes through one RPC that applies the **base-5 floor always** —
no internal no-floor view, unlike the financial indicators. That was decided on
25 Aug and does not reopen.

---

## 8. Two things the prompt does not cover, and I think it should

**8.1 · Reporting.** `_org_report_period_data` counts `bookings`. The moment a
counselling booking exists it will be counted in the session totals HR reads,
silently. Either the reporting functions split by line, or HR's numbers quietly
start including counselling. I recommend **splitting**, with psychosocial
counts exposed only through the base-5-floored aggregate. This is a real piece
of work and is not in the prompt's scope as written.

**8.2 · The M4 and M5 tables.** `work_plans`, `org_contracts`, `org_contacts`
and `contract_rates` are readable by `is_staff()`, which is *every advisor*.
Once a work plan carries counselling activities, a financial advisor reads
them. `actions` and `meetings` are the same shape — an action can name a
psychosocial activity in its title. These need the same line-awareness as
`bookings`, and the prompt only names `program_activities`.

---

## 9. The second requirement, which is the one that gets skipped

M3 has **two** requirements, and they fail separately:

- **(a) France cannot read psychosocial bookings or counselling notes.**
- **(b) France's ordinary admin access is unchanged everywhere else.**

(b) is the one that gets skipped, because **a migration that locks everything
down passes (a) perfectly.** The matrix must prove he still sees what he sees
today outside psychosocial — measured against real counts, not against
"returns without error".

`tests/m4a-tests.sql` assertions 18a–22 are the baseline for (b), taken before
M3 moves anything: France reads every contract, every handover and the whole
support audit trail, and can still write a contract.

---

## 10. Risk flags, with nobody to send them to

**Nobody is clinical lead.** A counsellor raising a risk flag today has nowhere
to send it.

**Proposed interim:** a flag creates an **action for Lone** that says a flag
exists on a psychosocial case — **with no content and no name**. It carries the
booking id in a column Lone cannot read, so that when a clinical lead is
appointed the history is intact and can be handed over. Lone learns that
somebody needs attention and that she must find the counsellor; she does not
learn who or what.

That is deliberately uncomfortable. The alternative — putting a name in an
action Lone can read — makes the flag useful by breaking the thing the whole
migration is for.

---

## 11. `kw_unit_label(uuid)`

Confirmed on live: **`SECURITY DEFINER`, callable by `anon`**, and it reads
`org_units`. An unauthenticated caller with a unit id gets back
"Company — Site".

It is not psychosocial and not urgent, but it is an anon-reachable definer
function reading a private table, and M3 is the migration that is already
auditing exactly that class of thing. Recommend **revoking `anon`** and
documenting it in the same pass.

---

## 12. What the tests must prove

Each as a **separate assertion**, because they fail separately:

1. The financial team lead **cannot** read a psychosocial booking — **through
   the policies, and through `advisor_clients_list`, `advisor_client_detail`
   and `advisor_pending_responses` separately.** Four assertions, not one.
2. A counsellor cannot read a financial booking.
3. A counsellor cannot read another counsellor's psychosocial booking.
4. A Lone-type admin reads both lines.
5. A France-type admin reads financial only — **and, separately, still reads
   everything else he reads today** (requirement (b)).
6. HR reads neither line directly.
7. HR's report numbers do not silently gain counselling sessions (§8.1).
8. A note is invisible to everyone but its author, including to an admin and to
   the database owner's own RPCs.
9. A clinical lead reads notes — asserted against a temporarily-seeded lead,
   then removed, since nobody holds it.
10. The theme RPC withholds below five, always, with no internal bypass.
11. **`ops_timeline`, `org_work_plan` and `contract_position` return no
    psychosocial rows to a France-type admin** — the three recorded
    obligations, in the wording they were recorded in.
12. Every other definer function in §2 gets its own assertion.
13. `bookings` ends with the expected policy count and no duplicate.
14. The un-lowered email comparison is gone.

---

## 13. How it reaches live

1. Apply on a **Supabase branch**.
2. Run the full role × line × command matrix there.
3. Report it as a **plain-language table** — "France, psychosocial, SELECT:
   0 rows (was: all rows)" — never as SQL.
4. Merge only on approval.

---

## 14. What I need before writing the DDL

**14.1 · Does the scope of §2 change what you want built?** M3 as scoped in the
prompt is a policy rewrite. What I found makes it a policy rewrite **plus**
line-gating roughly a dozen definer functions. That is materially more work and
I would rather you decided that than discovered it.

**14.2 · Reporting (§8.1)** — split the reporting functions by line in M3, or
let HR's totals include counselling for now and split later? I recommend
splitting in M3: it is much harder to remove a number from a report someone has
already seen than to never publish it.

**14.3 · The risk-flag interim (§10)** — is content-free-and-nameless the right
call, given it means Lone cannot triage?

**14.4 · Are there counsellors to seed?** M3 creates the table. Whether it
holds anyone on day one changes nothing structurally, but it changes what the
matrix can actually demonstrate on the branch.
