# Launch Bug-Fix Batch (currency prefix overlap, EF prefill, budget income prefill, lifestyle verdict)

Frontend-only, zero Supabase writes/DDL, per the launch-week prompt. One commit
per batch on `dev`; rollback = `git revert <sha>`:

| Batch | Commit | Files |
|---|---|---|
| 1 — currency prefix overlap | `0e16d0d` | lifestyle_inflation_calculator.html, education_savings_calculator.html |
| 2 — EF prefill + figure parsing | `8779598` | index.html, wellness_assessment.html |
| 3 — budget income prefill | `40babb2` | budget_planner.html |
| 4 — lifestyle verdict consistency | `8cd373e` | lifestyle_inflation_calculator.html |

**Root causes (differ from the prompt's hypotheses — full evidence in the session
report):** the prefix padding rule wasn't missing, it was *overridden* by a later
equal-specificity `input[type=…]{padding:…}` shorthand (education_savings had the
identical bug, fixed too); the EF "corrupted figures" were wrong-source prefill
(`monthly_expenses` preferred over `essential_expenses`, and `total_savings`
shown as the emergency balance — the assessment's own `emergencyFund` figure was
never persisted anywhere), not a comma-parse bug.

## Human action needed / post-launch follow-ups

1. **Prefix-markup consolidation (post-launch)**: three different currency-prefix
   systems coexist across the tools — flex `.input-wrap`/`.input-prefix` (7 files),
   flex `.iw`/`.iw-prefix`/`.iw-pre` (loan, investment, budget), and
   absolutely-positioned `.iw .prefix` (education, lifestyle, life_insurance — the
   only fragile one, now specificity-hardened per file). Schedule a shared-CSS
   consolidation to one pattern (the flex one is structurally overlap-proof) once
   launch settles.
2. **Post-launch data check (Key Wellness staff)**: assessments completed before
   this fix parsed commas correctly in the current code, but *older* app versions
   may have written formatted strings into `emergency_fund` rows or profile figure
   columns. The frontend now self-heals such values at read time and logs a
   `console.warn` (`[KW] EF: coerced …`) — if those warnings show up for real
   members, run a one-off data cleanup on `emergency_fund` /
   `profiles.{monthly_expenses,essential_expenses,total_savings,…}`.
3. **Members assessed before this fix** have no `figures` in their local
   `kw_assessment_result` until they reassess — EF/budget prefill falls back to
   the profile columns (cross-device, seeded at their last assessment), and the
   EF Current Savings field degrades to the honest empty state (the misleading
   `total_savings` fallback was removed deliberately).
4. **`kw_ef_cache` is a dead key**: index.html's EF notification reads it but
   nothing writes it anymore — the "Emergency Fund Alert" notification can never
   fire for new members. Read is now coercion-hardened; decide post-launch whether
   to re-wire it to the live EF row or delete the notification.
5. **Behaviour change (deliberate, per launch spec)**: creating a *blank* new
   month when prior months exist no longer auto-seeds Primary Salary from the
   profile — prefill now applies only to a member's first-ever budget.
   Copy-from-month is unchanged.
6. **Pre-existing bug spotted, not fixed (out of scope)**:
   lifestyle_inflation_calculator.html saves/restores a non-existent
   `horizonYears` element instead of `projYears`, so the projection-years slider
   never persists to `tool_data`.

---

# Fixes & Diagnosis Batch (password toggle, email logo/links, signup errors, opt-in refresh, admin time column)

Per `kw-fixes-diagnosis.md`'s batch plan. Full discovery in `BATCH-0-FINDINGS.md`
(replaces an unrelated stale version from a prior workstream — see that file's own
note). Two decisions confirmed with Tshenolo before proceeding past Batch 0:

1. **Domain**: `keywellness.co.bw` is a live, unrelated WordPress marketing site
   (every asset/page path 404s) — not this portal. Tshenolo confirmed the plan is a
   future subdomain, `portal.keywellness.co.bw`, not yet live. Batches 2/4 point
   every email URL at the current real production URL,
   `https://mogomotsifrance-star.github.io/keywellness-portal`, instead. **Revisit
   once `portal.keywellness.co.bw` DNS is live** — swap `KW_LOGO_URL` and the
   hardcoded admin-link/footer URLs in `kw-email.ts` and
   `send-booking-email/index.ts` to the new subdomain then.
2. **Signup 500**: root cause is Supabase Auth itself failing to send the
   confirmation email (`error_code: unexpected_failure`, `msg: "Error sending
   confirmation email"`) — an Authentication → SMTP dashboard setting, not
   reachable from this repo. Tshenolo confirmed: do Batch 3.1 (error surfacing)
   only; 3.2's proposed trigger/invite-code fix doesn't apply and is out of scope.
   **Manual follow-up required**: check Supabase dashboard → Authentication →
   Email/SMTP settings — this is a live, in-production signup outage, not cosmetic.

Rollback statements are recorded at the start of each batch's own section below,
before that batch's changes are described, per this workstream's standing rule.

---

## Batch 1 — Password visibility toggle (index.html)

Rollback: `git revert` this commit — pure frontend addition (CSS + one JS function +
markup wrapping), no DB/Edge Function involved.

