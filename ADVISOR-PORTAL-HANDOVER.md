# Advisor Portal — Build & Deploy Notes

Adds the financial advisor portal to the Key Wellness financial wellbeing portal,
with role switching, member-visible advisor bookings, and organisation utilisation
reporting.

---

## 1. Deploy order — do this exactly

The SQL must run **before** the HTML goes live. `advisor.html` calls `advisor_me()`
on load and will show an access-denied card if the function does not exist yet.

| # | Step | Where |
|---|---|---|
| 1 | Run `supabase_advisor_portal.sql` | Supabase → SQL Editor |
| 2 | Run `supabase_advisor_rpcs.sql` | Supabase → SQL Editor |
| 3 | Seed the first advisor (below) | Supabase → SQL Editor |
| 4 | Commit the HTML to `dev`, test on the Cloudflare test site | git |
| 5 | Merge `dev` → `main` once signed off | git |

Both SQL files are safe to re-run.

### Seed the first advisor

```sql
insert into advisors (email, full_name, title)
values ('france@keywealth.co.bw', 'France Mogomotsi', 'Financial Wellness Advisor')
on conflict do nothing;
```

That account is already in `admins`, and it gets a `profiles` row automatically —
so on next sign-in it will be offered **My Portal**, **Advisor Portal** and
**Admin**, which is the requirement.

### ⚠ One thing to check before you rely on the security model

`bookings` row-level security was configured in the Supabase dashboard and is not
captured in any file in this repo. Step 1 prints a **warning** if RLS is not
enabled on `bookings` — if you see that warning, the advisor policies added by this
migration have no effect and any signed-in user could read any booking. Check with:

```sql
select relrowsecurity from pg_class where oid = 'public.bookings'::regclass;
```

If it comes back `false`, that is a pre-existing hole, not one this change
introduced — but it must be closed before advisors go live.

### Rollback

`migrations/rollback-advisor-portal.sql`. It deliberately does **not** delete
advisor-created bookings (they are real delivered sessions that organisation
reports depend on) and does **not** drop the member consent columns.

---

## 2. What was built

### New files

| File | Purpose |
|---|---|
| `advisor.html` | The advisor portal, rewired from the localStorage prototype onto Supabase |
| `supabase_advisor_portal.sql` | Tables, role helpers, triggers, RLS |
| `supabase_advisor_rpcs.sql` | Consent-gated data access + reporting RPCs |
| `migrations/rollback-advisor-portal.sql` | Rollback |

### Changed files

| File | Change |
|---|---|
| `index.html` | Role redirects replaced with an interface chooser + sidebar switcher; My Bookings shows advisor-scheduled sessions with accept/decline/reschedule; advisor data-sharing consent toggle in My Profile; dashboard banner for sessions awaiting a reply |
| `admin.html` | New **Advisors** screen — roster management, member assignment, per-advisor session reporting, advisor-sourced vs self-booked split; sidebar switcher; the infinitely-bouncing "Back to Portal" link fixed |
| `employer.html` | Sidebar switcher (this page previously had no way out except signing out) |

---

## 3. The three design decisions that matter

### A client does not need a portal account

`advisor_clients.member_user_id` is nullable. An advisor can add anyone, work
through a full assessment with them, and book sessions for them. If that person
later registers with the same email address, two database triggers link the record
automatically — `trg_link_advisor_clients` on `auth.users` (they sign up second)
and `trg_link_advisor_client` on `advisor_clients` (they signed up first).

### Sessions are rows in `bookings`, not a separate advisor table

This is what makes the whole thing hang together. An advisor scheduling a session
writes to the same `bookings` table `index.html` writes to, so:

- it appears in the member's **My Bookings** with no sync step
- the existing `org_report_data()` session counts pick it up with **no change to
  those functions** — `total_booked`, `total_attended`, attendance rate,
  `mode_split`, `monthly_trend` and session-intensity tiers all just work
- attendance confirmed by an advisor fires the existing
  `trg_award_session_attended` trigger, so rewards qualification is unaffected

New columns on `bookings`: `advisor_id`, `advisor_client_id`, `booked_by`,
`member_response`, `member_response_at`, `member_response_note`,
`advisor_seen_response`. Existing rows are backfilled to `booked_by = 'member'`.

