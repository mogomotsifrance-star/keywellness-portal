# Key Wellness — Member Portal Pre-Launch Audit

**Audit type:** Read-only. Zero code, config, git, or Supabase changes were made. The only file created is this report.
**Audit date:** 2026-07-12 → 2026-07-13
**Branch:** `dev`
**Baseline HEAD at audit start:** `93bdf1a5a79b02538e35314faededd4544f3548a`
**HEAD at audit close:** `28af163f40f58055270e1af8941261766a744292`
**Working tree:** No tracked file was modified *by this audit* — the only file it created is `AUDIT-REPORT.md` (untracked, alongside `.claude/` and `supabase/.temp/`).

> ⚠️ **Baseline moved mid-audit (not by me).** A feature commit — `28af163 fix(learning): unlock Pathway 2 — per-user pathway gating, card navigation, activation SQL` — was made on `dev` by another session/tool while this audit was running (I ran zero git writes; the reflog shows the commit at `HEAD@{0}`). It changed `index.html` by 74 lines in the **Learn/LMS render functions only** (`renderLpLanding`/`renderLpPathway`/`lpPathwayArt`, roughly lines 2777–3090) plus two new SQL seed files. **Implications for this report:**
> - `index.html` line numbers cited for findings **below ~line 3011 are now ~+53 lines higher** in current HEAD (e.g. a finding cited at `:4951` is near `:5004` now). Findings above ~line 2777 (all auth, dashboard, booking, admin XSS, tool-page, PDF findings) are unaffected.
> - **Learn/LMS-specific findings must be re-checked against `28af163`** — notably the P2 "Learn/Videos false-complete when no pathways exist" item, which lands inside the rewritten `renderLpLanding`. Spot-check confirms the reworked lesson/pathway cards now use proper `role="button" tabindex="0" onkeydown` (so P1-4 keyboard-nav applies to the sidebar/bottom-nav only, not the LMS cards).
> - No RLS/points/data-persistence finding is affected (those files were untouched by the commit).

**Lenses applied:** QA engineering · UX/product design · business-owner (would a Debswana employee trust it; would HR renew).

---

## Coverage

**Audited (member-side):**
- `index.html` — the member SPA: auth, hash router, onboarding, consent, welcome video, dashboard, assessment redirect, Learn/LMS, Tools, Calculators, Emergency Fund, Check-in, Progress, Booking, My Bookings, Badges, Rewards, Profile, Notifications.
- Standalone tool pages (15): `wellness_assessment.html`, `budget_planner.html`, `goal_planner.html`, `expense_tracker.html`, `net_worth_tracker.html`, `debt_management_planner.html`, `dti_calculator.html`, `retirement_calculator.html`, `financial_stress_tracker.html`, `loan_calculator.html`, `investment_calculator.html`, `affordability_calculator.html`, `rent_vs_buy.html`, `education_savings_calculator.html`, `life_insurance_calculator.html`, plus the orphaned `booking_form_v2.html`.
- Shared assets: `css/kw-theme.css`, `css/kw-pathways.css`, `kw-badges.js`, `kw-profile-sync.js`, `js/*`.
- Supabase Edge Function `send-booking-email` + `_shared/kw-email.ts`.
- RLS/RPC review from the repo `supabase_*.sql` files.
- Live verification against `dev` served locally (`http-server` on :8091) and the deployed live/test URLs, signed in with the provided test member account.

**NOT fully covered (and why):**
- **Live Supabase RLS on `tool_data`, `stress_logs`, `bookings`, `admins`** — no DDL/policy for these exists in the repo, and a live cross-tenant read probe was (correctly) blocked by the environment's safety classifier as it targets a shared production DB. Routed to Manual Verification. **This is the single most important open item.**
- **Any write-path end-to-end** (submitting an assessment/check-in/booking, awarding points) — the engagement forbids writes to the shared prod DB. Traced in code; live behaviour routed to Manual Verification.
- **Email delivery** (booking confirmations, auth confirmation) — needs a live inbox + Supabase SMTP; routed to Manual Verification.
- **Admin/employer surfaces** — out of member-side scope (only touched where member input flows into them, e.g. the admin XSS finding).
- **Screenshots** — the in-app browser pane reliably times out on capture in this environment; visual evidence is text/DOM-based (page text, computed values, network timings).

---

## Executive Summary

**Verdict: NOT READY — launch-blocking work remains.** The portal is a genuinely impressive, feature-complete build with a coherent green brand, warm Botswana-appropriate copy, strong empty states, and — importantly — a **correctly server-locked points ledger and RLS pattern for every table whose policy is in the repo**. The core member journey renders cleanly and, when signed in, works. But it is not safe to launch to a corporate client in two days as-is.

