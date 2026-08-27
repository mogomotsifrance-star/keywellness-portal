# Batch 0 — Discovery Findings

No code or SQL changes were made in this batch. Reproduction steps used the live dev
preview (`http-server` on `localhost:8091`, real Supabase project — dev and prod share
one project, see CLAUDE.md) with `preview_eval`/`preview_network` to inspect real
network responses. No repo file was edited; no SQL was executed beyond nothing (no SQL
was run at all this batch).

**The `BATCH-0-FINDINGS.md` this replaces was stale** — it was the output of an
unrelated prior workstream (stress-log RPCs, bookings calendar, HR reports, rewards
fulfilment) that has nothing to do with this batch's five topics. Overwritten in full.

---

## ⚠️ Headline finding: `keywellness.co.bw` is a live, unrelated WordPress site — not this app

This is the actual root cause behind both 0.1 (broken logo) and 0.3 (broken links), and
it changes the fix for Batches 2 and 4 from "point at the existing constant" to "the
existing constant itself is wrong."

Every absolute URL baked into the email system (`supabase/functions/_shared/kw-email.ts`,
`supabase/functions/send-booking-email/index.ts`, and all 5 files in
`email-templates/auth/`) points at `https://keywellness.co.bw/...`. This repo's own
`CLAUDE.md` lists the actual production URL as
**`https://mogomotsifrance-star.github.io/keywellness-portal`** (GitHub Pages, `main`
branch) — a different domain entirely. Verified with `curl -sI`:

| URL | Status | Content-Type | Notes |
|---|---|---|---|
| `https://keywellness.co.bw/` | 200 | text/html | **Live WordPress site** (`X-Powered-By: PHP/8.1.34`, LiteSpeed, Hostinger `hpanel` — a real marketing site, not this portal) |
| `https://keywellness.co.bw/assets/img/kw-logo-horizontal.png` | **404** | text/html (WP 404 page) | The logo path used by every email template |
| `https://keywellness.co.bw/admin.html` | **404** | — | The "Open in admin" button target in the team booking email |
| `https://keywellness.co.bw/privacy` | **404** | — | Footer "Privacy" link, every email |
| `https://keywellness.co.bw/#profile` | 200 (WP homepage, hash ignored) | — | "Manage preferences" link in the certificate-reward email — resolves to the WordPress homepage, not the portal profile page |
| `https://mogomotsifrance-star.github.io/keywellness-portal/` | 200 | text/html | Real portal, GitHub Pages |
| `https://mogomotsifrance-star.github.io/keywellness-portal/admin.html` | 200 | text/html | Real portal admin |
| `https://mogomotsifrance-star.github.io/keywellness-portal/assets/img/kw-icon.png` | 200 | image/png | Portal's own logo assets, confirmed live |

**A prior workstream (see `BUILD-NOTES.md`, "Email Template Standardisation" section,
Batch 0/5) already investigated the logo specifically and concluded "PNG logo asset —
resolved... still blocked on `main` until `dev` merges," and left a note to re-check
`https://keywellness.co.bw/assets/img/kw-logo-horizontal.png` returns 200 post-merge.**
That prior session's working assumption — that `keywellness.co.bw` would eventually
serve this portal once `dev` merged to `main` — does not match what's actually live at
that domain today. `dev` has since merged past that point (the asset exists on `main`'s
GitHub Pages deploy, confirmed above) and the `keywellness.co.bw` URL still 404s,
because that domain is serving a separate WordPress installation, not GitHub Pages.

**This needs a decision before Batch 2/4 proceed** (recorded as a manual follow-up
below, not guessed at): is `keywellness.co.bw` meant to become a custom domain CNAME'd
to this portal's GitHub Pages deploy at some point (in which case the *code* is
future-correct and the fix is a DNS/hosting task outside this repo), or was that
always the wrong domain and every email link should point at
`https://mogomotsifrance-star.github.io/keywellness-portal` instead? The batch
instructions say "Target: `https://keywellness.co.bw/assets/img/kw-logo-horizontal.png`
(adjust path to actual repo layout)" — I'm treating "adjust" as covering the domain
question too, but this is a judgment call on Key Wellness's actual domain plans that
only Tshenolo can make with certainty. Recommend: point Batch 2/4 at the GitHub Pages
URL now (guaranteed to work today) and revisit if/when `keywellness.co.bw` DNS is
pointed at the portal.

