# Impact assessment and data model — extending the financial portal into the operating system

**TEAM 13 (Information Architect), TEAM 14 (Data Architect), TEAM 15 (Solution Architect), TEAM 21 (Security) · 25 Aug 2026 · draft 1.**
Read against the live Supabase project (`tarmpqxsabbehgjaonfz`): 37 public tables, ~115 functions, policies as they stand today. Nothing here has been applied.

---

## 1. The honest answer to "did you scope the impact?"

Not until now. Rev 1 listed additions; this is the first pass that reads what exists and says what changes, what is reused, and what must not be touched. The headline: **the existing portal is much closer to a two-line operating system than "financial-only" suggests, and the right move is to extend it, not fork it.** Most of the foundation is line-agnostic already. Three things are financial-specific and stay that way. Five things are missing entirely.

---

## 2. What exists, and what happens to it

### 2.1 Line-agnostic foundation — reuse unchanged

| Table / function | Rows | Verdict |
|---|---|---|
| `organizations`, `org_units` (company → site), `unit_departments`, `hr_unit_scope` | 3 / 11 / 161 | **Unchanged.** Already the account structure the ops workspace needs. The three organisations are **BOPEU** (2 members), **Sedimosa** (8 members, 7 bookings) and **Test Co** (22 members, all 4 issued reports, 13 bookings). Hollard, LEA, Morula and Debswana are real clients that do not yet exist as organisations — Prompt 6 creates them. Test Co must be excluded from ops lists. |
| `admins`, `employers` (HR), `is_admin()`, `employer_org()`, `hr_scoped_unit_ids()` | | **Unchanged.** Admin and HR roles serve both lines by definition (stated: same admins). |
| `profiles`, `notifications`, `threshold_config`, `kw_threshold()` | | **Unchanged.** `threshold_config` gains psychosocial keys (min base already there as `indicator.low_base`). `notifications` becomes the delivery channel for action reminders. |
| `org_reports` (status draft/published, narrative, snapshot, HR read of published only) | 4 | **Reuse as the report-status tracker.** Add `service_line` and `due_date`; the states become due → draft → review → published. This is the "reports in flight" the ops screens show. |
| `content_items` where `kind='webinar'` (org_id, webinar_date, published) + `webinar_views` | 10 | **Reuse as the webinar record.** Add `service_line`, `presenter`, `attendee_count`, `topic_id`. Flyers hang off it. |
| `program_activities` (org, activity_type, date, attendee_count, delivery_mode) | 1 | **This is the seed of the work-plan activity.** Extend rather than replace — `org_report_data()` already counts it as touchpoints, so extending keeps utilisation figures continuous. |

### 2.2 Financial-specific — keep, do not generalise

| Table | Verdict |
|---|---|
| `advisors`, `advisor_clients`, `advisor_notes`, `is_advisor()`, `is_team_lead()`, all `advisor_*` RPCs | **Untouched.** The charter says do not force symmetry. Counsellors get their own tables with a deliberately different shape (below). |
| `assessments`, `checkins`, `stress_logs`, `emergency_fund`, `tool_data`, indicator library, `org_financial_indicators()` | **Untouched.** Financial member data and its consent model stay exactly as built. |
| Rewards, points, learning pathways, certificates | **Untouched** for now; whether psychosocial engagement earns points is a product decision, not a schema one. |

### 2.3 `bookings` — the one shared table that must change

Today 22 rows, all financial, all `client_type` member/dependent. Fields: `service` (free text: "Budget Planning Session", "Debt Counselling"…), `session_type` (mixes mode and format: "In-Person", "Virtual", "Individual"), `session_mode`, `advisor_id`, `advisor_client_id`, `booked_by`, attendance and member-response fields.

Decision 1 of the advisor build was "sessions live in `bookings`" so they count in utilisation. Psychosocial bookings should follow the same decision, which means:

- add `service_line text not null default 'financial' check (in ('financial','psychosocial'))` — backfill is trivial, every existing row is financial;
- add `counsellor_id uuid references counsellors` and `counsellor_client_id`; constraint: at most one of `advisor_id` / `counsellor_id`;
- add `activity_id` → the work-plan activity this booking fulfils (nullable; a self-booked member session may fulfil none);
- add `session_format text check (in ('one_on_one','couple','group','talk','webinar','wellness_day'))` and stop overloading `session_type`; existing rows backfill to `one_on_one`. `session_type`'s mode values migrate into `session_mode` where that is null;
- `service` stays free text for the financial member form but psychosocial rows write the format label, never the presenting issue.

**Security consequence (TEAM 21 — this is the finding that matters).** Today `bookings_advisor_select` grants `is_team_lead()` read of every booking. France is the financial team lead. If counselling bookings go into `bookings` unchanged, the financial team lead reads every counselling booking with the member's name. That is a confidentiality breach by policy, not by bug. The policy must become:

```
(service_line = 'financial' and (advisor_id = current_advisor_id() or is_team_lead() or …))
or (service_line = 'psychosocial' and (counsellor_id = current_counsellor_id() or is_clinical_lead()))
or is_admin()
```