### The member's financial data is consent-gated in the database, not the UI

Advisors get **no** RLS read access to `profiles`, `assessments` or `checkins`.
The only path is `advisor_client_detail()`, a SECURITY DEFINER function that
checks `profiles.advisor_data_consent` before returning anything financial.
Turning the toggle off in **My Profile → Privacy** genuinely stops the data
flowing — it is not a display preference.

Without consent the advisor still sees name, contact details and session history.
That is deliberate: they need it to run the appointment.

---

## 4. How role switching now works

Previously `index.html` hard-redirected admins and HR managers out on every
sign-in, at three separate call sites. A member of staff could never see the
member portal, and `admin.html`'s "Back to Portal" link was an infinite bounce.

All three sites now call `kwRouteByRole()`:

- **plain member** → nothing changes, never interrupted
- **exactly one staff role** → still goes straight through to that dashboard, so
  nothing changes for existing HR managers or admin-only accounts
- **more than one role** → a chooser screen, once per session
- **an explicit choice** → honoured; switch again any time from the bottom of the
  sidebar (or the "More" sheet on mobile)

The choice lives in `sessionStorage` under `kw_interface` and resets on sign-out.

---

## 5. Booking flow, end to end

1. Advisor opens a client → **Appointments** → picks date, time, type, delivery
   mode, optional private note → **Schedule**.
2. `advisor_book_session()` writes a `bookings` row: `status = 'pending'`,
   `booked_by = 'advisor'`, stamped with the advisor's id server-side.
   **Advisor bookings are not auto-confirmed** — see below.
3. The member gets an email via the existing `send-booking-email` edge function,
   with copy explaining it was scheduled on their behalf.
4. The member sees it at the top of **My Bookings** and on their dashboard, and
   can **Accept** (→ `confirmed`), **Decline** (→ `cancelled`) or **Ask to move it**
   with a note.
5. The advisor sees the reply in the client's Appointments tab and on the
   portfolio-wide Appointments view.
6. After the session the advisor marks **Attended** or **No-show**, which writes
   the same `attended` / `attendance_confirmed_by` / `attendance_confirmed_at`
   columns `admin.html` already writes — feeding attendance rate and rewards.

Sessions are never hard-deleted, only cancelled, because organisation utilisation
reporting depends on them.

---

## 6. Admin reporting

**Admin → Advisors → Session Reporting**, backed by `advisor_session_breakdown()`
and `session_source_trend()`.

- Per advisor: booked, attended, no-show, unconfirmed, declined, unique clients,
  attendance rate
- Advisor-initiated vs member self-booked, with attendance rate for each
- Filterable by organisation and period; "All organisations" is admin-only,
  HR managers can only see their own org

The period filter uses `bookings.created_at`, the same rule `org_report_data()`
uses, so these totals reconcile with the sessions block of an organisation report
over the same dates.

Small-cell suppression is deliberately **not** applied to advisor rows — this is
operational data about staff, not member cohort data. The member-level cohort
guards inside `org_report_data()` are untouched.

---

## 7. Testing done

- **Database**: 21 tests against a local PostgreSQL 16 with RLS enforced under a
  non-superuser role — auto-linking in both directions, the consent gate, an
  unrelated member blocked from responding to someone else's booking, a
  non-advisor blocked from advisor RPCs, cross-org reporting denial, deactivation
  revoking access immediately, and a clean rollback.
- **Browser**: 58 headless-Chromium checks across `advisor.html`, `admin.html` and
  `index.html` with a stubbed Supabase client — every advisor tab renders, the
  consent gate shows the right state for consented / unconsented / non-member
  clients, booking responses call the right RPC, and the role switcher behaves
  correctly for plain members, single-role staff and multi-role staff. Zero
  JavaScript errors.

What is **not** covered: nothing has run against the live Supabase project. Test
on the `dev` branch before merging.

---

## 8. Incidental fix

**My Bookings never displayed the session time.** The booking form writes
`requested_time`, but the card read `b.time`, which only exists on a handful of
very early rows — so every booking showed `—`. Now reads
`b.requested_time || b.time`.

