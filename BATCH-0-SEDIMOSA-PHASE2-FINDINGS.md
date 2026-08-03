# Batch 0 — Sedimosa Phase 2 — Discovery Findings & GO/NO-GO

_Read-only discovery. Zero writes to the database or app code. This is the GO/NO-GO gate for:
Departments · Gender · Phone accounts · Notifications · Compulsory assessment · Budget actuals ·
Estate planning · Webinar enhancements · Password change · Department-level HR reporting._

**Date:** 2026-07-31
**Prerequisite:** `cc-prompt-org-units-sedimosa.md` (org_units) — **CONFIRMED APPLIED** (see §0).
**Environment note:** No live DB access from here (no service key/password). Every migration is
hand-applied by Tshenolo in the Supabase SQL Editor — the established workflow. A short list of
**live-verification SELECTs** Tshenolo must run before Batch 1 is applied is in §12.

---

## 0. Prerequisite check — GO

The org_units build is present and applied:
- `supabase_org_units.sql` — `org_units`, `hr_unit_scope`, `profiles.org_unit_id`, `current_member_org()`,
  RLS, and the set-once `trg_lock_org_unit_id` guard.
- `supabase_org_units_hr_scope.sql`, `supabase_org_overview_scoped.sql`,
  `supabase_org_rewards_stress_scoped.sql`, `supabase_org_report_data_v4.sql` (all Jul 31).
- Recent commits confirm "Batch 3c" landed.
➡ **org_units exists — do NOT STOP. Proceed.**

---

## 1. org_units live state & the DBGSS/DeBeers/Morupule correction

The applied seed (`supabase_org_units.sql` §5) created **8 top-level + 3 Debswana children = 11 units**:

| Seeded name | sort | Correction required (this prompt) |
|---|---|---|
| Debswana (parent) | 10 | keep (parent-only drill-down) |
| **Morupule** | 20 | **RENAME → `Morupule Coal Mine (MCM)`** |
| DBGSS | 30 | keep — **this IS DeBeers** |
| DTCB | 40 | keep |
| DPF | 50 | keep |
| Mmila | 60 | keep |
| **DeBeers** | 70 | **DEACTIVATE (`is_active=false`) — non-destructive** |
| Sesiro | 80 | keep |
| Jwaneng / Orapa / DCC | 11/12/13 | keep (Debswana children) |

After correction: **7 active top-level** (Debswana parent + MCM, DBGSS, DTCB, DPF, Mmila, Sesiro)
+ 3 Debswana children = **10 active**, 1 inactive (DeBeers). Matches the prompt's authoritative list.
- Tshenolo is on **Sedimosa / Mmila** (unaffected by the correction).
- ⚠ **Live check needed:** does the `DeBeers` unit have any profiles referencing it? If yes, reassign
  to `DBGSS` before/at deactivation (non-destructive), and report each move. (§12 SELECT d.)

## 2. Profiles schema — all four new columns are genuinely absent