---

## 0.1 Email logo audit

**Templates found** (everywhere `<img>`/`<svg>` could appear in a sent email):

| Template | Sent via | Logo `<img src>` | Inline SVG? |
|---|---|---|---|
| `supabase/functions/_shared/kw-email.ts` → `renderEmail()` (shared shell, used by every Resend send) | Resend API, from `send-booking-email` Edge Function | `KW_LOGO_URL` constant = `https://keywellness.co.bw/assets/img/kw-logo-horizontal.png` | No — always `<img>`, never `<svg>` (confirmed by grep, zero `<svg` hits in `kw-email.ts` or `send-booking-email/index.ts`) |
| `email-templates/auth/confirm-signup.html`, `magic-link.html`, `reset-password.html`, `invite-user.html`, `change-email.html` | **Not Resend** — these are the Supabase Auth dashboard's manual-paste templates (out of scope to touch per this file's own instructions), sent by Supabase's built-in auth mailer | Same broken URL, hardcoded: `https://keywellness.co.bw/assets/img/kw-logo-horizontal.png` | No — all 5 use `<img>` only |

**`curl -sI` results**: see the domain table above — the logo URL 404s (Content-Type
`text/html`, a WordPress 404 page, not an image) everywhere it's referenced.

**SVG**: not used anywhere in email HTML. Not the bug here — this is purely a wrong
domain, not an SVG-stripping-client problem.

**PNG exists at the right *path*, wrong *domain***: `assets/img/kw-logo-horizontal.png`
is a real file in this repo (`assets/img/kw-logo-horizontal.png`, confirmed via `ls`)
and is live at `https://mogomotsifrance-star.github.io/keywellness-portal/assets/img/kw-logo-horizontal.png`
(200, `image/png`, confirmed above). The only defect is which domain the templates
point at.

**Out of scope, flagged for manual follow-up**: the 5 Supabase Auth dashboard templates
in `email-templates/auth/` have the identical broken-domain bug in their logo `src` and
footer links. This file's own instructions say not to touch the dashboard — but since
the same fix (swap domain) applies, whoever updates the dashboard by hand should apply
the same URL correction there.

---

## 0.2 Signup failure reproduction

**Reproduced live** against the real dev-branch signup form (`index.html`'s `doSignup()`,
[index.html:1269](index.html:1269)) with a throwaway `@mailinator.com` address, both
with and without an invite code.

**The `{}` the user sees is real and exactly reproduced**: `sb.auth.signUp()` returns an
`AuthRetryableFetchError` whose `.message` property is the literal string `"{}"`
(confirmed via `JSON.stringify(error, Object.getOwnPropertyNames(error))` →
`{"message":"{}","name":"AuthRetryableFetchError","status":500}`). `doSignup()`
currently does `authErr(error.message || '...')` — since `error.message` is truthy (a
non-empty string, just one that happens to render as `{}`), the fallback never kicks in
and the user sees a lone `{}` on screen. **No `console.error` call exists in
`doSignup()` today** — the raw error was never logged anywhere, which is why this got
this far undiagnosed.

**Root cause is (a) a genuine Supabase Auth API error — but it is neither the trigger
nor the invite-code path the batch instructions expected.** Bypassing the JS client and
hitting the Auth REST endpoint directly (`POST /auth/v1/signup`) surfaces the real body
supabase-js was swallowing:

```json
{"code":500,"error_code":"unexpected_failure","msg":"Error sending confirmation email","error_id":"019f4511-c9f7-7f9a-9e62-f3b5c766162d"}
```