---

## 9. Known gaps / next steps

1. **Advisor notes are stored but not yet surfaced** in the client editor's Notes
   tab — that tab still writes to the advisor's own consultation record
   (`advisor_clients.assessment`). The `advisor_notes` table is created, RLS'd, and
   already receives the private note attached to a scheduled session.
2. **Advisor caseload assignment is one-directional** — an admin can assign a
   member to an advisor but cannot yet move a client between advisors from the UI.
3. **No advisor-side notification** when a member declines or asks to reschedule.
   The `advisor_seen_response` column exists for this; nothing writes it yet.
4. **The prototype's Documents tab** stores uploaded files as base64 inside the
   `assessment` jsonb. That works but will bloat rows fast — Supabase Storage is
   the right home for these before real client volume.
5. **HR managers** cannot see the advisor breakdown from `employer.html` yet, even
   though `advisor_session_breakdown()` already authorises them for their own org.

---

## 10. Follow-up changes (second pass)

No database changes — `advisor.html` only. The SQL from the first pass is unaffected.

### Robo-Advisor: monetary fields would not accept more than one digit

**Cause.** `updateRobo()` rebuilt the entire tab panel on every keystroke
(`el.innerHTML = panelRobo(...)`). That destroyed the input element being typed
into, so focus was lost after the first character. The money field was worse
because it re-formatted through `toLocaleString` on each render — typing `5`
became `5.00` with the cursor gone. Affected Extra Monthly Payment, Estimated
Consolidated Rate and Term.

**Fix.** The four derived regions now sit in `#robo-stats`, `#robo-payoff`,
`#robo-cons` and `#robo-restruct`. `updateRobo()` renders into a detached node
and swaps only those regions, so the input the advisor is typing in is never
re-created. Recalculation is debounced by 180ms, and the money field formats on
blur instead of mid-typing.

### Personal & Family: retirement horizon auto-calculates

The advisor types **Years to Retirement**; **Months** and **Salaries** derive
from it and are read-only, so the three figures can never disagree.

- Months = years × 12 (rounded, so half-years work)
- Salaries = the same number — a count of remaining monthly pay cheques

Salaries deliberately matches months. It is the framing advisors use in the room
("216 more pay cheques to fix this"), which lands differently to a number of
years. **If a client is on a 13th cheque this understates the count** — note it
in the advisory notes, or say the word and it becomes years × 13.

A live sentence under the fields restates the horizon in plain English.

### Diagnostics & Notes: problem identification with indicators and a plan

New layer on top of the existing `diag*()` functions, in `problemAnalysis()`.
For income, expenses and debt it produces a 0–100 severity, the named
**indicators** that fired, and an ordered **plan of action**. Thresholds come
from the Advisory Framework already in the portal — 50/30/20, DTI ≤35%, the 45%
restructuring line, 30% passive income, 70% income-generating assets.

Indicators by area:

| Area | Indicators |
|---|---|
| Expenses | Budget deficit · Essentials over 50% / severely over · Wants above 30% · Discretionary overspend · Not saving / below target · Large unclassified spending |
| Debt | DTI above lending threshold · Past the restructuring line · Debt servicing unaffordable · No borrowing headroom · Negative net worth · High-cost credit (≥20%) · Multiple creditors · Servicing debt from a deficit |
| Income | Income below essentials · Salary dependency · Passive income below target · Single income stream · Assets not working · Thin margin |

A banner at the top names the primary problem. Lifestyle is shown but not
ranked — it is a symptom of the other three rather than something an advisor
works on directly.

**One design decision worth knowing.** A genuinely distressed client saturates
every area: a deficit drives the income and debt scores up too. In testing, a
realistic stressed profile scored 100 / 99 / 98, at which point naming one area
"the main problem" is arbitrary and misleading. When the top scores fall within
10 points of each other the portal says so explicitly and gives a sequencing
rule instead — close the deficit, then the income gap, then restructure the debt
— because a payoff plan funded from a deficit will not hold. A client with one
dominant issue still gets a single clear verdict.

### Testing at merge time