Three things I would say to the product owner first: **(1)** New members may not be able to sign up at all — the last recorded state (BATCH-0) was a Supabase mailer 500 on `signUp`, and the live custom domain `portal.keywellness.co.bw` currently fails HTTPS (certificate-name mismatch) and serves over plain HTTP — both must be verified/fixed before anyone is invited. **(2)** Three tables holding members' financial data — `tool_data`, `stress_logs`, `bookings` — have **no RLS policy anywhere in the repo**; if the live policies are missing or permissive, any logged-in member can read every other member's finances. This is unverified and must be confirmed in the Supabase dashboard before launch. **(3)** In the code itself there are real launch blockers: Sign Out doesn't clear the session/cached data for returning users (a privacy leak on shared computers), all 15 tool pages tell members "Saved" even when the cloud write fails (silent cross-device data loss), member names flow unescaped into the admin dashboard (stored XSS), and the welcome video can trap a first-time user for 6 minutes with no skip button if Vimeo is blocked — which corporate firewalls routinely do.

None of this is fatal to the product — the P0 list is finite, specific, and mostly fast to fix. But "READY" is not honest today. Fix the P0 batch, verify the three infra items, and this becomes launch-ready.

**Tally:** P0: 8 · P1: 12 · P2: 21.

---

## P0 — Launch Blockers

> Ordered by a blend of severity and how load-bearing they are for a two-day launch.

### P0-1 — Live custom domain fails HTTPS; site served over plain HTTP
- **Location / evidence:** `portal.keywellness.co.bw` (the CNAME target that `mogomotsifrance-star.github.io/keywellness-portal` 301-redirects to). Verified: `curl https://portal.keywellness.co.bw/` fails with `SEC_E_WRONG_PRINCIPAL` (certificate name mismatch); the github.io URL issues `301 → http://portal.keywellness.co.bw/` (insecure); plain HTTP returns 200 with the current app. The Cloudflare test site (`keywellness-portal.mogomotsifrance.workers.dev`) serves correctly over HTTPS.
- **Impact:** A financial portal handling personal income, debt, and net-worth data is currently reachable only over unencrypted HTTP; the HTTPS URL throws a full-page browser security warning. Credentials and financial data transit in clear text. Brand- and trust-destroying for an HR buyer.
- **Suggested fix:** In GitHub Pages settings, set the custom domain and enable "Enforce HTTPS" so GitHub provisions a Let's Encrypt cert for `portal.keywellness.co.bw`; confirm DNS. Until the cert is valid, do not distribute the custom-domain URL.
- **Fix size:** S (config), but depends on DNS/cert propagation — start immediately.

### P0-2 — New-member signup may be broken in production (Supabase mailer 500)
- **Location / evidence:** `index.html` `doSignup()` (~`:1361`) calls `sb.auth.signUp()`. `BATCH-0-FINDINGS.md` §0.2 records this returning HTTP 500 "Error sending confirmation email" from Supabase Auth (an SMTP/mailer misconfiguration), and `doSignup`'s error branch renders the raw error object (shows `{}`) with no `console.error`.
- **Impact:** If still true, **no new member can create an account** — the entire top of the funnel is dead. For a launch in two days this is the highest-order blocker.
- **Suggested fix:** Supabase Dashboard → Authentication → verify SMTP sender is configured and the confirmation-email template sends; then re-test signup end-to-end. Separately, fix `doSignup` to `console.error(error)` and surface `error.message` (not the object).
- **Fix size:** S–M (dashboard config + one code fix). **Requires manual verification** — cannot be confirmed from the repo.

### P0-3 — RLS not verifiable for `tool_data`, `stress_logs`, `bookings` (potential cross-member financial-data read)
- **Location / evidence:** These tables are read/written throughout the member client (`tool_data`: every calculator + `index.html:1008,2043,2726`; `stress_logs`: `index.html:847,4094`; `bookings`: `index.html:848,4442`), but **no `CREATE TABLE`/`CREATE POLICY` for any of them exists in the repo** (`supabase_bookings_missing_columns.sql` only adds columns). Every table whose policy *is* in the repo is correctly `auth.uid()`-scoped — but these three are invisible to static review.
- **Impact:** `tool_data` holds budgets, net worth, debt, and stress blobs; `stress_logs` holds per-member stress levels/notes; `bookings` holds member name/email/service. If the live RLS is missing or `USING (true)`, **any authenticated member can read all other members' financial data** — a catastrophic privacy breach and DPA violation. Because the app works, policies probably exist in the live dashboard, but this cannot be assumed.
- **Suggested fix:** In Supabase dashboard, confirm each has RLS enabled with `USING (user_id = auth.uid())` on select/insert/update/delete (bookings additionally allows admin read). Extend `browser_rls_test.js` to probe these three and run it as a normal member.
- **Fix size:** S to verify; S to fix if a policy is missing. **Requires manual verification.**

