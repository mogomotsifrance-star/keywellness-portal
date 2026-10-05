# Batch 0 findings: HR suppression leak (P0), 5 Oct 2026

Read-only discovery. **Update 5 Oct 2026: GO given.** The stop-gap
(`migrations/stopgap-p0-hr-suppression.sql`) was trialled in a rolled-back
transaction, then **applied**. Rollback: `migrations/rollback-stopgap-p0-hr-suppression.sql`.
Batch 1 (merge small bands + the three rules) has a GO. See BUILD-NOTES for the
flag: no client HR user before Batch 1 is live. Every HR login today is internal
or test, so no client saw the leak. Test Co is a test organisation (`is_test`);
its published report needs no re-issue.

Method: read every live function body (`pg_proc.prosrc`). Called the HR functions as
the Test Co HR login, which is a plain employer, and as the Sedimosa HR login, which is
also an admin. Called the client-safe report helpers directly with
`p_client_safe = true`, which is exactly what an HR caller gets. Read-only transactions
throughout. Only counts are given below, never names.

## In plain language

The leak is wider than the brief's one example, and two parts of it are worse than
subtraction:

1. **The Sedimosa HR page shows one employee's stress score today.** The headline tile
   "Median Financial Stress" is a median over **1 person** (`org_financial_indicators`
   stress block, `reported_count` 1, median 5). The function's floor checks how many
   people *assessed* (13), not how many are in the block.
2. **Workforce Distribution prints counts of 2 outright.** `org_overview` has no
   per-band floor at all: Sedimosa "Struggling · 2 employees", Test Co "Thriving · 2
   employees".
