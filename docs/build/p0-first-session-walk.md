# P0 first-session walk — the checks a headless suite cannot make

**Audit task 7.** The 394 headless assertions drive the real pages against a
stubbed Supabase. They prove the logic. They do **not** prove the real signup,
the real invite code, the real RLS, or the live schema — so this walk exists.

Cloud sessions cannot run it: the agent proxy refuses outbound to
`tarmpqxsabbehgjaonfz.supabase.co` and to the Worker test site, so the browser
in a cloud container cannot reach Supabase at all. **A human runs the walk; the
schema-side verification is already done and recorded below.**

---

## Already verified against live (9 Sep 2026, via Supabase MCP, read-only)

| Check | Result |
|---|---|
| `organizations` has an active `TEST-1234` | ✅ "Test Co", `is_active = true` |
| All 19 `profiles` columns P0 writes exist and are nullable | ✅ incl. `net_income`, `essential_expenses`, `consent_accepted/date`, `onboarded`, `gender`, `will_status` |
| `assessments` shape matches the P0-3 INSERT | ✅ exactly `id, user_id, score, cat_scores, answers, created_at` |
| `score` is `integer NOT NULL` | ✅ habits scoring rounds, so it fits |
| Member RLS permits the whole P0 write path | ✅ `assessments_own`, `profiles_own`, `tool_data_self`, `ef_own` are all `ALL` |
| Rows already carrying `_habits_only` | 0 — nothing has run the new code yet |

**Grandfather rule, against real data:** 29 members have an assessment; the
latest row for **all 29** is within 90 days, so **no existing member loses their
score on the day this ships**. See the open issue below about what happens next.

---

## What the walk still has to prove

Ten minutes, one fresh account, on the **test site** (not live).

### Setup
Use a real mailbox you control. Email confirmation is **off** (see
`doSignup()` in `index.html`), so signup hands back a live session immediately.
Record the address — it has to be deleted afterwards.

### The walk

| # | Step | Pass looks like |
|---|---|---|
| 1 | Sign up with company code `TEST-1234` | Straight into "Before you start". **No pop-up at any point** — not name, consent, gender or video |
| 2 | "Before you start" | Three lines; Continue disabled until "I understand" is ticked; the full statement expands inline |
| 3 | "About you" | One screen: first name, age, employment, goals, then last name and gender below a rule with "Prefer not to say" pre-selected. **No company or department question. No Pula field** |
| 4 | Finish | Lands on the habits check |
| 5 | Habits check — use "Do this later" | Returns to the dashboard. Nothing lost; reopening resumes the draft |
| 6 | Dashboard | Reads **"Your picture — 0 of 6"**. **No score.** At most two nudges. Left navigation fully live |
| 7 | Open Learn, Tools, Book Session | All render. **No page is locked** |
| 8 | Habits check — complete it | Eleven asks, no numbers. Ends on "Your starting point" with sentences, no score ring, no Savings Rate / DTI / Net Worth strip |
| 9 | Dashboard again | "Your picture — 1 of 6" with the starting-point text. Still no score |
| 10 | Budget planner | Trust line under the heading. Enter income + spending, save |
| 11 | Save prompt | Asks before writing to your profile, with Yes as the default. Escape declines |
| 12 | Emergency fund | Essential costs already prefilled from the budget's Needs total |
| 13 | DTI | Income prefilled, labelled **"from your budget"** (not "from your Budget Planner" as static text). Try "I have no debts" |
| 14 | Dashboard | Picture advances; score appears only once habits + budget + EF + debts are all in |
| 15 | Goal Planner / Retirement | **Neither opens with an invented figure.** Retirement refuses to project until you give it an age and a retirement age |

### The regression check that matters most
Log in as an **existing member with an old full assessment**. Their score must
still show. (Verified structurally above — all 29 are inside the window — but
worth seeing once.)

### Afterwards
Send me the account email and I will verify the written rows via Supabase MCP —
the `assessments` row shape, `answers._habits_only`, and that **no financial
column was written by the habits check**. Then delete the account through
admin.html → Users → Delete, which routes to `admin_user_delete()`. Do not
delete by hand: `CLAUDE.md` records twenty-one foreign keys and two tables with
no key at all.

### One thing this walk cannot prove
**Test Co has no `org_units`**, so the company/department steps never fired for
`TEST-1234` even before P0-1 removed them. To see that removal exercised you
need an org that has units — Sedimosa. Worth one extra pass there if the
department question is the part Debswana specifically objected to.