Merged into the repo on 14 Aug 2026 (commit 91562be). The standalone build was
forked before cae4dc0, so it was applied additively rather than copied over —
the role fixes from that commit (HR role in ROLES, parallel role lookup, HR
Dashboard in the interface switcher) were re-applied on top and verified present.

Verified at merge: the inline script parses; problemAnalysis() and
panelDiagnostics() exercised against distressed, healthy and empty client
records (compound detection fires on the distressed profile at 100/90/90, every
ranked area carries actions, no NaN or undefined in the rendered panels);
panelReport() still renders; the page boots to the auth gate with no console
errors. The standalone build's own headless-browser suite was not re-run here.

### Testing at merge time (third + fourth pass)
Same fork hazard as the second pass, and it bit again: the standalone build for
the Team Lead and UX passes was forked before `cae4dc0`, so it was missing the
HR-role fixes (`ROLES.employer`, the parallel `Promise.all` role probe, and the
HR Dashboard entry in both the sidebar switcher and the mobile More sheet).
Those were re-applied on top of this merge rather than the file being copied
over wholesale, and a dedicated regression suite (`smoke6.js`, 12 checks) now
guards them. **If a future pass forks `advisor.html` again, diff the removed
lines before copying — `diff <(git show origin/dev:advisor.html) advisor.html |
grep '^<'` should contain nothing you did not intend to replace.**

Verified at merge: the inline script parses; all five existing headless suites
pass unchanged (172 checks); the new role-regression suite passes (12 checks);
`index.html` carries only the consent-wording change on top of `origin/dev`.


## 11. Advisory Team Lead (third pass)

A Team Lead for Financial Advisory who can see and work every advisor's
caseload, so they can supervise and step into advisory.

### Deploy

Run **`supabase_advisor_team_lead.sql`** in the Supabase SQL Editor, after the
first two SQL files. Then appoint the lead — either from **Admin → Advisors →
Make team lead**, or directly:

```sql
update advisors set is_team_lead = true, updated_at = now()
 where lower(email) = lower('teamlead@keywealth.co.bw');
```

Files changed: `advisor.html`, `admin.html`, `index.html` (consent wording only).
Rollback: `migrations/rollback-advisor-team-lead.sql`, then re-run
`supabase_advisor_rpcs.sql` to restore the original function bodies.

### The model

A Team Lead **is an advisor** — `advisors.is_team_lead` — not a separate role.
They keep their own caseload and gain scope over everyone else's. That keeps
them inside the advisory relationship the member consented to, which a
standalone management role would not be.

- **Full edit rights**, attributed to them. Sessions they book carry *their*
  `advisor_id`, and notes they write carry *their* `advisor_id`, so the record
  shows who actually did the work. `advisor_book_session()` returns
  `on_behalf_of` when the client belongs to someone else.
- **The consent gate is unchanged.** A Team Lead sees a member's financial data
  only where that member has switched on advisor data sharing — exactly like the
  owning advisor. Verified by test.
- **Deleting** a colleague's client is withheld in the UI; that stays with the
  owning advisor.

### Where it shows up

**Advisor portal** — a scope bar for team leads only: *My clients* / *All
clients* / pick an advisor. Working outside your own caseload turns the bar
amber and says so, because quietly editing a colleague's client is the obvious
failure mode. An Advisor column appears once you look beyond your own book, and
the client record carries an "Advisor: <name>" chip.

**Admin → Advisors** — a Team Lead badge, a Make/Remove team lead control, and
**View clients** on each row (the client count is clickable too), which
deep-links to `advisor.html?advisor=<id>`. There is also *Open all clients*.
Reusing the advisor portal means the full assessment, diagnostics and
robo-advisor come along rather than being rebuilt read-only in admin.

The URL is a convenience, not the access control: `can_manage_advisor()`
re-checks server-side on every call, so a hand-edited `?advisor=` from an
ordinary advisor returns an authorisation error and the UI falls back to their
own caseload with an explanation. Tested.

### Two pre-existing bugs fixed along the way

Both were found by testing co-advisory and would have bitten with or without a
Team Lead:

1. **An advisor could not see a booking made on their own non-member client by
   anyone else.** The old `bookings_advisor_select` policy matched on
   `bookings.user_id`, which is NULL for a client with no portal account. Now it
   also matches `advisor_client_id`.