### P0-4 — Sign Out does not clear session/cached data for returning users (privacy leak on shared devices)
- **Location / evidence:** `index.html` — `init()` returns early inside the `if (currentUser) {…} return;` block (`~:5172-5189`) **before** `sb.auth.onAuthStateChange(...)` is registered (`~:5196`). `doLogout()` (`~:1406`) only calls `await sb.auth.signOut()` and relies entirely on the never-registered `SIGNED_OUT` handler (`~:5237`) to clear caches, null `currentUser`, and show the auth screen.
- **Impact:** For any returning member (the dominant path), clicking Sign Out removes the token but leaves the dashboard rendered, `currentUser` set, and all `kw_*` cached financial data in localStorage. On a shared/kiosk computer the next person sees the previous member's finances until a manual reload. `onAuthStateChange` also being unregistered means mid-session token expiry is unhandled. (`switchAccount()` resets manually and works — the main Sign Out does not.)
- **Suggested fix:** Register `onAuthStateChange` unconditionally *before* the `if (currentUser)` branch, **and** make `doLogout()` self-contained: `await sb.auth.signOut(); clearLocalUserCache(); clearSessionTrust(); currentUser=null; window.location.replace(location.pathname);`.
- **Fix size:** S.

### P0-5 — All 15 tool pages report "Saved" even when the cloud write fails (silent cross-device data loss)
- **Location / evidence:** Every tool page writes localStorage synchronously, fires the `tool_data` upsert **unawaited**, logs any error to console only, then shows the "Saved" toast unconditionally. Representative sites: `budget_planner.html:530→532`, `expense_tracker.html:431→433`, `goal_planner.html:456→458`, `debt_management_planner.html:507→509`, `financial_stress_tracker.html:500→502`; the five calculators (`affordability:495`, `investment:423`, `loan:666`, `rent_vs_buy:603`, `retirement:693`) upsert to `tool_data` with **no localStorage fallback and no toast at all**. On load, cloud data overwrites localStorage when a cloud row exists (`budget_planner.html:1409-1421`), so an edit that failed to sync is silently discarded on the next device.
- **Impact:** A member edits their budget/goals/debt plan, sees a green "Saved", and believes it's stored. If the token expired or the network blipped, it reached only that browser. Switching devices silently loses the data. False confirmation on a core journey = trust-destroying. (`wellness_assessment.html:885` already does this correctly — the tool pages are inconsistent with it.)
- **Suggested fix:** `await` the upsert and gate the toast: `const {error}=await _sb....; showToast(error ? 'Saved on this device only — cloud sync failed' : 'Saved');`. Fix the shared save helper once; it propagates to all 15.
- **Fix size:** M (one pattern, 15 files).

