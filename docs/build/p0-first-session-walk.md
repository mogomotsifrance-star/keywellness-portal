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

**Grandfather rule, against real data:** 29 members have an assessment, and none
of them loses their score — **not on ship day and not later**. The rule has no
expiry (changed 10 Sep 2026; the 90-day limit in the original spec was wrong).
An old assessment is dated, not false, so the score stays and carries its date
on the gauge — "from your assessment on 20 June" — with the budget nudge live
beside it. The oldest latest assessment is 80 days and 13 of the 29 are past 60;
under the old rule they would each have gone scoreless as they crossed 90, in
the middle of the Debswana rollout.

---

## What the walk still has to prove

Ten minutes, one fresh account, on the **test site** (not live).

### Prerequisite — already applied to live (10 Sep 2026)

Two SQL files, in this order. Both are done; this records what was run and how
to check it, not work for you.

| File | What it does | Why the walk needs it |
|---|---|---|
| `supabase_fix_admin_unit_create_toplevel.sql` | Fixes `admin_unit_create()`, which could not create a top-level company at all | The seed below is exactly that call |
| `supabase_seed_test_org_units.sql` | Adds "Test Co Head Office" under Test Co, with departments "Finance" and "Operations" | Gives `TEST-1234` a unit and departments, so step 3 proves the removal |

Confirm before you start (the verification query at the foot of the seed file):

```
unit               | Test Co Head Office | (top level — a leaf) | true
dept               | Finance             | Test Co Head Office  | true
dept               | Operations          | Test Co Head Office  | true
members_on_a_unit  | 0                   | (expect 0 — nothing was reassigned)
```

Verified live on 10 Sep 2026: exactly those four rows. Test Co's 22 existing
members still have `org_unit_id` null — nothing was reassigned.

### Setup
Use a real mailbox you control. Email confirmation is **off** (see
`doSignup()` in `index.html`), so signup hands back a live session immediately.
Record the address — it has to be deleted afterwards.

### The walk

| # | Step | Pass looks like |
|---|---|---|
| 1 | Sign up with company code `TEST-1234` | Straight into "Before you start". **No pop-up at any point** — not name, consent, gender or video |
| 2 | "Before you start" | Three lines; Continue disabled until "I understand" is ticked; the full statement expands inline |
| 3 | "About you" | One screen: first name, age, employment, goals, then last name and gender below a rule with "Prefer not to say" pre-selected. **No company or department question** — even though Test Co now has both (see Prerequisite). **No Pula field** |
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
still show, with **"from your assessment on <date>"** beneath the gauge and the
**budget nudge still live** in the strip above. Dimensions they have no data for
still read "not yet" — the grandfather rule opens the score gate, it does not
invent figures.

### Afterwards
Send me the account email and I will verify the written rows via Supabase MCP —
the `assessments` row shape, `answers._habits_only`, and that **no financial
column was written by the habits check**. Then delete the account through
admin.html → Users → Delete, which routes to `admin_user_delete()`. Do not
delete by hand: `CLAUDE.md` records twenty-one foreign keys and two tables with
no key at all.

### The department removal is now provable under Test Co
Test Co used to have **zero `org_units`**, so the company and department steps
never fired for `TEST-1234` even before P0-1 removed them — the removal Debswana
specifically objected to was unverifiable. The prerequisite seed above fixes
that: Test Co now has one unit carrying two departments, so step 3's "no company
or department question" is a real check against an org that *has* both, not an
org that never asked. **Do not walk this under Sedimosa or Debswana instead** —
a test account would land in that client's member list and their aggregates.
