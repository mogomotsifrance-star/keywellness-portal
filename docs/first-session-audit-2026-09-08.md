# First Session Audit

**Key Wellness portal · member journey · stress test**

What a Debswana employee actually meets in their first ten minutes on the portal,
why it reads as intimidating, and a redesigned first session in which the numbers
come from the tools — entered once, used everywhere.

| | |
|---|---|
| **Date** | 8 September 2026 |
| **Evidence** | repo `keywellness-portal@main` + live walk |
| **Test account** | `ux-walk-20260908@example.com` (Test Co) — delete after |
| **Reviewer stance** | senior UX · financial-planning SME |

> Source: published as an artifact and transcribed to markdown for the repo.
> Line references are to the `main` branch on 8 September 2026.

**Contents**

1. [Verdict](#1-verdict)
2. [First session, observed](#2-the-first-session-as-it-happens-today)
3. [Findings](#3-ten-findings-in-the-order-they-should-be-fixed)
4. [The same question, asked six times](#4-the-same-question-asked-up-to-six-times)
5. [One money profile](#5-one-money-profile-every-tool-reads-from-it-and-writes-back-to-it)
6. [Proposed first session](#6-the-first-session-redesigned)
7. [Nudge sequence](#7-the-nudge-sequence-what-to-ask-why-and-what-it-unlocks)
8. [Trust design](#8-trust-is-designed-at-three-distances-not-one-pop-up)
9. [What HR reporting keeps](#9-what-hr-and-advisor-reporting-keeps-when-the-figures-move-to-the-tools)
10. [Build brief](#10-build-brief-in-four-phases-each-reversible)
11. [Left out on purpose](#11-left-out-on-purpose)

---

## 1. Verdict

### Debswana's reading is correct, and the cause is structural, not cosmetic

> The portal asks for a member's gross salary before it has given them a single
> reason to trust it — behind four stacked pop-ups, with the rest of the portal
> locked until they comply.

A new member signs up, is interrupted by a name pop-up, a 380-word data-protection
statement, a gender pop-up and a welcome video that "unlocks" the assessment, and
then arrives on a screen whose first three mandatory fields are gross salary,
take-home pay and total spending. Everything in the left navigation — budget,
learn, book a session — is greyed behind "One quick step first". The assessment
then asks for 14 Pula figures across eight sections. Every one of those figures is
asked again, later, by at least one tool, and most by three or four.

The good news: the architecture to fix this already exists. The dashboard already
recomputes the wellness score from tool data (`computeLiveWellness`), a shared
profile already carries income and debt figures between tools, and the assessment
already runs in a "figures from tools" mode on re-assessment. The redesign is
mostly about *sequence* and *one source of truth per number*, not new machinery.

| | |
|---:|---|
| **4** | pop-ups stacked on a new member before the first screen is usable |
| **14** | Pula amounts requested by the first assessment; 3 mandatory on screen 1 |
| **7** | tools besides the Budget Planner that ask a member their income (assessment, DTI, retirement, goals, affordability, life insurance, lifestyle inflation) |
| **0** | tools that read the debt register a member builds in the Debt Planner — the richest debt record in the portal goes nowhere |

---

## 2. The first session as it happens today

Walked live on 8 September with a fresh account under the Test Co company code,
then cross-checked against the code so each step is attributable. Desktop
viewport; the modal stacking is worse on a phone because the pop-ups exceed the
screen height.

**01 · Sign up**
Email or phone, password ×2, company invite code (required; "check with your HR
focal point" if wrong).
✅ Fine. Company code is the right way to bind a member to an employer — it is the
department step later that is the problem, not this.

**02 · "What's your name?" pop-up**
Fires 0.7 s after sign-in on top of the onboarding wizard, which is also asking for
the name.
❌ Duplicate ask. Saving the name marks the member as onboarded, so the wizard's age
/ employment / goals steps are never shown — the portal loses the only life-stage
data it would have had.

**03 · Data Protection & Confidentiality pop-up**
0.8 s after sign-in, layered above the name pop-up. ~380 words, eight clauses,
names the database vendor and a US AI processor, a checkbox, no close control.
❌ Maximum legal text at the moment of maximum anxiety. The one clause a worried
employee wants — "your employer never sees your figures" — is not in it; the
closest line says data is visible to "you and authorised Key Wellness advisors",
which the department step then contradicts.

**04 · "A quick detail" gender pop-up**
Appears after consent; the wizard underneath also asks gender.
❌ Third interruption; second duplicate. Copy says it is "for reporting across the
programme" — the member has now been told twice, before seeing anything, that they
are being reported on.

**05 · Welcome video pop-up**
"Watch the video to continue — your assessment unlocks when it finishes." Button
appears when the video ends (or after a 15 s timeout if the player fails).
❌ A gate, not a welcome. On our walk the player did not load and the button
appeared by timeout; a member on a slow connection sees a blank box and a locked
button.

**06 · Onboarding wizard (age, employment, goals, company unit, department)**
Rendered underneath all of the above; for organisations with units it inserts
"Which company?" and "Which department?" as required steps.
❌ Skipped entirely on the path we walked (see 02). When it does run, department is
mandatory and explained as "helps your HR team understand wellness across teams".

**07 · Assessment, section 1 of 8: "Income & Basic Financial Profile"**
Gross monthly salary, net take-home, other income, total monthly expenses. Gross,
net and expenses must be > 0 to proceed.
❌ This is the screen Debswana is describing. It is the first content screen the
member sees, and it cannot be skipped.

**08 · Sections 2 – 8**
Ten more Pula amounts (savings balance, monthly savings, emergency balance,
essential expenses, debt payments, debt balance, pension balance, pension
contribution, total assets, total liabilities) plus 11 behaviour questions and an
insurance checklist; then an estate-planning screen.
❌ Numeric fields are optional here but unlabelled as such; a conscientious member
assumes all are required. The behaviour questions — the part that is actually about
wellness — are buried under the figures.

**09 · Back to the portal without finishing**
Every route renders "One quick step first, {name} — Start my assessment →".
Navigation is drawn but dead.
❌ Hard lock. A member who closes the assessment to think about it cannot read an
article or book a session.

**10 · Dashboard after the assessment**
Score gauge, 11 summary tiles, an "Action Required" strip with up to nine nudges
(budget, emergency fund, stress, net worth, DTI, goals, retirement, insurance,
employment-specific), a tools grid of 12, a calculators grid of 7, quick actions.
❌ Nine simultaneous nudges is no sequence at all. The member has just typed 14
figures and the first nudge asks them to open the Budget Planner and type income
and expenses again.

**11 · Opening the tools**
Budget seeds two income rows from the assessment; DTI prefills income but presents
one anonymous "Monthly Debt Obligations (from assessment)" line; Net Worth, Debt
Planner, Expense Tracker, Goal Planner, Education, Life Insurance and Lifestyle
Inflation prefill nothing. Goal Planner and Retirement open with invented figures
(P15,000 salary, P50,000 savings, P3,000 contribution).
❌ The member's own numbers are replaced with placeholders in two tools, and two
prefill notices claim "pulled from your Budget Planner" when the source is the
assessment.

---

## 3. Ten findings, in the order they should be fixed

Severity is judged on two axes together: how much it damages trust in a first
session, and how many members it touches. Evidence lines cite the file and line in
the repository so the build can verify each one.

### F1 — The onboarding wizard is bypassed by the name pop-up · **high**

Saving the name in the pop-up sets `onboarded = true`, so the wizard's age,
employment, goals, unit and department steps never run for a member who follows the
pop-ups. The dashboard's employment-specific nudges and the Goal Planner's seeded
goals depend on data that is never collected.

*Evidence:* `index.html:3643` (name modal marks onboarded) · `index.html:2078`
(route gate accepts first_name) · walk step 02/06

> **Fix:** one onboarding sequence, not two. Delete the name and gender pop-ups;
> the wizard is the only place identity is asked, and it runs before anything else
> can appear.

### F2 — The first content screen demands salary, and the portal is locked until it is given · **high**

Assessment step 1 requires gross, net and expenses > 0. `renderFirstAssessmentLock`
blocks every member route until an assessment row exists. Together these mean "give
us your salary or you cannot use the thing your employer told you to use".

*Evidence:* `wellness_assessment.html:799–804` (required numerics) ·
`index.html:2087–2096` (lock)

> **Fix:** remove the lock; the dashboard opens immediately in a "first week"
> state. The assessment becomes a behaviour-only check with no Pula fields
> (section 6). Figures arrive from tools, each asked once.

### F3 — Department is mandatory, low-value, and explained in the most alarming possible way · **high**

Department is required at onboarding whenever the employer has units. Its only
consumer is an admin-side report-builder table (members / assessed / booked /
attended per department) that is already suppressed below five members and blanks
any cell under three. Nothing a member sees uses it. Its onboarding hint — "helps
your HR team understand wellness across teams" — is the first thing that tells a
member HR is watching.

*Evidence:* `index.html:2553–2557` (required step) · `admin.html:4085–4118` (only
reader) · `supabase_org_report_data_v5_departments.sql:77–82` (n<5 suppression)

> **Fix:** never ask the member. Department, where an employer needs it, is an
> employer-supplied attribute: the existing "Add members" invite feature already
> captures it from a roster, and HR can upload a mapping later. The member's
> profile shows it read-only with "set by your employer for team-level reporting
> only; ask us to remove it". Agree with Debswana's conclusion; the reason is that
> the perceived risk far outweighs a table one admin looks at.

### F4 — Four pop-ups before the first screen; two ask what the wizard asks · **high**

Name, consent, gender and welcome-video modals fire in sequence on sign-in, each
above the last. The welcome video is a gate ("unlocks when it finishes"), not a
welcome. On a phone, the consent modal alone exceeds the viewport.

*Evidence:* `index.html:7467–7476` (timed modal launches) · `index.html:3543–3613`
(video gate) · walk steps 02–05

> **Fix:** one linear flow of screens, no modals: sign-up → "before you start"
> (section 8) → about you → dashboard. Video becomes an optional card on the
> dashboard.

### F5 — The consent statement answers the lawyer's question, not the member's · **medium**

The statement is accurate and reasonably complete, but it is 380 words of clauses
at the moment the member is most anxious, names infrastructure vendors, and never
says the one sentence that matters: *your employer sees numbers about groups of
five or more, never you*. Worse, "accessible only by you and authorised Key
Wellness advisors" is contradicted three screens later by the department hint.

*Evidence:* `index.html:654–665` · `index.html:2555`

> **Fix:** layered consent (section 8): a three-line plain-language screen at
> sign-up, a "who sees this" line beside every field that leaves the member's
> device, and the full statement one tap away in the profile. Same legal content,
> different order.

### F6 — Income is asked in eight tools, loan balances in six, spending in five · **high**

The overlap matrix in section 4 lists every ask. The assessment and the DTI
calculator ask an identical income triple; the Net Worth tracker, DTI calculator,
Debt Planner, Affordability and Life Insurance calculators all ask for debts in
four incompatible shapes; the Debt Planner — the only tool that captures balance,
rate and minimum payment together — writes to nowhere the others read.

*Evidence:* Inventory tables §4 · `debt_management_planner.html:498–503` (own key
only)

> **Fix:** a single money profile with a debt register and an asset register
> (section 5). Every tool reads from it and writes back to it through one helper;
> no tool has its own copy of income.

### F7 — Prefill exists but is partial, silent in places and mislabelled · **medium**

Only five of sixteen tools load the shared-profile helper. The Budget Planner
overwrites profile income and expenses on every save without asking; Net Worth
never reads what it wrote; Loan and Rent-vs-Buy contain a prefill block that
targets fields that do not exist on those pages; DTI and Retirement tell the member
the figure was "pulled from your Budget Planner" when it came from the assessment.

*Evidence:* `budget_planner.html:517–526` · `loan_calculator.html:678–686` ·
`dti_calculator.html:219` · `retirement_calculator.html:217`

> **Fix:** one helper, every tool, one behaviour: prefill with a visible "from your
> budget, 12 Aug" source line; on change, ask whether to update the shared figure.
> Delete the dead code.

### F8 — Invented placeholder figures pollute the member's picture · **medium**

Goal Planner opens with income P15,000; Retirement with salary P15,000, savings
P50,000, contribution P3,000, age 30, retiring at 65. These values persist into
saved tool data and the dashboard snapshot the moment the member touches any field,
even if they never changed them. A retirement readiness of "62%" on a P15,000
salary the member does not earn is worse than no figure.

*Evidence:* `goal_planner.html:267,471` · `retirement_calculator.html:187–267,737`

> **Fix:** no numeric defaults anywhere. A field is either prefilled from the
> member's own profile (with source shown) or empty. Example figures, if wanted,
> live in a labelled "try an example" action.

### F9 — Nine nudges at once is no sequence; the first repeats the assessment · **medium**

The "Action Required" strip pushes budget, emergency fund, stress, net worth, DTI,
goals, retirement, insurance and an employment nudge simultaneously, ordered by
insertion, not value. The Budget nudge arrives seconds after the member has typed
income and expenses into the assessment.

*Evidence:* `index.html:3084–3135`

> **Fix:** a first-week path (section 7): at most two live nudges, ordered by what
> each unlocks for the others; each shows what it will ask and what it will not ask
> again.

### F10 — A wellness score out of 100 is shown on half-empty data · **low**

Six of eight dimensions are 50–60% numeric. Optional figures left blank score as
zero, so a member who skipped the savings and pension fields is told they are
"Critical" on dimensions they never answered. Under the new flow this gets worse
unless the score itself changes.

*Evidence:* `wellness_assessment.html:871–908`

> **Fix:** the score is only shown once budget, emergency fund and debt register
> exist; before that the dashboard shows "your picture: 2 of 6 pieces" and a
> written starting point from the habits check. Dimensions without data show "not
> yet", never zero.

---

## 4. The same question, asked up to six times

Every datum a member is asked to type, against every tool that asks for it. Read
across a row to see how many times a member types the same number today; read down
the "single source" column to see where it should live.

**Legend** — `●` asks the member · `✖` asks again (duplicate) · `✓` already
prefilled · `○` asked, optional

| Datum | Assess | Budget | DTI | Debt plan | Net worth | Emerg. | Retire | Goals | Afford | Invest | Life ins. | Educ. | Lifestyle | Rent v buy | Single source (proposed) |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|---|
| Take-home (net) income | ● | ✓ | ✓ | | | | | ✖ | ✓ | | | | ✖ | | Budget → `money.income.net` |
| Gross income (before PAYE) | ● | | ✓ | | | | ✓ | | ✓ | | ✖ | | | | Budget (optional line) or derived from net via BURS bands |
| Other income | ○ | ✓ | ✓ | | | | | | ✓ | | ✖ | | | | Budget income rows |
| Total monthly spending | ● | ● | | | | | | | ✓ | | | | ✖ | ✖ | Budget category totals |
| Essential (needs) spending | ○ | ● | | | | ✓ | | | | | | | | | Budget "Needs" group — never asked separately |
| Minimum debt payments (total) | ○ | ● | ✖ | ✖ | | | | | ✓ | | | | | | Σ debt register — budget line becomes read-only |
| Each debt: balance | ○ | | ○ | ● | ✖ | | | | ✖ | | ✖ | | | | Debt register |
| Each debt: rate, min payment | | | ● | ✖ | | | | | | | | | | | Debt register (rate optional) |
| Emergency savings balance | ○ | | | | ✖ | ✓ | | ✖ | | | | | | | Asset register, cash line |
| Monthly savings contributions | ○ | ● | | | | ✖ | ✓ | | | ✓ | | ✖ | ✖ | | Budget savings categories |
| Total savings & investments | ○ | | | | ✖ | | ✓ | | ✖ | ✓ | ✖ | ✖ | | | Asset register |
| Pension / retirement fund balance | ○ | | | | ✖ | | ✖ | | | | ✖ | | | | Asset register, retirement line |
| Total assets / total liabilities | ○ | | | | ● | | | | | | | | | | Derived: Σ assets, Σ debt balances |
| Age | ○ | | | | | | ✓ | | | | ✖ | | | | Profile (about you) |
| Planned retirement age | ○ | | | | | | ✖ | | | | ✖ | | | | Profile — no column exists today |
| Dependants (count, ages) | | | | | | | | | | | ● | ✖ | | | Profile — no column exists today |
| Insurance covers held | ● | | | | | | | | | | ✖ | | | | Cover checklist (own 1-minute tool) |

Two things stand out. The Budget Planner already collects, as a by-product, most of
what the assessment asks for outright: income, spending, the "Needs" total that *is*
essential expenses, minimum debt payments and every savings contribution. And the
one thing no tool derives — a per-debt list with balances and payments — is the
thing five tools each ask for in their own shape.

---

## 5. One money profile; every tool reads from it and writes back to it

This is not a new database so much as a discipline over the existing `profiles`
columns plus two small registers. The registers are what is missing: a debt
register (each debt once, with balance, payment, rate, type) and an asset register
(each asset once, by category). Everything else is a derived number.

### The data flow

**Sources (what the member enters)**

| Source | Holds | New? |
|---|---|---|
| About you | age · employment · goals · retirement age · dependants | existing |
| Budget | income rows · spend by category · savings lines · debt payments | existing |
| **Debt register** | per debt: type · balance · payment · rate (optional) | **new** |
| **Asset register** | cash / emergency · investments · pension · property · vehicle | **new** |
| Habits check | 11 behaviour answers, no Pula | existing |

**Derived, never asked** — surplus/deficit · savings rate · essential spend (Needs)
· Σ debt payments · DTI, front & back · Σ debt balances · net worth · emergency
months · retirement readiness · cover gap · wellness score (once 3 sources exist) ·
completeness "n of 6" · freshness per source

**Consumers** — every tool (DTI becomes a read-only result; Debt planner, Net
worth, Emergency fund, Retirement, Goals, Affordability, Investment, Education,
Life insurance, Lifestyle, Loan, Rent v buy read and write back) · the advisor
view, with member consent, sees figures and both registers · HR indicators,
aggregate only, groups of 5+.

A tool that changes a figure writes it back **only after asking the member**.

### What each tool stops asking

| Tool | Asks today | Asks after |
|---|---|---|
| Assessment → **Habits check** | 14 figures + 11 questions | 11 questions |
| Budget | income + 20 categories | same (it is the source) |
| DTI | 3 income + debts | 0 — a result page |
| Debt planner | per debt ×3 + budget | rate if missing + strategy |
| Net worth | assets + liabilities | assets only |
| Emergency fund | 3 figures | 1 (balance) + target months |
| Retirement | 11 inputs | retirement age + 2 assumptions |
| Goals | income + per goal | per goal only |
| Affordability | income ×3, debts, expenses, deposit | deposit + loan terms |
| Life insurance | ≈25 inputs | ≈8 (method, final expenses, cover held) |

> **The SME rule behind this.** A number should be captured at the moment the
> member has a reason to know it precisely. Nobody knows their "total liabilities"
> off-hand; everybody knows what their car loan costs a month. Ask for the
> concrete, itemised thing once, and let the totals be arithmetic.

---

## 6. The first session, redesigned

Six minutes, no pop-ups, no Pula amounts required, the dashboard open from minute
two. Side by side with what happens today so the change is visible step for step.

### Today

| # | Step | Detail |
|---|---|---|
| 01 | Sign up | email/phone · password · company code |
| 02 | Name pop-up | first, last |
| 03 | Data-protection pop-up | 380 words, checkbox |
| 04 | Gender pop-up | required |
| 05 | Welcome video gate | assessment unlocks at the end |
| 06 | Wizard (often skipped) | name again · gender again · company unit · department · age · employment · goals |
| 07 | Assessment, 8 sections | 14 figures, 3 mandatory on screen 1 · 11 questions · insurance list · estate screen — **portal locked until done** |
| 08 | Dashboard | score · 11 tiles · 9 nudges · 19 tools |

### Proposed

**01 · Sign up** — email/phone · password · company code. Unchanged. Company unit,
if the employer has several, is resolved from the code or set by HR — not asked.

**02 · Before you start** — One screen, three plain lines: what we will ask over
the coming weeks, who can see it (you; your coach if you say so; your employer only
as a group of five or more, never by name), what we never do. One checkbox. Full
statement linked.
✅ Same legal content as today, reordered around the member's question.

**03 · About you** — One screen: first name · age · employment status · what you
want to work on (chips). Gender and last name optional, at the bottom, with a
one-line reason and "prefer not to say" pre-selected.
✅ No department. No company picker. Nothing here is a Pula amount.

**04 · Dashboard, first-week state** — Greeting; "Your picture: 0 of 6" instead of
a score; two nudges, the first being the 3-minute habits check; the welcome video
as a card, not a gate; navigation live — articles, booking and every tool open.
✅ No lock. A member who only ever reads articles is still a member.

**05 · Habits check (3 min, optional but first nudge)** — The 11 behaviour
questions and the six-item cover checklist from today's assessment, nothing else.
Ends with a written starting point ("You save when you can, rather than first —
that is the one habit worth changing") and re-orders the nudges.
✅ This is the "assessment" HR reports count. It has no financial figures in it.

**06 · Nudge 1: Budget (4 min)** — Income and spending, once. On save, the member
sees exactly which other tools this just filled in.

**07 · Nudges 2 – 7 over two to three weeks** — Section 7. Each asks one new thing
and shows what it inherited.

**08 · Score appears** — Once budget, emergency fund and debt register exist.
Dimensions without data read "not yet".

> ⚠️ **Where I disagree with the brief, slightly.** Removing financial figures from
> the first assessment is right. Removing the assessment is not: the behaviour
> questions are the only part that measures *wellness* rather than *wealth*, they
> are what the HR indicators for goals, engagement and habits are built on, and
> they cost three minutes with nothing to look up. Keep them, lead with them, and
> keep them nudged rather than buried in the profile.

---

## 7. The nudge sequence: what to ask, why, and what it unlocks

Rules first. At most two nudges live at a time, plus one "done" line for momentum.
Order is by leverage — how many other tools the answer fills — then by the member's
own habits-check signals. Every nudge states what it will ask and what it will not
ask again. A nudge that has been dismissed twice goes quiet for 30 days.

### N0 · Day 0 — Habits check

> *"Three minutes, no numbers. Eleven questions about how you handle money, so the
> portal can put first things first."*

- **Asks** — 11 behaviour questions · covers held (6 checkboxes) · estate 4 (optional)
- **Why here** — Zero-risk, immediate personalisation, and it is the assessment HR
  counts. Lets the portal re-order N1–N7 by the member's own answers (debt stress →
  N3 earlier; no savings habit → N2 earlier).
- **Unlocks** — Goals, insurance, habit halves of all six scored dimensions;
  `assessments` row; the "completed assessment" funnel step for HR.

### N1 · Day 0–3 — Budget, where the money goes

> *"Your take-home pay and what you spend it on. This is the one place you will
> ever type your income."*

- **Asks** — take-home pay · other income · spend by category (needs, wants,
  savings lines, minimum debt payments as one line for now)
- **Why first** — Least threatening ask that is still numeric; everyone expects a
  budget; gives an answer (surplus or deficit) within four minutes; highest prefill
  leverage of any tool.
- **Unlocks** — Income for DTI, Retirement, Goals, Affordability, Life insurance,
  Lifestyle; total and essential spend for Emergency fund, Affordability; savings
  rate; savings contributions for Retirement, Investment, Education. HR:
  `low_savings_rate`, DTI denominator.

### N2 · Day 2–5 — Emergency fund, one number

> *"How much could you get to within 48 hours? Your essential costs are already
> here from your budget: P{needs}/month."*

- **Asks** — emergency savings balance · target months (3–6, pre-set from
  employment status: 6 for variable income)
- **Why second** — The single highest-impact figure in personal finance, one field,
  and it inherits the denominator from N1 so the member sees the "months of cover"
  result instantly.
- **Unlocks** — Emergency dimension; cash line of the asset register (Net worth);
  Goal planner's emergency goal "saved so far". HR: `no_emergency_buffer`,
  `thin_emergency_months`.

### N3 · Day 3–7, conditional — Debt register, each loan once

> *"List each loan or account once — what you owe and what you pay a month. Your
> debt-to-income and payoff plan come out of this without another form."*

- **Asks** — per debt: type · balance · monthly payment · rate (optional, needed
  only for the payoff plan)
- **Why here** — Shown only if the budget has a debt line > 0 or the habits check
  flagged debt. Replaces three tools' input screens (DTI, Debt planner, Net worth
  liabilities) with one list the member already knows by heart.
- **Unlocks** — DTI (becomes a result page, not a tool); Debt planner payoff order;
  Net worth liabilities; Affordability existing obligations; Life insurance
  debts-to-clear; budget's debt line becomes read-only. HR: `over_indebted`,
  `dti_strained`, `debt_strain`.

### N4 · Week 2 — Net worth, what you own

> *"Your debts are already listed. Add what you own — savings, pension, a car,
> property — and see the one number that measures progress."*

- **Asks** — assets by category (cash line prefilled from N2; pension balance;
  investments; property; vehicle)
- **Why here** — Only after debts exist, so the first net-worth result is honest.
  Asking assets alone halves the form and removes the duplicate liabilities entry
  Debswana noticed.
- **Unlocks** — Net worth; Retirement current savings (pension line); Investment
  lump sum; Education current savings; Life insurance assets. HR:
  `negative_net_worth`.

### N5 · Week 2–3 — Retirement, two questions

> *"When do you want to stop working? Your salary, pension balance and contribution
> are already here."*

- **Asks** — planned retirement age (saved to profile) · confirm pension
  contribution (from budget's retirement line) · optional return/inflation
  assumptions collapsed by default
- **Why here** — The tool that most needs prefilled data — eleven inputs today —
  becomes a two-question confirmation. Age comes from About you, salary from N1,
  balance from N4.
- **Unlocks** — Retirement dimension and readiness; Life insurance
  years-to-retirement; Goals "retire" horizon. HR: `retirement_shortfall`.

### N6 · Fortnightly — Stress check-in

> *"Thirty seconds: how is money feeling this fortnight, and what is driving it?"*

- **Asks** — 1–10 · triggers · optional note (unchanged)
- **Why here** — Not first: a stress question before any relationship exists reads
  as surveillance. After N1–N2 it reads as care. Its triggers ("no emergency fund",
  "debt") can now be cross-checked against real figures for better coaching.
- **Unlocks** — Stress trend; advisor pattern spotting. HR:
  `high_financial_stress`, stress bands.

### N7 · Week 3+ — Goals, cover checklist, then the calculators

> *"You said you want to buy property and clear debt. Put a number and a date on
> each — your income is already here."*

- **Asks** — per goal: target · date · saved so far (emergency goal prefilled from
  N2); dependants once (for Life insurance and Education)
- **Why last** — Goals are motivating only once the member knows their surplus.
  Calculators (affordability, loan, rent-v-buy, investment, education, lifestyle)
  are never nudged; they are offered contextually — Affordability when a "buy
  property" goal exists, Education when dependants are entered.
- **Unlocks** — Goals dimension; `cover_gap`; every calculator opens prefilled with
  a visible source line. Re-check every 90 days is the habits check only — figures
  stay live.

### Nudge logic, as a table the build can implement

| Nudge | Show when | Hide when | Inherits | Writes | Priority |
|---|---|---|---|---|---|
| N0 Habits | no `assessments` row, or last > 90 days | row exists ≤ 90 days | — | `assessments.answers, cat_scores` (habit halves) | first |
| N1 Budget | no budget for current month | budget saved this month | — | `money.income.*, spend.*, savings.*, debt_payments_total` | first |
| N2 Emergency | budget exists, no EF balance | EF balance saved | essential spend (Needs), employment → target months | `assets.cash, ef.target_months` | high |
| N3 Debts | budget debt line > 0 *or* habits debtMgmt ≤ 1; register empty | register has ≥ 1 debt, or member says "I have no debts" | — | `debts[]` → Σ payments, Σ balances, DTI | high |
| N4 Net worth | N2 done and (N3 done or "no debts") | ≥ 1 asset saved | cash from N2, liabilities from N3 | `assets[]` → net worth | medium |
| N5 Retirement | N1 done, no retirement age | retirement age saved | age, gross, pension balance, contribution | `profile.retirement_age`, retirement snapshot | medium |
| N6 Stress | N1 done and (no log, or last > 14 days) | logged ≤ 14 days | — | `stress_logs` | low → fortnightly |
| N7 Goals / cover | N1 done, goals from About you have no targets | all seeded goals have targets | income, EF balance | `goals[], covers[], dependants` | low |

---

## 8. Trust is designed at three distances, not one pop-up

### At sign-up: three lines, one screen

Replace the modal with a screen in the flow. Suggested copy, to be checked against
the current statement by whoever owns it:

> **What we will ask.** Over your first few weeks we will invite you to enter your
> budget, savings and any loans. Every number is optional and you can delete it any
> time.
>
> **Who can see it.** You. A Key Wellness coach, only if you choose to share with
> them. Your employer sees results for groups of five or more people — never your
> name, never your figures.
>
> **What we never do.** We never sell your data, never share it with lenders, and
> never show it to your manager or HR by name.
>
> ☐ I understand. · Read the full Data Protection statement

### Beside every field that leaves the phone

A one-line "who sees this" under the section heading of each tool, in the member's
language, not a legal footer: *"Your budget stays in your account. Your employer
only ever sees averages across 5+ colleagues."* On the debt register: *"Only you
and, if you choose, your coach. Never your employer, never a lender."* This is
where Debswana's "who is using my data" question is actually answered — at the
field, when it is asked.

### In the profile: the full statement and a "what we hold about you" page

The existing statement, unchanged in substance but with vendor names moved to a
technical annex, plus a page listing every figure held, its source tool, its date,
and a delete control per figure. The employer-set attributes (company, unit,
department if HR supplied it) shown read-only with "set by your employer for
team-level reporting; ask us to remove it".

### Fix the contradiction

Today the consent says "accessible only by you and authorised Key Wellness
advisors" and the department hint says HR sees it across teams. Both are half-true.
Say the whole truth once: individual data — member and, with consent, coach; group
data of five or more — employer.

---

## 9. What HR and advisor reporting keeps when the figures move to the tools

The constraint set for this work was member trust first, with the organisation
indicators kept working through prefill. Below, each indicator with its source
today and its source after the change. The short version: nothing is lost; three
indicators become more accurate because they stop depending on a single
self-estimate typed on day one, and the reports gain a completeness measure they
need anyway.

| Indicator (HR / advisor) | Source today | Source after | Effect |
|---|---|---|---|
| Wellness score, distribution, trend | assessment score; overridden by live score when fresher | live score only, shown once ≥ 3 sources exist; habits-only members counted as "engaged, not yet scored" | **kept** — more honest |
| Completed-assessment funnel step | any `assessments` row | habits check row (same table) | **kept** |
| Goals unclear · single-income reliance · living beyond means (habit halves) | assessment cat_scores | habits check cat_scores | **kept** |
| No emergency buffer · thin emergency months | assessment emergency dimension; EF table | EF balance ÷ budget Needs | **kept** — one source instead of two |
| Over-indebted · DTI strained · DTI median and bands | `profiles.monthly_debt / monthly_income` from assessment or budget | Σ debt register payments ÷ budget income | **kept** — itemised, not a guess |
| Negative net worth | profile totals from assessment or Net worth | Σ assets − Σ debt balances | **kept** |
| Low savings rate | profile monthly_savings ÷ income | budget savings lines ÷ income | **kept** |
| Retirement shortfall · retirement median | assessment retirement dimension | retirement tool readiness (age, salary, balance, contribution all inherited) | **kept** — arrives later in the journey |
| Cover gap | assessment insurance checklist | same checklist inside the habits check | **kept** |
| No will | assessment estate screen | optional estate questions at the end of the habits check | **kept** |
| High financial stress | stress logs | unchanged | **kept** |
| Department breakdown (admin only) | `profiles.department_id` from member onboarding | same column, populated by HR roster / invite only | **moved** to employer side |
| Gender split | required at onboarding | optional at About you | **reduced** base — acceptable |
| **New:** data completeness per cohort | — | share of members with 0 / 1–2 / 3+ sources | **added** — needed to read any of the above honestly |

Timing is the real trade-off. Today an indicator can exist on day one because the
member typed a guess; after the change the DTI indicator exists when the member has
built a debt register, typically in week one or two. For a rollout, HR reports for
the first month should lead with engagement and completeness, and with indicator
coverage stated on the page.

---

## 10. Build brief in four phases, each reversible

Written for the product owner rather than the developer: what changes, what stays,
what breaks if it is wrong, how to undo it. Phase 0 can ship before Debswana's
rollout on its own.

### P0 — days, before rollout · Stop the bleeding

- **Changes** — Remove the first-assessment lock. Remove the name and gender
  pop-ups; the wizard is the only onboarding. Drop the department step and the
  company-unit step (unit from invite code). Make assessment step 1's Pula fields
  optional with "skip for now" and move the four figure fields to the end of the
  section under the behaviour question. Welcome video becomes a dashboard card.
  Consent modal keeps its content, but becomes step 2 of the wizard with the
  three-line summary above the full text.
- **Stays** — All tools, all data, all reports. The assessment table and score
  formula are untouched.
- **If wrong** — Members skip the assessment entirely and the HR "completed
  assessment" count falls. Mitigation: it stays the first nudge and earns the
  existing badge.
- **Undo** — Each change is a flag in `index.html` / `wellness_assessment.html`;
  revert the commit. No database change.

### P1 — 1–2 weeks · Habits check and the first-week dashboard

- **Changes** — Assessment page split: habits check (behaviour questions, cover
  checklist, estate) as the default; figure sections removed from it. Dashboard
  first-week state: completeness "n of 6", two-nudge rule, nudge table from section
  7, written starting point. Score shown only at ≥ 3 sources; "not yet" for empty
  dimensions. No numeric defaults in any tool (F8).
- **Stays** — Live-score computation (already recomputes from tools). Existing
  members keep their scores.
- **If wrong** — Existing members with only an old assessment see "not yet" on
  dimensions they had scores for. Mitigation: treat a pre-change assessment as 3
  sources for 90 days.
- **Undo** — Front-end only; revert. Rows written by the habits check are ordinary
  assessment rows.

### P2 — 2–4 weeks · Money profile: debt register, asset register, one prefill helper

- **Changes** — Two new tables (`member_debts`, `member_assets`) plus
  `profiles.retirement_age`, `dependants`. Debt planner and Net worth become the
  register editors; DTI becomes a result page; Budget's debt line and every income
  field elsewhere become read-only inherited values with a source line. One helper
  replaces `kw-profile-sync.js` and the per-tool prefill blocks; dead prefill code
  removed. Write-back always asks.
- **Stays** — Tool pages and their calculations. Existing `tool_data` is migrated
  once: DTI and Debt-planner debts merged into the register (matched by name/type),
  Net-worth items into the asset register.
- **If wrong** — A migration mismatch could duplicate a debt for a member who used
  both DTI and Debt planner. Mitigation: migrate with a "review your debts" nudge
  that shows the merged list before it is used anywhere.
- **Undo** — Tables are additive; the old tool_data rows are kept untouched for 90
  days, so reverting the front-end restores the old behaviour.

### P3 — 1–2 weeks · Reporting reads the registers; department moves to the employer side

- **Changes** — Indicator functions read Σ register payments and balances instead
  of profile totals; completeness added to `org_overview` and the report builder;
  department populated only via invite / HR roster upload, shown read-only in the
  member profile; consent text and field-level "who sees this" lines from section 8.
- **Stays** — Suppression rules (n < 5 cohort, cell < 3), report layouts, advisor
  consent gate.
- **If wrong** — An indicator's base shrinks for a client whose members have not
  built registers yet. Mitigation: reports state coverage; the first-month HR report
  leads with engagement.
- **Undo** — SQL functions are versioned in the repo as today; redeploy the
  previous version.

### Three decisions only you and France can make

| Decision | Recommendation | Why it is yours |
|---|---|---|
| Is the habits check compulsory? | No — first nudge, badge-earning, but skippable | Retainer clients count "assessed" members; a compulsory check inflates the number and reintroduces a gate |
| Gender: optional or dropped? | Optional, "prefer not to say" default | Some HR reports want a gender split; Debswana may or may not |
| Does HR supply departments at all? | Only on request, via roster upload; default is none | It is an admin-only table today; whether any client has asked for it is a commercial question |

---

## 11. Left out on purpose

- **A single-page "quick assessment" with three figures.** Tempting, but any Pula
  field on day one recreates Debswana's objection in miniature. The budget is the
  quick assessment.
- **Removing the score altogether.** Members and advisors use it. Delaying it until
  it is honest is enough.
- **Redesigning the dashboard visually.** The tile grid and emoji navigation are
  their own review; this audit changed sequence and content only, so it can ship
  before rollout.
- **Gamification changes.** Points and badges are unchanged; the habits check keeps
  the "Self-Aware" badge and each register earns "tool first use".
- **Asking for a payslip upload.** It would solve gross/net precisely and is what
  advisors use in one-on-ones, but it is the most sensitive document a member
  holds. Appropriate inside a booked session, not in the first week.
- **Employment-specific onboarding branches.** Self-employed and unemployed members
  get different target months and nudge order from the one employment question; a
  separate flow would be premature.

---

**Method:** full read of `index.html`, `wellness_assessment.html` and all 16 tool
pages plus the indicator SQL (`financial_indicators`, `live_wellness`,
`org_account_phase1`, `org_report_data_v5`); live walk on
portal.keywellness.co.bw with a fresh Test Co account on 8 Sep 2026. Line
references are to the `main` branch on that date.

**Companion:** a client-facing summary for Debswana (Word) covers sections 1, 6, 7
and 8 without the code references.