### P0-6 — Stored XSS: member name / booking fields render unescaped in the admin dashboard
- **Location / evidence:** `admin.html:551` renders `${name}` (member's own `first_name`+`last_name`) into `innerHTML` without escaping; `admin.html:710-711` renders `${b.user_name}` / `${b.user_email}` (written by the member at booking time, `index.html:4442-4445`) unescaped. `escHtml` exists in the file and is used elsewhere (`:850,873`) — the omission is inconsistent. Member injection points: onboarding names (`index.html:1662,1670`) and profile names (`index.html:4875,4879`), stored raw with no `maxlength`.
- **Impact:** A member setting their first name to `<img src=x onerror=…>` executes arbitrary JavaScript in the **admin's** authenticated session when staff open the dashboard → admin-session takeover, which can read/exfiltrate all member data. `employer.html` correctly escapes everywhere, so this is an admin-surface hole fed by member input. Security exposure.
- **Suggested fix:** Wrap `admin.html:551,710,711` in `escHtml(...)`; add `maxlength="60"` + `escHtml` on the name inputs/attributes in `index.html`.
- **Fix size:** S.

### P0-7 — Reward-bearing points can be minted from the console; badge counts are forgeable
- **Location / evidence:** `supabase_points_ledger.sql:183-189` — `article_read` (15pts), `video_watched` (25pts), `tool_first_use` (25pts) have **no server-side evidence check** (`v_ok := true`) and trust the client's `p_ref_id`; the unique `(user_id,event_type,ref_id)` constraint only blocks repeating the *same* ref_id, so a loop over distinct ref_ids mints unlimited points. `session_booked` (100pts, `:144-148`) is gated only on a `bookings` row the member can self-insert. These flow into `org_leaderboard`/`org_rewards` — the **HR prize list** (`supabase_leaderboard.sql:57-61,124-129`). Separately, `badges` is directly client-writable (`supabase_multitenancy.sql:113-117`) and awards are client-decided (`kw-badges.js:332-351`, `index.html:969-973`); the leaderboard counts public badges straight from that array (`supabase_leaderboard.sql:64-70`), so a member can upsert all badge ids and top the count. The live test account already holds **3,340 points**.
- **Impact:** Per the brief's rule, client-mutable points are **P0 when reward-bearing** — they are (HR-visible payout list). A member can fabricate points/badges to win real rewards, undermining the program's integrity with the buyer.
- **Suggested fix:** Gate content events on a server-verifiable backing row (e.g. `content_progress` for `video_watched`) or a per-(user,event_type,season) cap inside `award_points`; only credit `session_booked` on staff-confirmed bookings; move badge-earning behind a SECURITY DEFINER RPC (or compute `badge_count` from evidence, not a client-writable array).
- **Fix size:** M–L (SQL RPC changes + retest). If the rewards program is not live at launch, this can drop to P1 — confirm with the team.

### P0-8 — Assessment shows "success" to the member even when the Supabase insert fails
- **Location / evidence:** `wellness_assessment.html:742` — `function showToast(){…}` **ignores its argument** and always reveals the fixed DOM pill reading "Progress saved". The error paths call it *with* messages (`:885 'Could not save to cloud…'`, `:924 '⚠️ …profile figures could not be updated'`) that never display. The results screen renders unconditionally (the save is a fire-and-forget IIFE `:866-928`).
- **Impact:** If the `assessments` insert fails (expired token, RLS, network), the member sees their full report and a "saved" state, but nothing persisted — Progress history, HR aggregates, and the `assessment_complete`/`improvement` points never happen, with no retry. Silent data loss on the portal's primary on-ramp.
- **Suggested fix:** Make `showToast(msg)` render its argument (as `index.html:1566` does) and show a real error banner on `insertErr`; queue the payload to localStorage and retry on next load.
- **Fix size:** S (toast) + S (retry).

---

## P1 — Should Fix Before Launch If Time Allows

### P1-1 — Welcome-video modal has no skip/close; traps first-run for up to 6 minutes
`index.html:476-494` (markup) + `:2639-2665`. The "Start My Assessment" button is hidden until the Vimeo `ended` event or a **360000ms (6-min) timeout**. There is **no skip/close control** despite the code comment at `:2641` claiming "The 'Skip intro' link is always available" — it is not in the markup. If Vimeo is blocked (corporate firewalls routinely do — **very likely at Debswana**), a brand-new member stares at an unclosable modal for 6 minutes. *Fix: add an always-visible "Skip intro →" link in `#welcome-wait-msg` that calls `closeWelcome()`.* **This is effectively P0 on any network that blocks Vimeo — verify the client network before demo.** Size: S.

### P1-2 — `booking_form_v2.html` is entirely off-brand and localStorage-only (a loaded gun)
It is the only page that does **not** import `kw-theme.css` and hardcodes the legacy palette (`:11` navy `#0D2545`, gold `#C8991A`, non-brand green `#1A8C5B`), uses gold-as-text (fails contrast ~2.6:1) and gold/navy button fills, and Inter font. Its submit handler (`:551-566`) writes **only** `localStorage.kw_client_bookings_v1` — **no Supabase insert, no email** — so any booking made through it is invisible to staff forever. It is currently unreferenced (dead), so harmless today, but if it is ever linked it becomes an instant P0. *Fix: delete the file (or, if kept, rewrite to the shared booking pipeline + `kw-theme.css`).* Size: S.

### P1-3 — Assessment PDF renders in the legacy gold/navy palette (off-brand member deliverable)
`wellness_assessment.html:1051` hardcodes `NAVY=[13,37,69]`, `GOLD=[200,153,26]`, `GREEN=[26,140,91]` — none are the current brand values, and section labels (`:1071,1081`) print gold text on white (~2.6:1, illegible). The one artefact a member downloads and may forward to family/HR looks nothing like the green brand and has no logo. *Fix: swap constants to brand values (navy `[26,39,68]`, accents → green `[57,126,43]`), stop gold-on-white text, embed the logo.* Size: S.

### P1-4 — Sidebar and mobile bottom-nav are not keyboard operable
`index.html:1481-1488` — `buildNav()` renders nav as `<div class="sb-item" onclick=…>` / `<div class="bn-item" onclick=…>`: plain divs, no `tabindex`, `role`, or `onkeydown`. They are unreachable by keyboard (the "More" sheet at `:1499-1500` shows the correct `role="menuitem" tabindex="0" onkeydown` pattern). No `:focus-visible` exists for nav items either. WCAG 2.1.1 (Keyboard) failure on primary navigation. *Fix: make them `<button>`/`<a>` (or add `role`+`tabindex`+`onkeydown`) and add a shared `:focus-visible` ring.* Size: S–M.

### P1-5 — Mobile bottom-nav is dead code (killed by `!important`)
`index.html:404` — `#bottom-nav{display:none!important}` hides the bar at **all** widths, overriding the desktop-only rule at `:403`; nothing ever sets it to `display:flex`. The 5-item `MOBILE_NAV` + "More" sheet are dead code. Mobile nav survives only via the hamburger → full sidebar drawer (which does list all 12 items, so **all views are reachable at 375px** — via a different mechanism than the code implies). Either a leftover kill-switch or a regression. *Fix: decide one model — restore the bottom bar (`@media(max-width:768px){#bottom-nav{display:flex!important}}`) or delete the dead markup/JS.* Size: S. **Verify intended design.**

### P1-6 — Profile save shows "✓ Saved" even when the write fails
`index.html:4951-4956` — `saveUser().catch(()=>{})` then unconditionally shows "✓ Profile saved!". A rejected Supabase write is reported as success. *Fix: show success only in `.then`, an error notice in `.catch`.* Size: S.

### P1-7 — My Bookings renders the "No bookings yet" empty state on load *failure*
`index.html:4795-4811` — on error, `bookings = data || []` falls through to the friendly empty state, so a member whose bookings failed to load is told they have none (they may think a session request vanished). *Fix: branch on `error` → distinct retry card.* Size: S.

### P1-8 — Supabase JS SDK load failure → permanent blank page
`index.html:761-762` — `const { createClient } = window.supabase; const sb = createClient(...)` at top-level. If the `cdn.jsdelivr.net` script (`:12`) fails to load (offline, CDN outage, firewall), `window.supabase` is undefined, the line throws at eval time, and the entire inline script never runs — no auth screen, no error, permanent blank page. *Fix: guard `if(!window.supabase){show retry banner}` before `createClient`, or self-host the SDK.* Size: S.

### P1-9 — Malformed localStorage in the notifications keys bricks login
`index.html:5009-5068` (`generateSmartNotifs`/`loadNotifications`) contain unguarded `JSON.parse` of 7 keys, and are called at `:5194` — **before** `onAuthStateChange` is registered at `:5196`, inside an unguarded `async init()`. If any of `kw_notifs`, `kw_notifs_dismissed`, `kw_snapshot`, `kw_profile`, `kw_goals`, `kw_ef_cache`, `financial_stress_v1`, `kw_assessment_result`, `kw_bookings` holds corrupted JSON (partial write, extension interference), `init()` throws and the auth listener is never registered → the user cannot sign in on that browser until localStorage is cleared. *Fix: central `safeParse(key, fallback)` try/catch helper across all `index.html` localStorage reads.* Size: M.

### P1-10 — Points/badge integrity via forged evidence rows (secondary vectors)
`supabase_points_ledger.sql:125-181` — `improvement` (150pts) and `checkin_streak_3` (150pts) read `assessments`/`checkins`, which members insert with arbitrary `cat_scores` and client-supplied `created_at` (`supabase_multitenancy.sql:83-103`; `wellness_assessment.html:876`, `index.html:4093`). A member can insert two rising-score assessments (mint improvement) or three back-dated check-ins (mint streak) per quarter. Period-bounded, so lower volume than P0-7, but still forged reward points. *Fix: enforce server `created_at default now()` and reject client timestamps; validate `cat_scores` ranges.* Size: M.

### P1-11 — `stress_logs` insert failure is silently swallowed in Check-in
`index.html:4092-4102` — `checkins` and `stress_logs` are inserted in a `Promise.all`, but only `ciRes.error` is checked; `slRes.error` is never read. If the check-in saves and the stress row fails (token refresh mid-flight, RLS/schema drift), the member sees "Check-in saved!" while the granular stress datum (which feeds the HR org-stress summary) is silently lost. *Fix: check `slRes.error` and warn.* Size: S.

### P1-12 — `--kw-grey` and `--kw-yellow-ink` fail WCAG AA as text
`css/kw-theme.css` — `--kw-grey #808185` on canvas `#fbfcfa` ≈ **3.75:1** and on white ≈ **3.89:1** (both < 4.5:1), used for `.kw-label` (11px) and pervasive captions/muted text. `--kw-yellow-ink #93790a` on white ≈ **4.22:1** (< 4.5), used as gauge/label text (e.g. `dti_calculator.html:667,698`). Small muted text across the app is below AA. *Fix: darken grey to ≥ `#6c6d70` for text uses; use `--kw-yellow-ink` only on `--kw-yellow-tint`, not on white.* Size: S–M.

---

## P2 — Post-Launch

1. **Signup success leaves user on the "Create Account" tab** — `index.html:1397` `authOk('Account created! Check your email…')` doesn't switch to Sign In or prefill email. (The reported "Or sign in now if email confirmation is disabled" hedge does **not** exist in current code — already removed.) Fix: `showAuthTab('login')` + prefill. S.
2. **Post-email-confirmation lands on the password re-auth wall** — `index.html:5152-5164` only special-cases `type=recovery`; a new user clicking the signup link hits the "Confirm your identity" overlay 60s after setting their password. Fix: treat `type=signup` as a trusted first entry. S.
3. **`doResetPassword` strands the submit button on a thrown exception** — `index.html:1427-1439`, no try/finally; a network throw leaves the button disabled forever. S.
4. **`confirmSession` strands its button on a thrown exception** — `index.html:1190-1213`, same pattern. S.
5. **`doForgotPassword` has no double-submit guard** — `index.html:1416-1425`; repeated clicks fire multiple reset emails. S.
6. **Password-reset auto-signin bounces to the login screen** — `index.html:1437-1438` sets `#dashboard` after `updateUser`, but `currentUser` is never set (listener not registered in the recovery branch) so `route()` shows the auth screen despite "Signing you in…". Requires manual test. S.
7. **Net Worth tool: top-level unguarded `JSON.parse`** — `net_worth_tracker.html:174`; malformed `kw_networth_v1` kills the whole page at load. Fix: wrap in try/catch. S.
8. **Other unguarded `JSON.parse` → blank views** — `index.html:2133,2388,2628,2699,4225,4465,4846,4925,4939,4984,5211,1735`; malformed `kw_snapshot`/`kw_profile` blanks the dashboard/profile/booking view. Covered by the P1-9 `safeParse` helper. S.
9. **Assessment DB insert failure has no retry** — `wellness_assessment.html:883`; warned but the row is permanently lost (localStorage copy survives for the dashboard). Fix: queue + retry. S.
10. **EmailJS is dead code shipping an extra third-party script** — `wellness_assessment.html:15,1022-1046`; `sendReport()` returns early on placeholder keys (**no real key exposed**). Would email a member's full financial breakdown to a shared inbox if ever enabled — a privacy concern. Fix: remove the script + `sendReport`/`showEmailBanner`. S.
11. **Assessment PDF: long client name not wrapped/truncated** — `wellness_assessment.html:1057`; `pdfSafe()` exists (`kw-badges.js:385`) but isn't applied to the name, so a long or emoji name overflows/garbles the header. Fix: `splitTextToSize(pdfSafe(name), maxW)`. S.
12. **`restartAssessment` doesn't fully reset reassessment state** — `wellness_assessment.html:1096-1102`; doesn't clear `kw_assessment_result`/`kw_snapshot` or `_isReassessment`, so a restarted reassessment can complete with money inputs hidden. S.
13. **Onboarding advances even if `saveUser()` fails** — `index.html:1730-1755`; return value ignored, so `onboarded` may not persist → re-onboarding on another device. Requires manual test. S.
14. **Consent write not error-checked** — `index.html:2601`; localStorage flag is set first, suppressing re-prompts even if the server never recorded consent (DPA record can silently fail). S.
15. **`budget_planner.pf()` doesn't strip a leading `-`** — `budget_planner.html:570`; a negative value reaching `pf` from a non-sanitized source flows into surplus/savings math. Low likelihood. S.
16. **Emergency Fund sub-label grammar** — `index.html:2307` renders "Saved · add monthly expenses for months". Fix copy. XS.
17. **Debt Planner uses native `alert()` + method-agnostic "Snowball" label** — `debt_management_planner.html:629,230`; jarring vs the app's toast style, and the "Extra Snowball Payment" field stays labelled "Snowball" under Avalanche. S.
18. **Stray `Inter` font references** — app loads Nunito+DM Mono only, but `Inter` lingers in `index.html:509,1603`, `budget_planner.html:373,1200`, `expense_tracker.html:298,344`, `dti_calculator.html:278`, `admin.html:331`, `employer.html:1215` → silent fallback to generic sans. Fix: replace with `Nunito`. S.
19. **Component drift across tool pages** — every page redefines local `.card`/`.btn`/inputs instead of the shared `.kw-*` classes: card padding 22 vs 24 (`budget_planner.html:53`), `index.html:83` `.card` adds a shadow `.kw-card` lacks, three different yellow notice recipes, progress-bar heights 6–10px. On-palette but inconsistent. Fix: consolidate onto `kw-theme.css` classes. M.
20. **Emoji-as-icons in primary nav/chrome** — `index.html:1445-1463` etc.; render differently per OS, can't be brand-colored, read informally for a corporate financial product. Recommend an inline-SVG icon set (`stroke:currentColor`). M.
21. **Misc a11y/UX polish** — bottom-nav touch targets ~40px (< 44px, `index.html:405`); color-only status dots in `admin.html:598` / `financial_stress_tracker.html` heatmap need a non-color cue; badges & notifications lack a first-time orientation line; `openTool()` always returns to `#dashboard` not the origin view (`index.html:1577`); retirement calculator jargon "COLA"/"nominal"/"drawdown" unexplained (`retirement_calculator.html:237,286`); inconsistent page max-widths (960 vs 1100 vs 680). Each S.

---

## Data-Storage Table (data-integrity risk map)

| Feature | Storage | Survives logout? | Survives device change? | Syncs to Supabase? | Notes |
|---|---|---|---|---|---|
| Profile / onboarding | Supabase `profiles` + `kw_profile` (name), `kw_consent_accepted` | Yes (DB) | Yes | Yes (`saveUser()` `:913`) | Onboarding advances even if save fails (P2-13); profile save false-success (P1-6) |
| Assessment | Supabase `assessments` + `profiles` + `kw_assessment_result`, `kw_snapshot` | Yes | Yes *if insert ran* | Yes (`wellness_assessment.html:876`) | False "saved" on insert failure (P0-8); no retry (P2-9) |
| Check-ins | Supabase `checkins` + `state` | Yes | Yes | Yes (`:4093`) | Primary insert error surfaced (good) |
| Stress (in-portal check-in) | Supabase `stress_logs` + `financial_stress_v1` | Yes | Partial | Partial — **insert error ignored** (P1-11) | Granular stress row can be silently lost |
| Stress tracker (standalone) | Supabase `tool_data` + `kw_snapshot` | Yes (local) | Only if upsert succeeded | Yes, error swallowed (P0-5) | |
| Emergency Fund | Supabase `emergency_fund` | Yes (DB) | Yes | Yes (`:978`) | Error surfaced via toast (good) |
| Badges | Supabase `badges.earned_badge_ids` | Yes | Yes | Yes (`kw-badges.js:332`) | **Client-writable & client-decided** → forgeable count (P0-7) |
| Points | Supabase ledger via `award_points()` RPC | Yes | Yes | Yes | Amount server-locked (good); **award count client-controllable** (P0-7/P1-10) |
| Bookings (index.html) | Supabase `bookings` + `kw_bookings` (reminder cache) | Yes (DB) | Yes | Yes (`:4442`) | DB is source of truth; My Bookings reads DB-only (good). RLS unverified (P0-3) |
| Bookings (booking_form_v2.html) | **localStorage `kw_client_bookings_v1` only** | Yes (local) | **No** | **No** | **Orphaned/dead** — staff never see these (P1-2) |
| Calculators (affordability, investment, loan, rent_vs_buy, retirement) | Supabase `tool_data` **only** (no localStorage) | **No (in-memory)** | Only if upsert succeeded | Yes, error swallowed, no toast | Logged-out = nothing persists (P0-5) |
| Trackers/planners (budget, expense, goal, debt, net_worth, dti, education, lifestyle, life_insurance) | Supabase `tool_data` + per-tool `LS_KEY` + `kw_snapshot` | Yes (local) | Only if upsert succeeded | Yes, error swallowed | False "Saved" (P0-5) |
| Notifications | Derived + `kw_notifs`, `kw_notifs_dismissed` | Yes (local) | **No** (dismissals device-local) | No (by design) | Malformed value can brick login (P1-9) |
| LMS progress | Supabase `content_progress`, `quiz_attempts`, `certificates` via RPCs | Yes | Yes | Yes (`:3060/3215/3333`) | All errors surfaced (good); RLS correct in repo |
| Rewards | Supabase `my_reward_fulfilments()` RPC | Yes | Yes | Yes (`:4634`) | Error surfaced in-UI (good); RLS correct in repo |
| Session trust | `kw_active_uid`, `kw_session_trust` | n/a | No | No | Not cleared on returning-user logout (P0-4) |

**Sync strategy for tool pages:** localStorage written first (sync) → `tool_data` upsert fired unawaited → "Saved" shown unconditionally. On load, cloud wins over localStorage when a cloud row exists. Offline/logged-out: upsert skipped, only localStorage written. **A failed or skipped cloud write is invisible to the member** (P0-5).

---

## Untested — Manual Verification Required

Each is runnable by Tshenolo or Lone in under 5 minutes.

1. **RLS on `tool_data`, `stress_logs`, `bookings`, `admins` (P0-3).** Supabase Dashboard → Table Editor → each table → RLS: confirm enabled with `USING (user_id = auth.uid())` (bookings also admin read). *Runtime:* sign in as a normal member, in the browser console run `await sb.from('tool_data').select('user_id')` — it must return **only** your own `user_id`. Repeat for `stress_logs`, `bookings`. Any foreign row = P0 breach. (Extend `browser_rls_test.js` to cover these three.)
2. **Signup end-to-end (P0-2).** In an incognito window on the live site, create a brand-new account with a real inbox. Confirm: no 500, a confirmation email arrives, the link logs you in and lands on onboarding. If it 500s → Supabase → Auth → SMTP settings.
3. **HTTPS on the live domain (P0-1).** Visit `https://portal.keywellness.co.bw/` in a browser — must load with a valid padlock, no cert warning, no downgrade to `http://`.
4. **`bookings.requested_time` migration applied (BATCH-0 §0.5).** In Supabase, confirm `bookings.requested_time` column exists. If not, every booking insert fails with PGRST204. *Runtime:* make a test booking end-to-end and confirm it appears in `admin.html`.
5. **Booking + auth emails deliver (Resend/SMTP).** Make a test booking; confirm the member confirmation and the team notification both arrive at `wellness@keywellness.co.bw`.
6. **Welcome-video behaviour when Vimeo is blocked (P1-1).** On the Debswana network (or with Vimeo blocked in DevTools), reach the welcome modal as a new user — confirm whether the member is trapped for 6 minutes with no skip. If Vimeo is blocked corporate-wide, escalate P1-1 to P0.
7. **Mobile nav model at 375px (P1-5).** On a phone/emulator, confirm all 12 destinations are reachable via the hamburger drawer and decide whether the bottom bar should be restored or the dead code removed.
8. **Cross-device persistence (P0-5).** Save a budget on device A while offline/expired, then open it on device B — confirm whether the edit is silently lost despite the "Saved" toast.
9. **Password-reset auto-signin (P2-6)** and **onboarding-flag persistence across devices (P2-13).**
10. **Corrupted-localStorage login brick (P1-9).** In console: `localStorage.setItem('kw_notifs','{bad')` then reload — confirm whether login/logout stops working.

---

## BUILD-NOTES Addendum (non-code launch tasks)

- **DNS / HTTPS:** provision a valid cert for `portal.keywellness.co.bw` and enforce HTTPS (P0-1).
- **Supabase Auth SMTP:** verify the confirmation-email sender so signup works (P0-2); confirm auth email templates (repo has `email-templates/auth/*.html`).
- **Supabase RLS dashboard audit:** confirm/repair policies on `tool_data`, `stress_logs`, `bookings`, `admins` (P0-3); these have no repo DDL.
- **Resend domain verification:** confirm `keywellness.co.bw` is verified in Resend and `RESEND_API_KEY` is set on the Edge Function (`send-booking-email/index.ts:22`).
- **Email link domain mismatch (BATCH-0):** `KW_PORTAL_URL`/`KW_LOGO_URL` point at `mogomotsifrance-star.github.io` (→ redirects to the broken-HTTPS custom domain); the logo URL currently 404s / fails HTTPS, so **email logos will break**. Decide the canonical public URL and update `_shared/kw-email.ts:28-30`.
- **Prolearn certificate assets:** `prolearn-logo.png` / signature / preview template are absent from the repo — certificates will show broken placeholders until supplied. Also obtain written intra-group authorisation for the non-BQA "Certificate of Completion" wording.
- **Rewards seasonal tuning:** Pathway-1 alone injects ~425–450 Learning points/member vs the `reward_thresholds.learning.returning_points = 150` — decide whether to raise the threshold (BATCH-0-LMS §D).
- **Storage egress:** ~380MB of Pathway-1 videos in the `Videos` bucket — watch Supabase egress after month 1; R2 fallback via `LP_VIDEOS_BASE` swap if needed.
- **Data housekeeping:** remove throwaway `kwtest.batch0.*@mailinator.com` auth users if present.
- **Privacy copy:** the consent modal (`index.html:449-472`) says data is "accessible only by you and authorised Key Wellness advisors" but **never states that the member's employer/HR cannot see individual finances** — the exact assurance that drives honest engagement. Add an explicit "Your employer can never see your individual data — only anonymous, aggregated group trends (min. 5 people)" line at onboarding/consent. (The `org_overview` n≥5 suppression backs this up technically; it just isn't communicated.)

