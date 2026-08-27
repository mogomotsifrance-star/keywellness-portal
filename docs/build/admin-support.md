# Member support — reset links and resends

**Built 26 Aug 2026 on `dev`. Prompt 4 of the operating-system pack.**

> **41 assertions green** — 28 SQL on PostgreSQL 17.6, 13 Deno on the Edge
> Function, plus 7 more in `smoke-ops.js` for the screen.
> **Not applied to Supabase, and the function is not deployed.**

Lone and Michelle can find a member, send them a password-reset link, and
resend a booking confirmation — without a developer doing it through Claude or
directly in the Supabase dashboard.

---

## 1. What was built

| File | Purpose |
|---|---|
| `supabase_support_audit.sql` | `is_ops_admin()`, `support_actions`, and the four RPCs. Idempotent |
| `migrations/rollback-support-audit.sql` | Full reversal, zero leftover objects |
| `supabase/functions/admin-support/index.ts` | The Edge Function |
| `supabase/functions/admin-support/index.test.ts` | 13 Deno tests |
| `tests/support-tests.sql` · `tests/run-support.sh` | 28 assertions, RLS enforced |
| `tests/support-verify-live.sql` | Read-only before/after |
| `ops.html` | The Support destination |
| `package.json` | `npm test` now runs the Deno suite too |
| `CLAUDE.md` | Sweep regex gains `is_ops_admin` |

---

## 2. Where the authorisation lives, and why

**The Edge Function holds the service role, which bypasses every policy in the
database.** If it also decided who may act, the whole authorisation model would
live in a TypeScript file next to a key that can do anything.

So the split is:

- **SQL decides who may, and records what happened.** `is_ops_admin()`,
  `support_lookup()`, `support_can()`, `support_log()`, `support_recent()` —
  all called by the Edge Function **as the signed-in user**, so the gate is
  evaluated against the real caller.
- **Deno does only what a database cannot** — verify a JWT, and call the Auth
  admin API.

This is the pattern `booking_notify_payload()` already uses, and for the reason
its own header gives.

### The three rules, and the one this breaks

`send-booking-email/index.ts` opens with an account of a real vulnerability and
the three rules that fixed it. They hold here, with one deliberate difference:

1. **The caller is authenticated.** `admin.auth.getUser(jwt)`. `verify_jwt` is
   *not* authentication — it proves only that the caller holds a JWT signed
   with the project secret, and **the anon key, published in every page of
   view-source, is exactly that**.
2. **Nothing addressable comes from the body.** ← **this is the rule a support
   tool must break**, because support means acting on someone else's account.
   So it is *replaced*, not dropped: the body carries a **`user_id` that came
   from `support_lookup()`**, and the address is resolved server-side from
   `auth.users`. An admin cannot type an arbitrary address and have Key
   Wellness mail it. That is the difference between a support tool and an open
   relay with a logo. A body carrying `email`, `to` or `recipient` is
   **refused outright**, not ignored — ignoring it would let the caller believe
   it had been honoured.
3. **Everything interpolated is escaped.** Nothing here builds HTML: the reset
   mail is Supabase's own and the resend goes through the existing template
   unchanged.

---

## 3. Decisions

### 3.1 Gated on `is_ops_admin()` from the start

> **CORRECTED 27 Aug 2026 — read this before the section below.**
>
> `is_ops_admin()` **no longer exists.** M4a removed it, and member support is
> now gated on `is_admin()`.
>
> The reasoning below — that France would lose this capability when M3 lands —
> **was wrong, and the correction matters.** It assumed `is_ops_admin()` was
> the confidentiality boundary. It was not. One name was carrying three ideas
> that fail separately:
>
> - **Access** — who may see. France holds admin as MD at his own request;
>   Tshenolo holds it for testing. `is_admin()`. **Neither is to be removed.**
> - **Ownership** — who is assigned work. Configuration, never a role, never
>   sort order.
> - **Confidentiality** — who may not see psychosocial data, whatever role
>   they hold. `is_psychosocial_admin()`: Lone and Michelle.
>
> Member support reveals no psychosocial content — `support_lookup` returns an
> address and a role list, nothing clinical. It is **ordinary admin** and stays
> that way. See `supabase_m4a_ownership_and_roles.sql`.


Defined now as `select is_admin();`. **M3 replaces the body and nothing else
changes** — every caller already asks the right question.

**France holds admin, and when M3 lands he will lose this capability.** That is
the intended consequence: he must not be able to trigger a password reset for a
counselling client. One function changes; no call site is revisited.

### 3.2 No masking

Full addresses in the lookup, the confirm and the audit list. An admin already
sees every member address on the admin users page, so masking here would add
friction without adding a control (decided 26 Aug). **The control that matters
is rule 2** — the body carries a `user_id`, never an address.

### 3.3 Denied and failed attempts are recorded

A support log that only holds successes cannot answer *"who tried"*, which is
the question it exists for. `outcome` is `ok | denied | error`, and the Edge
Function writes a row on every path.

`support_actions` has **one policy: SELECT for an ops admin.** No insert,
update or delete policy exists, and the table grants are revoked from
`anon` and `authenticated`. **Not even the admin whose action produced a row
can amend or remove it** — assertions 8, 9 and 10.