Confirmed identical on three separate attempts (different throwaway emails, with and
without a valid invite code `ACME-7F3K2` — both fail exactly the same way). **This
rules out the trigger and the invite-code path as the cause**: `handle_new_user()`
([supabase_multitenancy.sql:284-309](supabase_multitenancy.sql:284)) is a plain `AFTER
INSERT` trigger with no `NOT NULL`/RLS surface that could throw here (it already
resolves unknown/missing invite codes to `null` gracefully, per its own comment), and
the identical failure with a *valid* code proves it isn't invite-code resolution
either. The failure point is specifically **"Error sending confirmation email"** — i.e.
Supabase Auth successfully validates the request and (almost certainly, given the
trigger's simplicity) creates the `auth.users` row, then fails at the mail-send step of
its own signup flow, a step this repo's code has no visibility into or control over.

This means:
- **Category (a)** — Supabase Auth API error, not (b) a `handle_new_user` trigger
  failure, not (c) a frontend exception.
- **The Batch 3.2 "root-cause fix" playbook (trigger defensiveness, invite-code
  pre-validation) does not apply** — there is nothing to fix in `handle_new_user()` or
  in a pre-`signUp` invite-code check; both already behave correctly, and neither is
  where this 500 originates.
- **The actual fix is outside this repo's reach**: Supabase project → Authentication →
  Email settings / SMTP provider configuration. This is very likely either (i) a broken
  custom SMTP relay (if one is configured — e.g. pointed at Resend with stale/invalid
  credentials), or (ii) the built-in Supabase mailer hitting its own rate limit. Cannot
  be diagnosed further from this environment (no dashboard access, no Postgres/Auth log
  access). **Flagged as a mandatory manual follow-up** — this is a live, in-production
  signup outage, not a cosmetic error-message bug.
- Every retry against the same throwaway email returns the identical 500 (tested
  twice on the same address) — consistent with the user row already existing
  unconfirmed after the first attempt and Auth re-attempting (and re-failing) the
  confirmation email send each time, rather than the request failing before user
  creation.

**Batch 3.1 (never render a raw object, log the full error) is fully applicable and
necessary regardless of the above** — today's code has zero diagnostic logging for
this path and a fallback string that never triggers because `error.message` is always
truthy.

---

## 0.3 Booking confirmation link audit

**Templates**: `supabase/functions/send-booking-email/index.ts`, three email variants,
all built through the shared `renderEmail()` shell in `kw-email.ts`. `booking_form_v2.html`
is dead code — grepped for references from any other page in the repo, zero hits; it is
not linked from anywhere and does not participate in the live booking flow (the live
flow is `index.html`'s inline `#booking` view → `submitBooking()` →
`sb.functions.invoke('send-booking-email', ...)`, [index.html:3857](index.html:3857)).

| Email variant | `<a>` tags found | Status |
|---|---|---|
| `type: "new"` — client "Booking received" | None (no `button`/`altLink` passed) | N/A — no link to break |
| `type: "new"` — internal "New booking request" (to HR/team) | `button: { label: "Open in admin", url: "https://keywellness.co.bw/admin.html" }` | **Broken** — 404 (see headline finding) |
| `type: "confirmed"` — client "Your booking is confirmed" | None (no `button`/`altLink` passed) | N/A — no link to break |
| Every variant, footer (`renderFooter()` in `kw-email.ts`) | `https://keywellness.co.bw` (site), `mailto:wellness@keywellness.co.bw` (real, works), `https://keywellness.co.bw/privacy` | Site link resolves (200) but lands on the wrong site's homepage, not the portal; `/privacy` 404s. `mailto:` link is unaffected by the domain bug and works correctly |

**No empty `href`, no `#`, no literal unrendered template variables anywhere** — this
codebase's template strings are JS template literals evaluated at send time (not a
separate templating engine with `{{ }}` placeholders), so there's no class of "the
literal string `${link}` appears in the sent HTML" bug possible here. The defect is
entirely the wrong-domain issue above, confined to one button (`Open in admin`) and the
shared footer's two `keywellness.co.bw` links, repeated across every email family.

**Resend click-tracking**: no tracking options are set anywhere in `sendEmail()`'s
payload (`supabase/functions/send-booking-email/index.ts`) — the send body is exactly
`{from, to, reply_to, subject, html}`, nothing else. If links appear rewritten in a
delivered email, it is a **dashboard-level Resend setting**, not code — per this file's
own instructions, flagging as a manual check for the user rather than something Claude
Code can verify (Resend dashboard → domain settings → click tracking).

**Live send test**: not performed in this batch (Batch 0 is discovery-only per this
file's own rule; sending a real test booking through Resend belongs to Batch 4's
verification checklist, after the fix, not before). The two structural defects above
(wrong domain, matching the already-reproduced 404s) are sufficient to explain "links
don't work" without needing a live send to confirm — Batch 4 will do the real send-and-
inspect-raw-HTML pass as part of its own verification.