2. **An advisor could not see notes another advisor wrote on their own client.**
   The old policy only matched the note's author. A new
   `advisor_notes_on_my_client` policy fixes it, and notes now carry an author
   name and an `is_mine` flag.

### Consent wording changed — read this

Because the Team Lead now sees the same financial data, the consent text in
**My Profile → Privacy** was updated from "my advisor" to "my advisory team",
with a sentence naming who that includes. **Do not widen advisor access again
without a matching wording change**, or the consent stops being honest about
what the member agreed to.

### Testing

13 database tests with RLS enforced — scope isolation, ordinary advisors blocked
from colleagues' caseloads and clients, the consent gate holding for the lead,
correct attribution, the owning advisor seeing co-advisory work, revocation
taking effect immediately, members still shut out — plus a clean rollback.
37 browser checks across the lead view, the deep link, the ordinary advisor, a
hand-edited URL and the admin screen. All passing.

---

## 12. UX pass (fourth pass)

Run **`supabase_advisor_ux.sql`** after the other three SQL files.
Files changed: `advisor.html` only.
Rollback: `migrations/rollback-advisor-ux.sql`.

### The advisor portal now works on a phone

It previously did not. Below 900px the sidebar is hidden and **nothing replaced
it** — no navigation, no Sign Out, no interface switcher, no team-lead scope bar,
and the page scrolled sideways. An advisor on a phone could see the client list
and was then stuck.

Added: a bottom navigation bar (Clients · Appts · Activity · Tools · More), a
More sheet carrying the Advisory Framework, the interface switcher and Sign Out,
a stacked page header, horizontally scrollable tabs, and a stacked scope bar.
Desktop is untouched — verified at 1400px in the same test run.

### Notes are one attributed timeline

There were two note stores. `advisor_notes` held session notes and anything a
team lead wrote, and **nothing rendered it**. The Notes tab read
`consultationNotes` inside the assessment JSON, which had no author at all — so
with two people on a case you could not tell who wrote what.

Now: one timeline in `advisor_notes`, every entry showing author, timestamp and
origin (*Session note*, *Earlier note*, *Case history*). Old `consultationNotes`
are **migrated automatically** by a block in the SQL, credited to the advisor who
owned the case and keeping their original timestamps, then the array is cleared.
The migration is idempotent — running the file twice does not duplicate.

You may edit and delete **only your own** notes. A team lead sees everything and
adds their own, but cannot rewrite a colleague's record of a consultation —
that would destroy the point of attributing it. Enforced in
`advisor_note_update()` / `advisor_note_delete()`, not just hidden in the UI.

Two other places read the old array and would have silently shown zero after the
migration; both were repointed: the printed **Report** (now shows the author
against each note) and the **Activity Report** (now counts via
`advisor_note_counts()`, scoped like the client list).

### Reassigning a client

Team leads and admins get a **Reassign** control on the client record. The
assessment, notes and sessions move with the client, and the move is written to
the note timeline as case history — *"Case reassigned from A to B by C. Reason:
…"* — so the file explains itself a year later.

Past sessions deliberately keep the advisor who delivered them; reassignment
changes who holds the case, not who did the work. Reassigning to an inactive
advisor is refused.

### Declines and reschedule requests are surfaced

`advisor_seen_response` existed from the first build but nothing ever wrote it,
so a member declining a session sat in the data with no way for the advisor to
notice. There is now an amber panel on Clients and Appointments listing unseen
responses with the member's own words, a **Got it** button that marks them seen,
and the count folded into the appointments badge — so one number means "needs
your attention". A team lead sees the whole team's.

### Testing

37 browser checks for this pass (mobile navigation at 390px, desktop unchanged at
1400px, the note timeline and its edit rules, reassignment, and the pending-
response flow), plus 6 database security tests: author-only edit, unrelated
advisors blocked from adding notes, reassignment restricted to team leads, the
previous advisor losing access and the new one gaining it, inactive advisors
refused as a target, and the seen-flag clearing correctly.

**Across all four passes: 172 browser checks and 40 database tests, plus a full
rollback chain that unwinds to zero leftover objects.**
