# Batch 0 — Ask Key (Member AI Chat) — Read-only Discovery Findings

**Date:** 2026-08-03
**Scope:** Member-facing "Ask Key" chat, powered by Anthropic via a Supabase Edge Function (`ask-claude`).
**Writes performed:** none (this document only).
**Verdict:** **GO** — every snapshot field has a server-side Supabase source. Details and one scope caveat below.

---

## 1. Edge Functions setup

- **Existing functions** (`supabase/functions/`):
  - `phone-signup/index.ts` — anon-callable, does its own validation, uses the **service role**.
  - `send-booking-email/index.ts` — service role + Resend, writes `notifications`, shared template.
  - `_shared/kw-email.ts` — shared email renderer/constants.
  - `webinar-url/` — **empty** (no `index.ts`).
- **Runtime / imports:** Deno std `http/server.ts@0.177.0` + `@supabase/supabase-js@2.39.7` via `esm.sh`. This is the house pattern to mirror for `ask-claude` (add the Anthropic call via `fetch`, no SDK needed).
- **Secrets:** read with `Deno.env.get(...)`. Auto-injected: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`. Manually-set example: `RESEND_API_KEY`. → `ANTHROPIC_API_KEY` follows the same manual-secret pattern.
- **Deploy workflow:** `supabase functions deploy <name>` (no `config.toml`; project linked to ref `tarmpqxsabbehgjaonfz`). `verify_jwt` is **enabled by default** on the gateway.
- **CORS pattern (verbatim house style):**
  ```
  Access-Control-Allow-Origin: *
  Access-Control-Allow-Headers: authorization, x-client-info, apikey, content-type
  Access-Control-Allow-Methods: POST, OPTIONS
  ```
  `OPTIONS` → `204` with CORS headers; non-POST rejected.

## 2. Corpus source

- Lives in **`index.html`**: `CONTENT` (array of 14 article cards, line ~4729) + `ARTICLE_BODIES` (full HTML bodies, lines ~5048–5265).
- **Size:** ~65.5 KB of source text ≈ **16k–20k tokens** (HTML markup inflates the estimate). **Well under the ~50k ceiling → no trimming needed.** Ship titles + full bodies as-is.
- Build-time snapshot: re-deploy `ask-claude` when articles change materially (noted for BUILD-NOTES).

## 3. Snapshot data locations (all server-side in Supabase)

| Snapshot line | Source (server-side) | Notes |
|---|---|---|
| Wellness score band + 8-dimension summary | `assessments` (`score`, `cat_scores`, `answers`) | Latest row by `created_at`. Client also computes a *live* score (`computeLiveWellness`) from tools; server can use assessed `score`/`cat_scores` directly. |
| Emergency fund months | `emergency_fund` (per-user, `maybeSingle`) | ✓ |
| Budget headline | `tool_data` where `tool = 'budget_planner'` | Budgeted income/expenses/savings allocations. **Caveat below.** |
| Will status | `profiles.will_status` (e.g. `'has_will'`) | ✓ |
| Org display name | `profiles.org_id` → `org_units.name` (`is_active`) | Degrades gracefully if unresolved. |

**Scope caveat (not a blocker):** the budget "**actual**" (logged spending) comes from `expense_tracker`, which is **localStorage-only** (not in the `tool_data` load: only `budget_planner, net_worth_tracker, dti_calculator, retirement` are server-side). → The budget snapshot line must use **budgeted figures only** (income vs budgeted expenses vs savings allocation). Do not promise "budgeted vs actual" unless actual is later migrated to Supabase.

**Excluded per Locked Decision 7** (all available server-side but must NOT enter the snapshot): name, surname, email, phone, user id, `org_unit_id`/department, gender, free-text.

## 4. JWT validation pattern

- Frontend calls via `sb.functions.invoke('<name>', ...)`, which **forwards the user's JWT automatically** (confirmed by the comment at `index.html:6090`; `verify_jwt` enabled).
- Existing functions don't extract the user — they run as service role. For `ask-claude` the standard approach: read the `Authorization: Bearer <jwt>` header and resolve the user with the service-role admin client (`admin.auth.getUser(jwt)`), returning **401** on missing/invalid/expired token. Then use the same service-role client for caps + snapshot reads.

## 5. Frontend shell (FAB + panel placement)

- **z-index landscape:** page-header 50; bottom-nav **108**; more-overlay 110 / more-sheet 111; notif-overlay 900 / notif-panel 901; welcome-modal 998; name/consent/company/dept/gender modals 1000–1002; toast 9999; sidebar 200.
- **Recommendation:** FAB at z-index **~107** (below bottom-nav 108 so it never overlaps mobile nav); chat **panel ~112** (above more-sheet, below notif/modals so notifications and onboarding modals still win). Standing disclaimer pinned in the panel.
- **Mobile bottom-nav height:** `--bottom-nav-h: 64px`. On mobile the FAB sits **above** the bottom nav: `bottom: calc(var(--bottom-nav-h) + 16px)`; panel as a full-height sheet clearing the nav.
- Bottom nav renders from `MOBILE_NAV` into `#bottom-nav` (`index.html:1844`).

## 6. Anthropic API access

- **`ANTHROPIC_API_KEY` secret:** cannot be verified from the repo (secrets are not in git; `.gitignore` excludes `.env*`, `.dev.vars*`, `supabase/.temp/`). **Assume NOT set.** Setting it is a manual Supabase-dashboard step for BUILD-NOTES — never in git or frontend.

---

## GO / NO-GO

**GO.** No snapshot field is materially localStorage-only — assessment, EF, budget (budgeted), will status, and org name all resolve from Supabase server-side. The single reduced-scope item is the budget "**actual**" figure (expense_tracker is localStorage-only): the budget snapshot line uses **budgeted totals only**. Confirm that reduced budget scope and I proceed to Batch 1 (migration — production-live, rollback-first).