---

## 0.4 Opt-in flow trace

**UI**: Badges page, "🏆 Rewards Opt-In" card ([index.html:4024-4032](index.html:4024)),
checkbox `#lb-optin` bound to `state.user.leaderboard_opt_in`, "Save" button calls
`saveRewardsOptIn()` ([index.html:3889-3896](index.html:3889)).

**What it writes**: a plain `profiles` table upsert via the existing `saveUser()`
helper ([index.html:867-916](index.html:867)) — not an RPC, not a separate table.
`leaderboard_opt_in` is one column in `saveUser()`'s whitelisted payload
(`u.leaderboard_opt_in ?? false`, [index.html:901](index.html:901)). This write path is
already exercised by every other profile field (name, income, goals, etc.) and has
working RLS (members already successfully update their own `profiles` row elsewhere in
this app) — **no RLS/schema gap here**, unlike the unrelated prior workstream's finding
about `reward_fulfilments` (a different table).

**The actual bug — confirmed, not `insufficient_cohort`-style, a real state bug**:

```js
async function saveRewardsOptIn() {
  const optIn = document.getElementById('lb-optin').checked;
  state.user = { ...state.user, leaderboard_opt_in: optIn };   // ← mutated BEFORE the write
  await saveUser();                                             // ← return value never checked
  showToast(optIn ? "You're sharing your points with HR" : 'Rewards opt-in updated');
  const _cur = location.hash.replace('#','') || 'badges';
  if (VIEWS[_cur]) VIEWS[_cur]();                                // ← always re-renders as if it worked
}
```

1. `state.user.leaderboard_opt_in` is flipped **optimistically, before** `saveUser()`
   runs — this is the "flips a local flag optimistically" case the batch spec expects.
2. `saveUser()` **does** surface its own failure today (`console.error` +
   `showToast('⚠️ Could not save your profile...')`, [index.html:910-913](index.html:910))
   and returns early without updating `state.user` on error — but it doesn't return any
   value the caller can branch on.
3. `saveRewardsOptIn()` never inspects `saveUser()`'s outcome — it unconditionally shows
   its own success toast and unconditionally re-renders the Badges view. On a failed
   save, the user sees **two contradictory toasts** (the real error, immediately
   followed by a fake success message) and the checkbox/card **still renders as
   opted-in** (or opted-out) because `state.user` was mutated in step 1 regardless of
   whether the write actually landed. A hard refresh would reveal the true (unsaved)
   state, but nothing in the UI signals that until then.
4. On a **successful** save, `saveUser()` already does the right thing structurally —
   it sets `state.user = data` using the row PostgREST hands back from the `upsert(...).select().single()`
   call, i.e. the authoritative post-write DB state, not a re-assertion of the optimistic
   guess. So a working refetch-equivalent already exists on the success path; it's the
   failure path (and the premature step-1 mutation) that's broken.

**Render source**: `VIEWS['badges']` reads `state.user.leaderboard_opt_in` directly
([index.html:4028](index.html:4028)) — populated at initial page load by the profile
fetch in `loadAllData()`, then mutated in place by writes like the one above. It is not
a page-load-only stale snapshot (it does update after a save attempt) — the problem is
specifically that it updates optimistically and unconditionally rather than being
gated on the write's actual result.

**Fix shape for Batch 5**: stop mutating `state.user` before the write; make
`saveUser()`'s success/failure observable to its caller (e.g. return `!error`); in
`saveRewardsOptIn()`, only show the success toast / re-render on a confirmed success,
and show a distinct inline error (not a second contradictory toast) on failure. No
opt-out control exists separately from this same checkbox — unchecking and hitting
Save is the opt-out path, same code, same bug, same fix.

---

## 0.5 Appointments table check