---

## Proposed Fix Plan (dependency-ordered batches for a follow-up prompt)

**Batch A — Infra / go-live gates (do first; mostly dashboard, some external latency).**
P0-1 (HTTPS/DNS), P0-2 (signup SMTP), P0-3 (verify RLS on the three tables), plus BUILD-NOTES email-domain + Resend verification. *These are verify-or-fix and may already be resolved server-side — but must be confirmed before anyone is invited.*

**Batch B — Auth & data-integrity code fixes (highest code risk, low interdependence).**
P0-4 (register `onAuthStateChange` unconditionally + self-contained `doLogout`) → unblocks P1 auth-button fixes (P2-3/4/5/6). P0-5 (fix the shared tool-page save helper: await upsert, gate toast) — one change, 15 files. P0-8 (`showToast(msg)` + assessment retry). P1-6, P1-7, P1-11 (surface swallowed save/load errors). P1-8 (SDK-load guard) + P1-9 (`safeParse` helper — also clears the P2-8 blank-view class and P2-7 net-worth crash).

**Batch C — Security & integrity.**
P0-6 (escape member input in `admin.html` + `maxlength` on names). P0-7 + P1-10 (points/badge server-side gating in `supabase_points_ledger.sql` + move badge awards to an RPC) — SQL work, test in a branch. *If rewards aren't live at launch, this batch can trail P0-6.*

