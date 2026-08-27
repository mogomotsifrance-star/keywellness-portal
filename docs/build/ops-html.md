# `ops.html` — the Tuesday review and the daily view

**Built 26 Aug 2026 on `dev`. Prompt 3 of the operating-system pack.**
The first screen in the ops design language, and the first automated guard on
`index.html`.

> **189 browser assertions green** — 38 ops, 19 routing, 95 account, 37 picker.
> Nothing applied to Supabase. `ops.html` needs M1, M5 and M5a applied before
> it shows anything.

---

## 1. What was built

| File | Purpose |
|---|---|
| `ops.html` | The staff workspace: Review, Today, Organisations, Reports |
| `css/kw-ops.css` | The ops language. Does **not** load `kw-theme.css` |
| `js/kw-session.js` | Shared client, CDN guard, role probe, interface list, routing rule |
| `index.html` | −71 / +47 lines: the four duplicated things now come from the module |
| `tests/smoke-routing.js` | 19 assertions. The first guard on `index.html` |
| `tests/smoke-ops.js` | 33 assertions across both screens |
| `package.json` | `npm test` runs all four browser suites |

---

## 2. The duplication that made the module worth writing

The prompt asked for the client and role probe to be shared "without
duplicating index.html's code". The survey found more than expected:

| Thing | Copies before |
|---|---|
| Project URL + anon key | **4** — index:985, admin:398, advisor:645, employer:266 |
| CDN-failure guard | **2 of 4** — index and advisor have one; **admin and employer render blank** if jsdelivr fails |
| Role probe | **3 shapes** — index sets `_isAdmin`/`_advisor`/`_employerOrgId`; admin and employer use `_kwRoles`; advisor.html has none |
| `kwGoToInterface` | **3** — one carrying the comment *"matching kwGoToInterface() in index.html / admin.html"*, which is a hand-copy admitting it is one |
| The interface list | **4 expressions** |

`ops.html` would have been the fifth of each.

**The seam is decision versus presentation.** Everything in `kw-session.js` is
testable without a DOM; anything touching `document` — the chooser, the role
switcher — stayed on the page that owns those elements. `resolveRoute()` is the
whole routing rule as a pure function, which is why `smoke-routing.js` can
assert 16 role combinations × 6 stored values without loading a page.

### The index.html diff, line by line

| Was | Now |
|---|---|
| URL, key, CDN guard, `createClient`, `_kwSb` (15 lines) | `const SUPABASE_URL = KW.url; … KW.guard(); const sb = KW.sb();` (4) |
| `kwAvailableInterfaces` (24 lines) | one-line delegation |
| `kwGetInterface` / `kwSetInterface` / `kwGoToInterface` | one-line delegations |
| `kwRouteByRole` body (26 lines) | acts on `KW.resolveRoute()`'s verdict (12) |
| `kwShowInterfaceChooser`, `kwRenderRoleSwitcher` | **untouched** — DOM-coupled |

**The bodies were replaced, not the functions.** `kwGoToInterface` and
`kwAvailableInterfaces` are called from inline `onclick` handlers and the
mobile More sheet in three places; keeping the names means the logic is
single-sourced and no call site was disturbed. `window._isAdmin`,
`_advisor` and `_employerOrgId` are deliberately kept for the same reason.

**What did NOT converge:** index.html keeps its own role *fetch*, because it is
woven into a boot sequence with session-trust and `loadAllData()`. It now
mirrors the result into `KW.roles` so the shared interface list and routing
rule have what they need. `ops.html` calls `KW.detectRoles()` directly. Two
probes remain; the four diverging *interface lists* are gone, which was the
part that mattered. Prompt 11 converges the rest.

### The fork check is broken on Windows

The preamble's check —

```bash
diff <(git show origin/dev:index.html) index.html | grep '^<'
```

— reports **every line of the file** on this machine, because the working tree
is CRLF and `git show` emits LF. It is a 100% false positive, so it cannot
distinguish real drift from none, and anyone following it literally would
either drown or stop believing it.

Use either of these instead:

```bash
git diff origin/dev -- index.html
diff <(git show origin/dev:index.html | tr -d '\r') <(tr -d '\r' < index.html) | grep '^<'
```

Verified before editing (clean) and after (71 removed lines, every one
accounted for in the table above). Recorded in `CLAUDE_CONTEXT.md` §3.1.

---

## 3. Routing

`interfaces()` offers **`ops` → ops.html** where it used to offer
`admin` → admin.html. `admin.html` is reachable only from the "Other
interfaces" menu inside ops.