Admins (Lone, Michelle) do see counselling bookings — they make them by phone and email today, so they know who; what they never see is the note. HR has no row-level read on `bookings` at all (confirmed), only `org_report_data()` with suppression, so the aggregate-only rule holds as long as psychosocial figures go through that same suppressed path.

Housekeeping already flagged twice and still open: `bookings_admin` duplicates `bookings_admin_all`, `bookings_own` duplicates `bookings_self`. Correction after Claude Code's repo read: four bookings policies *are* in executable repo SQL (`supabase_advisor_portal.sql`, and the current `bookings_advisor_select` in `supabase_advisor_team_lead.sql`); the four legacy ones exist only as a comment inventory in `supabase_org_account_phase0.sql`. M3 starts from the team-lead version and captures the legacy four as DDL.

### 2.4 `org_report_data()` and the account file (`admin.html`)

`org_report_data()` counts `bookings` and `program_activities` per org and period, wrapping people-counts in `{value, suppressed}`. Adding psychosocial rows to both tables means it counts them automatically — which is **wrong by default**: a financial utilisation report would silently include counselling sessions. Every reporting RPC (`org_report_data`, `_org_report_period_data`, `advisor_session_breakdown`, `session_source_trend`, `org_report_company_breakdown`, `org_report_department_breakdown`) needs a `p_service_line` parameter defaulting to `'financial'`, so existing calls and issued reports are unchanged, and a new psychosocial panel calls with `'psychosocial'` and the base-5 floor applied **always** for HR (not the internal no-floor rule used for financial indicators — counselling has no "internal view" of individuals).

`admin.html` (246 KB) impact: the account file gains one tab; the organisations list gains service-line and retainer columns from `org_contracts`; the Roles & Access screen gains "counsellor" and "clinical lead". Nothing else in `admin.html` changes. **The ops workspace (Tuesday review, daily view, work plans, actions, invoices, flyers) is a new page, `ops.html`, not more `admin.html`** — the file is already at the size where the fork hazard bites, and the ops workspace has a different design language and a different primary user (Lone, not Tshenolo/France).

### 2.5 Roles and routing

Roles stay table-membership. Add `counsellors` (mirror of `advisors` in shape: `user_id, email, full_name, is_active, is_clinical_lead`) and `is_counsellor()`, `is_clinical_lead()`, `current_counsellor_id()`. `kwRouteByRole()` in `index.html` and the role switcher gain a counsellor entry; `smoke6.js` extends to guard it. No Clinical Lead is assigned (decided 25 Aug); `is_clinical_lead` stays false for everyone until France appoints one.

---

## 3. What is missing entirely — the new tables

```text
service line is a text check ('financial','psychosocial') on every table that needs it — no lookup table

org_contracts            org_id, retainer_amount, billing_frequency (monthly), included_lines text[],
                         covered_headcount, account_manager (advisor or admin user), start_date, end_date,
                         notice_period_days, auto_renew, reporting_cadence            ← spec'd in rev 3, never built

work_plans               org_id, contract_id, title, period_start, period_end, status (draft/agreed/active/closed),
                         authored_by, agreed_with (HR contact), document_url (Lone's Word/PDF, until the plan IS the record)

work_plan_activities     ← program_activities, extended:
                         work_plan_id, service_line, format (talk/one_on_one/couple/group/webinar/wellness_day/flyer/other),
                         planned_month or planned_date, scheduled_at, delivered_at, state
                         (planned/scheduled/delivered/reported/cancelled), practitioner_kind + id, attendee_count,
                         delivery_mode, org_unit_id, webinar_id → content_items, notes
                         keep the old columns so org_report_data() keeps working during migration

counsellors, counsellor_clients (member link optional as with advisors; org attribution rules reused via the same
                         trigger pattern), counselling_notes (author-attributed; RLS: author or clinical lead only —
                         NO admin policy, unlike advisor_notes), session_themes (booking_id, theme_key) + theme_taxonomy
                         (key, label, active) — themes are the only counselling data that aggregates

meetings                 kind (tuesday_review/client/other), held_at, attendees uuid[], org_id nullable
actions                  meeting_id nullable, org_id nullable, activity_id nullable, title, owner user_id, due_date,
                         state (open/done/dropped), created_by, done_at, carried_from action_id
action_reminders         action_id, remind_at, sent_at — or simply rows in notifications written by a scheduled function

invoices                 contract_id, period_start, period_end, amount, due_date, state (to_produce/sent/paid/overdue),
                         produced_by, scan_url, sent_at, paid_at — rows created on the 1st by a scheduled function;
                         the "to_produce" row is Laone's task

topics, topic_tips       topic (key, title, service_line); tips (topic_id, body, sort_order)
flyers                   webinar_id or activity_id, variant (pre/post/awareness), topic_id, state (draft/approved/sent),
                         approved_by, rendered_pdf_url, html_body
flyer_sends              flyer_id, recipient_kind (hr_contact/members), recipient, sent_at, sent_by
org_contacts             org_id, name, email, role (HR contact…), receives_flyers boolean, direct_to_staff boolean

practitioner_availability  practitioner_kind + id, weekday/date, start, end, ceiling_per_fortnight (in threshold_config per person)
```