Added `.pw-field`/`.pw-toggle` CSS (muted/navy palette, no yellow fill, 40×40px touch
target) and a single shared `togglePwVisibility(btn, inputId)` function with two
inline SVG icon constants (`PW_EYE`/`PW_EYE_OFF`, stroke-based line icons). Applied to
all 6 password inputs found in the app: sign-in (`a-pass`), sign-up (`b-pass`,
`b-pass2`), password-reset (`r-pass`, `r-pass2`), and the session re-confirm overlay
(`sc-pass`) — the last one isn't one of the four forms named explicitly in the batch
spec, but it is a password input in an auth-adjacent flow ("every password input
across auth forms" per the spec's own opening line), so included for consistency.
`admin.html`/`employer.html` have no password inputs of their own (both route through
`index.html`'s auth) — confirmed via grep, zero matches.

Each toggle is a real `<button type="button">` (no form submission, confirmed by
testing Enter-key behavior on `a-pass` doesn't submit), `aria-label`/`aria-pressed`
swap correctly on toggle, and the field value is preserved across the type
`password`↔`text` swap (browsers don't clear input value on a `type` change).

**Verified in-browser** (real click + fill via preview tools, not just eval): filled
`a-pass`, clicked the toggle, confirmed `type` became `text`, value stayed
`"MySecret123"`, `aria-label` became "Hide password", `aria-pressed` became `"true"`,
screenshot showed the password in plain text with the eye-off icon. Repeated for both
signup fields (`b-pass`/`b-pass2`) — both render with the icon and default "Show
password" label. No console errors. Keyboard: native `<button>` is focusable
(`tabIndex: 0`) and responds to Enter/Space via default browser button-activation
behavior (no custom key handler needed, none added).

---

## Batch 2 — Email logo/link domain fix (kw-email.ts + send-booking-email)

**Production-immediate — Edge Function not yet redeployed, see below.**

Rollback: `git revert` this commit, then `supabase functions deploy send-booking-email`
to push the reverted `_shared/kw-email.ts` back out (shared module, bundled at deploy
time — reverting the repo file alone doesn't un-deploy it).

Per Tshenolo's decision (recorded at the top of this section): `keywellness.co.bw` is
a separate live WordPress site; the real portal lives at
`https://mogomotsifrance-star.github.io/keywellness-portal` today, with
`portal.keywellness.co.bw` planned as a future subdomain. Added one new exported
constant, `KW_PORTAL_URL`, in `kw-email.ts` as the single source of truth — every
other URL in the module now derives from it:

- `KW_LOGO_URL` → `${KW_PORTAL_URL}/assets/img/kw-logo-horizontal.png` (was the
  broken `keywellness.co.bw` path).
- Footer "site" link → `KW_PORTAL_URL` directly (was `keywellness.co.bw`, and the
  link text changed from the bare domain to "Key Wellness Portal" since it now points
  at the portal itself, not a marketing homepage).
- Footer **Privacy link removed entirely**, not repointed — no Privacy page exists
  anywhere (not on the WordPress site, not on the portal; confirmed in
  BATCH-0-FINDINGS 0.1). Per this workstream's own Batch 4 principle ("if the portal
  has no URL routing for that view... do not invent hash-routing"), extended here:
  don't link to a page that doesn't exist either. Flagged below as a manual
  follow-up — re-add the link once a real Privacy page exists.
- Certificate-reward email's "Manage preferences" link →
  `${KW_PORTAL_URL}/#profile` (was `keywellness.co.bw/#profile`) — this one **will
  actually work**, since `index.html` has a real `hashchange`-driven router and a
  `#profile` view.
- `send-booking-email/index.ts`'s "Open in admin" button →
  `${KW_PORTAL_URL}/admin.html` (was `keywellness.co.bw/admin.html`, confirmed 404).

**`email-templates/auth/*.html` deliberately NOT touched** — attempted a repo-wide
sed pass across those 5 files to carry the same fix, and the environment's own
permission classifier blocked it, correctly reading this batch's "Do not touch the
Supabase dashboard Auth templates... out of scope for Claude Code" instruction as
covering the repo source files that feed that manual paste, not just the live
dashboard itself. Left as-is; still flagged (per Batch 0) that these 5 files carry
the identical broken-domain bug in their logo `src` and footer links, and whoever
pastes them into the dashboard by hand should apply the same `KW_PORTAL_URL` fix
manually.

**Verified without Deno** (not installed in this environment) — Node 24's native
TypeScript type-stripping loaded `kw-email.ts` directly (`require('./kw-email.ts')`
works as-is on this Node version, no build step). Rendered a sample email and the
certificate-reward email and confirmed: zero remaining `keywellness.co.bw/assets` or
`keywellness.co.bw/privacy` hits, the logo `src` resolves to the GitHub Pages path,
the footer link points at the portal root, and the certificate email's "Manage
preferences" link resolves to `.../keywellness-portal/#profile`. Confirmed via `grep`
that every remaining `keywellness.co.bw` reference left in both `.ts` files is either
a `mailto:`/`From:` email address (unaffected by the web-hosting bug, works today) or
an inert commented-out CORS-origin example.

**Not yet done — same "won't deploy without you present" rule as every prior email
workstream batch**:
1. `supabase functions deploy send-booking-email` (bundles `_shared/kw-email.ts`
   automatically — confirm in deploy output).
2. Send one real test booking on dev; open the received "New booking request" email
   and confirm the logo renders and "Open in admin" resolves to the real portal.
3. Once `portal.keywellness.co.bw` DNS goes live: swap the single `KW_PORTAL_URL`
   constant, redeploy, done — every other line in this file was written to depend on
   that one constant for exactly this reason.

---

## Batch 3 — Signup/login error surfacing (index.html) — 3.1 only, per Tshenolo

Rollback: `git revert` — pure frontend, no DB/Edge Function involved.

**3.2 (root-cause fix) explicitly skipped, per Tshenolo's decision recorded at the
top of this section** — BATCH-0-FINDINGS 0.2 already proved the trigger/invite-code
path isn't the cause (identical 500 with and without a valid invite code); the real
cause is a Supabase Auth SMTP/email-sending failure outside this repo. Nothing in
`handle_new_user()` or the invite-code flow was touched.

**3.1**: added a shared `resolveAuthErrorMessage(error, fallback)` helper — tries
`error.message` → `error.error_description` → `error.msg` in order, but **rejects any
candidate that looks like raw JSON** (`/^[\{\[]/` on the trimmed string) rather than
just falling back on falsy/empty values. This is the actual fix for the reported bug:
`error.message` in the reproduced case is the non-empty string `"{}"`, so the old
`error.message || fallback` pattern never reached the fallback at all — a length/
truthiness check alone doesn't catch a garbage-but-truthy message. Both `doLogin()`
and `doSignup()` now: log the full error via `JSON.stringify(err,
Object.getOwnPropertyNames(err))` before doing anything else with it (nothing was
logged before — this is why the `{}` went undiagnosed as long as it did), route the
resolved message through the same category-detection branches as before (unchanged
behavior for real, recognizable errors like "already registered" or "invalid login
credentials"), and — new — wrap the whole Supabase call in `try/catch/finally` so a
thrown network exception (not a returned `{error}`, an actual `fetch` failure) no
longer leaves the button stuck on "Signing in…"/"Creating account…" forever; the
`finally` block unconditionally restores button state.

**Verified live** against the real reproduced bug from Batch 0 (same dev preview,
real Supabase project): called `doSignup()` with a fresh throwaway address — result
is now the generic message `"Account creation failed — please try again or contact
wellness@keywellness.co.bw."` instead of `{}`, button correctly re-enabled
("Create Account", not disabled), and the console now shows
`doSignup failed: {"message":"{}","name":"AuthRetryableFetchError","status":500}` —
the full error is finally visible for diagnosis. Regression-tested `doLogin()` with a
deliberately wrong password against a nonexistent account: still correctly shows the
specific field-level "Incorrect email or password" message (not the generic banner),
confirming the existing category-detection branches weren't broken by routing through
`resolveAuthErrorMessage` first.

**Manual follow-up (carried over from Batch 0, restated here since it blocks real
verification of this fix's actual production value)**: signup remains broken for
every real user until someone checks Supabase dashboard → Authentication →
Email/SMTP settings. This batch makes the failure legible instead of cryptic; it does
not make signup work.

---

## Batch 4 — Booking confirmation links

**No separate code change — already fixed by Batch 2.** Per BATCH-0-FINDINGS 0.3, the
booking emails' only broken link was the internal "New booking request" email's
"Open in admin" button (the client-facing "booking received"/"booking confirmed"
emails have no links at all beyond the shared footer) — both are built from the same
`kw-email.ts`/`send-booking-email/index.ts` pair Batch 2 already repointed at
`KW_PORTAL_URL`. Nothing left to fix in code; this batch is the dedicated
verification pass the checklist calls for.

**Verified**: rendered both the `type:"confirmed"` (client) and `type:"new"`
(internal/team) email bodies exactly as `send-booking-email/index.ts` builds them,
via the same Node-native-TS `require('./kw-email.ts')` approach used in Batch 2, and
extracted every `href`:
- Client "confirmed" email: `https://mogomotsifrance-star.github.io/keywellness-portal`
  (footer) + `mailto:wellness@keywellness.co.bw` (aside/help).
- Internal "new booking" email: `https://mogomotsifrance-star.github.io/keywellness-portal/admin.html`
  (button, appears twice — mso/non-mso conditional markup, both branches correct).

Zero relative hrefs, zero literal `{{`/`${` leftovers, zero `mailto:`-adjacent false
positives — every non-`mailto:` href is absolute `https://` and resolves to a real,
live page (confirmed in Batch 0's `curl` pass: portal root and `/admin.html` both
200).

**Not yet done — requires a real Resend send, same "won't send real test emails
without you present" rule as Batch 2**:
- [ ] Real test booking on dev → open the received email → click every link → confirm
  each lands on a live page (mechanically expected to pass, given the href audit
  above, but not yet observed against a real inbox's rendered HTML).
- [ ] Resend dashboard click-tracking setting — still unverifiable from code (Batch
  0.3); if links appear rewritten in the real send despite the correct hrefs above,
  this is where to look.

---

## Batch 5 — Opt-in state refresh (index.html)

Rollback: `git revert` — pure frontend, no DB/RLS change (per BATCH-0-FINDINGS 0.4,
the write path itself — `profiles` upsert via the existing `saveUser()` — already had
working RLS; this batch fixes the caller's handling of that write's outcome, not the
write itself).

`saveUser()` now returns `true`/`false` (previously returned `undefined` on both
success *and* failure — every other call site (`saveUser().catch(()=>{})`,
`await saveUser();` with the value discarded) was already ignoring the return value,
confirmed by grep across all 8 call sites, so this is additive and doesn't change
existing behavior anywhere else).

`saveRewardsOptIn()` rewritten per BATCH-0-FINDINGS 0.4's exact diagnosis: the
optimistic flip to `state.user.leaderboard_opt_in` now gets **reverted** if
`saveUser()` returns `false`, instead of staying flipped regardless of outcome. On
success, no separate refetch call was added — `saveUser()` already sets `state.user`
to the row Postgres just returned from `.upsert(...).select().single()`, which is the
authoritative post-write state, not a re-assertion of the guess. The misleading
"You're sharing your points with HR" success toast now **only fires when the write
actually succeeded**; on failure, no second toast is added on top of `saveUser()`'s
own `'⚠️ Could not save your profile...'` toast — a distinct opt-in-specific error
string was considered (per the batch spec's example wording) but `showToast()`
appends a new fixed-position element per call with no dismiss/stacking logic
(confirmed by reading its implementation), so two toasts firing back-to-back would
visually overlap at the same screen position rather than replace each other. Relying
on the shared helper's existing, already-explicit error is enough to satisfy
"no silent failures" without introducing that visual bug. The view always re-renders
after either outcome (unchanged from before) — but now off the corrected `state.user`,
so a failed save renders the true, pre-save state instead of the false "it worked"
state.

**Verified via a mock harness** (not a real authenticated session — signup is
currently broken in production per Batch 0/3, so no way to reach the Badges page
end-to-end as a real logged-in member in this environment): stubbed `window.saveUser`
and `window.VIEWS` in the live page, drove `saveRewardsOptIn()` through both outcomes
directly — success case: checkbox checked, stub resolves `true`, `state.user.leaderboard_opt_in`
ends `true` (kept). Failure case (run second, starting from the `true` state the
success case left behind): checkbox unchecked, stub resolves `false`,
`state.user.leaderboard_opt_in` **stays `true`** — confirms the optimistic flip to
`false` was correctly reverted rather than persisted. No console errors introduced by
either run.

**Not yet done**: a real end-to-end pass (check the box → Save → confirm the card
re-renders opted-in without a manual refresh → hard refresh → confirm it persisted →
force a write failure via devtools → confirm the inline/toast error and that the
checkbox doesn't silently show "opted in" when it isn't) needs a real authenticated
member session, blocked on the same signup-SMTP issue as Batch 3's remaining manual
follow-up.

---

## Batch 6 — Admin appointments requested-time column (admin.html)

Rollback: `git revert` — pure frontend rendering change, no SQL. Per
BATCH-0-FINDINGS 0.5, `admin.html`'s main bookings fetch already `select('*')`s
`requested_time` into `allBookings` — the Table view just never displayed it. Added
one `<th>Requested Time</th>` next to `<th>Requested Date</th>` and a matching
`<td class="mono">${escNar(b.requested_time||'—')}</td>` in the same row map,
formatted as the existing 24-hour `HH:MM` string (no reformatting needed — matches
the Calendar view's existing display of the same field). Used `escNar()` (this file's
existing generic escaper, already used for the identical purpose in the Calendar
view) rather than rendering the value raw, even though it only ever comes from a
fixed `BK_TIMES` slot list today — consistent with the rest of this table, which
escapes every other user/booking-derived cell the same way. `.table-wrap` already has
`overflow-x:auto` (pre-existing), so the extra column degrades to horizontal scroll on
narrow viewports rather than breaking layout — no new CSS needed.

**Dependency flagged, not re-verified here**: BATCH-0-FINDINGS 0.5 noted
`supabase_bookings_missing_columns.sql` (an existing untracked file in this repo)
adds `requested_time` to the live `bookings` table, but whether it's actually been
run against the shared project couldn't be confirmed from this environment. If it
hasn't, this column will show "—" for every row (graceful, not broken) until it's
run — worth a quick check before considering this batch fully live.

**Verified**: real authenticated admin session isn't available in this environment
(no admin credentials, and admin.html redirects unauthenticated visitors back to
`index.html` before its script's functions become reachable via the same
direct-navigation approach used for the signup tests above). Instead, replicated the
exact two edited template-literal lines (date cell + new time cell, using this file's
real `escNar`) against three constructed rows: a normal `"14:00"` value, a `null`
value (renders `—`, not `"null"` or blank), and a `<script>` payload in
`requested_time` (renders HTML-escaped, confirming the new cell doesn't introduce an
XSS path). Also ran `new Function()` against the full extracted `<script>` block from
`admin.html` post-edit — zero syntax errors, confirming the edit didn't break the
template-literal nesting.

**Not yet done**: a real click-through in an authenticated admin session against live
data (no admin credentials in this environment), and confirming whether the
`supabase_bookings_missing_columns.sql` dependency above has actually been applied.

---

# Batch 5 — Member view of HR-awarded rewards (index.html + new RPC)

**Required a new RPC that wasn't anticipated by the original plan.**
BATCH-0-FINDINGS 0.4.3 confirmed `reward_fulfilments` has zero RLS policies
for `authenticated` — every existing read path (`org_reward_history()`) is
employer-only, and the plan's assumption ("member reads own rows only —
existing RLS; verify, don't assume") did not hold. Added
`my_reward_fulfilments()` (`supabase_my_reward_fulfilments.sql`, `language
sql security definer`, hard-scoped `where rf.user_id = auth.uid()` in the
query itself, no parameters — a caller literally cannot ask for anyone
else's rows). Rollback: `drop function if exists my_reward_fulfilments();`.
This is not a new HR-facing surface — it mirrors the existing member-scoped
security-definer pattern (`award_points()`); no HR view changed in this
batch.

**Frontend**: `renderRewardsProgressCard()` (`index.html`) gained a
"Rewards received" section with a `.kw-skeleton` placeholder, filled in by
a new `loadMyRewardFulfilments()` async call (fired from `VIEWS['badges']`
right after the synchronous render — same render-then-fill-in-async
pattern already used for `admin.html`'s org-overview banner). Newest first
(RPC already orders `by rf.created_at desc`); friendly empty state
("Nothing redeemed yet — keep earning!") instead of a blank block; explicit
error message on RPC failure. `category` → label mapping
(`REWARD_CATEGORY_LABELS`) covers all four fulfilment categories
(`utilisation`/`learning`/`progress`/`overall`) — the data can always
describe itself (per BATCH-0-FINDINGS 0.4.3, the schema already has what's
needed), so no BUILD-NOTES flag was needed for an undescribable-award case.

**Verified** with a mock harness — extracted `escHtml`/`fmtDate`/
`loadMyRewardFulfilments` from the live page source and ran them with a
*locally shadowed* `sb` mock (a direct `eval()` inside a wrapper function
declaring its own `const sb`, since `index.html`'s own top-level `const sb`
is a real Supabase client already active on the page and a `window.sb`
reassignment doesn't shadow a lexical `const` — worth noting for future
sessions testing this file the same way): populated state (2 rows, newest
first, correct labels/dates), a `<script>` payload in the `note` field
rendered HTML-escaped rather than executed, empty state, and error state
all behave correctly. `new Function()` parse-check on the full extracted
`<script>` block: no syntax errors. Grep for `improvement` in the new SQL
file: zero matches.

**Not yet done**: `supabase_my_reward_fulfilments.sql` has not been applied
to the live Supabase project (same "no DB credentials in this environment"
constraint as every batch above — see Batch 1's "Execution path" note);
real two-account cross-member isolation test needs to happen once it's
applied.

---

# Batch 4 — Report download via print (employer.html + admin.html)

Print-to-PDF via the existing browser print dialog (`window.print()`), no
server-side PDF generation, per the locked design decision.

**Chart print-reliability handled proactively, not gambled on.** BATCH-0-FINDINGS
flagged Chart.js `<canvas>` print rendering as "not yet verified" and this
environment has no real print-preview tool to test it visually. Rather than
ship the button and hope, added `KWReportCharts.printReport(title)` (new
shared function in `kw-report-charts.js`, alongside the existing
`registry` of canvasId → Chart instance): on call, every registered chart
canvas is swapped for a `<img>` snapshot (`canvas.toDataURL()`), printed,
then swapped back on `afterprint`. `document.title` is set to
`KeyWellness-Report-<org>-<period>` for the duration (browser's suggested
PDF filename) and restored afterward. Both `employer.html`'s
`downloadHrReportPdf()` and `admin.html`'s `downloadAdminReportPdf()` call
this one shared function — verified end-to-end with a real Chart.js chart
rendered into a real canvas, calling `printReport()` with `window.print`
stubbed: confirmed the title swap, image-snapshot insertion, canvas hiding,
and full restore-on-`afterprint` all fire correctly, in that order.

**Button is structurally published-only, not just conditionally hidden.**
`employer.html`'s Reports tab already queries `.eq('status','published')`
(nothing else is reachable there), so no draft-check was needed on that
side. `admin.html`'s builder serves both drafts and published reports —
the button only renders when `readOnly` (`row.status === 'published'`),
matching the existing draft/published toggle already in
`renderReportBuilder()`.

**`admin.html` had no `@media print` block at all** (confirmed by
BATCH-0-FINDINGS) — added one scoped to hide `#sidebar`/`.btn-outline`
(which also hides the Download button itself during the actual print,
same treatment `employer.html` already gives its own chrome) and to apply
`break-inside:avoid` to the report card/chart boxes. Deliberately did
**not** rebuild admin's read-only report view into `employer.html`'s
full cover-page/appendix `report-doc` layout — that would be a much larger
change than "add a print stylesheet"; admin's existing read-only builder
view (chart boxes + disabled narrative fields, no cover/appendix) is what
gets printed there, matching what the spec asked for literally.

**Page numbers**: added a `@page { @bottom-center { content: counter(page)
"/" counter(pages) } }` rule in both files, per the spec's own "if
achievable with CSS counters" hedge — flagging honestly that `@page`
margin-box content has inconsistent/no support in mainstream browsers
(notably Chrome); it's a harmless no-op where unsupported, kept rather than
omitted.

**Verified**: `new Function()` parse-check on all three modified files
(`employer.html`, `admin.html`, `kw-report-charts.js`) confirmed no syntax
errors from the edits; the `printReport()` mock test above exercised the
real, unmodified rendering code, not a stub.

**Not yet done**: an actual browser print-preview/print-to-PDF pass on a
real published report (no print-preview tool available in this
environment, same gap noted in the prior workstream's Batch 4 notes above)
— this remains the one genuinely unverified piece and should be checked
manually before this ships to a client.

---

# Batch 3 — Admin confirmed-bookings calendar (admin.html)

Custom month grid, view-only, no external calendar library — placed as a
**view toggle inside the existing Appointments tab** ("Table" / "Calendar"
buttons in the card header), not a new top-level sidebar tab and not a
replacement of the existing table, per the spec's "adjacent to the
appointments table, not replacing it."

- **Month-scoped fetch**: `loadCalMonth()` queries `bookings` directly with
  `.eq('status','confirmed').gte('requested_date', monthStart).lte('requested_date', monthEnd)`
  on every month navigation — does not filter the existing `allBookings` full
  cache (that cache stays dedicated to the Table view/search, per the
  existing pattern; BATCH-0-FINDINGS explicitly flagged these as needing to
  stay separate).
- **`requested_time` is actually 24-hour `"HH:MM"`** (confirmed via
  `index.html`'s `BK_TIMES` constant, e.g. `'08:00'`, `'14:00'`) — corrects
  BATCH-0-FINDINGS 0.2.2's guess of a `"10:00 AM"`-style label. Lexical sort
  (`.order('requested_time')`) is therefore already correct with no parsing
  needed.
- **No `escHtml` helper existed in `admin.html`** (unlike `employer.html`) —
  reused the existing `escNar()` function verbatim (defined further down the
  file for narrative fields, but a generic `&`/`<`/`>` escaper; already used
  inside `value="..."` attributes elsewhere in this file, so matching that
  established convention rather than introducing a second, slightly-more-
  correct escaping helper). Confirmed via a mock test that a `<script>` tag
  in a booking's `user_name` renders escaped, not executed.
- **Day cell** shows up to 3 compact `time + service` entries, `+N more`
  beyond that; clicking either opens the day-detail modal (new
  `calDayModal`, following this file's existing static-modal-shell +
  `classList.add('open')` pattern) listing every confirmed booking that day
  with time, service, client name, session type, and delivery mode (no
  "counsellor" field — confirmed absent from the schema in
  BATCH-0-FINDINGS 0.2.2).
- **Verified** with a mock harness: extracted `renderCalGrid`/
  `openCalDayModal`/`calDateKey`/`calMonthLabel`/`escNar` from the live page
  source via `window.eval`, drove them against constructed bookings —
  correct leading-blank cell count for the month's start weekday (verified
  July 2026 = 3 blanks + 31 days = 34 cells), correct 3-shown +
  "+1 more" overflow, correct empty-month message, and confirmed a `<script>`
  payload in `user_name` renders HTML-escaped, not executed. Also ran
  `new Function(mainScriptSource)` against the full extracted `<script>`
  block to confirm no template-literal nesting/syntax errors from the
  toggle-view refactor of `renderBookings()`.
- **Not yet done**: a real click-through in an authenticated admin session
  (no admin credentials in this environment — same constraint as every
  prior batch); tablet-width visual check beyond the CSS media query added.

---

# Batch 2 — HR dashboard Financial Stress card (employer.html)

Consumes `org_stress_summary()` (Batch 1, below). Not yet applied to Supabase
— frontend is ready but will show the new card's explicit error state until
`supabase_org_stress_summary.sql` is run in the SQL Editor.

**Replaced the existing `renderFinancialStress()` card rather than adding a
second one, per Tshenolo's explicit choice.** `employer.html` already had a
live "Financial Stress" card fed by `org_financial_indicators()`'s `stress`
section — per BUILD-NOTES above, that RPC has `stress_logs.level`'s scale
backwards (mislabels calm members as high-stress) and shows bands only, no
causes. Asked whether to replace it, add a second card, or replace-and-also-
patch the older RPC; chose **replace** (not the deeper RPC patch) — the old
RPC's bug is out of scope for this batch and flagged separately. `fin.stress`
from `org_financial_indicators()` is now unused in `employer.html`; the RPC
itself is untouched (still called for `dti`/`retirement`, which
`renderDebtHealth()`/`renderRetirementReadiness()` still consume).

**Error vs. insufficient_cohort kept distinguishable**, same reasoning as
admin.html's `currentReportDataError` (see the "ambiguous column n" incident
above) — `init()` now stores `window._stressError` separately from
`window._stressData`, and `renderStressCard()` checks the error branch first.

**Suppression shape**: `_suppress_count`/`_suppress_rate` return
`{value, suppressed}` (confirmed by reading their actual definitions in
`supabase_org_report_data.sql`/`supabase_suppress_count_bigint_fix.sql`/
`supabase_org_report_data_v2.sql`) — not a `"<smallest reportable"` string as
the batch spec's wording suggested. Rendering reads `.value`/`.suppressed`
directly; a suppressed band shows the existing 🔒 lock-icon segment
(`finBandsHtml()`, reused verbatim from the Debt Health/Retirement cards).

**High-stress action-strip threshold treats a suppressed `high` band as 0**,
matching `renderDebtHealth()`'s exact existing precedent ("the true count
never reaches the client, so the threshold check can only work off what was
actually disclosed") — in a small-cohort edge case this could under-trigger
the "Request wellbeing outreach" prompt, but that's the established,
deliberate tradeoff already made elsewhere in this file, not a new gap.

**Verified** with a temporary mock harness (fetched the live page source,
`window.eval`'d only `renderStressCard()` + its direct dependencies —
`escHtml`/`finBandsHtml`/`finLegendHtml`/`finSuppressedNote` — with
constructed mock data, never touched the actual DOM/init() flow): full data
(low/moderate bands + one suppressed high band + 3 causes), `insufficient_cohort`,
and error states all render distinct, correct output; grep for `improvement`
in the new code: zero matches (one pre-existing unrelated hit elsewhere in
the file, already flagged above).

**Not yet done**: real end-to-end test against a live org once
`supabase_org_stress_summary.sql` is applied (mobile layout check also
pending a real render, though the card reuses the existing responsive
`.fin-bands`/`.fin-legend` layout unchanged).

---

# Batch 1 — org_stress_summary() RPC — rollback + design notes

**Rollback (recorded before execution, per process):**
```sql
drop function if exists org_stress_summary(int);
```
File: `supabase_org_stress_summary.sql`. Pure addition — one new function, nothing existing altered.

**Design decisions:**
- Source table is `stress_logs` (fortnightly Check-in flow), not the `financial_stress_tracker`
  tool's `tool_data` blob — see "headline finding" in `BATCH-0-FINDINGS.md` for why two stress
  sources exist and why they're on opposite scales.
- **Band thresholds correct a scale-direction bug found in `org_financial_indicators()`.**
  `stress_logs.level` is 1–10 where **lower = more stressed** ("1 = Barely coping" ... "10 =
  Completely at ease" — see `index.html`'s `stressLabel` array). `org_financial_indicators()`
  (already shipped) assumed the opposite direction and mislabels calm members as "high stress".
  `org_stress_summary()` uses the same numeric cut points (≤3 / 4–6 / ≥7) but the corrected
  label mapping: **level ≤3 = High stress, 4–6 = Moderate, ≥7 = Low stress.** This does NOT fix
  `org_financial_indicators()` itself — that's a separate, pre-existing bug, flagged but out of
  scope for this batch. Exact cutoffs should still be reviewed with whoever owns the check-in
  instrument (see follow-up list at the bottom of this file).
- Cohort guard: <5 distinct members with a check-in in the window → `{"insufficient_cohort":
  true}` only, matching `org_report_data()`'s exact convention.
- Suppression: reuses `_suppress_count(bigint)` and `_suppress_rate(int,int)` verbatim from
  `supabase_org_report_data_v2.sql` / `supabase_suppress_count_bigint_fix.sql` — no new
  suppression logic invented.
- Top causes: assumes `stress_logs.tags` is a Postgres `text[]` (matches how `index.html` inserts
  a plain JS array via supabase-js). **Verify this before running** — if it's actually `jsonb`,
  `unnest(sl.tags)` must be swapped for `jsonb_array_elements_text(sl.tags)`. Verification query
  included at the bottom of `supabase_org_stress_summary.sql`.
- Causes are filtered to `count >= 3` first, then ranked and the top 3 taken — so "fewer than 3
  causes" happens by a cause simply not clearing the suppression bar, never by ranking then
  blanking a slot.

---

# Follow-up: a SECOND bug behind the same symptom — ambiguous column "n"

After applying `supabase_suppress_count_bigint_fix.sql`, the bigint error
was gone, but `admin.html` still showed "This organisation has fewer than
5 enrolled members" for `Test Co` (28 enrolled) — the legitimate
insufficient-cohort message, not the new error banner, so at first glance
this looked like it might be a real small-cohort edge case. Calling
`org_report_data()` directly confirmed it was not:

```
{"code":"42702","message":"column reference \"n\" is ambiguous",
 "details":"It could refer to either a PL/pgSQL variable or a table column.","hint":null}
```

**Root cause**: `_org_report_period_data()` declares a plpgsql variable
`n int` (the org headcount, used throughout). The `demographics_cross`
section's CTE chain (`session_counts`, `counts`, `full_grid`, `cell_flags`,
`row_stats`, `col_stats`) used `count(*) as n` as a column alias in several
places — Postgres raises "ambiguous" whenever a bare identifier inside a
plpgsql function's embedded SQL could refer to either the outer plpgsql
variable or a query column of the same name. This is the exact class of
bug this file's own "general lesson" (from the Rewards-reshape build,
further below) already warned about, and I didn't catch it when writing
that CTE chain in Batch 2 of the HR-audit workstream.

**Fix**: renamed the colliding alias from `n` to `cnt` throughout the
`demographics_cross` block in `supabase_org_report_data_v2.sql` (in place
— same file, same `CREATE OR REPLACE`, no new file needed). Swept the
rest of the function for any other bare `n` column aliases — none found;
this was the only collision.

**Why the UI showed the wrong message again**: this is the exact same
"real error repainted as insufficient-cohort" gap the bigint fix's
`admin.html` change was supposed to close — and it DID work correctly
this time (no error was silently swallowed into a misleading state)...
except `renderReportBuilder()`'s two checks are ordered
`currentReportDataError` first, `data.insufficient_cohort` second, and
that ordering is correct — the actual reason the wrong message still
showed is that `data` legitimately doesn't exist when there's an error
(`currentReportData = rpcData || null`), so it should have hit the error
branch. Re-confirmed by testing again after this second fix that the
error-banner path does trigger correctly when a real RPC error occurs —
the visible "fewer than 5 members" Tshenolo saw was from the SQL error
existing *before* `admin.html`'s fix had been deployed/loaded in that
particular page load. Noting this only so a future session doesn't assume
the error-surfacing fix itself was broken.

**Manual follow-up still needed**: re-run `supabase_org_report_data_v2.sql`
(now fixed) and reopen the Q3 2026 Test Co draft to confirm real data
loads end-to-end, then retest `publish_org_report()`.

---

# CRITICAL: org_report_data() has never worked against real data — `_suppress_count(bigint)` type mismatch

Discovered live, in production, while helping Tshenolo verify the
`org_overview()` fix (below) and reproduce a separate, unrelated
"row-level security policy" error he'd hit creating a report in
`admin.html`. That RLS error did not reproduce (created two real test
draft reports against `Test Co` live, both inserts succeeded — almost
certainly a transient PostgREST schema-cache lag right after the SQL was
first applied, which self-resolves). But opening either draft's builder
then failed with:

```
{"code":"42883","message":"function _suppress_count(bigint) does not exist",
 "hint":"No function matches the given name and argument types. You might
 need to add explicit type casts."}
```

**Root cause**: `_suppress_count(v int)` (defined in the very first
`supabase_org_report_data.sql`, never touched by the Batch 2 v2 extension)
is called throughout the RPC with raw `count(*)`/`count(distinct ...)`
subquery results — Postgres's `count()` always returns `bigint`, and
Postgres has no implicit cast from `bigint` to `int` for direct function-
argument resolution (only the reverse, `int`→`bigint`, is implicit). This
means **every call to `org_report_data()`, for every org and every
period, has always failed** since the very first version of this RPC —
not a regression introduced by the HR-audit workstream's Batch 2
extension. It was never caught because every prior verification pass in
this file used mocked JS data in the browser (which never touches
Postgres's type system) — this is the first time the RPC was actually
invoked against live data end-to-end.

**Compounding "no silent failures" gap**: `admin.html`'s
`openReportBuilder()` catches the RPC error and only `console.error`s it;
`currentReportData` becomes `null`, and `renderReportBuilder()`'s
`if (!data || data.insufficient_cohort)` branch then shows "This
organisation has fewer than 5 enrolled members" — a real error was
silently repainted as a misleading, unrelated legitimate-suppression
message. Fixed alongside the type bug so a real RPC failure is visibly
distinguishable from an actual small-cohort suppression.

**Fix** (file: `supabase_suppress_count_bigint_fix.sql`): add a `bigint`
overload of `_suppress_count` rather than touching the ~20 call sites
across `supabase_org_report_data_v2.sql` — Postgres resolves to whichever
overload matches the argument's actual type, so both `int` and `bigint`
callers keep working with no other SQL changes needed. Rollback:
`drop function if exists _suppress_count(bigint);` (the original
`_suppress_count(int)` overload is untouched either way).

**This also means `publish_org_report()` has never worked** — it calls
`org_report_data()` internally and would hit the identical error, so no
report has ever been publishable against real data either. Once this fix
is applied, the publish flow needs a real end-to-end retest (not just the
draft-builder retest done here).

**Side effect of diagnosis — disclosed and remediated**: two real draft
`org_reports` rows were created against the live `Test Co` org while
reproducing this (Q1 2026, then Q3 2026), both with Tshenolo's explicit
go-ahead. The Q1 2026 one was deleted immediately after. The Q3 2026 one
was left in place (status: draft, org_id for Test Co) since it has real
value as the report Tshenolo was actually trying to build — needs a
refresh (reopen the draft) once the SQL fix below is applied, since its
data preview never successfully loaded.

---

# org_overview() suppression fix — remediating audit findings #1 and #2

Fixes both related findings from the "HR Reporting Audit" section below:
(#1) `trend[]` can disclose an individual member's real wellness score when
a historical quarter had exactly one assessor, and (#2) `funnel`/
`distribution`/`distress` counts had no `<3` suppression at all — only the
whole-org `n≥5` gate. Requested together since they're the same root
cause: `org_overview()` predates the `<3` suppression pattern
`org_report_data()` established later in this file, and both findings are
in the same live, currently-in-production RPC.

Rollback (file: `supabase_org_overview_fix.sql`): re-apply the exact
function body from `supabase_employer_dashboard.sql` (the pre-this-fix
version, unchanged) — `CREATE OR REPLACE`, same signature.

## A broader vulnerability found while implementing the fix

The original Batch 0 audit flagged `trend[]` specifically (row #6) but
classified `summary`/`dimensions` as `AGGREGATE_SAFE` without scrutinising
their own small-cohort exposure. Implementing the fix surfaced that
**`summary.avg_score` and `dimensions.items[].avg` have the identical
vulnerability as `trend[]`, just for the current period instead of a
historical quarter**: both are computed by averaging `cat_scores`/`score`
across "however many members have completed an assessment" — a sub-cohort
the outer `n≥5` gate does **not** protect, since it only checks total org
headcount, not how many of them have actually been assessed. If an org has
12 employees but only 1–2 have completed an assessment, `avg_score` and
every `dimensions.items[].avg` value **is** that person's (or those two
people's) real score — not an approximation, the actual value. `distress`
has the same shape of risk via its own `n_assessed`. `distribution`'s
`assessed_count` is the same denominator again.

**Fix**: compute `v_assessed_n` (distinct members with ≥1 assessment,
org-wide) once, up front. Any output derived from that sub-cohort —
`summary.avg_score`/`participation_pct`, the whole `distribution` section,
the whole `dimensions` section, `distress.pct_low_emergency_fund` — is
suppressed as a unit when `v_assessed_n < 3`, since with fewer than 3
assessed people, no cut of that data (an average, a band count, a
per-dimension average) can be shown without it being attributable to a
specific 1–2 individuals. This is broader than the original audit's
finding #2 called for, but it's the same underlying bug, found by tracing
the fix through rather than patching only the fields explicitly named.

## Shape decisions (kept deliberately minimal, not a full `{value,suppressed}` rewrite)

`org_report_data()`'s convention wraps every suppressible cell in
`{value, suppressed}`. Adopting that everywhere in `org_overview()` too
would touch every rendering function in both `employer.html`'s Overview
tab and `admin.html`'s org-overview banner, for a fix whose actual goal is
closing a data leak, not a redesign. Instead:

- **Scalars** (`summary.avg_score`, `summary.participation_pct`,
  `funnel.completed_assessment`, `funnel.did_checkin`,
  `distress.pct_low_emergency_fund`, each quarter's `avg_score`/
  `participants` in `trend[]`) become plain SQL `null` when suppressed —
  frontend code already has a `value == null ? '—' : ...` pattern in
  several places (`fmtPct`-style helpers) and needs only a small check
  added where it doesn't yet.
- **Section-level objects** (`distribution`, `dimensions`) gain a new
  `suppressed` boolean; when `true`, their detail fields (`struggling`/
  `coping`/`thriving`, `items`/`focus_dimension`) are `null` instead of
  populated. Raw headcounts (`n_employees`, `distribution.assessed_count`,
  `distress.n_assessed`) are **always** shown, matching the existing
  precedent that the whole-org suppressed state already discloses
  `n_employees` — a headcount alone isn't the leak; the derived
  aggregate computed from a too-small headcount is.
- Each `trend[]` entry gains its own `suppressed` boolean (independent
  per quarter — a quarter with 1 assessor is suppressed even if the org
  currently has hundreds of members and plenty of other well-populated
  quarters).

## Frontend changes required (both call sites)

- `employer.html`'s Overview tab (`render()`, `funnelStep()`, the
  distribution/dimensions/distress/trend rendering blocks) — each needs a
  `suppressed` check before rendering real numbers, falling back to a
  "—" / privacy note, matching the pattern its own `finBandsHtml()`/
  `finSuppressedNote()` already uses for `org_financial_indicators()`.
- `admin.html`'s one-line org-overview banner (`renderUsers()`'s async
  banner load) — currently reads `ov.participation_pct`/`ov.avg_score`
  directly; needs a null check.

## Pre-existing bug found and fixed while implementing this (unrelated to the leak itself)

`admin.html`'s org-overview banner read `ov.n_employees`/
`ov.participation_pct`/`ov.avg_score` off the **top level** of the RPC
response. That was only ever correct for `org_overview()`'s original v1
shape (`supabase_multitenancy.sql`) — the moment it was extended to the
current six-section shape (`supabase_employer_dashboard.sql`, nesting
these three under `summary`), this banner started reading `undefined` for
all three fields on every non-suppressed call, and nobody had touched it
since. Fixed alongside this leak fix (same lines, same function) to read
`ov.summary.n_employees`/`.participation_pct`/`.avg_score`, with the new
null-suppression handling built in from the start.

## Files changed

`supabase_org_overview_fix.sql` (new — the fixed `org_overview()`),
`employer.html` (Overview tab: headline stats, `funnelStep()`, workforce
distribution, by-dimension, trend chart caption — all now check for
`null`/`suppressed` before rendering a real number), `admin.html`
(org-overview banner — reads the correct nested path and the fix above).

## Verified in-browser

Temporary mock harness (added to `employer.html`, exercised, then fully
removed — confirmed via `grep mocktest` after cleanup): rendered a fully
suppressed response (summary/funnel/distribution/dimensions/distress all
suppressed, one suppressed quarter in `trend[]` alongside two normal
quarters) and confirmed every affected element shows "—" or a privacy
note — no `NaN`, no `undefined`, no blank space, and critically no real
score/percentage anywhere in a suppressed field. Then rendered a fully
populated non-suppressed response and confirmed real values (75%, 68.4,
"Debt Management" dimension label, distribution bands) still render
correctly — the fix doesn't regress the normal case. No console errors in
either pass.

## Not yet done

- **This SQL file has not been applied to the live Supabase project** —
  same "no DB credentials in this environment" constraint as every prior
  batch. `supabase_org_overview_fix.sql` needs to be run in the SQL
  Editor; recommend testing against a real org with a known small
  assessed sub-cohort (per the file's own verification queries) before
  considering this closed.
- Findings #3 (Rewards individual-level exposure — deliberate, consented,
  flagged for legal sign-off) and #4 (narrative free-text, process
  control only) from the original audit remain unremediated, as before —
  not requested in this fix and not the same category of bug (both are
  by-design, not accidental leaks).

---

# HR Reporting Audit & International-Grade Report Upgrade

Batch 0 (read-only — no files or DB objects modified): prerequisite check
+ full HR-data-surface audit, ahead of the schema/RPC/UI upgrade batches
that follow this section.

## Prerequisite check

Confirmed live (per Tshenolo, since this environment has no DB credentials
to check directly — see "Execution path" in the previous workstream's
Batch 1 notes below): `org_reports` table, `bookings.attended` /
`attendance_confirmed_by` / `attendance_confirmed_at` / `session_mode`
columns, `org_report_data()`, `publish_org_report()`, the admin report
builder (`admin.html`'s Reports tab), and the HR report view
(`employer.html`'s Reports tab) all exist. Proceeding on that basis.

## Current report structure (for reference before the Batch 4 redesign)

- **Narrative JSONB keys in use**: `executive_summary` (text),
  `progress_outcomes` (text), `challenges_risks` (array of `{challenge,
  severity, impact, mitigation}`), `next_steps` (text).
- **Chart module**: `kw-report-charts.js`, shared by `admin.html` and
  `employer.html`. Exposes `renderFunnel`, `renderModeSplit`,
  `renderMonthlyTrend`, `renderCategoryBands`, `renderAgeBands`,
  `qoqBadge`, plus `cellValue`/`cellDisplay`/`anySuppressed` helpers for
  `{value, suppressed}` cells. Suppressed bar/stacked-segment cells render
  as Chart.js `null` (no bar drawn), not `0` (see the prior workstream's
  Batch 5 notes on why).
- **Current HR report view section order** (`employer.html`, Reports tab):
  period header + published date → 4 stat cards (n_employees, total
  booked, total attended, coverage %) → one QoQ badge line (sessions
  booked only) → 2×2 chart grid (funnel, mode split, monthly trend, age
  bands) → category-bands chart → standing "All data is aggregated…" line
  → narrative cards (executive summary, progress & outcomes, challenges
  table, next steps). **No cover page, no methodology/confidentiality
  appendix, no print-optimised page-break structure** — all new in Batch 4
  below.
- **`org_report_data()` current top-level keys**: `insufficient_cohort`,
  `n_employees`, `period_start`, `period_end`, `engagement_funnel`,
  `sessions`, `assessment_categories`, `demographics`, `learning`,
  `previous_period` (same shape, recursive). Signature:
  `org_report_data(p_org_id uuid, p_start date, p_end date)` — Batch 2
  below must extend this in place without changing the signature.

## Tool-usage → wellness-category mapping (for Batch 2's "most engaged areas")

`points_events.event_type = 'tool_first_use'` already exists (from the
points-ledger build) with `ref_id` = the tool's filename
(`index.html:1479`, `openTool(filename)`). This can be mapped to the same
8 wellness dimensions used everywhere else via a `CASE` on filename — no
new tracking needed, so this section should NOT be omitted per the spec's
"omit if absent" instruction; the telemetry exists, just needs a filename→
dimension lookup in the RPC. Proposed mapping (tool file → dimension):
`budget_planner.html`→income/spending, `expense_tracker.html`→spending,
`net_worth_tracker.html`→spending, `goal_planner.html`→goals,
`debt_management_planner.html`/`dti_calculator.html`/`loan_calculator.html`→debt,
`retirement_calculator.html`→retirement,
`life_insurance_calculator.html`→insurance,
`education_savings_calculator.html`/`investment_calculator.html`/
`lifestyle_inflation_calculator.html`→savings,
`affordability_calculator.html`/`rent_vs_buy.html`→debt,
`financial_stress_tracker.html`→(no matching dimension — excluded from
this ranking, it isn't one of the 8 `cat_scores` keys).

## HR Data Audit

Scope: every page/section/RPC reachable by an HR-role (`employers` table)
account — i.e. everything in `employer.html`'s three tabs. (`admin.html`
is gated to `admins` only and is a *counsellor* surface, not HR, so it's
out of this audit's scope by definition — an HR account cannot reach it.)

| # | Source | What it shows | Classification | Suppression/guard status |
|---|---|---|---|---|
| 1 | `org_overview()` → `summary.n_employees/participation_pct/avg_score` | Org-wide headcount, % assessed, avg wellness score | AGGREGATE_SAFE | Whole-RPC `n<5` → `suppressed:true`, no other keys returned |
| 2 | `org_overview()` → `funnel.{signed_up,completed_assessment,did_checkin}` | Raw counts at each funnel step | **QUASI_IDENTIFIER_RISK** | **Unguarded** — only the outer `n≥5` org gate applies; no per-cell `<3` suppression, so e.g. a 5-person org showing `completed_assessment: 1` discloses that exactly one (eliminable-by-coworkers) person has/hasn't acted |
| 3 | `org_overview()` → `distribution.{struggling,coping,thriving}.count/pct` | Wellness-band member counts | **QUASI_IDENTIFIER_RISK** | **Unguarded** — same gap as #2; a band count of 1–2 is shown raw |
| 4 | `org_overview()` → `dimensions.items[].avg`, `focus_dimension` | Per-dimension average score across all assessed members | AGGREGATE_SAFE | True averages (not counts) over the whole assessed cohort; lower re-identification risk, consistent with `org_financial_indicators()`'s medians |
| 5 | `org_overview()` → `distress.pct_low_emergency_fund`, `n_assessed` | % and count of assessed members with low emergency-fund coverage | **QUASI_IDENTIFIER_RISK** | **Unguarded** — `n_assessed` can be a small subset of the org total (assessment is optional), with no independent `<3` gate on this sub-cohort |
| 6 | `org_overview()` → `trend[].avg_score`, `participants` | Quarterly avg wellness score + participant count, last 6 quarters | **QUASI_IDENTIFIER_RISK escalating to INDIVIDUAL_LEVEL when `participants` = 1** | **Unguarded, most significant finding in this audit** — the outer `n≥5` gate checks *current* org headcount, not per-quarter participation; a historical quarter with exactly one assessor renders that person's own `avg_score` directly to HR as an "average." This is a live, in-production per-person financial-wellness score disclosure under invariant 3, via a structural gap rather than a designed field |
| 7 | `org_financial_indicators()` → `dti`/`retirement`/`stress` bands + medians | Debt-to-income, retirement readiness, financial-stress band distributions | AGGREGATE_SAFE | Correctly guarded: `assessed_count<5` → `{eligible:false}` only; every band has its own `suppressed` flag for counts of 1–2 |
| 8 | `org_rewards()` → `user_id, first_name, last_name, email, *_points, qualified_*, overall_rank, rewarded_categories` | Per-member name/email/points/rank, one row per **opted-in** member | INDIVIDUAL_LEVEL | Guarded by **explicit member opt-in consent**, not aggregation/suppression — a different guard class than invariants 2/3 describe. Pre-existing, deliberate design (Rewards tab); already flagged for DPA/consent-copy review elsewhere in this file. Not a new gap, but must appear in this audit for completeness |
| 9 | `org_rewards_summary()` → org-level counts, headcount, season dates | Org totals only | AGGREGATE_SAFE | No identifiers; no guard needed |
| 10 | `org_reward_history()` → `first_name, last_name, email, category, note, season, fulfilled_at` | Per-fulfilment name/email/category/note history | INDIVIDUAL_LEVEL | Same opt-in-consent guard class as #8; `note` is free text (gift description), not a financial-state value, but still tied to a named individual and a wellness *category* |
| 11 | `set_org_headcount()` | Writes org headcount (not a read of member data) | N/A (write, not a data-subject exposure) | `p_org_id` ignored for employer callers — always resolved server-side via `employer_org()`, so cross-org write is not possible |
| 12 | `org_reports` (published rows) → `period_label`, `published_at` | Report metadata | AGGREGATE_SAFE | Non-sensitive |
| 13 | `org_reports.narrative` (all 4 keys) | Free text written by a counsellor | **QUASI_IDENTIFIER_RISK** | **Process/training guard only — no technical enforcement.** Nothing prevents a counsellor typing an identifying description (already flagged in this file's DPA note from the prior workstream; restated here since this audit's scope explicitly covers it) |
| 14 | `org_reports.data_snapshot.engagement_funnel` | Funnel step counts for the reporting period | AGGREGATE_SAFE | `<3` suppression per step (this RPC, unlike `org_overview()`, does this correctly — see finding #2/#3 above for the older RPC's gap) |
| 15 | `org_reports.data_snapshot.sessions.{total_booked,total_attended,attendance_confirmation_coverage_pct}` | Whole-org session totals for the period | AGGREGATE_SAFE | Not individually suppressed by design (whole-org totals, covered by the outer `n≥5` gate) — same reasoning as `org_overview()`'s summary stats, but unlike #2/#3/#5/#6 these are true org-wide totals, not sub-cohort counts, so the risk profile is materially different |
| 16 | `org_reports.data_snapshot.sessions.mode_split` / `.monthly_trend` | Session-mode split, monthly booked/attended trend | AGGREGATE_SAFE | `<3` suppression per cell |
| 17 | `org_reports.data_snapshot.assessment_categories` | Per-dimension band counts for the period | AGGREGATE_SAFE | `<3` suppression per band |
| 18 | `org_reports.data_snapshot.demographics.age_bands` | Age-band member counts | AGGREGATE_SAFE | `<3` suppression per band; gender omitted entirely (prior workstream decision) |
| 19 | `org_reports.data_snapshot.learning` | Distinct-engager counts per learning event type | AGGREGATE_SAFE | `<3` suppression per cell |
| 20 | `org_reports.data_snapshot.previous_period` | Same shape as the current period, recursively | AGGREGATE_SAFE | Same guards applied independently (own cohort/suppression check) |
| 21 | `organizations` (name lookup), `employers`/`admins` (self-row check) | Org display name; HR's own role-check row | N/A | Not data-subject exposure (org metadata / the HR user's own record) |

## AUDIT FINDINGS — requires remediation

Human review required before Batch 5 remediates any of these (per this
workstream's own instruction: "if findings lack an approval note from
Tshenolo, list them prominently and skip remediation rather than
guessing"). **No remediation has been performed in Batch 0.**

1. **`org_overview()`'s `trend[]` can disclose an individual member's own
   wellness score to HR** when a historical quarter had exactly one
   assessor (audit row #6). **Proposed fix**: add `participants < 3 →
   {suppressed: true}` per quarter (mirroring the new pipeline's own <3
   rule), replacing `avg_score` with `null` for that quarter, same shape
   as everywhere else in this codebase.
2. **`org_overview()`'s `funnel`, `distribution`, and `distress` sections
   have no per-cell `<3` suppression** (audit rows #2, #3, #5) — only the
   whole-org `n≥5` gate applies. **Proposed fix**: apply the same
   `{value, suppressed}` cell shape used throughout `org_report_data()` to
   each count in these three sections. This changes `org_overview()`'s
   JSON shape, so the Overview tab's rendering in `employer.html` (and
   `admin.html`'s org-overview banner) would need matching updates —
   larger than a pure backend fix, flagged accordingly.
3. **`org_rewards()` / `org_reward_history()` expose per-person name,
   email, and category-level engagement data to HR** (audit rows #8, #10).
   This is a deliberate, consented, pre-existing design (opt-in rewards),
   not a bug — but it is still `INDIVIDUAL_LEVEL` data reaching HR, which
   is worth an explicit legal-review sign-off given this audit's stated
   purpose (input to the DPA lawyer engagement), rather than assuming the
   original consent-copy review already covers it. **No code change
   proposed** — this is a legal/business confirmation, not a remediation.
4. **`org_reports.narrative` has no technical safeguard against an
   identifying description** (audit row #13). **No code fix proposed** —
   free-text scanning for identifying content is out of scope for this
   system; this remains a staff-training/process control, consistent with
   this file's existing DPA note.

## Batch 1 — `program_activities` table + `bookings.client_type` (rollback recorded before applying)

Rollback (file: `supabase_program_activities.sql`):

```sql
drop table if exists program_activities;
alter table bookings drop column if exists client_type;
```

- **`program_activities` has no HR-facing RLS policy at all** (only
  `is_admin()` full-access) — matching `supabase_multitenancy.sql`'s
  established "deliberately NO employer policy" pattern for member-data
  tables, extended here to activity data too. HR reaches this data only
  through `org_report_data()`'s aggregated `program_activities` section
  (Batch 2), never a direct table read — satisfies "HR no direct access."
- **No member policy either** — members have no legitimate reason to read
  this table (it's counsellor-entered, org-level, not member-owned), so
  the checklist's "member cannot see other members' rows" is trivially
  true: a member sees zero rows, not just their own.
- **`bookings.client_type` defaults to `'member'`** so every existing
  booking row is valid immediately on migration (additive, no backfill
  needed) — counsellors set it to `'dependent'` only when they know a
  session was for a family member, via the Batch 3 UI toggle.

## Batch 2 — extend `org_report_data()` (rollback + design decisions)

Rollback (file: `supabase_org_report_data_v2.sql`): re-apply the exact
`_org_report_period_data()` and `org_report_data()` bodies from
`supabase_org_report_data.sql` (the pre-Batch-2 version, unchanged from
the previous workstream) — both are `CREATE OR REPLACE`, same signatures,
so reverting is a straight re-run of that original file.

**`demographics_cross` axis substitution — asked, got no reply, went with
the technically sound option instead of the one I'd offered as
"Recommended."** I asked whether to cross age × client_type, add a real
`gender` column, or skip the cross-tab; no answer came back, so I proceeded
with the default-marked option (age × client_type) — but building it
exposed a flaw in that option I hadn't caught before asking: **dependents
have no age at all** in this schema (a dependent is a flag on a *booking*,
`bookings.client_type`, not a separate `profiles` row with its own `age`).
Age × client_type would therefore always show an empty/degenerate
`dependent` row. Used **age band × session-intensity tier** instead (both
already real, both apply only to the member cohort, which is the only
cohort with an age at all) — this is the same "no new data collection"
spirit as the option I'd offered, just a coherent pairing instead of a
broken one. Flagging this clearly since it's a substitution of a
substitution, not what was asked for verbatim.

**Complementary suppression — implemented as one-level margin
suppression, not full recursive disclosure control.** For each age-band
row and each tier column: a cell is suppressed if its raw count `< 3`
(same rule as everywhere else in this codebase). A row's (or column's)
**total** is *additionally* suppressed when **exactly one** cell in that
row/column is suppressed — because `total − (sum of the other, disclosed
cells) = the one hidden cell`, defeating the point. If zero cells in a
row/column are suppressed, there's nothing to protect and the total shows
normally; if two or more are suppressed, the total is safe because the
equation has more than one unknown. **Not implemented**: recursion beyond
this one level (e.g., a grand total combined with several row totals,
where only one row total ends up suppressed by the rule above, could in
principle still be back-solved) — true k-anonymity-style disclosure
control across a whole matrix is a materially bigger problem than "cross
one small 4×3 matrix correctly," and the original spec itself defers
exactly this class of problem (cross-org benchmarking's k-anonymity
design) as future work. Flagging the same limitation here for consistency
rather than silently pretending one level of margin suppression is a
complete solution.

**Tool → wellness-dimension mapping for `wellness_areas`'s "most engaged"
ranking** uses one canonical dimension per tool file (no tool counted
twice), per the mapping recorded in Batch 0's discovery notes above.
`financial_stress_tracker.html` and `wellness_assessment.html` are
excluded from this ranking (stress isn't one of the 8 `cat_scores`
dimensions; the assessment itself is already reflected in
`assessment_categories`, not a "tool" in this sense).

**`wellness_areas` is additive, not a replacement for `assessment_categories`.**
The existing `assessment_categories` key is left completely untouched (same
shape, same data) so the current report view keeps rendering without any
change — the checklist's "previous consumers still render, signature
unchanged" requirement. `wellness_areas` is a new, separate top-level key
containing only the new "most engaged" ranking; it does not duplicate the
band-count data that already lives in `assessment_categories`.

**New percentage fields in `kpi_summary` are suppressed when their
underlying raw count is `< 3`** (`participation_rate`, `attendance_rate`),
via a new `_suppress_rate(numerator, denominator)` helper — a rate like
"100%" computed from "1 of 1" is nearly as identifying as showing the raw
count directly. `total_reach` and `total_touchpoints` are left as
unsuppressed whole-org totals, matching the existing treatment of
`sessions.total_booked`/`total_attended` (a true org-wide sum, not a
sub-group breakdown, the same distinction the Batch 0 audit table draws
between rows #2/#3/#5/#6 and row #15 in the prior workstream's RPC).
**Note for a future pass, not changed here**: `sessions.attendance_confirmation_coverage_pct`
from the *previous* batch was never given this same small-numerator
suppression check — this batch is more rigorous about it for the new
fields than the last batch was for that one. Not fixing the older field
now (out of scope for what was asked, and changing an already-shipped
field's behaviour without being asked risks surprising anyone already
relying on it), but worth revisiting together with the `org_overview()`
findings from Batch 0.

**`total_reach`/session-intensity "client" unit is `(user_id, client_type)`,
not a true per-dependent count.** Since dependents aren't separate profile
rows (see above), a member who brought a dependent to a session
contributes at most 2 reach units total (one for themself, one for
"their dependent(s)," lumped together) regardless of how many actual
family members attended. This is the best available approximation given
the schema, not a true unique-human count — documented here so it isn't
mistaken for one later.

**Bug caught in review, fixed before shipping**: `data_coverage.assessment_completion_pct`'s
numerator was initially `count(*)` over assessment rows in the period,
which would over-count (and could push the percentage past 100%) for any
member who submitted more than one assessment in the same period. Changed
to `count(distinct a.user_id)`, matching `engagement_funnel.completed_assessment`'s
existing distinct-member definition.

**Not tested against a live Postgres instance** — same "no DB credentials
in this environment" constraint as every prior batch (see Batch 1's
"Execution path" note). Reviewed carefully by hand for CTE ordering
(Postgres only allows forward references within a single `WITH` clause,
which this file's 12-CTE `demographics_cross` block respects), scalar-
subquery correlation correctness, and the distinct-count fix above, but
the verification queries at the bottom of `supabase_org_report_data_v2.sql`
still need to be run for real once applied.

## Batch 3 — admin builder upgrades

New "Activities" sidebar tab (CRUD for `program_activities`, org filter,
add/edit modal — errors surface via a visible banner, matching the
established pattern), a `client_type` select added alongside the existing
session-mode select in the Appointments attendance controls (both write
together via one extended `updateAttendance(id, attended, sessionMode,
clientType)` call), a new `insights` narrative key + "Insights &
Observations" card positioned between Executive Summary and Progress &
Outcomes (per the spec's section order), a new `suggestInsights()`
generator, and `suggestExecutiveSummary()` extended with reach/touchpoints/
dependent-inclusion/QoQ language. The builder's auto-data preview was also
extended with the new aggregate sections (KPI strip replacing the old
booked/attended stat cards, session-intensity chart, member/dependent
reach, demographics-cross table, programme-activities list, data-coverage
statement) — kept in the admin builder too, not just Batch 4's HR view,
so "admin preview and HR view cannot drift" continues to hold for the new
sections as well as the old ones.

- **Bug fixed during this batch, unrelated to the new work**: `renderBookings()`'s
  attendance-cell template literal had a malformed closing tag (a stray
  backslash) that a Grep-tool content preview rendered as `<\div>` —
  turned out to be a display artifact of the tool, not the actual file
  content (confirmed by reading the raw file directly), so no fix was
  needed there after all. Noting this only so a future session doesn't
  waste time chasing the same false alarm.
- **New chart-module functions** (`renderSessionIntensity`,
  `renderDemographicsCrossTable`, `renderActivitiesListTable`) added to
  the shared `kw-report-charts.js` rather than inlined in `admin.html`,
  so Batch 4's HR view can reuse them exactly — same "cannot drift"
  reasoning as the original module.
- **Demographics-cross renders as an HTML table, not a Chart.js chart** —
  a suppression-aware matrix with per-cell and per-total "—" reads far
  more clearly as text than as a chart would; the spec's other new
  sections (session intensity, KPI strip) are genuine charts/stat cards.
- **Verified in-browser** with a temporary mock harness (added, exercised,
  then fully removed from `admin.html` — confirmed by `grep mocktest`
  after cleanup): draft builder renders all new sections including a
  constructed complementary-suppression example (a 2-cell-suppressed row
  showing a real total, a would-be-1-cell-suppressed row showing "—" for
  its total in the mock data), `suggestExecutiveSummary()` and
  `suggestInsights()` produce the expected deterministic text, the
  Activities modal's client-side validation blocks an empty title, and
  the Appointments tab's new client-type select renders with the correct
  element id pattern. No console errors in any of these paths.

## Batch 4 — HR report redesign (international-grade template)

`employer.html`'s `renderHrReportDetail()` fully rebuilt to the spec's
11-section structure (cover → executive summary/KPI strip → programme
delivery → programme utilisation → who we reached → wellness areas →
insights → progress & outcomes → challenges & risk register → next steps
→ methodology/confidentiality appendix), still rendering strictly from
`data_snapshot`/`narrative` — no RPC call added. New shared chart-module
function `renderTouchpointsTrend()` (line chart merging portal
`sessions.monthly_trend` with `program_activities.activities_list`,
bucketed to months client-side) and a local `mergeModeSplits()` helper
(combines `sessions.mode_split`'s suppression-aware cells with
`program_activities.mode_split`'s plain counts into one delivery-mode
doughnut) — both reused as-is from/alongside Batch 3's admin preview
additions.

- **New `currentOrgName` global**, set in `init()` where the org name was
  already being fetched for the sidebar — previously nothing held this
  value in a form the cover block could read; the sidebar DOM element held
  it mixed with other text ("HR / Employer view").
- **"No emoji" is scoped to the report body itself** — the page's existing
  chrome (sidebar nav icons, the persistent "🔒 Aggregate only" header
  badge) is unchanged, since the spec's design bar is about the printable/
  exportable report document, not the surrounding app shell. Verified via
  `textContent` regex scan of `.report-doc` specifically: zero emoji
  matches.
- **Print CSS**: `.report-cover` gets `page-break-after: always` (cover on
  its own page), every `.report-section` and `.chart-box` gets
  `break-inside: avoid`, and `.report-appendix` gets
  `break-before: page` (starts its own page, since the spec calls it "a
  differentiator, not filler" — worth a clean page rather than whatever
  trails after Next Steps). Not verified against an actual printed PDF in
  this environment (no print-preview tool available) — reviewed by CSS
  inspection only; a real print/PDF pass on a real published report is
  still needed before this ships to a client.
- **Verified in-browser** with a temporary mock harness (added, exercised,
  then fully removed — confirmed by `grep mocktest` after cleanup): all
  11 sections render with no console errors, QoQ badges compute correctly
  from `previous_period.kpi_summary`, the demographics-cross table's
  complementary suppression renders correctly from constructed mock data,
  and a `textContent` scan of the whole report body confirmed zero emoji
  and zero PII-shaped strings (`user_id`, email patterns).
- **Not yet tested**: an actual full print-preview render (browser print
  dialog / print-to-PDF) of a real published report, and the "mutate live
  data after publish, confirm report unchanged" checklist item against a
  real Supabase project (this environment has no DB access — same
  constraint noted throughout this file).

## Batch 5 — audit remediation + final sweep

### Audit remediation — NONE performed

Per this workstream's own instruction, findings without an explicit
approval note from Tshenolo are listed prominently, not guessed at. **No
approval was given for any of the four Batch 0 findings during this
session** — they were surfaced in conversation but not confirmed — so
**zero remediation has been performed.** Re-listing all four here so they
aren't lost between sessions:

1. **`org_overview()`'s `trend[]` can disclose an individual member's own
   wellness score to HR** when a historical quarter had exactly one
   assessor. This is the most significant finding — a live, in-production
   per-person financial-wellness score disclosure. Proposed fix
   unchanged from Batch 0: suppress any quarter with `participants < 3`.
2. **`org_overview()`'s `funnel`/`distribution`/`distress` sections have no
   per-cell `<3` suppression** — only the outer `n≥5` org gate. Proposed
   fix: apply the same `{value, suppressed}` shape used throughout
   `org_report_data()`, with matching frontend updates in `employer.html`'s
   Overview tab and `admin.html`'s org-overview banner.
3. **`org_rewards()`/`org_reward_history()` expose per-person name/email/
   category data to HR** — deliberate, consented, pre-existing design, not
   a bug, but flagged for an explicit legal sign-off rather than assumed
   coverage under the earlier consent-copy review.
4. **`org_reports.narrative` has no technical safeguard against an
   identifying description** — process/training control only, no code fix
   proposed.

**Action needed from Tshenolo**: review these four and say explicitly
which (if any) should be remediated — ideally referencing this list by
number — before a future session acts on them.

### Grep sweep

- `improvement` (case-insensitive) across every new file this workstream
  touched (`supabase_program_activities.sql`, `supabase_org_report_data_v2.sql`,
  `kw-report-charts.js`, and the new Activities/Reports code in
  `admin.html`/`employer.html`): **zero matches.** The one hit anywhere in
  either HTML file is the same pre-existing, out-of-scope Overview-tab
  trend caption already flagged in the prior workstream's Batch 6 —
  confirmed still isolated to that one unrelated line.
- `user_id`/`.email`/`first_name`/`last_name` across the same file set:
  **zero matches** in actual query/render logic — the only hits anywhere
  are English verification-comment text (e.g. "inspect for any user_id/
  email/name"), never live code.

### Full-flow test

Not run as one continuous session against a real Supabase project (no DB
credentials in this environment — same constraint as every batch above).
Exercised piecemeal with mocked data instead, across Batches 3–5:
activities CRUD (add validation, edit, delete-with-confirm), the
client-type + attendance toggle together, the draft builder's full new
data preview, all deterministic suggestion generators, the read-only
published view, the HR report's full 11-section render, and — new in this
batch — **an old-shape snapshot (missing every field this workstream
added) rendered without error**, confirming reports published before this
schema upgrade won't break the redesigned HR view. A real end-to-end pass
(enter activities → confirm attendance with client types → build draft →
suggestions → publish → HR view → print preview) against a live org still
needs to happen once the SQL is applied.

### Error-path pass

Confirmed via code review + the mock testing above: Activities CRUD
save/delete failures surface a visible banner/alert (never silent);
`updateAttendance()`'s extended signature still follows the same
error-then-alert pattern as before; the HR view's `!snap` guard and every
new section's `|| {}` fallback mean a missing or old-shape
`data_snapshot` renders gracefully with "—" rather than a blank page or a
thrown error (see the old-shape test above).

### Not merged to main

Per this workstream's own instruction and this repo's branch rules —
merging is a human decision, not attempted.

## Client communication item

A one-paragraph note for Tshenolo to send existing clients (e.g. Hollard)
whose prior reports included a per-client table: *"Your Key Wellness
utilisation report has been upgraded to reflect international EAP
reporting standards. In place of the previous per-client table, you'll now
see session-intensity and reach aggregates — this is a confidentiality
upgrade, not a reduction in insight: it protects individual employees
while giving you a clearer, benchmarked view of programme-wide
utilisation, delivery mix, and outcomes."* Prepare and send is a Key
Wellness business action, not something this system does automatically.

## Legal-review item (for the Botswana DPA lawyer engagement)

The `## HR Data Audit` table above (Batch 0) is the intended input for
this engagement. Flag explicitly to the lawyer: **"no names = not
personal data" is not the correct standard** — identifiability governs,
and several `QUASI_IDENTIFIER_RISK` rows in the audit table (small raw
counts, narrative free text) could re-identify someone in a small cohort
without ever showing a name. Separately: pseudonymised per-client tables
("Client A, Female, 48, 2 sessions") as seen in prior manually-prepared
reports are a legal/business decision outside this system's scope — this
portal will not generate them, per invariant 1, regardless of what a
template or example document shows.

## Operational note (extending the prior workstream's note)

Programme activities and client-type flags are now **standing counsellor
data-entry duties**, alongside the existing attendance-confirmation duty.
If activities aren't logged or client-type isn't set, reports will
understate total reach and touchpoints, and will misattribute dependent
sessions as member sessions — not merely show a gap, but a quietly wrong
number. Add both to the same staff process documentation as the existing
attendance-confirmation note.

## Deferred (not attempted, out of scope for this build)

- **Cross-org anonymised benchmarking** ("your org vs. portfolio
  average") — explicitly named as high client value but requiring its own
  privacy design (k-anonymity across organisations, not just within one)
  that must not be improvised inside this batch. A future workstream, not
  a follow-on task to slot into this one.
- **PDF export** — print CSS shipped (Batch 4); `jsPDF`/Edge-Function
  rendering remains deferred, same as the prior workstream.
- **LLM-assisted narrative suggestions** — still fully deterministic,
  rule-based generators; an LLM-backed version needs an Edge Function, an
  API key, and a DPA review first, same reasoning as the prior workstream.

---

Batch 0 discovery (read-only — no files or DB objects modified). Reference
for all later batches in this initiative: counsellor-built org utilisation
reports (admin dashboard) → publish → immutable snapshot → HR dashboard view.

## Schema recorded

- **`organizations`**: `id uuid pk`, `name text`, `invite_code text unique`,
  `is_active boolean`, `created_at timestamptz`. (`supabase_multitenancy.sql`)
- **`profiles`**: PK `id` = `auth.users.id`. Has `org_id uuid → organizations(id)`
  (locked against client writes by `trg_lock_org_id`/`lock_org_id()` — only
  `is_admin()` callers can change it). Demographic/financial columns
  confirmed via `saveUser()` in `index.html:867-904`: `first_name`,
  `last_name`, `phone`, `age` (raw integer, member-entered — **no age band
  column**), `monthly_income`, `monthly_expenses`, `last_score`,
  `last_cat_scores`, `consent_accepted/date`, `welcome_seen`, `onboarded`,
  `joined_at`, plus shared financial fields (`gross_income`, `total_assets`,
  `total_liabilities`, `monthly_debt`, `total_savings`, etc.),
  `leaderboard_opt_in`, `display_alias`. **No `gender` column exists
  anywhere in `profiles` or any tracked SQL file.** `profiles` also has no
  `created_at` (uses `auth.users.created_at` instead, per the rewards-reshape
  section below) and no `email` (joins `auth.users`).
- **`bookings`**: no `CREATE TABLE` found anywhere in this repo or its SQL
  files — the table predates the repo's SQL-migration convention and was
  created directly in the Supabase dashboard. Columns confirmed by union of
  `index.html`'s insert (`index.html:3810-3820`) and
  `supabase_bookings_missing_columns.sql`: `id`, `user_id`, `user_name`,
  `user_email`, `service`, `session_type` (existing field — a booking
  *category*, e.g. counselling type; **do not confuse with the new
  `session_mode` column Batch 1a adds** for physical/virtual delivery),
  `requested_date`, `requested_time`, `status` (`pending`/`confirmed`/
  `cancelled`), `client_seen_confirmation`, `updated_at`, `created_at`. No
  `org_id` column — bookings are scoped to an org only via
  `user_id → profiles.org_id`, so `org_report_data()` must join through
  `profiles`, not filter `bookings` directly.
- **`assessments`**: `user_id`, `score`, `cat_scores` (jsonb, keyed by
  dimension — confirmed keys: `income`, `savings`, `emergency`, `debt`,
  `retirement`, `insurance`, `goals`, `spending`, plus an internal
  `_insCount` bookkeeping key excluded from `org_overview()`'s dimension
  loop), `answers`, `created_at`. No per-assessment `id` referenced by
  reports; "latest per member" is the pattern used everywhere
  (`order by created_at desc limit 1`).
- **`points_events`** (`supabase_points_ledger.sql`): `id`, `user_id`,
  `event_type text → points_catalog(event_type)`, `ref_id`, `points`,
  `season`, `created_at`. **`points_catalog` already contains a row literally
  named `'improvement'`** (150 pts, awarded on assessment-score improvement
  between periods) — this is a pre-existing, unrelated feature, but it means
  a naive `grep -i improvement` over a live system will always have at least
  one hit somewhere; the Batch 2/4/6 greps must be scoped to the new RPC
  source and HR-facing JSON output specifically, not the whole schema.
  Learning-engagement events already tracked here: `article_read`,
  `video_watched`, `quiz_passed`, `tool_first_use` — usable for the Batch 2
  `learning` section (counts, no per-person rows) without fabricating new
  tracking.
- **No existing report/attendance table.** `org_reports` (Batch 1b) and the
  `bookings` attendance columns (Batch 1a) are both wholly new.

## HR + admin dashboard files and auth pattern

- **HR dashboard = [employer.html](employer.html)**. Client-side gate
  (`init()`, ~line 230-252): reads the Supabase session, then queries
  `employers` (by `user_id` OR lower-cased `email` — email match covers HR
  users added before their first login) and `admins` in parallel; redirects
  to `index.html` if neither matches. `window._isEmployer` is set but
  commented as "UI convenience flag only — never a security boundary. All
  access control is enforced by RLS and the `org_overview()` RPC." Calls
  `sb.rpc('org_overview')` **with no argument** — the RPC resolves the
  caller's org itself via `employer_org()`. Also calls
  `org_financial_indicators()` (a related, already-shipped RPC) in parallel;
  its failure doesn't block the rest of the dashboard — same non-blocking
  pattern the new report RPC's sections should follow.
- **Admin/counsellor dashboard = [admin.html](admin.html)**. Gate (~line
  212-218) checks `admins` table only (email match) — admin.html is
  admin-only, unlike employer.html which accepts either role. Currently has
  exactly two sidebar tabs: **Users** and **Appointments** (`showTab()`,
  lines 141-142) — confirms **Batch 3's Reports tab is wholly new**, nothing
  to migrate. Has an org selector (`selectedOrgId`, line 232) already used to
  filter the Users tab and to call `loadOrgOverview(selectedOrgId)` — i.e.
  admin.html already calls `org_overview(target_org)` **with an explicit
  org id** (the admin-override path), while employer.html calls it with none.
  The Appointments tab (`sb.from('bookings').select('*')...`,
  `updateBookingStatus()`) is exactly where Batch 3's attendance
  confirmation toggle (Attended/No-show + session mode) should be added —
  it already renders one row per booking with a status-change action, so
  attendance fields are a natural addition to the same row/action set,
  not a new view.
- Both pages share the same design tokens (`css/kw-theme.css`, green/yellow
  brand vars aliased over the old navy/gold names) — the new Reports tab and
  HR Reports section should reuse `.card`/`.stat-box`/`.tabs`/`.modal-overlay`
  classes already defined in `admin.html`'s `<style>` block rather than
  inventing new ones.

## `org_overview()` guard reference (copied verbatim for the new RPC to match)

Current live definition is `supabase_employer_dashboard.sql`'s v2 (the
richer six-section JSON); `supabase_fix_org_overview_authz.sql` is the
superseded-but-still-relevant v1 that shows the exact NULL-logic bug and fix.

```sql
-- Auth (resolve org first, then check):
if target_org is null then
  target_org := employer_org();
end if;
if target_org is null then
  raise exception 'not authorised';
end if;
if not (is_admin() or coalesce(employer_org() = target_org, false)) then
  raise exception 'not authorised';
end if;

-- Cohort guard (n < 5 → suppressed empty state, no other keys):
select count(*) into n from profiles where org_id = target_org;
if n < 5 then
  return json_build_object(
    'suppressed',   true,
    'n_employees',  n,
    'message',      'Aggregates appear once at least 5 employees have enrolled, to protect individual privacy.'
  );
end if;
```

**Important subtlety for `org_report_data()` to replicate exactly**: the
`coalesce(employer_org() = target_org, false)` — without the coalesce, a
non-employer's `employer_org()` returns `NULL`, `NULL = target_org` is
`NULL`, `is_admin() OR NULL` is `NULL` (not `false`) when `is_admin()` is
`false`, and `NOT NULL` is `NULL` — so `IF NOT (...) THEN raise` **silently
does not raise**, letting any authenticated user through. This exact bug
shipped once already in this codebase (`supabase_fix_org_overview_authz.sql`
is its fix) and must not be reintroduced in the new RPC. `org_overview()`
currently has no distinct "under 3" suppression — only the whole-org ≥5
cohort gate — so the new RPC's <3 cell-level suppression (invariant 3) is
new logic, not a copy of an existing pattern; model it as
`case when count(*) < 3 then json_build_object('value', null, 'suppressed', true) else json_build_object('value', count(*), 'suppressed', false) end` per cell.

## Charting approach

**No charting library is loaded in `admin.html` or `employer.html` today**
(confirmed: no `<script>` tag for Chart.js/any chart lib in either file).
`index.html` (member dashboard) does use Chart.js v4.4.0 via CDN elsewhere
in this codebase per `CLAUDE.md`, so Batch 3/5's plan to add Chart.js via
cdnjs is consistent with the existing stack — just not yet present on these
two pages. Confirms the shared `kw-report-charts.js` module (Batch 3) needs
its own `<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/...">`
tag added to both `admin.html` and `employer.html`.

## RLS posture

`profiles`, `assessments`, `checkins`, `badges`, `emergency_fund`,
`organizations`, `employers` all have RLS enabled with policies defined in
`supabase_multitenancy.sql` (verified structurally by `supabase_verify.sql`,
which itself notes SQL-Editor checks bypass RLS and true isolation needs
browser-session testing). `points_catalog`/`points_events` RLS is in
`supabase_points_ledger.sql` (read-your-own only; all writes gated through
`award_points()` security-definer function, no client insert policy at all).
**`bookings` RLS policies are not defined in any tracked SQL file** — per
`supabase_bookings_missing_columns.sql`'s own comment, they were "already
working" before this repo's SQL-migration convention started, meaning they
were set up directly in the Supabase dashboard and were never captured in a
file. This repo has no Supabase CLI/MCP access in this environment to
introspect them directly — Batch 1c's new `org_reports` RLS must be written
from scratch (there's no existing `bookings`-style policy to mirror for a
report table), and the actual current `bookings` SELECT/UPDATE policies
should be pulled from the dashboard (Database → Policies) and pasted into
this file before Batch 1a ships, so the attendance columns' access is
verifiable rather than assumed.

## Decisions from Tshenolo (resolved before Batch 1)

- **Gender**: omitted from `demographics` entirely — age bands only, no
  `profiles.gender` column added. Flag to Key Wellness as a known gap the
  same way pension % was flagged, not silently absent.
- **Execution path**: confirmed I have no DB credentials (no password, no
  service-role key, no Supabase MCP connector) in this environment to run
  SQL against the live project directly — `supabase` CLI is authenticated
  (`projects list` works) but not linked, and linking/pushing needs a DB
  password I don't have. Every batch below follows this repo's established
  convention: I write the `supabase_*.sql` file with rollback statements
  recorded here first; Tshenolo runs it in the SQL Editor, in file order.

## Batch 1 — rollback statements (recorded before applying; file: `supabase_org_reports.sql`)

```sql
-- 1a. Bookings attendance columns
alter table bookings drop column if exists attended;
alter table bookings drop column if exists attendance_confirmed_by;
alter table bookings drop column if exists attendance_confirmed_at;
alter table bookings drop column if exists session_mode;

-- 1b/1c. org_reports table (drop cascades its own RLS policies)
drop table if exists org_reports;
```

No existing function is replaced in this batch (that starts at Batch 2), so
there is nothing to roll back beyond the column drops and the table drop
above.

**Design notes for the RLS split** (checklist requires "published rows
reject updates" to be independently testable, not just enforced by the
publish RPC):
- No separate "counsellor" role/table exists in this codebase (Batch 0
  confirmed `admin.html`'s gate checks only the `admins` table) — the
  spec's "counsellor/admin" role is implemented as `is_admin()`,
  identical to every other admin-gated RPC here.
- SELECT/INSERT/UPDATE/DELETE are four separate admin policies (not one
  blanket `for all`), because the UPDATE policy's `using` clause needs
  `status = 'draft'` to make edits to a published row fail at the RLS
  layer itself — a single `for all using (is_admin())` policy would let an
  admin's direct client-side `update()` call silently flip
  `status='published'` on their own or edit narrative post-publish,
  bypassing `publish_org_report()`'s snapshot logic entirely (Batch 4).
  `with check (status = 'draft')` on the same policy additionally blocks a
  direct client update from setting `status` to `'published'` itself —
  only the security-definer `publish_org_report()` RPC (Batch 4, bypasses
  RLS the same way every other security-definer function in this codebase
  does) can make that transition.
- **Supabase-JS footgun to handle in Batch 3's UI**: when an RLS `UPDATE`
  policy's `using` clause excludes a row (e.g. trying to edit a published
  report), `supabase-js` does NOT return a truthy `error` — it returns
  `{ data: [], error: null }` (0 rows matched, 0 rows updated). Per
  invariant 6 ("no silent failures"), Batch 3's save/publish handlers must
  check `data.length === 0` as its own error condition, not just
  `if (error)`, or a blocked update will look like a successful save.

## Batch 2 — `org_report_data()` RPC design notes + rollback

Rollback (recorded before applying; file: `supabase_org_report_data.sql`):

```sql
drop function if exists org_report_data(uuid, date, date);
drop function if exists _org_report_period_data(uuid, date, date);
drop function if exists _suppress_count(int);
```

Design decisions made while implementing, none of which the spec pinned
down explicitly:

- **`used_tool` funnel step is NOT omitted**, despite `CLAUDE.md`'s
  "Data Gap" note that the 13 tool pages save to `localStorage` only. That
  note is about the tools' *data* (budget figures, goals, etc.), not usage
  tracking — `index.html:1479` already calls
  `KWBadges.recordPoints('tool_first_use', filename)` server-side (into
  `points_events`) the first time a member opens any tool page, from the
  existing points-ledger build. `org_overview()`'s older funnel omits a
  tool-usage step with an explicit comment that it's a v1 gap — this RPC
  closes that gap using data that already exists, rather than repeating
  the omission.
- **Cohort/registered-count is period-accurate, not "current total."**
  Both the current and previous period recompute `n` as `profiles` in this
  org whose `auth.users.created_at` is on/before that period's end date
  (same tenure-lookup pattern as the rewards-reshape build, which also has
  no `profiles.created_at` to rely on). This lets the two periods'
  ≥5-cohort guards genuinely apply *independently*, per the spec — an org
  that had 4 members last quarter and 6 this quarter now correctly shows
  `previous_period.insufficient_cohort: true` while the current period
  renders, instead of both periods sharing today's headcount.
- **Which cells get the <3 suppression, and which don't** (the spec names
  three examples — age band, category count, mode split segment — but says
  "any aggregate cell," which needed a concrete line drawn): suppression is
  applied to every cell that counts **distinct people in a bucket** —
  funnel steps (`completed_assessment`/`used_tool`/`booked_session`/
  `attended_session`), `assessment_categories`' per-category assessed count
  and three band counts, `demographics.age_bands`, `learning`'s three
  distinct-engager counts, and `sessions.mode_split`'s per-mode attended
  counts, plus every `sessions.monthly_trend` month's booked/attended
  counts. It is **not** applied to whole-org totals that are already
  covered by the outer ≥5 cohort gate and aren't sliced by any dimension:
  `registered`, `sessions.total_booked`, `sessions.total_attended`,
  `sessions.attendance_confirmation_coverage_pct`, and
  `engagement_funnel.bookings_unconfirmed`. Each suppressed cell is
  `{"value": null, "suppressed": true}`; unsuppressed is
  `{"value": <n>, "suppressed": false}`, per the spec's exact shape.
- **`demographics` has no `gender` key** — per Tshenolo's decision above,
  only `age_bands` plus a `gender_note: "Gender is not currently collected
  by the portal."` string, so Batch 5's HR view has something concrete to
  render/branch on instead of a silently-missing key.
- **`assessment_categories` is keyed by the real `cat_scores` dimension
  names** (`income`, `savings`, `emergency`, `debt`, `retirement`,
  `insurance`, `goals`, `spending` — dynamically read via `jsonb_each`,
  excluding `_insCount`, exactly like `org_overview()`'s dimensions section),
  **not** the spec's illustrative label list ("Budgeting, Savings, Debt,
  Retirement, Insurance…", which don't match any real key). Batch 3/5's
  UI needs a label map (`DIM_LABELS`, already defined in `employer.html`)
  to render human names — reuse it rather than inventing a second one.
- **Two private helper functions** (`_org_report_period_data`,
  `_suppress_count`) do the real work; `org_report_data()` itself only
  checks authorisation once, computes the previous-period date range, and
  calls the helper twice. `_org_report_period_data` is `security definer`
  (it must bypass RLS to read across all org members — HR has deliberately
  no read policy on `assessments`/`profiles`/`bookings`, same as
  `org_overview()`) but has `execute` **revoked from `public`, `anon`,
  `authenticated`** so it cannot be called directly via RPC to skip the
  outer authorisation check — only reachable through `org_report_data()`
  itself, whose `security definer` privilege (running as the function
  owner) is unaffected by that revoke.
- **`grep -i improvement` note**: per Batch 0's discovery that
  `points_catalog` already contains an unrelated `'improvement'` event
  type, this RPC's own source and every sample JSON output were grepped
  and confirm zero hits — the pre-existing catalog row is never queried
  by this function at all (it isn't in the `event_type` list this RPC
  reads: `article_read`, `video_watched`, `quiz_passed`, `tool_first_use`).

## Batch 3 — admin.html Reports tab + kw-report-charts.js

New files: `kw-report-charts.js` (shared chart module, loaded by both
`admin.html` and, in Batch 5, `employer.html`, per the spec's explicit
"cannot drift" requirement). `admin.html` changes: new `Reports` sidebar
tab, new-report modal (org + quarter-preset picker, plus a custom-date
checkbox), full builder view (auto-data preview + charts, four narrative
sections, structured challenges/risk editor, deterministic "Suggest draft"
buttons, Save Draft), and attendance confirmation controls (mode select +
Attended/No-show buttons) added directly into the existing Appointments
table for `status='confirmed'` rows — no separate view, per Batch 0's
discovery that this is where an attendance action naturally belongs.

- **Chart.js loaded via `jsdelivr`, not the spec's suggested `cdnjs`.**
  `index.html` already loads `chart.js@4.4.0` from
  `cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js` — reused the
  exact same URL/version for consistency with the one other place this
  library is already used in this codebase, instead of introducing a
  second CDN source for the same library.
- **Suggestion generators avoid the word "improvement" deliberately**,
  using "rise/fell/increase/decrease" instead — narrative text is
  free-form and edited by counsellors, so it isn't covered by the RPC-output
  invariant literally, but there's no reason for the deterministic
  generator itself to introduce the flagged word, so it doesn't.
- **`suggestChallenges()` threshold heuristics**: attendance rate
  (`total_attended / total_booked`) < 60% → medium severity, < 40% → high;
  debt category's under-50 band share > 50% of assessed → medium, > 70% →
  high. Both are as specified; a `challenge`/`severity`/`impact`/
  `mitigation` row is only added when its threshold actually triggers, and
  a "no threshold-triggered risks" placeholder row is added when neither
  does, rather than leaving the section empty (the counsellor can still
  delete or edit any row before saving).
- **`saveDraft()` and `confirmPublish()` both check `data.length === 0`**
  as an explicit failure branch (not just `error`), per the Supabase-JS
  RLS-silent-block footgun recorded under Batch 1 above.
- **Report builder is read-only once `status === 'published'`** — all
  textareas get the `readonly` attribute and the Save Draft/Publish/Suggest
  buttons are omitted entirely from the render, rather than disabled (so
  there's no risk of a stray click reaching a handler on a published row).

## Batch 4 — `publish_org_report()` RPC + publish UI

Rollback (recorded before applying; file: `supabase_publish_org_report.sql`):

```sql
drop function if exists publish_org_report(uuid);
```

- **The snapshot is the full `org_report_data()` output**, including its
  `previous_period` key — not a re-derivation of just the "current period"
  shape — so the HR view (Batch 5) can render QoQ badges straight from a
  single published report's `data_snapshot` without needing a second
  published report to exist for comparison.
- **`publish_org_report()` calls the public `org_report_data()` wrapper**,
  not the private `_org_report_period_data()` helper directly, so the exact
  same authorisation and cohort logic the admin already exercised in the
  builder preview is what gets snapshotted — no second, slightly-different
  code path for "the numbers HR actually sees."
- **Admin-only** (`is_admin()`), matching the spec's "counsellor/admin
  only" — there is no separate counsellor role in this codebase (Batch 0).
- Raises (visibly, surfaced by the UI's error banner) on: caller not admin,
  report not found, already published, or `org_report_data()` returning
  `insufficient_cohort: true` (a report that cannot lawfully show data
  cannot be published — per invariant 2).
- The actual `status='published'` + `data_snapshot` write happens in the
  same `UPDATE` statement, inside the function's single implicit
  transaction — there's no window where one is set without the other.
- The admin UI's publish flow saves any in-progress narrative edits first
  (a plain `update`, still gated by the draft-only RLS policy) before
  calling the RPC, so the snapshot always reflects the latest narrative
  text the counsellor was looking at when they clicked Publish.

## Batch 5 — employer.html HR Reports section

New "Reports" sidebar tab in `employer.html`, alongside the existing
Overview/Rewards tabs. Renders strictly from `org_reports.narrative` and
`data_snapshot` fetched once per report — no RPC call, no live query,
confirmed by testing with mocked live data that didn't match the snapshot
(see verification below).

- **Query is `.eq('status','published')` even though RLS already enforces
  this** (`org_reports_hr_read`'s `using` clause) — kept as an explicit
  client-side filter too, defense-in-depth, since this page's own comment
  already states `window._isEmployer` etc. are "never a security boundary."
  If an admin ever loads `employer.html` directly, they'd hit the same
  `org_overview()` no-arg failure the Overview tab already has (Batch 0) —
  not something this batch introduces or fixes.
- **Bug found and fixed during verification: Chart.js canvases inside a CSS
  Grid caused runaway horizontal layout growth** (`#page-content` measured
  ~1950px in a ~1265px viewport). Root cause: `.chart-box` grid items had
  no `min-width:0`, so Chart.js's `responsive:true` resize loop and the
  grid's default `min-width:auto` fed off each other. Fixed in **both**
  `admin.html` and `employer.html` (same shared CSS class names): added
  `min-width:0` to `.chart-box` and `.report-grid`, plus an explicit
  `width:100%` on `.chart-canvas-wrap` and `max-width:100%` on its canvas.
  Caught by checking `document.body.scrollWidth` vs `clientWidth` in the
  browser — a screenshot alone made it look like a rendering glitch, not an
  actual layout bug, until measured.
- **Suppressed chart cells render as `null` (Chart.js draws no bar/segment),
  not `0`.** Originally written as `cellValue(cell) ?? 0` in
  `kw-report-charts.js`, which would have drawn a suppressed "attended a
  session" cell as a confirmed-zero bar — indistinguishable from "nobody
  attended" to anyone not reading the tooltip or footnote. Changed to pass
  `null` through for every bar/stacked-segment dataset (funnel, monthly
  trend, category bands, age bands), matching the existing suppressed-data
  convention already used elsewhere in this codebase
  (`employer.html`'s pre-existing `finBandsHtml()` renders suppressed DTI/
  retirement bands as a distinct 🔒 segment rather than folding them into
  a real number) — a withheld value must never be visually confirmable as
  zero. `renderModeSplit()` (doughnut) still uses `?? 0` implicitly via
  `cellValue(...) ?? 0` — a doughnut slice can't meaningfully be "absent,"
  and it's already covered by the suppression footnote underneath.

**Verification performed** (temporary in-page mock harness added and then
fully removed from both `admin.html` and `employer.html` after use — see
each file's git diff has no trace of it): loaded the reports list, opened a
draft in the builder, ran all four `suggest*()` generators against fixed
mock data and confirmed deterministic output, exercised the RLS-silent-
block failure path for `saveDraft()`, added/removed challenge rows, opened
a published report in read-only mode (no Save/Publish buttons, `readonly`
textareas), and opened the same mock snapshot in the HR view. No console
errors in any of these paths. Confirmed via `openReportBuilder`/
`openHrReport` called directly (not via UI click) after discovering
`preview_click` was unreliable against dynamically-injected `onclick`
table rows in this environment — direct function calls exercise the same
render code path and are the more reliable check here.

## Batch 6 — verification sweep + merge prep

**Grep sweep results:**
- Case-insensitive sweep for "improvement" (the `points_catalog` event
  type flagged in Batch 0/2 as a pre-existing false-positive risk) across
  all four new files
  (`supabase_org_reports.sql`, `supabase_org_report_data.sql`,
  `supabase_publish_org_report.sql`, `kw-report-charts.js`) and the new
  code in `admin.html`/`employer.html`: **zero matches** after rewording
  two of my own SQL comments that had quoted the term as part of a "run
  this grep" instruction (they were false positives against my own file,
  not the RPC logic). One pre-existing, unrelated hit remains at
  `employer.html:1028` ("Wellbeing improvement is gradual…") — this is
  marketing copy on the existing Overview tab's trend caption, predates
  this initiative entirely, and isn't part of `org_reports`/
  `org_report_data`'s output or the new Reports section. Left untouched as
  out of scope for this build.
- Spot-check for `user_id`/`email`/`first_name`/`last_name` leakage:
  searched the Reports-specific functions in both `admin.html` (the
  builder/list, not the pre-existing Users tab, which legitimately shows
  member PII to counsellors) and `employer.html` (the new Reports tab) —
  zero hits in either. Searched both new RPC SQL files for the same terms
  — the only hits are in verification-comment English text describing what
  to check for, never in actual query/output logic.

**Error-path pass** (verified by code review + the Batch 3/5 browser
testing above, since this environment has no live-DB access to trigger a
real network failure or a real deleted-row race — see "Execution path"
under Batch 1):
- `saveDraft()` and `confirmPublish()` both check `error` AND
  `data.length === 0` (the RLS-silent-block case) and render a visible
  banner either way — never a silent success.
- `createReport()` and `openReportBuilder()` (admin) render a visible error
  state on RPC/query failure (an inline banner and a full-page "could not
  load" card respectively) rather than leaving a stuck spinner.
- `publish_org_report()` itself raises (not silently no-ops) on: not admin,
  report not found, already published, or insufficient cohort — every one
  of these surfaces through `confirmPublish()`'s existing `error` branch.
- `loadReports()` and `openHrReport()` (HR view) both render a visible
  error/empty state on query failure or a missing/deleted report id —
  never a blank page.
- Every spinner in the new code (`<div class="spinner">…`) is always
  followed by a synchronous `.innerHTML` replacement in the same async
  function, on both the success and error branches — none of the new code
  can leave a spinner spinning forever.

**Full-flow test**: not run against a real Supabase project in this
session (see "Execution path" note under Batch 1 — no DB credentials in
this environment). The functional pieces were verified individually with
mocked data in-browser (Batches 3 and 5's verification notes above) rather
than as one continuous real-account journey. A real end-to-end pass
(confirm attendance → build draft → suggest + edit narrative → publish →
view as HR → print preview) should happen once the three SQL files are
live — see "Manual follow-up" below.

## Client expectations (per the original build brief)

The previous manually-prepared organisation reports (e.g. the Hollard
Apr–Jun 2026 report, produced in Word) included a **per-client
demographics table** — individual rows per employee. This generated
pipeline **intentionally does not reproduce that table**; it is replaced
by the aggregate `demographics` section (age bands only, gender omitted —
see Batch 0/2) inside `org_report_data()`'s output, per invariant 1
(aggregate-only to HR, no individual rows ever). **Key Wellness needs to
communicate this format change to existing clients before their next
report cycle** — this is a business/communications action, not something
resolvable in code.

## Deferred (not attempted, out of scope for this build)

- **PDF export.** Batch 5 shipped print-friendly CSS (`@media print` in
  both `admin.html` and `employer.html`) as the "view now" deliverable.
  `jsPDF` or a Supabase Edge Function PDF-render path is deferred.
- **Richer admin attendance workflow.** Batch 3 shipped the minimal
  per-booking Attended/No-show + mode toggle described in the spec. Bulk
  attendance actions, a dedicated attendance-review view, or reminders to
  counsellors about unconfirmed bookings are all deferred.
- **LLM-assisted narrative suggestions.** The current `suggest*()`
  generators are fully deterministic, rule-based templates reading
  directly from `org_report_data()`'s aggregate output — no model call.
  Adding real LLM assistance would require a Supabase Edge Function, an
  API key, and adding the AI provider to Key Wellness's processor
  register — a DPA review is needed first, given `org_reports.narrative`
  can reference workforce wellbeing data.
- **Off-platform activity capture** (group talks, education sessions not
  run through the booking flow) as admin-inputted data feeding into
  `engagement_funnel`/`sessions` — not built; the pipeline currently only
  reflects `bookings` and `assessments`/`points_events` activity that
  already exists in the schema.

## Operational note for Key Wellness staff

**Attendance confirmation is now a standing counsellor duty.** Every
report's `engagement_funnel.attended_session` and `sessions.*attended*`
figures are computed **only** from bookings where `attended` has been
explicitly set (`true` or `false`) via the Batch 3 toggle in `admin.html`'s
Appointments tab — an unconfirmed booking (`attended is null`) counts
toward `bookings_unconfirmed` and the data-completeness banner, but not
toward attendance. If counsellors stop confirming attendance after a
session, every subsequent report will **understate** utilisation, not
merely show a gap. This should be added to Key Wellness's internal staff
process documentation as a recurring task, not a one-off setup step.

## DPA note for legal review

`org_reports.narrative` (executive summary, progress & outcomes,
challenges & risk register, next steps) is **free text written by
counsellors** — nothing in the schema or RLS prevents a counsellor from
typing something identifying into it. Per this file's existing DPA
follow-ups (see the Rewards-reshape and Email-standardisation sections
below), staff guidance must make explicit that narrative text must never
name or describe an identifiable member — the brief's own example
("a 53-year-old spouse of an employee") is identifying in a small cohort
even without a name. This needs to go into staff training notes and onto
the same DPA legal-review agenda already flagged for the Rewards
consent-copy changes elsewhere in this file.

## Manual follow-up — NOT attempted by Claude

- **None of this build's SQL has been run against the live Supabase
  project.** Per this repo's established convention (confirmed again for
  this build — see "Execution path" under Batch 1), Tshenolo needs to run,
  in the Supabase SQL Editor, in this exact order:
  `supabase_org_reports.sql` → `supabase_org_report_data.sql` →
  `supabase_publish_org_report.sql`. Each file's own verification-queries
  block should be run afterward.
- **Full real-account end-to-end walkthrough** (see "Full-flow test"
  above) — build a real draft against a real org with ≥5 members, confirm
  attendance on real bookings, publish, and view as a real HR account —
  once the SQL is live.
- **Client communication about the demographics-table format change** (see
  "Client expectations" above) — a Key Wellness business action.
- **DPA legal review** of the narrative free-text risk (see "DPA note"
  above) and the gender-omission decision (Batch 0) before the next real
  client report cycle.
- **Do not merge `dev` to `main`** — per this initiative's own instructions
  and this repo's branch rules, merging is a human decision.

---

# Build notes — Points/Rewards + Leaderboard + HR Financial Indicators

Schema deviations from the original build spec, and follow-ups, discovered while
implementing. See `.claude` plan history for the full reasoning; this file is the
durable record.

## Batch 1 — Points ledger

- **Badge id scheme differs from the spec.** `kw-badges.js` uses tiered ids
  (`budget_master_t1/t2/t3`, `ef_t1/t2/t3`, etc.), not the flat legacy ids the
  spec assumed (`budget_master`, `ef_halfway`). Public/private classification
  (Batch 2) is applied per-tier using the rule: badges revealing a specific
  financial-state threshold are private; badges reflecting pure engagement or
  consistency are public. Final mapping (each entry now carries
  `public: true/false` in `kw-badges.js`):
  - **Public**: `first_login`, `first_assessment`, `booked_session`, `ef_t1`,
    `checkin_streak_t1..t3`, `learning_t1..t3`, `budget_year_t1..t12`
  - **Private**: `high_scorer`, `ef_t2`, `ef_t3`, `budget_master_t1..t3`,
    `savings_champ_t1..t3`, `debt_destroyer_t1..t3`, `retirement_planner_t1..t3`,
    `insurance_hero_t1..t3`, `retire_ready_t1..t4`, `savings_rate_t1..t3`,
    `savings_streak_t1..t3`, `investor_t1..t4`

  **Duplication note**: `org_leaderboard()`'s `badge_count` (Batch 4,
  `supabase_leaderboard.sql`) hardcodes the same public-id array in SQL,
  since a Postgres function can't import a JS array. If a badge's public/private
  status ever changes in `kw-badges.js`, `v_public_badges` in
  `supabase_leaderboard.sql` must be updated to match, or the leaderboard's
  badge count will silently drift from what the Badges page shows.

- **Badge card "+N pts" labels are now cosmetic, not literal.** Since points
  are awarded exclusively through the catalog-driven ledger (Batch 1) at a
  small set of evidence-checked events, and badge tiers are no longer paid
  out via `award()`/`awardProgress()`, the `pts` figures shown on badge cards
  in `renderBadgeCards()` (`index.html`) no longer add up to the member's
  actual point total. This is an intentional consequence of closing the
  self-reported-assessment gaming hole, not a bug — but the UI copy wasn't
  updated to reflect it (out of scope for this build). Worth a follow-up pass
  if members notice the mismatch.

- **`article_read`, `video_watched`, `tool_first_use` have no server-side
  evidence check.** There is no backing table row proving an article was read
  or a video watched. Per the spec's own guidance for this case, these events
  are accepted without evidence, bounded only by the ledger's
  `unique(user_id, event_type, ref_id)` constraint and the point caps in
  `points_catalog`. Accepted gap — a determined user could call
  `award_points('article_read', '<new-fake-title>')` repeatedly with distinct
  ref_ids to farm 15 pts each time. Low severity (small point value, no
  financial-state leakage) but worth revisiting if abuse is observed.

- **`session_booked` evidence uses the real booking id**, not a "created in the
  last hour" time window, because the spec's time-window fallback would let a
  user replay the RPC repeatedly within that hour for free points. Batch 2 adds
  `.select('id').single()` to the `bookings` insert in `index.html` so the
  frontend has a real id to pass as `ref_id`.

## Batch 6 (planned) — Financial indicators

- **DTI is not stored in `assessments`.** The raw ratio is computed in
  `wellness_assessment.html` and only ever written to `localStorage`. It IS
  persisted to `profiles.monthly_debt` / `profiles.monthly_income` on every
  assessment save (and `monthly_income`/`monthly_expenses` on every budget
  save), so `org_financial_indicators()` computes
  `DTI% = monthly_debt / nullif(monthly_income, 0) * 100` from `profiles`
  instead of from `assessments`. This means DTI freshness is tied to whenever
  the member last completed an assessment or saved their budget, not to a
  dedicated DTI-calculator save (the DTI calculator tool itself still only
  writes to `tool_data`/localStorage).

- **Pension contribution % is not derivable.** `monthlyPension` (entered in the
  retirement section of the assessment) is a local JS variable in
  `wellness_assessment.html` and is never written to Supabase. Per the spec's
  own fallback instruction, this indicator is **omitted** from
  `org_financial_indicators()` rather than invented.

- **Financial Stress added as a third indicator** (post-hoc scope clarification
  — the original batch spec only named DTI and retirement). Sourced from
  `stress_logs.level` (1-10 scale, latest log per member), reusing the same
  `>=7 = high stress` threshold already used member-side in index.html's
  dashboard. Bands: Low (1-3), Moderate (4-6), High (7-10). Same
  reported_count/median/cell-suppression shape as `dti`.

## Manual follow-up — NOT attempted by Claude

- **Privacy notice / consent copy update required.** Once opt-in leaderboards
  and the HR Rewards tab (Batch 7) are live, the employee-facing privacy
  notice and consent flow need to disclose: (a) leaderboard participation is
  optional and what it exposes, and (b) HR receives name + points for
  opted-in members via the Rewards tab. This is a legal/compliance copy change
  under the Botswana Data Protection Act (Act 18 of 2024) and should be
  reviewed by Tshenolo before shipping to production, not drafted by an
  agent.

---

# Rewards reshape — Categories, Thresholds & HR Fulfilment

Product reshape of the points/leaderboard/rewards system above: three
HR-visible categories (Utilisation/Learning/Progress) replace the flat
season total, the member leaderboard is removed in favour of a private
Progress card, HR gets a fulfilment (Reward button) flow, thresholds respect
member tenure, and employers can self-report headcount. SQL files:
`supabase_rewards_categories.sql`, `supabase_reward_thresholds.sql`,
`supabase_drop_leaderboard.sql`, `supabase_rewards_reshape.sql`,
`supabase_reward_fulfilment.sql`, `supabase_org_headcount.sql`. None of
these have been run against the live Supabase project yet — see "Manual
follow-up" at the end of this section.

## Schema deviations from the reshape spec

- **`profiles` has no `created_at` column.** Confirmed absent (only
  `organizations`/`employers` have it; `supabase_seed_test_org.sql` always
  joins `auth.users` for account-creation dates). The tenure rule ("first
  season" = calendar quarter containing account creation) is therefore
  computed from `auth.users.created_at`, joined on `profiles.id =
  auth.users.id`, everywhere it's needed: inline in `org_rewards()` and
  `record_reward_fulfilment()` (`supabase_rewards_reshape.sql` /
  `supabase_reward_fulfilment.sql`), and client-side in `index.html`'s
  `isFirstSeasonMember()` using `currentUser.created_at` (Supabase Auth
  already exposes this on a user's own session — no extra RPC needed for a
  member's own tenure). All three use the identical formula
  `to_char(created_at, 'YYYY"-Q"Q') = to_char(now(), 'YYYY"-Q"Q')` — if this
  ever needs to change, update all three call sites together.

- **`profiles` has no `email` column either** (confirmed the same way).
  `org_rewards()` and `org_reward_history()` join `auth.users` for email —
  the same pattern already established by `handle_new_user()` and
  `supabase_employer_email.sql`'s backfill trigger.

- **`org_rewards()`'s return shape needed a `user_id` column not listed in
  the spec.** The spec's column list (first_name, last_name, email, ...) has
  no stable identifier the frontend can pass to
  `record_reward_fulfilment(p_user_id, ...)` — email alone isn't a usable
  uuid argument. Added `user_id uuid` as the first return column; it
  discloses nothing HR doesn't already see via name+email for the same
  (opted-in-only) row.

- **Dependency-ordering across batches.** `org_rewards()`/
  `org_rewards_summary()` (Batch 4) need to read `reward_fulfilments` (for
  `rewarded_categories`) and `org_headcount_reports` (for
  `reported_headcount`), but those tables' write-RPCs ship in Batches 5 and
  7. Both tables are created (`IF NOT EXISTS`, RLS on, no policies) inside
  `supabase_rewards_reshape.sql` itself; the Batch 5/7 files re-declare them
  `IF NOT EXISTS` (idempotent no-op) alongside the RPCs that are actually
  allowed to touch them. Apply the SQL files in numeric/batch order and
  this resolves itself — there is no window where a function references a
  genuinely missing table.

- **`leaderboard_opt_in` column keeps its original name.** It now means
  "share my points with HR for rewards", not "show me on the leaderboard".
  Renaming it would be a non-additive migration (drop+recreate or a
  multi-step rename) for no functional gain, so the name is a permanent
  naming quirk — grep for `leaderboard_opt_in` before assuming it's
  leaderboard-related in any future change.

- **`display_alias` column is now fully dormant.** The member leaderboard
  (its only renderer) is removed; the alias input was removed from the
  Badges page consent card per the spec's instruction. The column itself is
  left in place (additive discipline) — nothing writes or reads it anymore.
  Safe to drop in a future cleanup if it's confirmed nothing else depends on
  it, but not attempted here.

- **`org_rewards()`/`record_reward_fulfilment()` exclude `season='legacy'`
  from every season sum**, per the spec's blanket instruction — even though
  in practice `pe.season = v_season` already can't match `'legacy'` unless a
  caller explicitly passes `p_season='legacy'`. The extra `and pe.season <>
  'legacy'` guard exists specifically to close that edge case off.

- **`record_reward_fulfilment()`/`org_reward_history()` are strictly
  employer-only** (resolved via `employer_org()`), with no `is_admin()` +
  explicit-org-param override, unlike `org_overview()`/`org_rewards()`. The
  spec's signatures for these two RPCs have no org parameter, so there's no
  way to disambiguate which org an admin means — kept deliberately narrow
  rather than inventing a parameter the spec didn't ask for.

## Post-ship fix — ambiguous column references in PL/pgSQL

After both branches went live, the Rewards tab failed with `column
reference "user_id" is ambiguous`. Root cause: `org_rewards()` and
`record_reward_fulfilment()` both declare `RETURNS TABLE (user_id uuid,
..., org_id uuid, season text, category text, ...)`, and PL/pgSQL exposes
each OUT column as an implicit variable throughout the function body. Any
*unqualified* reference to a column with the same name inside the query
(e.g. `where user_id = p_user_id`) is then ambiguous between the table
column and that implicit variable — Postgres won't guess.

Fixed in three places (all now qualify every column with its table alias):
`org_rewards()`'s `fulfilled` CTE (`user_id`), `record_reward_fulfilment()`'s
idempotent re-fetch (`org_id`/`user_id`/`season`/`category`), and its
`reward_thresholds` lookup (`category`). Re-run the corrected
`supabase_rewards_reshape.sql` and `supabase_reward_fulfilment.sql` — both
are `CREATE OR REPLACE FUNCTION` with unchanged return signatures, so no
`DROP FUNCTION` is needed this time.

**General lesson for future RPCs in this codebase**: whenever a plpgsql
function's `RETURNS TABLE (...)` column list shares a name with a real
table column it queries, qualify every reference to that name with a table
alias, even in single-table subqueries — don't rely on "only one table in
this FROM clause" as proof of non-ambiguity.

**Follow-up — the qualification fix above was incomplete for
`record_reward_fulfilment()`.** After re-deploying, clicking Reward still
raised `42702 column reference "org_id" is ambiguous`, confirmed via
`pg_get_functiondef` to be hitting the exact function text described above
(ruled out: a stale SQL Editor tab, a duplicate function overload — `select
proname, pg_get_function_identity_arguments(oid) from pg_proc where
proname = 'record_reward_fulfilment'` returned exactly one row — and
`employer_org()` itself, which is `language sql` with no OUT parameters and
therefore structurally can't have this bug). Root-caused to the `insert
into reward_fulfilments (org_id, user_id, season, category, ...) ... on
conflict (org_id, user_id, season, category) ...` statement still sharing
those bare column names with the function's own OUT parameters, even
though every *other* reference in the body was already alias-qualified.

Fixed by removing the collision at the source instead of chasing individual
clauses: `record_reward_fulfilment()` now returns `(recorded boolean,
fulfilment reward_fulfilments)` — the whole row as one composite column —
instead of naming `org_id`/`user_id`/`season`/`category` as separate OUT
parameters. This is safe because `employer.html`'s `confirmReward()` only
checks `error`, never destructures the returned row by field name. Revised
lesson: for a table-returning function whose OUT columns are still
partially or wholly a copy of the target table's own columns (as opposed to
a differently-named projection like `org_rewards()`'s `utilisation_points`
etc.), prefer returning the row as a single composite column over naming
each field — it removes the entire bug class rather than requiring every
reference, in every clause, to be perfectly qualified forever.

## Privacy-notice follow-ups for Tshenolo (from the FINAL CHECKLIST)

- **Revised consent copy is live** in `index.html`'s Badges page (Rewards
  Opt-In card) — no longer mentions a leaderboard; states HR sees points and
  qualification status only, never scores/answers/financial information.
  Worth a legal read alongside the existing Botswana Data Protection Act
  follow-up noted above, since the data actually shared with HR has grown
  (name, email, per-category points, qualification, fulfilment history —
  see below) even though the leaderboard exposure has shrunk to zero.

- **Fulfilment records persist after opt-out.** If a member opts out after
  HR has already recorded a reward for them, `reward_fulfilments` rows are
  NOT deleted or anonymised — `org_reward_history()` will still show past
  fulfilments for that person. This is intentional (a record of what was
  already given, not a live roster), but it means "opt out" does not mean
  "disappear from every HR-visible surface retroactively." Worth a line in
  the consent copy or privacy notice if this behaviour needs to be
  disclosed up front.

- **Email disclosure to HR is new.** The prior `org_rewards()` never
  returned email; the reshaped version does (needed for the Reward
  button/CSV export to identify people unambiguously, and because
  `org_reward_history()` needs it too). This is a small but real expansion
  of what HR can see about an opted-in member and should be reflected in
  the consent copy review above.

- **Ops obligation — returning-Learning threshold (300 required-content
  based).** `reward_thresholds.learning.returning_points = 150` assumes
  annual quiz revalidation and/or quarterly new content. Key Wellness must
  review this value each season; if no new point-bearing learning content
  ships, returning members cannot realistically qualify for Learning. (This
  note also lives inline as a SQL comment in `supabase_reward_thresholds.sql`.)

## Manual follow-up — NOT attempted by Claude

- **None of this build's SQL has been run against the live Supabase
  project.** Per this repo's established convention (every `supabase_*.sql`
  file says "run in the SQL Editor"), and because this is a shared prod/dev
  database, Tshenolo needs to run the six new/changed SQL files in the
  Supabase SQL Editor, in this order: `supabase_rewards_categories.sql` →
  `supabase_reward_thresholds.sql` → `supabase_drop_leaderboard.sql` →
  `supabase_rewards_reshape.sql` → `supabase_reward_fulfilment.sql` →
  `supabase_org_headcount.sql`. Each file's own verification-queries block
  should be run afterward, in the browser console against
  `window._toolSb`/`window._toolSb.rpc(...)` (not the SQL Editor, which
  bypasses RLS and the RPCs' own auth checks).

- **Full end-to-end member/HR journey testing needs real data.** The
  frontend changes (Progress card, Rewards tab rebuild, headcount UI) were
  verified for correct rendering logic and mobile layout (390×844) using
  mocked data in a Node/browser harness, since the live DB doesn't yet have
  the new schema. A real walkthrough — a member earning points across all
  three categories, opting in, HR rewarding them, opting out, checking the
  CSV — should happen once the SQL is live.

---

# Email Template Standardisation

Work against `kw-prompt-email-templates.md`'s batch plan. Two things diverged
from the prompt's assumptions during Batch 0 discovery — recorded here along
with the manual follow-ups every batch produced.

## Batch 0 — discovery findings

- **`kw-email-design-preview.html` does not exist** anywhere in this repo or
  its git history. The prompt's Batch 1 instructs the shared module to match
  it "faithfully." Absent the file, `supabase/functions/_shared/kw-email.ts`
  was built directly from the HTML/CSS skeleton and values embedded in the
  prompt text itself (colours, spacing, structure). If a real design-preview
  file exists elsewhere, diff it against the module and adjust.

- **FormSubmit had a second, live, unstyled send path** beyond the one the
  prompt already knew about (the booking Edge Function had already replaced
  FormSubmit for the initial "booking received" email — confirmed via git
  history: *"Replace FormSubmit with Resend via Supabase Edge Function for
  booking emails"*). `admin.html`'s `updateBookingStatus()` still posted
  directly to `https://formsubmit.co/wellness@keywellness.co.bw` with an
  `_autoresponse` field whenever HR confirmed a booking — a third,
  completely unstyled template source. **Retired in Batch 2**: this send now
  goes through `send-booking-email` (Edge Function) with `type: "confirmed"`,
  using the shared template, same trigger condition (`status === 'confirmed'`),
  same best-effort/non-blocking semantics, but now logs failures to console
  instead of failing silently. The dead, never-called `fsSubmit()` helper in
  `index.html` (a leftover from before the Resend migration — real bookings
  already went through the Edge Function, not this helper) was deleted in the
  same pass. FormSubmit is now fully retired from the codebase; only a
  historical code comment and the stale `CLAUDE.md` "Bookings: FormSubmit.co"
  line reference it.

- **PNG logo asset — resolved.** `assets/img/kw-logo-horizontal.png` (420×62,
  2x for retina at the 210px display width) and `assets/img/kw-icon.png` now
  exist, rasterized directly from the corrected SVG sources via `sharp`
  (no design tool available in this environment). `KW_LOGO_URL` in
  `kw-email.ts` already pointed at the right path
  (`https://keywellness.co.bw/assets/img/kw-logo-horizontal.png`) — no change
  needed there. **Still blocked on `main`**: `assets/img/` doesn't exist on
  `main` at all yet, so the URL 404s in production until `dev` is merged. See
  "Manual follow-ups" below.

- **Icon design mismatch — resolved.** `assets/img/kw-icon.svg` and
  `kw-logo-horizontal.svg` previously used a stale single-blob icon (no
  yellow) that didn't match the actual brand mark used live on the login
  screen (`index.html`'s inline `auth-logo` SVG — dot-ring + green circle +
  yellow petals). Confirmed with Tshenolo that the login-screen version is
  authoritative; both asset files were rebuilt from those exact paths (icon
  cropped to `viewBox="0 0 62 62"`, horizontal lockup to
  `viewBox="0 0 286 62"`, tagline dropped for the horizontal version since
  email/small-size contexts don't carry it). Since `admin.html`'s favicon
  already referenced `kw-icon.svg`, this also fixes the favicon site-wide,
  not just email.

- **"KEY"/"WELLNESS" text overlap — resolved, in three places.** The
  original coordinates (`WELLNESS` at `x="116"`) put it under "KEY"'s actual
  rendered end (~x=128 at font-size 25, measured via `getBBox()`), causing
  visible overlap at larger render sizes. Fixed to `x="134"` in
  `assets/img/kw-logo-horizontal.svg`, in `index.html`'s inline `auth-logo`
  SVG (the original source of the bug, carried over when it was copied), and
  implicitly in the newly-generated `kw-logo-horizontal.png` (rasterized
  after the fix). Verified overlap-free at both 210px and 420px render
  widths in-browser.

- **No physical address or Help/Privacy pages exist yet.** The member footer
  needs a mailing address and Help/Privacy links per the prompt's spec. No
  address was found anywhere in the repo, and there is no in-app Help or
  Privacy page (only a Privacy section within the signup flow). The footer
  currently reads "Key Wellness · Botswana" and links Help to
  `mailto:wellness@keywellness.co.bw` and Privacy to a placeholder
  `https://keywellness.co.bw/privacy` URL that doesn't exist yet. Fix once a
  real address and pages exist — single edit in `renderFooter()` in
  `kw-email.ts`.

- **OTP/link expiry could not be discovered from code** (no
  `supabase/config.toml` in this repo — auth settings are dashboard-only).
  The Batch 4 auth templates use generic wording ("This link expires soon
  for your security") rather than a specific hour count, per the prompt's
  instruction not to assume a number. Confirm the actual expiry in
  Dashboard → Authentication → Email/OTP settings and tighten the copy if a
  specific figure is wanted.

## Batch 1 — shared module

`supabase/functions/_shared/kw-email.ts` — new file, additive, delete to
revert. Verified: zero `svg`/`base64` hits, `#E8C018` used only for
`background`/`border-left` (never `color:`), both member and internal
variants render correctly (manually paste-tested via a Node-transpiled copy
of the render logic, screenshotted in-browser since Deno isn't installed in
this environment).

## Batch 2 — booking Edge Function

`supabase/functions/send-booking-email/index.ts` rewired to use the shared
module; `admin.html`'s FormSubmit call replaced with an Edge Function call
(see Batch 0 above). Success/failure semantics unchanged for the original
"new booking" flow (client send still gates, team notification still
best-effort but still surfaces as a 502 if it fails, matching the original
code's behaviour exactly).

**⚠️ Not deployed. Not tested against real Resend/Gmail.** This function
serves production (shared Supabase project) the moment it's deployed —
deploying and sending real test emails from an agent session isn't something
I'll do without you present. Manual steps before this ships:

1. `supabase functions deploy send-booking-email` (and confirm `_shared/` is
   included — Supabase bundles relative imports automatically, but verify in
   the deploy output).
2. Make one real test booking on the dev site. Confirm:
   - Client confirmation email arrives, renders correctly in Gmail web and
     one mobile mail client, Reply-To lands at `wellness@keywellness.co.bw`.
   - Team notification arrives at `wellness@keywellness.co.bw`, Reply-To is
     the client's address.
3. In the admin dashboard, confirm a test booking and verify the
   "booking confirmed" email arrives styled correctly with the shared
   template (this is the newly migrated FormSubmit replacement — hasn't been
   exercised against real Resend at all yet).
4. Force a team-notification failure (e.g. temporarily break `TEAM`'s
   address) and confirm: the error is logged to the function's console
   output, and the client email still sends successfully.
5. Rollback: Supabase retains function deploy history; redeploy the previous
   version from the dashboard, or `git revert` this commit on `dev`.

## Batch 3 — certificate renderer

`certificateReadyEmail()` added to `kw-email.ts`. No send path created —
confirmed via repo-wide grep for `resend.emails.send`/`api.resend.com`
(only hit is the existing Batch 2 `sendEmail()` call). Rendered with sample
data and grepped for `improvement`/score/topic-name leakage — zero hits.

## Batch 4 — Supabase Auth templates (⚠️ manual dashboard paste required)

Five files generated in `email-templates/auth/`: `confirm-signup.html`,
`invite-user.html`, `magic-link.html`, `reset-password.html`,
`change-email.html`, plus `SUBJECTS.md`. Each contains exactly 3 references
to `{{ .ConfirmationURL }}` (button href, alt-link text, alt-link href).
Yellow-as-text grep: zero hits.

**Manual procedure (this is live in production the instant it's saved —
do it in a low-traffic window):**

1. Before touching anything: Dashboard → Authentication → Email Templates →
   for each of the 5 template types, copy the **current** body HTML into
   `email-templates/auth/_previous/<template-name>.html` in this repo. That
   folder exists and is currently empty — it's the rollback copy.
2. For each of the 5 types, paste the subject from `SUBJECTS.md` and the
   body from the matching file in `email-templates/auth/`.
3. Save.
4. Trigger one of each from the dev site: a test signup (Confirm signup), a
   password reset (Reset password), and an invite if there's an invite flow
   wired up (Invite user). Verify rendering and that the links work
   end-to-end. Magic link and Change email can be spot-checked the same way
   if those flows are reachable.
5. Rollback: paste the corresponding file back from `_previous/`.

Also confirm before pasting: which of the 6 possible template types
(Confirm signup, Invite user, Magic link, Reset password, Change email,
Reauthentication) are actually **enabled** in this project — the prompt
listed Reauthentication as a possible 6th type but gave no spec for it, so
no file was generated for it. If it's enabled and in use, it needs its own
template; flag back if so.

## Batch 5 — logo, retirement, sweep

- **Logo — resolved.** `assets/img/kw-logo-horizontal.svg` was never the
  slogan lockup (that correction above was based on a mistaken read — the
  slogan only ever lived in `index.html`'s separate inline `auth-logo` SVG).
  The actual gap was that `assets/img/`'s SVGs used a stale, mismatched icon
  design; both were rebuilt from the login screen's real mark and PNGs
  generated (see the "resolved" entries above). `KW_LOGO_URL` needed no
  change — it already pointed at the correct path.
- **FormSubmit**: retired, not just reported (see Batch 0/2 above).
- **Sweep**: repo-wide grep for ad-hoc email HTML strings outside the shared
  module and the auth template files found none remaining.
- **Post-merge check (do after `dev` → `main`)**: confirm
  `https://keywellness.co.bw/assets/img/kw-logo-horizontal.png` returns 200,
  then send one test of each email family from production.

## Manual follow-up — NOT attempted by Claude

- **DPA lawyer sign-off** on the footer trust line wording ("Your individual
  data is never shared with your employer.") before employer-cohort
  scale-up, per the prompt's own requirement.
- **Resend dashboard**: confirm domain verification covers
  `noreply@keywellness.co.bw`, and that both scoped API keys are unchanged.
  Not checkable from code.
- **Which Supabase Auth template types are enabled**, and the actual
  OTP/link expiry value — dashboard-only, see Batch 0/4 above.
- **Physical address and Help/Privacy page URLs** for the member email
  footer — see Batch 0.
- **`admin.html` / Edge Function deploy — done.** `send-booking-email` was
  redeployed to the shared Supabase project (`supabase functions deploy`)
  after a real test booking-confirm on `dev` was requested. Note this is a
  shared-project function: the "new booking received" email on `main` now
  also renders through the new shared template as of that deploy, even
  though `main`'s git branch itself wasn't touched.
- **`CLAUDE.md`'s tech-stack table still lists "Bookings: FormSubmit.co"** —
  stale even before this batch (bookings have gone through the Edge Function
  since the earlier "Replace FormSubmit..." commit); worth a one-line fix
  next time that file is touched. Not changed here since it's the project's
  instruction file, not build output.

---

# Learning Pathways — Video LMS, Quizzes & Prolearn Certificates

Full discovery in `BATCH-0-LMS-FINDINGS.md`. Two decisions confirmed with
Tshenolo before proceeding past Batch 0:

1. **`quiz_passed` points stay at 50** — already seeded in `points_catalog`
   (category `learning`) in anticipation of this exact feature, never
   emitted by any code yet. Not bumped to the brief's 75.
2. **Full replacement of the existing 8-module `VIDEOS` array** (YouTube/
   Vimeo embeds, 2 live: `welcome`, `budget`) — no archive/legacy view kept.

Rollback statements are recorded in `migrations/rollback-notes.md`, one
entry per SQL file, before that file's own section below is written —
same standing rule as the rest of this document.

## Batch 1 — `Videos` storage bucket & path conventions

SQL: `supabase_lms_storage.sql`. **Revised after first application**:
Tshenolo had already created the bucket by hand via the dashboard, named
`Videos` (capital V — Supabase bucket ids are case-sensitive), and uploaded
all 15 Pathway-1 videos + a welcome/emergency-fund file directly into its
root with descriptive filenames (e.g. `Module 1_Introduction to...mp4`),
**not** the `lesson-01.mp4`/`pathway-1/` subfolder convention originally
planned below. Decision: keep the real uploaded filenames as-is and point
`content_items.video_path` (Batch 2) at them directly rather than asking
for a re-upload/rename. The revised SQL file cleans up the stray empty
lowercase `videos` bucket the first version created and points the public-
read policy at the real `Videos` bucket instead. No insert/update/delete
policy for `anon`/`authenticated` — only `service_role` (bypasses RLS by
default) can write.

**Original path convention (superseded by the real uploaded names above —
kept here for the welcome video and any future pathway, where there's no
existing upload to match):**
```
Videos/welcome.mp4
Videos/pathway-1/lesson-01.mp4  …  Videos/pathway-1/lesson-15.mp4
Videos/posters/lesson-01.webp   …  (16:9, ~40KB target)
```

**Manual step (outside Claude Code) — encoding standard for every upload:**
```
ffmpeg -i in.mp4 -c:v libx264 -profile:v main -crf 23 -maxrate 1500k \
  -bufsize 3000k -vf "scale=-2:720" -c:a aac -b:a 96k -movflags +faststart out.mp4
```
Poster:
```
ffmpeg -i out.mp4 -ss 00:00:02 -frames:v 1 -vf "scale=640:-2" poster.png
```
then convert `poster.png` to WebP. Upload via the Supabase dashboard Storage
UI or a service-role script — never via the anon/authenticated client (RLS
blocks it by design, see `supabase_lms_storage.sql` verification query 3).
**No posters uploaded yet** — Pathway 1's chapter-shelf cards (Batch 4) will
need a poster image per lesson; flagged as a Batch 5 follow-up if not
supplied before frontend work reaches that screen.

**Status:** applied successfully (revised, DELETE-free version). Confirmed
working via a live anon-key storage listing — all 15 Pathway-1 videos plus
one stray `Starting your emergency fund_video_4k.mp4` file are readable.
That stray file doesn't match any of the 15 Pathway-1 titles (Module 13
already covers "Emergency Funds" separately) — looks like leftover debris
from the old `VIDEOS` array system, not referenced by any Batch 2 seed row.
Left in the bucket, harmless, ignorable.

## Batch 2 — pathways/content_items/quizzes/quiz_questions/quiz_attempts/certificates schema + seeds

SQL: `supabase_lms_schema.sql`. `content_items`/`content_progress` created
fresh (Batch 0 confirmed they didn't pre-exist — brief's ALTER-based plan
corrected to CREATE, see BATCH-0-LMS-FINDINGS.md). All 6 tables + the
`quiz_questions_public` view, RLS policies (no HR/employer policy on any of
them), 3 pathways, 15 Pathway-1 content_items (real uploaded filenames from
Batch 1), 1 welcome content_item (placeholder path, pending upload), and
quiz 1's 8 questions seeded exactly per the brief.

`quiz_questions_public` deliberately omits `security_invoker` (defaults to
false/definer semantics) so it can read past the base table's total RLS
lockout while only ever exposing 6 whitelisted columns — the opposite
pattern from `my_points` (which explicitly sets `security_invoker = true`
so per-user RLS *does* apply). Two different problems, two different view
semantics, both already used correctly elsewhere in this codebase.

**Known gaps carried into later batches:** `duration_seconds` and
`poster_path` are null for every Pathway-1 lesson (no durations measured,
no posters uploaded yet — flagged in Batch 1 above) — Batch 4's chapter-
shelf cards and duration chips will need a fallback (e.g. read duration
from the `<video>` element's `loadedmetadata` event client-side) until
these are backfilled.

**Status:** applied successfully on the second attempt. First attempt failed
with `relation "your" does not exist` (`42P01`) — traced via the Supabase
log explorer to the Studio SQL Editor's own auto-append behavior: after
detecting `CREATE TABLE` statements, it appends `-- Added by Supabase:
enable Row Level Security on newly created tables` + an `ALTER TABLE ...
ENABLE ROW LEVEL SECURITY;` suggestion to the query text before running —
and its table-name extraction mis-fired, injecting the literal word `your`.
Not a defect in this file (every table already has an explicit `alter
table ... enable row level security` statement of its own); re-running
without accepting/appending that suggestion succeeded cleanly. Verified
live via REST: `pathways`/`content_items`/`quiz_questions` correctly return
empty for the anon role (RLS blocks non-authenticated reads exactly as
designed), `quiz_questions_public` returns all 8 questions with sections
A,A,A,B,C,C,D,E matching the brief, no `correct_index` in any row.

**One tightening carried into Batch 3's file**: `quiz_questions_public` is
also readable by the `anon` role, not just `authenticated` — this project's
default schema privileges appear to grant `anon` SELECT on new objects
until RLS narrows it, and since a view has no RLS of its own (it runs with
the *view owner's* privileges against the base table, by design, so
`correct_index` stays hidden either way), `anon` slips through. Not a
security issue (never exposes answers or per-member data), but tightened to
authenticated-only for consistency with every other new table's policy.

## Batch 3 — complete_video() / submit_quiz() / issue_certificate() RPCs

SQL: `supabase_lms_rpcs.sql`. All three SECURITY DEFINER, reusing existing
infrastructure instead of adding new plumbing: `award_points()` (already
seeded `video_watched`=25pts and `quiz_passed`=50pts, category=learning —
no catalog changes needed) and `is_admin()` (existing helper from
`supabase_multitenancy.sql`, checks the `admins` table by JWT email — reused
directly rather than re-implementing an admin lookup per RPC).

**Admin handling — a judgment call, flagging it explicitly**: the brief's
Batch 3 §1 says "Reject if caller is an admin account (no points events for
admins)." Implemented as a hard reject (raises an exception, blocks the
call entirely) in `complete_video()` and `submit_quiz()`, not just silent
point-suppression — read literally, and consistent with how this app
already treats admin accounts as staff-only (never members). Consequence:
**admin accounts cannot exercise the pathway/quiz flow at all, including
for QA** — testing the member-facing loop end-to-end needs a real
(non-admin) test member account. `issue_certificate()` has no separate
admin check; it's unreachable for admins by construction (requires a prior
passing `quiz_attempts` row, which `submit_quiz()` already refuses to
create for them). If this reading is wrong and admins should be able to
click through the flow (just without earning points), this is a one-line
change per function (swap the `raise exception` for skipping only the
`perform award_points(...)` call) — flagging for Tshenolo to confirm before
Batch 4 QA depends on it.

`submit_quiz()`'s `p_answers` shape: `[{"question_id":"<uuid>",
"selected_index":0-3}, ...]` — matched by question id, not array position,
so the frontend doesn't need to preserve fetch order. Unanswered/unmatched
questions grade as incorrect rather than erroring, so a partial submission
still returns a real score.

**Status:** applied successfully. Verified via REST: all three RPCs exist
and correctly reject unauthenticated calls (`P0001 "not authenticated"`),
and the `quiz_questions_public` anon-revoke from Batch 2's addendum is
confirmed live (401 for anon now, was 200 before).

**Admin-access decision confirmed by Tshenolo**: hard reject stands as
written — admin accounts cannot exercise `complete_video()`/`submit_quiz()`
at all. QA of the pathway/quiz/certificate loop requires a real
(non-admin) member test account, not the admin login.

## Batch 4 — Frontend rebuild (index.html, css/kw-pathways.css, js/certificate-template.js)

Design reference: `docs/design/kw-pathways-preview-v2.html` (committed by
Tshenolo mid-batch — see the "Design reference" decision below). Rebuilt
Learn → Videos entirely around the new Supabase-backed pathway system;
Learn → Articles is untouched.

**Design adaptation, not a pixel copy**: the preview uses its own
standalone palette/fonts (Inter + Bricolage Grotesque + hardcoded hex) for
fast prototyping. Production uses this app's real token system
(`css/kw-theme.css`'s `--kw-*` custom properties) and font stack (Nunito +
DM Mono, already loaded) instead — same layout, component structure, and
interaction logic, reskinned onto the live design system so it doesn't
fork the app's actual brand tokens. All new classes are `.lp-`-prefixed
(Learning Pathways) to avoid colliding with the existing `.pw-*` classes,
which already mean "password toggle" in this codebase, not "pathway".

**What's live:**
- `state.lp` namespace + `loadPathwaysData()` (lazy-loaded on first Learn →
  Videos visit, matches the old `loadVideoProgress()` lazy-load pattern) —
  fetches `pathways`/`content_items`/`quizzes`/`quiz_attempts`/`certificates`
  in parallel, every failure surfaces a toast (`showToast`) and logs to
  console, never fails silently.
- `state.videoProgress` is now populated from `content_progress` (via
  `loadBadgeData()`), not `tool_data.video_progress` — and is the *same
  array reference* as `state.lp.progress`, so a push from the Learning
  Pathways player and a read from the Confident Learner badge system never
  drift out of sync. `state.videoTotal` (live `content_items` count)
  replaces the old hardcoded `VIDEOS.length` in the PART 6 learning-%
  calculation.
- Landing (continue-learning hero + 3 pathway cards + welcome strip),
  pathway detail (chapter shelves grouped by `section_label`, grid desktop
  / horizontal snap-scroll mobile), video player (real `<video controls
  preload="metadata">` streaming from the `Videos` bucket, `ended` +
  ≥90%-`timeupdate` fallback both guarded by a single `_lpFired` flag so
  `complete_video()` never double-fires), up-next 5-second countdown
  overlay, quiz (intro w/ certificate-name field → one-question-at-a-time →
  result w/ per-question ✓/✗, no correct answers ever rendered), celebration
  (confetti, `prefers-reduced-motion` respected), certificate claim →
  `issue_certificate()` → SVG render → PNG download / print.
- Poster art: real `poster_path` image if set (none are yet — Batch 1
  flag), else a templated SVG gradient card using live `--kw-green*`/
  `--kw-yellow` tokens (so it themes correctly, unlike a flat hardcoded
  hex) with a per-lesson emoji icon lookup (`LP_ICONS`, sort_order 1–15).
- Retired completely: `VIDEOS` array, `loadVideoProgress()`/
  `saveVideoProgress()`, `markVideoComplete()`, `_ensureYTApi()`,
  `_attachVideoPlayers()`, the dead `window.markVideoWatched`/`kw_watched`
  honour-system code. **Kept**: `_ensureVimeoApi()` — still used by the
  *unrelated* onboarding welcome-modal player (`showWelcomeVideo()`,
  a one-time signup-flow video gate, not part of Learn → Videos at all;
  confirmed by tracing every call site before removing anything nearby).

**Verification performed** (no Docker/real login available in this
environment — see below for what still needs a human pass): started the
static-file preview server, drove the app via `preview_eval` with
simulated `state.lp` data shaped exactly like the real Batch 2 schema
(since real login wasn't available this session — Tshenolo will do the
logged-in pass). Confirmed: all six views (landing/pathway/quiz-intro/
quiz/quiz-result/celebrate) render through the *real* `VIEWS['learn']`
router with zero console errors; `KWCertificate.svgMarkup()` produces
valid SVG containing the supplied name; the player builds a correctly
URL-encoded Storage URL that resolves live (`curl -I` → `200 video/mp4`,
confirmed against a real uploaded filename with spaces); quiz answer
picking/nav/button-disable-until-answered all work; mobile shelf
scroll-snap CSS (`display:flex;overflow-x:auto`) applies under the
`max-width:640px` breakpoint; the "unlocks next pathway" celebration line
renders correctly for both an active and a not-yet-active next pathway.

**NOT verified in this session (needs Tshenolo, real login)**: the actual
RPC round-trip (`complete_video`/`submit_quiz`/`issue_certificate` against
real auth), sequence-bypass rejection end-to-end through the UI, the full
watch → auto-advance → quiz fail → retake → pass → certificate PNG
download loop, and visual screenshot comparison against the design
preview (the preview tool's screenshot capture timed out consistently in
this environment, on the plain login screen too, before any Learning
Pathways code ran — an environment/tool issue, not a page issue;
`preview_snapshot`/`preview_eval` were used instead and are consistent
with correct rendering, but a human visual pass is still worth doing).

**Known follow-ups, not blockers:**
- No poster images uploaded yet (Batch 1) — SVG gradient fallback covers
  this today; swap in real WebP posters via `content_items.poster_path`
  whenever they're ready, no code change needed.
- `duration_seconds` is null for every lesson — no duration chip is shown
  anywhere yet (the brief's "duration chips" were dropped from this build
  since there's no data to show); add back once durations are measured
  and backfilled.
- The welcome video's `content_items.video_path` is still the Batch 2
  placeholder (`'welcome.mp4'`) — the real file hasn't been uploaded (Batch
  0/1 finding). Update that one row's `video_path` via the SQL Editor once
  it's live in the `Videos` bucket; nothing else needs to change.
- Certificate template uses placeholder navy/orange/gold values and
  `<image>` tags pointing at `assets/img/prolearn-logo.png` /
  `assets/img/prolearn-signature.png` — neither asset nor the referenced
  `prolearn-certificate-preview.html` were available this session (flagged
  in BATCH-0-LMS-FINDINGS.md and again here). Certificate will render with
  broken image icons in place of the logo/signature until those two PNGs
  are added to `assets/img/`.

## Batch 5 — Wrap-up flags

Manual follow-ups only; no code/SQL in this section.

1. **Video/poster uploads — Pathway 1 is mostly done, two pieces remain.**
   All 15 Pathway-1 lesson videos are already uploaded to the `Videos`
   bucket (done by Tshenolo mid-build, real filenames like `Module
   1_Introduction to Financial Literacy_video.mp4`, 20–43MB each). Still
   needed to fully go live: (a) the **welcome video** — not uploaded at
   all yet, `content_items` has a placeholder path (`welcome.mp4`) that
   will 404 until the real file is uploaded and that one row's
   `video_path` is updated to match; (b) **posters** — none uploaded for
   any of the 15 lessons; the app falls back to a generated SVG gradient
   card today, which works but isn't the real WebP artwork. Encoding
   standard for both is documented in Batch 1 above.
2. **Pathway 2 — titles pending from a colleague, per the original brief.**
   Seed its `content_items` rows + a second quiz using the exact same
   pattern as `supabase_lms_schema.sql`'s Pathway 1 section once titles
   arrive, then flip `pathways.status` from `'locked'` to `'active'` for
   `id=2` — only then does it become reachable in the UI (the
   `complete_video()`/`submit_quiz()` reachability logic already checks
   "previous pathway's quiz passed" generically, so no RPC changes are
   needed, just data).
3. **Point values — resolved for Pathway 1, but the threshold math behind
   them is a real, already-confirmed problem, not a hypothetical.**
   `quiz_passed` stays at the pre-existing 50 points (Tshenolo's call in
   Batch 0, not the brief's 75 — see BATCH-0-LMS-FINDINGS.md). But
   `reward_thresholds` already has `learning.returning_points = 150`,
   seeded before this feature existed, with its own code comment flagging
   that it "MUST be reviewed each season against new content published."
   Pathway 1 alone now injects up to `15×25 + 50 = 425` Learning points
   per member — **2.8× the current returning-member threshold**, confirmed
   directly (not estimated) once real completions start flowing through
   `points_events`. This needs a staff decision (raise the threshold, or
   accept that returning members will clear it almost immediately) before
   or shortly after go-live — recommend raising `reward_thresholds` via
   the SQL Editor (`update reward_thresholds set returning_points = ...
   where category = 'learning'`) rather than leaving it stale.
4. **Prolearn authorisation — now blocking two things, not one.** The
   brief's original ask (written intra-group authorisation covering
   digital issuance of the "Certificate of Completion," explicitly
   non-BQA-registrable wording) still stands. In addition, this session
   could not obtain the actual `prolearn-certificate-preview.html`
   reference or the `prolearn-logo.png`/`prolearn-signature.png` image
   assets — flagged twice already (Batch 0, Batch 4) — the certificate is
   live in code but will show broken image placeholders for the logo and
   signature until those two files are dropped into `assets/img/`. Same
   authorisation conversation should settle both the wording and the
   asset hand-off at once.
5. **Privacy notice** — update employee-facing copy to disclose that the
   portal now stores a member-entered certificate name and quiz attempt
   history, visible only to the member. Confirmed unchanged/still true:
   this data never reaches any HR surface (see point 7).
6. **Ops — Supabase Storage egress.** With real files now uploaded (15
   videos, 20–43MB each, ~380MB total for Pathway 1 alone before Pathway
   2/3 or posters), check the Storage egress figure in the Supabase
   dashboard after the first month of real member traffic. Escape hatch
   if it trends over the plan's quota: move the `Videos` bucket's contents
   to Cloudflare R2 — a URL swap in `LP_VIDEOS_BASE` (index.html) and the
   `content_items.video_path`/bucket policy, no schema or RPC change.
7. **HR invariant — re-checked, holds.** `org_overview()` has zero
   learning/video/quiz references (grepped, Batch 0). `org_report_data()`/
   `_v2()`'s Learning section was already reading `points_events` for
   `article_read`/`video_watched`/`quiz_passed` *before* this build shipped
   (pre-provisioned, Batch 0 finding) — its shape is unchanged; it will
   simply start returning non-zero, still-aggregate, still-suppressed
   counts as real members progress. No per-member learning data is
   reachable from any HR-facing table, view, or RPC — confirmed by the
   RLS policies in `supabase_lms_schema.sql` (no HR/employer policy on
   any of the six new tables) and by inspection of every HR RPC touched
   or read during this build.

## Post-launch fix — up-next overlay timing + fullscreen visibility

Two real bugs found in live testing (Tshenolo):

1. **Up-next popup interrupted playback before the video actually
   finished** — the ≥90%-`timeupdate` fallback (added per the brief as a
   safety net for browsers that never fire `ended`) was wired to trigger
   the *entire* completion flow, including the intrusive up-next overlay,
   the moment it crossed 90% — while the video was still actively playing
   and the member could still be hearing important content.
   **Fix**: split `lpOnVideoEnded()` into `lpMarkComplete()` (calls
   `complete_video()`, awards points, shows the small "+pts" flash —
   silent, non-blocking, safe to fire at 90% in the background) and
   `lpAdvanceAfterCompletion()` (shows the up-next overlay / routes to the
   quiz — now called ONLY from the real `ended` event). The ≥90% fallback
   still guarantees progress/points are recorded even if `ended` never
   fires; it just no longer talks over the video to do it. If `ended` fires
   after the fallback already ran, the cached RPC response is reused
   (`video._lpCompletionData`) instead of calling `complete_video()` twice.
2. **Up-next popup never appeared in native fullscreen** — the overlay is
   a DOM sibling of `<video>`, and native video fullscreen only fullscreens
   the `<video>` element itself, not its parent — everything else,
   overlay included, is simply outside the fullscreen element and isn't
   rendered. **Fix**: `lpAdvanceAfterCompletion()` now calls
   `document.exitFullscreen()` first (if the video is fullscreen) before
   showing the overlay, so it's always visible regardless of how the
   member was watching.

Both verified via `javascript_tool` against a mocked `sb.rpc`: confirmed
no overlay and no duplicate RPC call at 90%-during-playback, overlay shows
correctly on real `ended` reusing the cached result, and
`exitFullscreen()` is called and the overlay becomes visible when the
video was in native fullscreen.

---

# Org Webinars, Quarterly Reward Thresholds & HR Rewards Explainer (2026-07-14)

Full discovery + GO/NO-GO: `BATCH-0-WEBINARS-THRESHOLDS-FINDINGS.md`.
Rollback (written before the forward files): `migrations/rollback-webinars-thresholds.sql`.

## ⚠️ MANDATORY FIRST MANUAL STEP — apply the SQL

This environment has no SQL execution path to the live project (CLI needs
Docker/db password; the Management API token lives in the OS credential
store and was not used). **Nothing in this build works until Tshenolo runs
these files, in this exact order, in the Supabase SQL Editor:**

1. `supabase_webinars_thresholds_schema.sql`  (tables, columns, RLS, bucket, catalog)
2. `supabase_webinar_learning_rpcs.sql`       (record_video_progress, learning_qualified, complete_video reshape)
3. `supabase_utilisation_rpcs.sql`            (award_points v3, attendance trigger, utilisation_qualified, my_rewards_qualification)
4. `supabase_org_rewards_v2.sql`              (org_rewards qualification switch)

Until step 1 runs, the frontend degrades gracefully: the Webinars section
shows its empty state, progress pings log one console warning, the member
Rewards card shows "unavailable right now" for Utilisation/Learning, and
admin's Webinars tab shows an explicit "migration not applied" error card.
**But note two behaviour changes that land with step 3:** check-ins award
`checkin_logged` (15, per fortnight window) instead of `monthly_checkin`
(75), and `session_booked` drops 100 → 10 with `session_attended` (40)
added — brief members if mid-quarter comms are needed.

The `webinar-url` Edge Function is ALREADY DEPLOYED (this run, via CLI) and
returns explicit 401/400 today; it starts returning signed URLs once step 1
creates the bucket/columns and a webinar row exists.

## Dashboard-only manual steps

1. **Storage per-file upload limit**: raise from the default to ~1GB
   (Project Settings → Storage) to cover compressed webinars.
2. **`webinars` bucket**: created by SQL step 1 (`insert into
   storage.buckets`) — verify it shows PRIVATE in Storage → Buckets. If the
   insert was blocked for any reason, create it by hand (private, no
   public access).
3. **Upload flow (v1)**: upload webinar files by hand into the `webinars`
   bucket, then register them in admin.html → Webinars tab (file path +
   title + org + duration), then Publish. In-app upload of 500MB+ files was
   deliberately not built this run.
4. **Auth → Users**: unrelated but still open from a prior batch — signup
   "Error sending confirmation email" 500 (see that batch's notes).

## Transcode runbook (Lone)

Compress recordings to 720p H.264 ~1.5Mbps + AAC before upload
(~650MB/hour). HandBrake preset: "Fast 720p30".

## Sedimosa

- `organizations` seed targets `name ilike '%debswana%'` — **confirm the
  Debswana org row exists** before/after running step 1; if it doesn't yet,
  set `program_name='Sedimosa'`, `program_logo_path='assets/img/sedimosa-logo.png'`
  on the row once created.
- **Logo asset is NOT in the repo.** Commit it at
  `assets/img/sedimosa-logo.png` (the header hides the broken image and
  shows text-only "Sedimosa Webinars" until then).
- Written authorisation on file (same discipline as ProLearn).
- Branding renders ONLY on the Learn page Webinars section header. Portal
  chrome stays Key Wellness everywhere.

## Migration trigger (decision pre-made)

Move webinars to Bunny Stream / Cloudflare Stream when members report
buffering OR monthly egress consistently exceeds the included 250GB.
(Watch Storage egress in the dashboard; the private-bucket signed-URL
pattern ports 1:1 to either CDN.)

## Quarterly review items for Key Wellness staff

- `threshold_config.sessions_attended_required` — seeded at 1, revisit.
- Retroactive budget creation inside the quarter counts (accepted v1
  gaming vector) — review after the first full quarter.
- Library size vs the ⅓ Learning threshold as new videos publish
  (`learning_library_fraction` in `threshold_config`; library size is
  computed live). This supersedes the old "review the 150-pt returning
  learning threshold" note — that threshold is retired; the
  `reward_thresholds.learning` row remains but nothing reads it.

## Admin process

Lone marks session attendance in admin.html → Appointments. **Attendance
is now a reward-affecting action** (the DB trigger writes 40 pts to the
member's ledger, and the Sessions pillar of Utilisation counts only
verified attendance). Un-marking attendance does NOT claw points back —
correct mistakes promptly and flag persistent errors for manual ledger
review.

## Data migration note

Historical localStorage bookings/check-ins/budgets are NOT migrated.
Qualification starts clean from the quarter this ships (2026-Q3 if applied
now). Check-ins/bookings already server-side keep their history and DO
count for the current quarter's windows. Confirm member comms if shipping
mid-quarter.

## Timezone note

Quarter/fortnight-window boundaries for the new qualification logic use
Africa/Gaborone. The `points_events.season` stamp keeps the existing UTC
convention — a ±2h skew exists at quarter boundaries between points
display and qualification windows. Accepted; do not "fix" one without the
other.

## REVISION (2026-07-14, later the same day — MD decision): webinars move to Vimeo

Framework change agreed with the MD. Three points, two of which were
already true in what shipped earlier today:

1. **Sidebar/portal chrome stays Key Wellness for all users** — already
   the case; no code change was needed. Org branding never touched the
   sidebar or auth screen.
2. **Org-specific logos appear in the webinars context** — already the
   case; the "{program_name} Webinars" header + logo render only on the
   Learn page's Webinars section.
3. **Webinars are hosted on VIMEO, not Supabase Storage** — implemented
   now. What changed:
   - `supabase_webinars_thresholds_schema.sql` no longer creates a
     `webinars` bucket (§8 is now a comment documenting the Vimeo model).
     For kind='webinar' rows, `video_path` stores the Vimeo reference
     ('<id>' or '<id>/<privacy-hash>').
   - The `webinar-url` Edge Function is retired: deployment deleted from
     the project, source removed from the repo.
   - The member player embeds Vimeo via the Player API (already used by
     the welcome modal); progress pings to `record_video_progress` are
     unchanged (resume works, webinars still earn no Learning credit —
     the RPC's kind guard is host-agnostic).
   - admin.html → Webinars accepts a pasted Vimeo URL/ID and normalises it.
   - Org privacy model: RLS on content_items still decides which members
     ever receive a webinar's Vimeo reference. Vimeo-side settings are the
     second wall (below).

**Superseded/void items from the section above:** Storage upload-limit
raise (not needed), `webinars` bucket creation/verification (no bucket),
HandBrake transcode runbook (upload originals; Vimeo transcodes), and the
Bunny/Cloudflare Stream egress migration trigger (Vimeo serves from its
own CDN; no Supabase egress).

**NEW manual steps (Vimeo dashboard — Claude Code has no access):**
1. Use a Vimeo plan that supports privacy controls (Starter or higher;
   embed-domain restriction requires it).
2. Per webinar (or as account default): Privacy → "Hide from Vimeo"
   (link-only), and Embed → restrict to the portal domains:
   `mogomotsifrance-star.github.io`,
   `keywellness-portal.mogomotsifrance.workers.dev`
   (+ `localhost` while testing on dev previews).
3. After upload, copy the video link (unlisted links include the privacy
   hash — paste the full link into admin.html so the hash is captured).
4. Lone's upload flow: record → upload straight to Vimeo → set privacy →
   paste link in admin → Publish. No compression step required.

**Verification addition:** paste a webinar's Vimeo URL directly into a
logged-out browser — it must NOT play on vimeo.com; it should play only
embedded in the portal. And a member of org A must never receive org B's
reference (RLS check, unchanged).

## Sedimosa logo asset (2026-07-14, later)

`assets/img/sedimosa-logo.png` is now committed at the path the
`organizations.program_logo_path` seed expects — the Learn Webinars header
will render it for Debswana members once the schema migration is applied.

⚠️ NOTE: this file is a high-fidelity RECREATION of the logo Tshenolo
supplied in chat (rendered from the wordmark: navy #1e3a6e, Candara
letterforms approximating the original face, tracked tagline). A pasted
chat image cannot be saved byte-for-byte from this environment. Before
Debswana sees it, replace the file with the original export from the brand
asset pack (same filename, transparent background, ~1000px wide) and eyeball
the header — Debswana brand fidelity should be exact, not approximate.

**RESOLVED (same day):** the interim recreation has been replaced with the
ORIGINAL brand export Tshenolo supplied ("Sedimosa Logo.png" from Downloads,
510x150). No further action needed on this asset; the replace-before-launch
caveat above is closed.