### 3.4 Three rate-limit axes

| Axis | Limit |
|---|---|
| per actor | 30/day, 5/minute |
| **per target** | **3 password resets per person per day** |
| global | 100/day |

Gaborone day boundaries, the same as `ai_chat_usage`. **The per-target axis is
the one that matters:** repeated resets against one person is what an attacker
does, and the actor's own daily cap would never notice it. Assertions 22–24.

### 3.5 A password reset is an account-takeover primitive

It is contained here because the link only ever goes to the address **already
on file**, and nothing in the portal lets an admin change an auth email.

**If an "update member email" feature is ever added, these two together become
a takeover chain.** That is the moment to require a second approver, and this
paragraph is the reason someone will know to.

---

## 4. What the member receives

- **A reset:** Supabase's own recovery mail, plus an in-app notification —
  *"A member of the Key Wellness team sent you a link to set a new password.
  If you did not ask for it, you can ignore this."* Phone-only members have no
  routable address, so the mirror is the only thing they see.
- **A resend:** the existing confirmation mail, unchanged, through the existing
  `send-booking-email` function. **No "an administrator resent this" framing** —
  from the member's side nothing unusual happened.

---

## 5. What the tests prove

### The Edge Function — 13 Deno tests

Four are marked ★ because they ask one question: **did we re-open the hole
`send-booking-email` had?**

- ★ **the anon key alone is refused** — the exact hole, restated
- ★ a valid non-admin JWT is refused **by the database**, and the denial is recorded
- ★ **a body carrying `email`, `to` or `recipient` is refused outright**, and nothing is sent
- ★ **the address is resolved from the `user_id`**, never from the request

Plus: no `Authorization` header is refused; an account with no address is an
error rather than a silent success; the per-target limit refuses *and* records;
successes and lookups are recorded; the resend reads the booking as the caller
so its own gate applies; unknown actions, `GET` and an unlisted CORS origin are
all refused.

### The database — 28 assertions, RLS enforced

The gate is true for an admin and false for an advisor; an ops admin reads the
trail and **an advisor, a member and an HR user read nothing of it**; nobody
deletes, amends or writes a row directly; `support_log` takes the actor from
`auth.uid()` and caps the detail; lookup returns **full** addresses, finds by
email and by name, refuses a two-character search so nobody lists the
membership, and refuses an advisor; the three rate-limit axes; `support_recent`
resolves both addresses and refuses an HR user; and the ungated-SECDEF sweep.

### The screen — 7 assertions in `smoke-ops.js`

The audit log is the left column; a denied attempt appears in it; the lookup
shows the full address; sending is two steps and the confirm names the address;
**the confirmed call sends a `user_id` and no address field**; **no yellow
anywhere**; no uncaught errors.

### One test bug worth recording

An assertion put `support_log()` in a `WHERE` clause. **PostgreSQL evaluates a
volatile function once per row scanned**, so it wrote one audit row per
existing row, tripped the burst limit, and made four later rate-limit
assertions fail for a reason that had nothing to do with them. Capture the
result first, then query.

---

## 6. What is NOT done

- **The function is not deployed** — `supabase functions deploy admin-support`.
- ~~Resend needs a booking id the Support screen does not list.~~ **Done
  26 Aug.** There is no booking picker, deliberately: a booking is selected
  where the user is already looking at it. Clicking a row in the centre column
  of Today or the review opens it in the right panel with **Resend
  confirmation**, as the same two-step inline confirm the Support screen uses,
  calling `admin-support` with that `booking_id`. An activity or a webinar
  offers no resend — neither has a member-facing mail, so the button would be
  dead. Assertions 41–46 in `smoke-ops.js`.
- **No flyer or invoice resend** — M6 and M4. The same shape, added when those
  exist; `support_actions_action_check` will need the new values.
- **No account creation, deletion, email change, role change or
  impersonation.** Deliberately.
- **No second approver** on resets. See §3.5 for when that changes.
- **The daily/burst limits are not surfaced to the user before they hit them.**
  The screen reports the refusal; it does not show a remaining budget.

---

## 7. Deploy

**Order: `supabase_support_audit.sql` first, then the function.** The function
calls RPCs that must already exist.

1. `tests/support-verify-live.sql` — run it, save the output.
2. Apply `supabase_support_audit.sql`.
3. Run the verification again. Expect: **one** policy on `support_actions`
   (SELECT), RLS enabled, `INSERT`/`DELETE` **false** for `authenticated`,
   `is_ops_admin()` true for an admin, and **zero rows** from the V6 sweep.
4. `supabase functions deploy admin-support` — it needs `SUPABASE_URL`,
   `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` in the function
   environment.
5. On the test site, open **Support** as Lone: search a member, select, send a
   reset, and confirm the row appears in the left column **and** the member
   receives the mail.
6. Then check the trail from the SQL editor with V5 — the row must be there
   whether the send succeeded or not.

**Rollback** — `migrations/rollback-support-audit.sql`. Note that it
**deletes the audit trail**: export it first if any real support action has
been taken.

```sql
select * from support_actions order by created_at;
```