1. **Column confirmed**: `bookings.requested_time`, type `text`, format 24-hour
   `HH:MM` (e.g. `"08:00"`) — matches `index.html`'s `BK_TIMES` constant
   ([index.html:3589](index.html:3589)) written on insert
   ([index.html:3816-3817](index.html:3816)). Confirmed already added to the live schema
   by an existing untracked migration file in this repo,
   `supabase_bookings_missing_columns.sql` (adds `requested_time text` — comment in that
   file records the original bug: booking inserts started sending this column before it
   existed, causing `PGRST204`). **Not verified whether that file has actually been run**
   against the live project (no DB credentials in this environment, same constraint as
   every SQL file in this repo) — Batch 6 should confirm before assuming the column is
   populated for new bookings; if unrun, bookings are currently failing to save
   `requested_time` at all (same `PGRST204` class of error the file's own comment
   describes), which is a bigger problem than a missing admin-table column and should be
   flagged back immediately if confirmed.
2. **Admin appointments table query**: `admin.html`'s main data load
   (`sb.from('bookings').select('*')...`, [admin.html:377](admin.html:377)) already
   fetches every column including `requested_time` — the data is available in
   `allBookings` client-side today. **The Table view simply never renders it.** Current
   column list rendered in `renderBookings()`'s table
   ([admin.html:674-684](admin.html:674)): Client, Email, Service, Session Type,
   **Requested Date** ([admin.html:713](admin.html:713), via `fmtDate(b.requested_date||b.created_at)`),
   Status, Attendance, Actions. No time column. (A separate **Calendar** view of the
   same tab, added by a prior workstream, does already render `requested_time` per-day
   — confirmed at [admin.html:848](admin.html:848)/[870](admin.html:870) — so the
   precedent for how to format/display it already exists in this same file.)
3. **Batch 6 is therefore a pure frontend rendering fix** — add a `<th>Requested Time</th>`
   next to `<th>Requested Date</th>` and a matching `<td>${b.requested_time||'—'}</td>`
   in the same row-map — contingent on confirming point 1's migration has actually run.

---

## Disclosure: test signups against the live (shared) Supabase project

Per this batch's own instruction ("attempt a signup with a throwaway email"), four
`sb.auth.signUp()`/raw `POST /auth/v1/signup` calls were made against the real,
shared dev/prod Supabase project during 0.2, using disposable `@mailinator.com`
addresses (`kwtest.batch0.*@mailinator.com`). All four failed server-side with the
500 "Error sending confirmation email" documented above. Depending on where in
Supabase Auth's signup flow that failure occurs, it's possible one or more
unconfirmed `auth.users` rows now exist for these throwaway addresses (the
"identical 500 on retry of the same address" behavior noted above is consistent
with, but doesn't conclusively prove, a user row having already been created).
None of these addresses are real people; flagging for awareness, not alarm — worth
a quick check of Auth → Users for `kwtest.batch0.*` rows and deleting them if
present, at the user's convenience.

## Manual follow-ups for BUILD-NOTES.md (flagging here so they aren't lost)

- **Decide the domain question** (headline finding): is `keywellness.co.bw` meant to
  become this portal's custom domain eventually, or was it always the wrong URL?
  Recommend defaulting Batch 2/4 to the known-working GitHub Pages URL now.
- **Signup is broken in production for every user, right now** — "Error sending
  confirmation email" from Supabase Auth itself (0.2). Needs the Supabase dashboard →
  Authentication → Email/SMTP settings checked directly; not fixable from this repo.
  This is more urgent than the `{}` cosmetic bug it was originally reported as.
- The 5 Supabase Auth dashboard templates in `email-templates/auth/` have the same
  broken-domain logo/link bug as the Resend templates — out of scope to edit here (this
  file's own rule), but whoever pastes the dashboard templates by hand should apply the
  same domain fix.
- Resend click-tracking/tracking-domain dashboard setting — cannot be checked from code
  (0.3); ask the user to confirm it's off or points at a verified domain.
- `booking_form_v2.html` appears fully dead (unreferenced from any page) — candidate
  for deletion in a future cleanup pass, not touched in this batch.
- Confirm whether `supabase_bookings_missing_columns.sql` has actually been run — if
  not, new bookings may currently be failing to save silently on the `requested_time`
  column (0.5).

## Verification checklist (Batch 0)

- [x] BATCH-0-FINDINGS.md complete — all five sections, plus the domain headline finding
- [x] No repo file changed, no SQL executed (read-only `curl`/browser reproduction only)
- [x] Every curl result recorded with status + content-type (domain table above)