Existing profiles columns include: `org_id`, `org_unit_id`, `phone`, `live_score/live_cat_scores/live_score_at`,
`leaderboard_opt_in`, `display_alias`, plus the financial figures. **Absent:** `gender`, `department_id`, `will_status`.
- ✔ `gender`, `department_id`, `will_status` → additive columns, safe.
- ⚠ **`phone` ALREADY EXISTS** (it is in `saveUser()`'s whitelist, index.html:984). Batch 1's
  `add column phone` must be `IF NOT EXISTS` — it will be a no-op. (Phone accounts still need the
  Auth-side work in Batch 3; the column is not the blocker.)
- `saveUser()` uses a **hard column whitelist** (index.html:980-1013). `org_unit_id` is deliberately
  excluded and written via a dedicated `update({org_unit_id})` at index.html:2003. **`gender`,
  `department_id`, `will_status` must be added to the whitelist OR written via dedicated updates** —
  otherwise saves silently drop them (the #1 "no silent failure" gotcha, same as org_unit_id).

## 3. Signup / auth flow

- **Company code is currently OPTIONAL.** `#b-code` label literally says "(optional…)"; `doSignup()`
  (index.html:1440-1461) validates only email + password length + match, then passes
  `invite_code: inviteCode || null` into `signUp` metadata. Unknown/blank → `org_id` NULL (public member).
  ➡ Batch 2.4 (mandatory code) is a small, clean change: add validation + relabel.
- **No phone-auth anywhere.** Signup/login are email/password only (`signInWithPassword`). No
  `signInWithOtp`, no `phone:` in any auth call. Batch 3's phone path is entirely new frontend.
- **Login** (`doLogin`, :1407) is email-only. **Forgot password** (`doForgotPassword`, :1507) →
  `resetPasswordForEmail`; reset completion via `updateUser({password})` at :1536 and the
  `PASSWORD_RECOVERY` event at :6105.

## 4. Onboarding step machinery

- `VIEWS['onboarding']` (:1863); `steps` array (:1868-1875): **names → age → employment(single) → goals(multi)**.
- A `type:'company'` step (key `org_unit_id`) is **spliced in at index 1** at runtime when the org has
  active units (:1987-1991); `finishOnboarding` (:1996) persists `org_unit_id` via a dedicated update (:2003).
- ➡ **Gender** field slots onto the names step render (:1896-1914) + names-branch persistence (:1963-1968).
- ➡ **Department** step: a new picker step spliced after the company step (same pattern as :1987-1991),
  RLS-scoped fetch of the selected unit's departments; persist `department_id` via a dedicated update
  (mirror :2003). Switching company must reset the department selection.
- **Backfill modal:** `showNameModal()` (:3002) fires from the `SIGNED_IN` branch of `onAuthStateChange`
  (:6089-6094) when no name exists. Batch 2.3 extends this pattern to prompt, in order, whichever of
  company → department → gender is missing (Tshenolo: has company → will be asked department + gender).

## 5. Compulsory first assessment — NO lock exists today (new behaviour)

- Assessment reached via `openTool('wellness_assessment.html')` (:1689). Onboarding hands off through a
  one-time **welcome video** gate (`closeWelcome` → openTool at :2996); the "Start Assessment" button
  only appears after the video (:2942). Missing assessment otherwise only produces nudges (:2516, :2675)
  and placeholder hub/gauge states — **navigation is never blocked**.
- ➡ Batch 2.5 hard lock is entirely new. **Enforce via a completion record in Supabase, not
  localStorage:** completion = the existence of an `assessments` row for the user (§6). A cleared cache
  must neither re-lock a completed user nor unlock an incomplete one.
- Draft auto-save already exists (see §6) so "resume, not restart" is free.
- The three "Back to Portal" links in `wellness_assessment.html` (:170, :557, :596) must be hidden
  **only during the first, compulsory assessment**; retakes keep them.

## 6. Assessment internals (for Batches 2.5 & 6)

- **Draft:** localStorage `kw_assessment_v2` (`LS_KEY`, :669); `saveDraft` (:748) fires on every
  interaction; `loadDraft` (:755) restores at :1202. Cleared on "Start new" (:1096).
- **Results save:** insert into **`assessments`** (`user_id, score, cat_scores, answers, created_at`,
  :889-895) + `profiles` update (`last_score`, `last_cat_scores`, financial figures, :920-940).
  Failure queues to `kw_assessment_pending` and retries (:1205-1218). **No completion table, no version column.**
- **Score computation:** `calculateWellness()` (:767); `totalScore` (:830) reduces **only** over the
  `dims` array (8 dimensions × 12.5 = 100, :820-829).
  ➡ **Estate Planning (Batch 6) is score-safe** if and only if it is NOT pushed into `dims`. Persist its
  answers via the existing `answers`/`saveDraft` path and write `profiles.will_status` in the
  `profiles.update` payload (:920-940). Verify score is byte-identical for identical non-estate answers.

## 7. Financial Hub (for Batch 6 estate card)

- Rendered as `hubCards` (title "Your Financial Hub", :2797; card map :2799-2806). 10 existing cards
  (Wellness Score, Budget Surplus, Net Worth, Emergency Fund, Goals, Stress, DTI, Savings Rate,
  Insurance, Retirement), pushed at :2577-2670.
- ➡ Estate card = `hubCards.push({...})` keyed off `state.user.will_status`; add `will_status` to the
  profiles `select` (:898) and the state-user mapping (:988). Card states: has_will → affirming +
  annual-review nudge; in_progress → encouragement + coach CTA; no_will/null → plain-language "why a
  will matters" + Learn + coach CTAs.
- Score reaches dashboard via `state.assessments[0].score` (load :898/:910), fallbacks to
  `profiles.last_score` then localStorage; a **live override** (`computeLiveWellness`, :2422-2429) can
  supersede the stored value — Estate card is independent of this.

## 8. Budget Planner actuals (Batch 5) — NO migration needed

- Persists to **both** localStorage `budget_planner_v2` and Supabase `tool_data` (JSON blob:
  `{budgets, currentKey}`, upsert on `user_id,tool` at budget_planner.html:524). Cloud overrides local on load.
- **Line-item shape gotcha:** `expenses` is a **flat map `{catId: amount}`** (not item objects); income
  IS `[{id,label,amount}]`. ➡ Add a **parallel `b.actuals = {catId: amount}`** map (+ income-actual
  scheme); variance is derived (`budgeted − actual`), not stored.
- Render: `renderExpenseCats` (:827-869, grid `1fr 130px 130px 32px` → widen for Actual + Variance);
  totals in `calcTotals` (:635) and `renderSummaryPanel` (:874). Currency via `fmt`/`fmtYrSigned` (:576/1077).
- **Backward-compatible:** load path does no schema validation and reads defensively; old budgets load
  with `actuals` defaulting to empty. Add `actuals:{}` to `newEmptyBudget` (:604); decide copy-month
  behaviour (recommend: new month starts with zero actuals). Update `flushToState` (:737) + PDF export.

## 9. Webinars (Batch 7)

- Webinars = **`content_items` rows with `kind='webinar'`** (schema in `supabase_webinars_thresholds_schema.sql`).
  Admin create UI exists: `createWebinar()` (admin.html:524-560); fields = title, org, Vimeo ref, duration,
  description, `published:false`. **No date field is captured, and no date column exists** beyond `created_at`.
  ➡ Batch 1 adds `content_items.webinar_date date`; Batch 7.1 adds the form input + insert field; existing
  rows get dates via a recorded UPDATE per webinar (values from Tshenolo).
- **Ordering** is `created_at desc` in two places: member `lpWebinars()` (index.html:3230) and admin (admin.html:460).
  ➡ Both switch to `webinar_date` (fallback `created_at`). Spotlight/grid split (Batch 7.2) goes in `lpWebinars()`.
- **Playback / view hook:** `lpOpenWebinar(id)` (index.html:3665); Vimeo player `ready().then()` at :3714 is the
  clean once-per-open hook for a `webinar_views` insert. Fire-and-forget (never block playback).
- **`webinar_views` is NEW.** `video_watch_progress` / `video_watch_credits` already exist but are
  resume/Learning-credit only — not a per-view audit log. Precedent for the new table: `tool_usage_events`.
- **Admin views report (7.4):** new sidebar tab (admin.html tab pattern :203-209 / :441) or a section in
  `renderWebinars()`. Admin-only via `admins`-table RLS; HR/employer get zero rows (must be tested).
- **Infographics placeholder (7.5):** Articles tab — narrow the confidence-progress card, add a "Coming
  soon" card + empty-state view. No backend; must not touch the Learn engagement denominator.

## 10. Notifications (Batch 4) — a shell already exists (DIVERGENCE from prompt)

The prompt assumes a brand-new notification centre. **The UI shell already exists** and is **client-derived only**:
- Bell + unread badge + panel in the header (index.html:774-777, panel :748-760);
  `toggleNotifPanel()` (:6003), `loadNotifications()` (:5967), `dismissNotif`, `kw_notifs`/`kw_notifs_dismissed`.
- `loadNotifications()` builds `all = [...bookingNotifs, ...custom(kw_notifs), ...smart]` (:5980) — booking
  notifs are **derived from `state.bookings`**, `smart` from `generateSmartNotifs()`. **There is NO
  `notifications` DB table.** Phone-only users on a new device would see nothing persistent.
➡ Batch 4 is therefore **"add a persisted `notifications` table + server inserts + merge Supabase rows
into the existing panel"**, not build-from-scratch. Merge point: fold fetched `notifications` rows into
the `all` array at :5980 (replacing/augmenting the localStorage `custom` source for cross-device), and
write `read_at` on tap. This is *less* work than the prompt assumes and reuses the existing UI.

**Email → notification parity sites (Batch 4.2):**
- **Our own sends** (can co-write a notification row): `send-booking-email` Edge Function (Resend),
  invoked client-side at **index.html:5316** (member booking, `type:new`) and **admin.html:1036**
  (admin confirm, `type:confirmed`). Cleanest: write the notification row at these two call sites (or
  inside the Edge Function — record its version hash before deploy).
- **Legacy Formspree** booking on the standalone `booking_form_v2.html:532` (separate public page).
- **No session-reminder email exists anywhere** — the "reminders" are in-app/derived only. (So there is
  no reminder send to mirror; a future reminder feature must ship with a notification insert.)
- **Supabase Auth SYSTEM emails** (signup confirm, password reset, magic link, invite, email change) are
  **NOT interceptable** in this repo (no Auth webhook/hook function) → BUILD-NOTES known gap.

## 11. Change password (Batch 8) — three net-new surfaces

- **Member profile** (`VIEWS['profile']`, index.html:5737): no password UI today; insert a "Change
  password" block ~:5806-5808. Uses `sb.auth.updateUser({password})` (same API as :1536).
- **Admin** (admin.html): **no self-settings area at all** — only a read-only email + logout in the
  sidebar footer (:210-213). Net-new lightweight settings section/modal.
- **Employer** (employer.html): **no settings page** — 3 tabs + email/logout footer (:238-241). Net-new
  `nav-settings` item or footer block.
- Confirmation UX: prompt for current password and re-authenticate (`signInWithPassword` / phone
  equivalent) before `updateUser`. Generic failure copy (don't reveal which credential failed).

## 12. HR reporting & department breakdown (Batch 9)

- Two HR surfaces (as documented previously): the **admin report builder** (`org_report_data`, now **v4**)
  and the **employer live dashboard** (`org_overview`, `org_financial_indicators`, `org_stress_summary`,
  `org_rewards*`; employer.html:347-350, 416-440). Employer calls pass **no unit param** today — scoping
  is server-side.
- **v4 is the extension point:** `_org_report_period_data(p_org_id, p_start, p_end, p_unit_ids uuid[])` is
  the single body; `NULL` = org-wide, non-NULL = cohort filtered to `profiles.org_unit_id`, with the ≥5
  cohort guard and <3 cell suppression applied per view. There is already an
  `org_report_company_breakdown`.
  ➡ Batch 9 adds a **department dimension** (a `p_department_ids uuid[]` filter + an
  `org_report_department_breakdown`) over `profiles.department_id`, each department row independently
  guarded, suppressed rows marked, plus an "Unassigned" row (guarded). Client-supplied department
  filters validated server-side against `hr_unit_scope`. Debswana combined view gets NO department
  breakdown this iteration.

---

## Live-verification SELECTs for Tshenolo (run in Supabase SQL Editor, read-only)

```sql
-- a) Sedimosa org + current units (confirm the 11 seeded, DeBeers/Morupule present)
select u.name, u.sort_order, u.is_active,
       (select name from org_units p where p.id = u.parent_unit_id) as parent
from org_units u
where u.org_id = (select id from organizations where name ilike '%sedimosa%' limit 1)
order by u.sort_order;

-- b) Does the profiles.phone column already exist? (expect: yes)
select column_name from information_schema.columns
where table_schema='public' and table_name='profiles'
  and column_name in ('phone','gender','department_id','will_status','org_unit_id');

-- c) Does content_items already have a webinar/session date column? (expect: no)
select column_name from information_schema.columns
where table_schema='public' and table_name='content_items';

-- d) CRITICAL before Batch 1: any profiles on the wrong 'DeBeers' unit? (must reassign to DBGSS if >0)
select count(*) as members_on_debeers
from profiles
where org_unit_id = (
  select id from org_units
  where org_id = (select id from organizations where name ilike '%sedimosa%' limit 1)
    and name = 'DeBeers');

-- e) Existing webinar rows needing a date backfill
select id, title, created_at from content_items where kind='webinar' order by created_at desc;
```

---

## GO / NO-GO

**VERDICT: GO.**

- Prerequisite org_units is applied (§0). No STOP condition on the org side.
- All schema additions are additive and confirmed non-colliding (§2). The DBGSS/DeBeers/Morupule
  correction is fully scoped and non-destructive (§1).
- Batches 1, 2, 4, 5, 6, 7, 8, 9 have clear, confirmed insertion points and **may proceed**.

**Batch 3 (phone accounts) — conditional gate, does NOT block the rest:**
- Based on Supabase's documented behaviour, the Phone provider with **phone confirmations disabled** and
  **no SMS provider** supports **password-only phone signup** (users are immediately confirmed, no SMS
  sent, no cost). So Batch 3 is feasible — **but this is a manual dashboard toggle + must be verified
  with one live test signup before building 3.2+** (per the prompt's own instruction). If, on toggling,
  Supabase refuses phone signup without an SMS provider, Batch 3 is flagged blocked and the rest proceeds.
- **Batch 3.4 constraint:** admin-mediated password reset for phone-only members needs a **server-side
  Edge Function** (the browser anon key cannot call `sb.auth.admin`). This is a build item + a process
  definition (who verifies identity), not doable purely client-side.

**What I need from you before writing production-live SQL (Batch 1):**
1. Run SELECTs (a)–(e) above and paste the results — especially (d) (DeBeers members) and (b)/(c)
   (phone/date columns), so the migration is finalised against live state, not assumption.
2. Confirm you want me to proceed batch-by-batch (author SQL + rollback first, you apply in SQL Editor;
   frontend to `dev`), starting with **Batch 1 (migrations + seed correction)**.
3. For Batch 3: confirm whether to attempt the Supabase Auth phone toggle now (I'll write the exact
   dashboard steps + a test procedure to BUILD-NOTES and pause), or defer Batch 3 and do 1–2, 4–9 first.