3. **Subtraction (the brief's case) is live on both organisations with HR users:**
   - Sedimosa DTI: hidden band = 10 − 6 − 0 − 3 = **1**
   - Sedimosa retirement: 13 − 0 − 4 − 5 − 3 = **1**
   - Test Co DTI: 10 − 8 − 0 − 0 = **2** (two employees are overindebted)
   - Test Co stress block: 5 − 0 − 3 = **2**
4. **Withholding the total would not close it.** The retirement block's total, 13, is
   the same figure HR already sees as `org_overview`'s "Completed Assessment" and
   `distribution.assessed_count`. Each function also returns its own base: the stress
   card's `cohort_size`, a report's `registered`. So the total is known from elsewhere
   whatever one function hides.
5. **A whole-org HR login can call the report functions directly, though the HR page
   never does.** That means org, every company, every department and the previous
   period, which is enough to difference a small site or department back out.
   Example on live data: Sedimosa Q3 org total 78, Debswana 13, MCM 58, so 7 people sit
   in sites that are each withheld. The org's 5 bookings and 12 assessments, against 0
   bookings and 6 + 4 assessments in the visible companies, put 5 bookings and 2
   assessments among those 7.
6. **The one published report is affected.** Test Co, Q3, published 8 Jul:
   `attended_session` is suppressed, but `total_reach` 1 and `total_attended` 1 sit
   beside it. So exactly one person attended one session.

## Function table

Leak types: **(a)** subtraction within one payload; **(b)** differencing across two
payloads (scope, period, window); **(c)** a rate times its base; **(d)** no floor at
all, the figure is shown as it is.

| Function | HR reaches it by | Type | Example (counts only) | Shown on employer.html? |
|---|---|---|---|---|
| `org_financial_indicators` DTI / retirement / stress | `employer_org()`, own scope | a, d | DTI: 10 − 6 − 0 − 3 = 1 · retirement 13 − 12 = 1 · stress median over 1 person | Yes: Debt Health, Retirement cards, 3 headline medians |
| `org_overview` distribution | same | d, a | Struggling 2 (Sedimosa), Thriving 2 (Test Co), printed as "2 employees" | Yes: Workforce Distribution |
| `org_overview` completeness | same | d | none/some/most have no cell floor; the `<3` test is on the whole cohort | Not displayed; API only |
| `org_overview` distress | same | c | pct × `n_assessed` = count; no floor on the count or its complement (none at 1–2 today) | Yes: emergency-fund tile |
| `org_overview` trend | same | b (weak) | quarter participants vs total assessed | Yes |
| `org_stress_summary` | `employer_org()`, own scope | a, b | `cohort_size` beside 3 bands; window is caller-chosen (`p_window_days`), so 30 vs 31 days differences one log | Yes: stress card |
| `_org_report_period_data` (via `org_report_data`, `publish_org_report`) | `org_report_data` (HR-callable), snapshots | a, b, c | `total_reach` / `total_attended` beside suppressed `attended_session`; `session_intensity` and `client_type_split` sum to `total_reach`; `mode_split` sums to `total_attended`; monthly trend sums to `total_booked`; dimension bands sum to `assessed_count`; age bands sum to `registered` when every age is known; `demographics_cross` row/column totals; `previous_period` always attached | Published snapshots only |
| `org_report_company_breakdown` | whole-org HR | b | company `n_employees` and funnel vs org totals; `unassigned_members` exact | No (API only) |
| `org_report_department_breakdown` / `_dept_metrics` | `hr_unit_in_scope()` | a, b | gender split sums to `n_employees` (dept of 27: 12 + 13 shown, 2 hidden); unit total minus visible departments = withheld departments (MCM: 59 − 50 = 9 across 4 small departments + unassigned) | No (API only) |
| `publish_org_report` | admin publishes, HR reads `org_reports` | inherits `_org_report_period_data` | 1 published report, affected (above) | Yes |
| `admin_org_indicators` | **not HR**: `is_admin() or is_team_lead()` | — | count + base per indicator, but team leads are Key Wellness staff | No |
| `theme_counts` | **not HR**: psychosocial admin / counsellor | — | floor 5, no total | No |
| `_kw_cell`, `_suppress_count`, `_suppress_rate` | helpers | the cause | suppress a cell but know nothing about its siblings or total. `_suppress_rate` floors the numerator only, never its complement | — |

## What employer.html shows (live site, `main`)

Calls: `org_overview`, `org_financial_indicators`, `org_stress_summary`, and published
`org_reports.data_snapshot`. It never calls `org_report_data` or the breakdowns.

Displayed: enrolled count; completed-assessment %; average score; emergency-fund %;
the three medians (DSR, retirement, stress); band bars with each band's count in the
legend; Debt Health's "across N employees"; distribution counts and %; the stress card's
`cohort_size`. For reports, the page shows total reach, the funnel, session intensity,
client type, the mode split, the touchpoint trend and the previous period.

**A median is a disclosure when its base is small:** 1 person (Sedimosa stress) is that
person's figure. Every block needs a base floor of its own, not a floor on the
assessed count.

## Published reports

**1** published report in total (Test Co, Q3 2026, whole-org scope, published 8 Jul
2026). It is affected (type a). Test Co reads as a test organisation (25 members,
named "Test Co"). If it is one, nothing real was disclosed, but that needs confirming.
Sedimosa has 1 report, still a draft.

## Fix options (Batch 1)

| Option | Stops (a) | Stops (b) | Cost to HR |
|---|---|---|---|
| Complementary suppression | Only partly. Hidden cells are known to be 1–2, so two hidden cells with a known sum of 2 or 4 still solve | No | Loses a second band; totals kept |
| Withhold the total | **No.** The total is known from another function (retirement = `org_overview` assessed) | No | "Across N employees" disappears |
| Round every count to 5 | Mostly. Differences become ranges | Partly | Every number is fuzzy; a cohort of 10 reads "10" with bands 5/0/0/5 |
| Merge small bands | **Yes.** No cell is hidden, so there is nothing to subtract | No | Labels vary ("40% and above: 4") |

**Recommendation: merge small bands, plus three rules that handle (b).** No single
option covers (b).

1. **Merge:** collapse any band of 1–2 into its neighbour toward the risk end until every
   shown cell is 0 or 3+. If everything collapses into one cell, withhold the
   distribution: one band holding everyone is a fact about each of them. The total stays
   true and nothing is hidden.
2. **A base floor per block:** median and bands only from 5+ people in that block. This
   stops the one-person median.
3. **No HR-chosen filters:** HR keeps its fixed scope (`hr_scoped_unit_ids`). The stress
   window is fixed. `org_report_data` and the breakdowns become admin-only for HR, and
   HR receives only the published snapshot, which is one scope and one period.
4. **Rates floor both sides:** a rate is withheld when its count *or its complement* is
   1–2.

The trade-off: HR sees "Healthy 6 · 40% and above 4" instead of four bands with a lock
icon. That is arguably more useful, because the lock icon tells them nothing anyway.
The residual risk is a live dashboard watched over time: one person joining moves a
cell by one. That cannot be closed without rounding or noise, and is worth recording as
accepted.

Psychosocial stays floored for everyone. The admin internal view stays unsuppressed.

## Stop-gap that could go live today (written, NOT applied)

`migrations/stopgap-p0-hr-suppression.sql`. **Rule: any block holding a cell of 1–2 is
withheld from employers, using the "not enough data" message the live page already
renders.** It needs no page change, shows no blank or NaN, and leaves admin untouched.

| | Change | What HR sees today |
|---|---|---|
| SG-1 | `org_financial_indicators`: any band of 1–2, or any block of 1–4 → `eligible:false` | Debt Health, Retirement and the 3 medians show "Data appears once 5+ employees have completed assessments (13 of 5)" |
| SG-2 | `org_overview`: distribution or completeness with a cell of 1–2 → suppressed; emergency-fund % whose count or complement is 1–2 → null | Distribution shows "Appears once at least 3 employees…"; the emergency-fund tile is hidden only when it would disclose |
| SG-3 | `org_stress_summary`: window fixed at 90; any band of 1–2 → `insufficient_cohort` | Existing "Not enough check-in data yet" |
| SG-4 | `org_report_data` (5-arg), company and department breakdowns: admin only | Nothing; the page never calls them |

Operational, no code: **publish no org report until Batch 1.**

**Why not the smaller "withhold `reported_count`" stop-gap the brief suggested:**

- It leaves retirement open, because the total is in `org_overview`.
- The live Debt card falls back to "No employees have reported income and debt figures
  yet", which is false.
- Blanking the bands instead makes the action strip say "Debt levels look manageable",
  which is also false when 3 of 10 are overindebted.

Withholding the whole block is the only DB-only version that says nothing untrue.

**Cost:** both live organisations lose their financial cards and the distribution until
Batch 1. The wording "(13 of 5)" is clumsy but makes no claim about anyone's money.

**Rollback:** `migrations/rollback-stopgap-p0-hr-suppression.sql` restores all six bodies
from `kw_fn_backup` tag `p0-hr-suppression-stopgap`.

**Verified before writing:** all eight insertion points occur exactly once in today's
live bodies. The generated `org_stress_summary` text was read back without executing.
Not dry-run: a rolled-back trial is the first step after GO if you want one.

## Also noticed (not part of this brief)

- `org_financial_indicators` reads the stress scale opposite to `org_stress_summary`.
  This is already recorded in BUILD-NOTES as pre-existing. With the HR stress card on
  `org_stress_summary`, only the headline "Median Financial Stress" tile still uses the
  old direction.
- `_suppress_count` and `_suppress_rate` are executable by `anon`. Both are pure, read
  no table, and are not SECURITY DEFINER, so this is fine under CLAUDE.md.
