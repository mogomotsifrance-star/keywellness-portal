# Batch 0 — Company Units (Sedimosa sub-org structure) — Discovery Findings

_Read-only. Zero writes. GO/NO-GO gate for the org_units build._
_Date: 2026-07-30_

---

## 1. Profile ↔ organisation link

- **Column:** `profiles.org_id uuid references organizations(id)`. Added in `supabase_multitenancy.sql` §2.
- **How it's set:** at signup, a `BEFORE/AFTER INSERT` trigger on `auth.users` (`handle_new_user()`) reads `raw_user_meta_data ->> 'invite_code'`, resolves it against `organizations.invite_code` (active only), and stamps `profiles.org_id`. Unknown/blank code → `org_id` stays NULL (public member).
- **Lock:** `trg_lock_org_id` (BEFORE UPDATE on profiles) forces `NEW.org_id := OLD.org_id` for any non-admin caller. Members can never change their own org after signup. **It does not touch any other column** — so a new `org_unit_id` column is writable by members unless we add our own guard.
- **Matches assumptions.** ✔

## 2. Invite-code redemption flow

- Frontend: `index.html:1434` reads `#b-code`, upper-cases it, passes it as `data: { invite_code }` into `sb.auth.signUp(...)` (line ~1440). Happens **at signup**, in auth metadata — the DB trigger does the resolution. No separate redemption table.
- One org = one invite code = one branded experience. ✔ (aligns with locked decision 1 — Sedimosa keeps ONE code.)

## 3. Onboarding step machinery

- `VIEWS['onboarding']` (`index.html:1845`) — a local `steps` array, current order: **names → age → employment(single) → goals(multi)**. Types seen: `names`, `age`, `single`, `multi`.
- `wNext()` advances; on the last step calls `finishOnboarding()` (`index.html:1950`) which builds `state.user` and calls `saveUser()`, then consent/welcome/dashboard.
- Company step slots cleanly **after names** (index 1) per spec. ✔
- ⚠ **`saveUser()` uses a hard column whitelist** (`index.html:963-996`) — `org_id` is deliberately excluded, and there is **no `org_unit_id` key**. Persisting the picker's choice through `saveUser()` alone will silently drop it. **The company step must persist `org_unit_id` via a dedicated `sb.from('profiles').update({ org_unit_id }).eq('id', uid)`** (or we add `org_unit_id` to the whitelist). This is the #1 implementation gotcha for Batch 2 and directly relevant to the "no silent failure" rule.

## 4. Name-capture backfill modal

- `showNameModal()` (`index.html:2946`) + `saveNameModal()`. Triggered inside the `SIGNED_IN` branch of `onAuthStateChange` (`index.html:5901`) when the user has a profile but no first name (`setTimeout(showNameModal, 700)`).
- The company-backfill modal mirrors this exactly: same trigger location, same "save-to-Supabase-with-visible-error" pattern. ✔

## 5. HR reporting surface — **MATERIAL DIVERGENCE FROM PROMPT**

The prompt assumes a single `org_report_data()` RPC is "the HR reporting surface." In reality there are **two distinct HR-facing aggregate surfaces**, and `org_report_data` is **not** the one HR users see live:

| Surface | RPC(s) | Who calls it | File |
|---|---|---|---|
| **Admin report builder** (draft → publish snapshots) | `org_report_data(p_org_id, p_start, p_end)` (live = "v3"), `publish_org_report(p_report_id)` | **admin only** (`is_admin()`) | `admin.html:1253`, `:1722` |
| **HR live dashboard** | `org_overview()`, `org_financial_indicators()`, `org_stress_summary()`, `org_rewards()`, `set_org_headcount()`, … | **HR managers** (employers) | `employer.html:346-669` |
| HR published reports | reads `org_reports` rows (RLS: `status='published' AND org_id = employer_org()`) | HR managers | `org_reports` table |