### Two deliberate asymmetries (TEAM 05)

1. `counselling_notes` has **no admin read policy** and no team-lead-equivalent other than `is_clinical_lead()`. `advisor_notes` has `is_admin()` read; that is right for money and wrong for counselling.
2. `counsellor_clients.assessment` is **not** a jsonb consultation blob like the advisor one. Counselling has no structured "financial position" to capture; it has themes (aggregable) and notes (private). Copying the advisor shape would invite putting clinical content in a field admins can read.

---

## 4. Migration order and rollback

Each step is its own idempotent migration with its own rollback, in the repo, tested locally against PG16 before the SQL editor — the discipline the org-account phases established.

| # | Migration | Touches existing? | Risk |
|---|---|---|---|
| M1 | `service_line` on `bookings`, `program_activities`, `org_reports`, `content_items`; backfill `'financial'`; `session_format` | Yes — additive columns with defaults | Low. No behaviour change until something writes `'psychosocial'`. |
| M2 | Reporting RPCs gain `p_service_line default 'financial'` | Yes — function signatures (new overloads, old kept) | Low if overloads; **medium** if any caller passes positional args — check `admin.html` and `employer.html` call sites. |
| M3 | `counsellors`, `counsellor_clients`, `counselling_notes`, `theme_taxonomy`, `session_themes`, role functions; **rewrite `bookings` select policy by service line; capture all bookings policies in the repo; drop the two duplicates** | Yes — RLS on `bookings` | **High.** This is the confidentiality boundary. DB tests must prove: team lead cannot read a psychosocial booking; counsellor cannot read a financial one; admin reads both; HR reads neither; nobody but author and clinical lead reads a note. |
| M4 | `org_contracts`, `org_contacts`, `work_plans`, `work_plan_activities` (extend `program_activities`), `invoices` + the 1st-of-month function | Extends one table | Medium. `org_report_data()` must still count the old rows identically — regression test against the three organisations and the four issued Test Co report periods. |
| M5 | `meetings`, `actions`, reminders via `notifications` + scheduled function | No | Low. Ship first if sequencing allows — it is what fixes "nobody records Tuesday". |
| M6 | `topics`, `topic_tips`, `flyers`, `flyer_sends`; rendering is an Edge Function producing PDF/PNG + HTML into Storage | No | Low schema risk; the renderer is the work. |
| M7 | `practitioner_availability`, capacity ceilings | No | Low. |

**Suggested delivery order: M1 → M5 → M4 → M3 → M2 → M6 → M7.** M5 before M3 because the Tuesday action ledger needs no confidentiality machinery and gives the team a reason to open the system daily; M3 before M2 because psychosocial figures must never reach a report before the row-level boundary is proven.

---

## 5. Open items for Tshenolo and France

1. ~~`ops.html` versus `admin.html`~~ **Decided 25 Aug, then corrected the same day.** Lone and Michelle do not use the portal today, and everything in the admin portal is theirs to do — Tshenolo does it only because the financial admin portal is unfinished. So `admin.html` is **not** a setup console for developers; it is the other half of Lone and Michelle's job. Revised position: **`ops.html` is the single staff workspace.** New staff capabilities are built there from the start in the ops language, and the admin functions Lone and Michelle need (organisations, units, departments, HR contacts, roles, report publishing, the account file) migrate into it release by release; `admin.html` is retired when the last one moves, not maintained in parallel. Consequence for TEAM 28: the first thing Lone opens is the thing she will judge the whole system by — the Tuesday actions ledger (M5) ships first, populated with the four real work plans.

   **Member support functions (requested 25 Aug):** sending password-reset links and resending transactional emails (booking confirmations and the like) so the developer is not doing support through Claude or directly in Supabase. These cannot run from the browser with the anon key — they need the Auth admin API and the mail path — so they are an **Edge Function with the service role**, callable only by `is_admin()`, with every call written to an audit table (who, for whom, what, when). Same pattern later serves "resend flyer" and "resend invoice reminder".

   **France's access — decided 25 Aug:** France keeps his admin role but must not see who booked counselling. M3 therefore needs an admin split for psychosocial rows (an `admins.lines` column or an `ops_admins` membership — the M3 plan must recommend one). Psychosocial admin is done by Lone and Michelle, not Karabo. No Clinical Lead is assigned; counselling notes are author-only until one is, and a risk flag creates a content-free action for Lone.
2. **Storage** — flyers, invoice scans and (already flagged) advisor documents all want Supabase Storage rather than base64 in jsonb. One bucket policy design covers all three.
3. **Scheduled functions** (1st-of-month invoices, reminder sends) — Supabase `pg_cron` + Edge Function, or an external scheduler. Needs a decision before M4/M5 land.
4. **Backfill of the four real work plans** (BOPEU, Hollard, LEA, Morula) from Lone's documents so the Tuesday review is populated on day one, not empty.
5. The `bookings.session_type` cleanup (mode vs format) touches `index.html`'s booking form and `advisor_book_session()` — small, but three files.