**The migration shim matters.** Every live session today holds
`kw_interface = 'admin'`; `getInterface()` maps it forward to `'ops'` so the
next load does not land on the page being retired. Assertions 6 and 15.

`smoke-routing.js` covers the rule as a pure function (assertions 1–11,
including all 16 role combinations × 6 stored values) and the wrapper acting on
the verdict (12–19). It does **not** drive index.html's whole login flow:
`kwRouteByRole()` is called from three places, each after `loadAllData()` and
the session-trust gate, and stubbing that would test the login flow rather than
the routing change. The roles are placed, the function is called, navigation is
intercepted and recorded rather than followed.

---

## 4. The two screens

Both are `docs/design-directions.md` §4 as written: 230px roll-call · fluid
centre · 340px panel on white, rows separated by 1px rules, sections as label
+ rule.

**Review** — numbered roll-call with the current position on a 3px green bar
and a yellow square on any client needing a decision; the client at 40px with
one line of facts; *Since last Tuesday*, *Coming up*, *Retainer*, *Last week's
actions*; actions written live on the right; a black **Next: <client> →**.

**Today** — *Needs me* numbered and urgency-ordered, *Waiting on others*
unnumbered, Tuesday's completion rate; the day at 40px over Today / This week /
Next week / undated; the selected item, capacity and month on the right.

**Empty state** — one line and one action, *Start Tuesday's review*, calling
`tuesday_review_open()`. Safe to double-click: `unique nulls not distinct`
makes it idempotent, and `created` tells the page whether it started or
resumed.

### Three things the screenshots caught that the tests did not

1. **The kicker asserted a service line we do not know.** It read
   "1 of 3 · Financial" for every client, hardcoded. There is no org-level
   service line; it now derives from what the client actually has in the
   window, and says "no activity in this window" when there is none. M4's
   `included_lines` replaces it.
2. **The daily view reported "not reviewed yet" on a direct load.** Tuesday's
   completion rate lives on the pack, which only the review screen fetched —
   so arriving from a reminder or a bookmark always said the review had not
   happened. Today now fetches the pack too.
3. A screenshot-stub artefact that looked like a page bug: the daily view makes
   one `ops_timeline` call and the stub was returning windows by call order.
   Worth recording because the *symptom* — every date section empty while the
   count said 4 — is exactly what a real bug would look like.

### Four fixes after the screen review (26 Aug)

| | |
|---|---|
| **1. A yellow flag must name its decision** | It read "Needs a decision" — a flag with no referent. `needs_decision` is exactly *"this client has an open action past its due date"*, so the reason is always derivable: it now reads **"1 action overdue"** and is a button that scrolls to the action and marks it. If a future reason ever arrives that cannot be named, it must not be flagged |
| **2. "33.3% done" → "1 of 3 done"** | A percentage over a denominator of three is false precision: it reads as a measurement when it means one of three. Counts below 20, a percentage at or above. The denominator is M5's — done + open + carried; deliberately dropped work stays out |
| **3. Delivery states only** | A webinar showed **"published"**, which is editorial and tells the room nothing about whether it happened. `ops_timeline` now maps by date: `scheduled` before, `delivered` after. Bookings map to cancelled / attended / did not attend / scheduled / pending, and `bookings.status` no longer leaks through |
| **4. The day opens on the first thing that needs her** | Instead of "Choose something on the left" — a screen asking to be used. A row whose booking has no organisation or practitioner now says **"no organisation"** in ink-2 rather than showing nothing |

Fix 3 went into the SQL, not the page: the state vocabulary is a property of
the data, so every future consumer inherits it. `ops_timeline` is `stable`
because `current_date` is stable within a statement.

**One thing to confirm.** The five delivery states you named are pending,
scheduled, attended, delivered, cancelled. A no-show is none of those — it is
`attended = false`, and the session may well have been delivered. Mapping it
to `cancelled` would tell Lone a session was called off when someone simply
did not turn up, so it currently reads **"did not attend"**, a sixth state.
Say if you would rather it folded into one of the five.

### Two test bugs the fixes exposed

- The smoke fixture's `last_week` omitted the still-open action, so the
  page-derived denominator came to 2 where the SQL's `completion_rate` says 3.
  The real RPC returns *every* action from the previous meeting whatever its
  state.
- The fixture used fixed dates, which drift into the past; the daily view then
  filtered every row out and rendered empty sections — which looks exactly like
  a page bug and is not one. Dates are now relative to today.
- An M5a assertion pinned a literal row count. It re-broke the moment the
  fixture grew; it now asserts the property (same as the admin, and not
  vacuously zero).