- **HR identification:** `employers` table, resolved by `employer_org()` = "org where `lower(email)=jwt email` OR `user_id=auth.uid()`" (`supabase_employer_email.sql`). Employers can be pre-added **by email** before they register; `trg_backfill_employer` fills `user_id` on first login. `admins` table (by email) gates admin.
- **Where org scoping happens:** inside the SECURITY DEFINER RPCs — `org_report_data` and `org_overview` both authorize via `is_admin() OR employer_org() = target`. Guards live server-side (`_suppress_count`, `_suppress_rate`, `n < 5` cohort guard). Frontend never filters HR data. ✔ (this part matches.)
- **Implication for Batch 3:** "unit-scoped HR reporting" is **not** a one-RPC change. A Debswana Manager who logs in hits `employer.html` → `org_overview()` (+ siblings), *not* `org_report_data()`. To actually scope what a company manager sees, the unit dimension must be threaded through **`org_overview()` and its sibling org_* RPCs**, not only `org_report_data()`. This needs a scope decision before building (see questions below).

## 6. Dependent modelling

- Dependents are **not** separate accounts. The member/dependent distinction lives on `bookings.client_type ('member'|'dependent')` (used throughout `org_report_data_v3` — `client_type_split`, `session_intensity`, `reach_units`). Confirmed by the RPC's own comment: _"dependents have no separate identity in this schema."_
- ⇒ **Unit inheritance needs no schema change** — a dependent's sessions are booked under the member's account, which carries `org_unit_id`. ✔ (matches locked decision 8.)

## 7 & 8. Sedimosa / Test Co org rows + member counts — **CANNOT CONFIRM FROM HERE**

- **No live DB access in this environment.** `supabase/.temp` has the project ref (`tarmpqxsabbehgjaonfz`, EU-west-1 pooler) but **no password / service key / access token**, and there is no working `supabase` CLI or `psql`. Every SQL file in this repo is applied **by hand in the Supabase SQL Editor** — that is the established workflow, and it's how these migrations must ship too.
- **Sedimosa is not referenced in any codebase SQL** (only in BUILD-NOTES/webinars branding context). Its full UUID, invite code, Test Co's UUID, and Tshenolo's profile UUID all live only in production and must be read from the SQL Editor.
- The Batch 1 seed + account-move SQL will be written to **resolve Sedimosa by name/invite_code** (same self-contained pattern as `supabase_seed_test_org.sql`), so no UUID needs hardcoding — but the discovery SELECTs below still need to be run to confirm the rows exist and current linkage before applying.

### Discovery SQL to run in the Supabase SQL Editor (read-only)
```sql
-- a) Both org rows (full UUIDs + invite codes)
select id, name, invite_code, is_active
from organizations
where name ilike '%sedimosa%' or invite_code = 'TEST-1234';

-- b) Tshenolo's profile + current org linkage
select p.id as profile_id, p.first_name, p.last_name, p.org_id, u.email
from profiles p join auth.users u on u.id = p.id
where lower(u.email) = 'tshenolo@prolearn.co.bw';

-- c) Member counts per org (expected Sedimosa 0)
select o.name, count(p.id) as members
from organizations o left join profiles p on p.org_id = o.id
where o.name ilike '%sedimosa%' or o.invite_code = 'TEST-1234'
group by o.name;

-- d) Sanity: org_units must NOT already exist
select to_regclass('public.org_units') as org_units_table; -- expect NULL
```

---

## GO / NO-GO

**Verdict: GO for Batches 1–2 (schema, seed, account move, onboarding picker + backfill).** They match the assumptions cleanly, with two known implementation gotchas already captured:
1. `saveUser()` whitelist → persist `org_unit_id` via a dedicated update, not `saveUser()`.
2. Add a `lock_org_unit_id` trigger (set-once; admin/service_role-only changes) to enforce admin-only transfers (locked decision 7), since `trg_lock_org_id` doesn't cover the new column.

**FLAG on Batch 3 — needs one decision before building:** the HR reporting surface is **two surfaces** (`org_report_data` admin builder + `org_overview` & siblings HR live dashboard), not the single RPC the prompt assumes. Scope of "unit-scoped HR reporting" must be confirmed.

**Practical gate:** I author all SQL + frontend; **you apply the SQL in the Supabase SQL Editor** (no DB access from here). Batch 1 cannot be finalised/applied until the discovery SELECTs above confirm the 3 UUIDs and that `org_units` doesn't already exist.
