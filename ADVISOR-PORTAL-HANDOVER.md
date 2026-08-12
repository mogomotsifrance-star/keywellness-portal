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