### Marked slots

Contract, work plan, capacity and invoices have no source until M4 and M7. The
sections render with their label and rule and **one plain line**:
*"No contract, work plan or capacity recorded yet."* Three apologies in a row
read as a broken screen, so they collapse into one sentence — per the
26 Aug decision. Unrecorded facts say so inline rather than showing a blank:
*"Account manager not recorded"*.

---

## 5. The `design-directions.md` §6 checklist

Answered in one line each, as the checklist asks.

| Question | Answer |
|---|---|
| Remove the wordmark — does it still read as designed, not templated? | Yes. The roll-call, the 40px client name and the rule-separated rows carry it; nothing about the layout is a framework default |
| What is the design idea? | A working document that walks a meeting. Not a dashboard that reports one |
| Is the hierarchy obvious in three seconds? | Yes — one 40px name, one green bar, one yellow flag. Everything else is the same weight |
| What was left out? | Cards, tiles, icons, status colours, charts, and every section M4 will fill. Capacity, retainer position and invoices are named as absent rather than faked |
| Does type alone carry hierarchy? | Yes. 40px / 13px uppercase labels / 14px body. Colour carries no hierarchy at all |
| Does every colour have its one job? | Verified programmatically: green `#397E2B` is the current-position bar and the psychosocial marker; yellow `#F0C90A` is only "needs a decision". Nothing else is coloured, and **nothing is red** |
| Why this layout for this task? | The roll-call is a meeting device — a numbered walk with a Next that advances the room. Tuesday's problem is "we did not record what we decided", and the right-hand panel is where it gets recorded, in view the whole time |
| Is it one system with the other screen? | Same three columns, same rules, same markers. Today swaps the roll-call for a queue and the client for a day |
| Can Lone do the thing without effort? | Start the review in one click; type an action and press Enter; Next. No modal, no menu, nothing behind a click on the meeting screen |
| Would another model produce this from the same prompt? | No — the default for "operations workspace" is a sidebar, KPI tiles and a card grid, which is what charter rev 2 §4 forbids and what the rev-1 mockups were rejected for. The tells: nothing collapses behind a click, there is no status colour scale, and nothing is red on a screen whose job is surfacing what is late |

Verified in the browser: paper `rgb(251,250,247)`, ink `rgb(28,29,31)`,
Public Sans, **max border-radius 2px**, **0 shadows**, **0 gradients**,
**0 sidebars**, **no emoji**.

---

## 6. What is NOT done

- **Mobile for the daily view is owed, not out of scope.** Charter §9 asks for
  deliberate design at each size, and Lone reads her day on a laptop *and* a
  phone. Today stacks below 900px, which is a reflow, not a design. The meeting
  screen is deliberately not for a phone — it is projected for 60–90 minutes —
  and keeps its shape with a sideways scroll.
- **Owner names.** `actions.owner` is a uuid and there is no staff directory to
  resolve it against, so the panel says "you" or "assigned" rather than
  printing a uuid. M4's `org_contacts` and a staff list fix it.
- **Work plans, contracts, retainer position, capacity, invoices** — M4, M7.
- **The psychosocial panel** — M2/M3.
- **Practitioner and France variants** of the daily view — `design-directions`
  §4.2 says they follow the same structure with different defaults; not this
  release.
- **Report publishing** stays in `admin.html`; Reports here is a read-only list.
- **No real-time.** Two people typing actions at once during a meeting will not
  see each other's. It matters the moment a second person types, which is not
  how Tuesday runs today.
- **Ctrl-K searches organisations and open actions only** — a way to reach a
  client mid-meeting, not a command palette.

---

## 7. Deploy

`ops.html` is inert until **M1 → M5 → M5a** are applied. Before then it loads,
gates correctly, and every RPC call fails.

1. Apply M1, M5, M5a in order, each with its own verification (see their build
   records). Flag Test Co: `update organizations set is_test = true …`.
2. Enable `pg_cron` and re-run M5, or no reminder ever fires.
3. Push `dev`; Cloudflare Pages serves the test site.
4. Sign in as Lone. Expect the chooser if she also holds another hat, otherwise
   straight to ops. Confirm the roll-call lists BOPEU and Sedimosa and **not
   Test Co**.
5. Start a real Tuesday review, write an action, and confirm it survives a
   reload.
6. Check France can open ops and read last week's actions.

**Still preconditions:** Lone and Laone need accounts (Michelle was granted
admin on 26 Aug). Without an account Laone cannot own M4's invoice actions or
receive a reminder about one.
