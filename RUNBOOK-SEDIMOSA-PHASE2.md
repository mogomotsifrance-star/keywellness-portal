# Sedimosa Phase 2 — Apply / Deploy Runbook

Consolidated manual steps for the Sedimosa Phase 2 build (departments, gender,
phone accounts, notifications, compulsory assessment, budget actuals, estate
planning, webinars, change password, department HR reporting).

- **Frontend** for every batch is already merged to `dev` **and** `main`, so it
  is live on both the test site (Cloudflare, from `dev`) and the live site
  (GitHub Pages, from `main`). Nothing to do for the frontend.
- **Backend** (Supabase SQL + Edge Functions) is applied **manually** by you —
  this doc is that checklist. The Supabase project is shared dev/prod, so every
  SQL apply / function deploy is **production-live immediately**.
- Project ref: `tarmpqxsabbehgjaonfz`. Repo root contains the `supabase/` folder.

---

## ✅ Already done (for the record)

| Item | How it was applied |
|---|---|
| `supabase_sedimosa_phase2_batch1.sql` (Batch 1: seed correction, unit_departments, gender/department_id/will_status, webinar_views, notifications, content_items.webinar_date) | Applied in SQL Editor (verified: 7 active units, 161 departments) |
| `supabase_verify_invite_code.sql` (Batch 2: signup code validation) | Applied in SQL Editor |
| `send-booking-email` Edge Function (Batch 4 notifications + Batch 3 email-optional) | **Deployed** (redeployed 2026-08-03 with the Batch 3 email-optional change) |
| Batch 2 onboarding (gender/dept, mandatory code, assessment lock) | Live + tested with Tshenolo |
| **Batch 3 phone accounts (pseudo-email)** | **Shipped + FUNCTIONAL:** frontend merged to `dev` + `main`; both Edge Functions (`phone-signup` NEW, `send-booking-email` redeploy) deployed 2026-08-03. |
| Prerequisite org_units build (`supabase_org_units.sql`, `..._hr_scope.sql`, `org_report_data_v4`, scoped overview/rewards) | Applied before this phase (Batch 3c) |

---

## ⚠ PENDING — do these, in this order

### Step 1 — Apply the Batch 9 department-reporting SQL
Open a terminal or the folder, then Supabase → **SQL Editor**, paste and run:

- **File:** `supabase_org_report_data_v5_departments.sql`
- **Depends on:** v4 report + hr_scope + Batch 1 (all already applied) — safe now.
- **Effect:** adds `org_report_department_breakdown()` + `_dept_metrics()`. The v4
  report is unchanged. The admin report builder's "Department Breakdown" table
  starts working for unit-scoped reports.
- **Verify:** run the queries at the bottom of the file (leaf unit → department
  rows + Unassigned, small ones suppressed; Debswana parent → not available).
- **Rollback:** `migrations/rollback-org-report-departments.sql`.

### Step 2 — Backfill webinar dates
Admin dashboard → **Webinars** tab → set the date on each existing webinar with
the inline date picker (rows without a date show a red "no date set" flag). New
webinars capture the date at creation. This drives the newest-first ordering and
the "Latest Webinar" spotlight on the member Webinars tab.

---

## Process / config still to define (not code)

- **Admin-mediated phone password reset.** Phone accounts can't self-reset (no
  email, no SMS). Define who verifies identity and how — e.g. an admin sets a
  temporary password via the Supabase dashboard (Authentication → Users), or build
  a small admin reset action later. The portal already shows phone users the
  "contact your administrator" message.
- **`hr_unit_scope` seeding.** To give a company/site manager a scoped HR view
  (and to test Batch 9 department scoping as a non-admin), insert an
  `hr_unit_scope` row for them (by email or user_id, with their `unit_id`). A
  fund/whole-org manager gets a row with `unit_id = NULL` (or no row = whole-org).

---

## 🔐 Privacy notice / Botswana DPA updates to publish

Collected/newly-visible personal data introduced this phase — disclose in the
privacy notice:

- **Gender** (with a "prefer not to say" option) — surfaces to HR only as guarded
  aggregates, never per person.
- **Estate/`will_status`** collected in the assessment.
- **Phone numbers** collected and **unverified** (no SMS verification).
- **Key Wellness staff can see individual webinar-viewing activity** (admin-only
  `webinar_views`).
- **Notification content** is retained in the `notifications` table.
- **AI Assistant (Ask Key):** identifier-stripped wellness context + the member's
  message are sent to **Anthropic (Anthropic PBC, USA)** as a data processor to
  generate replies; this is a **cross-border transfer** (processing outside Botswana);
  chat content is **not stored** by Key Wellness in v1. Privacy-notice clause added to
  the `consent-modal` in `index.html` (dev). BLOCKER before live: Anthropic on the
  Botswana DPA foreign-processor register (signed DPA + recorded cross-border transfer)
  — a compliance action, not a code change.

---

## SQL files ↔ rollback map

| Apply file | Rollback file | Status |
|---|---|---|
| `supabase_sedimosa_phase2_batch1.sql` | `migrations/rollback-sedimosa-phase2-batch1.sql` | applied |
| `supabase_verify_invite_code.sql` | `migrations/rollback-verify-invite-code.sql` | applied |
| `supabase_org_report_data_v5_departments.sql` | `migrations/rollback-org-report-departments.sql` | **pending (Step 1)** |

Edge Functions: rollback = re-deploy the previous committed `index.ts` for that
function (`git show <prev-sha>:supabase/functions/<fn>/index.ts`).

---

## One-line "am I done?" check

Phase 2 is fully live once: **Step 1** SQL is applied and **Step 2** webinar dates
are set. Everything else (all frontend, Batch 3 Edge Functions, and Batches
1/2/4/5/6/7/8 backend) is already in place.

_See BUILD-NOTES.md for the full per-batch record, verification queries, and design notes._