**Batch D — First-run & brand-facing.**
P1-1 (welcome-video skip link — quick, high-impact). P1-2 (delete/rewrite `booking_form_v2.html`). P1-3 (assessment PDF palette + logo). P1-4 (keyboard nav + focus-visible). P1-5 (resolve mobile-nav model). P1-12 (contrast on grey/yellow-ink).

**Batch E — Polish (post-launch).**
The P2 list: copy fixes, Inter→Nunito, component-class consolidation, SVG icons, EmailJS removal, restart-assessment reset, and the a11y touch-target/color-cue items.

---

## Verification Checklist (engagement close-out)

- [x] Zero tracked files modified *by the audit*; only `AUDIT-REPORT.md` created (audit-only honoured).
- [⚠] Branch still `dev`. HEAD moved from `93bdf1a` → `28af163` **during** the audit via a feature commit made by a **separate** session/tool (not this audit — zero git writes were issued here). See the ⚠ baseline note in the header for line-number and Learn/LMS implications.
- [x] No Supabase writes executed (sign-in for read-only verification only; the blocked cross-tenant probe was **not** worked around).
- [x] Every finding has location, evidence, severity, and a suggested fix.
- [x] Data-storage table complete for every member feature.
- [x] Executive summary gives an unambiguous verdict (**NOT READY**).
- [x] No fixes attempted.

*Prepared read-only. No code was changed. Awaiting your review before any fix work begins.*
