# Key Wellness — Financial Portal
## CLAUDE.md — Read this at the start of every session

---

## What This Project Is

Key Wellness is a financial wellness portal for clients in Botswana. It helps users understand and improve their financial health through assessments, tools, coaching bookings, and progress tracking. The platform is built for a Botswana audience — currency is BWP (Pula), and the tone is warm, professional, and empowering.

**Live site:** https://mogomotsifrance-star.github.io/keywellness-portal
**Test site:** https://keywellness-portal.mogomotsifrance.workers.dev (Cloudflare Pages — replaces Netlify which ran out of credits)
**Contact email:** wellness@keywellness.co.bw

---

## Branch Rules — CRITICAL

- **NEVER commit or push to `main` directly**
- Always work on the `dev` branch
- `dev` → deploys to Cloudflare Pages test site
- `main` → deploys automatically to GitHub Pages (live site)
- Only merge `dev` into `main` when changes are tested and approved

```bash
# Always confirm you are on dev before making changes
git checkout dev
git status
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | Plain HTML, CSS, JavaScript — no framework |
| Auth | Supabase Auth (email + password) |
| Database | Supabase (PostgreSQL) |
| Charts | Chart.js v4.4.0 (CDN) |
| Fonts | Inter + DM Mono (Google Fonts) |
| Bookings | FormSubmit.co → wellness@keywellness.co.bw |
| Live hosting | GitHub Pages (main branch) |
| Test hosting | Netlify (dev branch) |

---

## File Structure

```
keywellness-portal/
├── index.html                    ← Main portal (auth, dashboard, all core views)
├── admin.html                    ← Key Wellness admin (users, bookings, advisors, organisations, roles, org reports)
├── employer.html                 ← HR / employer organisation dashboard
├── advisor.html                  ← Advisor portal (clients, assessments, session diary)
├── wellness_assessment.html      ← 8-dimension financial wellness assessment
├── budget_planner.html           ← Monthly budget builder (50/30/20)
├── expense_tracker.html          ← Daily expense logging
├── goal_planner.html             ← SMART financial goals tracker
├── net_worth_tracker.html        ← Assets vs liabilities tracker
├── debt_management_planner.html  ← Debt management planner
├── dti_calculator.html           ← Debt-to-income calculator
├── retirement_calculator.html    ← Retirement projection tool
├── financial_stress_tracker.html ← Fortnightly stress logging
├── loan_calculator.html          ← Loan repayment calculator
├── investment_calculator.html    ← Investment growth projector
├── affordability_calculator.html ← Purchase affordability checker
├── rent_vs_buy.html              ← Rent vs buy comparison
└── CLAUDE.md                     ← This file
```

---

## Supabase Configuration

```javascript
const SUPABASE_URL = 'https://tarmpqxsabbehgjaonfz.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...'; // anon key — safe for frontend
```

### Supabase Tables (already exist)

| Table | Purpose |
|---|---|
| `profiles` | User profile data (name, age group, income range, goals) |
| `assessments` | Assessment results (score, category scores, answers) |
| `checkins` | Monthly check-in scores and notes |
| `badges` | Earned badge IDs and total points |
| `emergency_fund` | Emergency fund targets and progress |
| `bookings` | Coaching sessions — member-booked and advisor-scheduled |
| `advisors` | Advisor roster (email-keyed, like `employers`) |
| `advisor_clients` | An advisor's caseload; `member_user_id` is nullable |
| `advisor_notes` | Private advisor working notes |

### Important Data Gap
The 13 tool pages (budget, goals, net worth, etc.) currently save data to **localStorage only** — not Supabase. This means data is lost if a user switches devices. Migrating tool data to Supabase is a priority before real client onboarding.

---

## Design System

### Colours
```css
--navy: #1a2744        /* Primary — sidebar, headers */
--navy-light: #243360  /* Hover states */
--gold: #c8973a        /* Accent — CTAs, highlights, brand */
--gold-light: #e8b85a  /* Gold hover */
--cream: #f5f0e8       /* Page background */
--cream-dark: #ede7d9  /* Card backgrounds, inputs */
--white: #ffffff       /* Card surfaces */
--green: #2d8a4e       /* Positive values, success */
--red: #c0392b         /* Negative values, errors */
--orange: #e67e22      /* Warnings, medium risk */
--text: #1a2744        /* Body text */
--muted: #6b7280       /* Secondary text, hints */
--border: #ddd6c8      /* Borders, dividers */
```

### Typography
- **Body:** Inter (400, 500, 600, 700)
- **Numbers/Code:** DM Mono (400, 500) — class `.mono`

### Spacing & Radius
```css
--radius: 12px      /* Cards */
--radius-sm: 8px    /* Buttons, inputs */
--shadow: 0 2px 12px rgba(26,39,68,.10)
--sidebar-w: 240px
```

### Component Patterns
- **Cards:** `.card` — white background, 24px padding, border-radius 12px, shadow
- **Buttons:** `.btn .btn-primary` (gold), `.btn-navy` (navy), `.btn-outline` (bordered)
- **Form fields:** `.field` with label + input, gold focus border
- **Stat boxes:** `.stat-box` with coloured left border
- **Progress bars:** `.progress-bar` + `.progress-fill` (gold fill)
- **Notices:** `.notice-gold`, `.notice-green`, `.notice-red`

---

## Navigation Structure

```javascript
const NAV = [
  { id:'dashboard',   icon:'🏠', label:'Dashboard' },
  { id:'assessment',  icon:'📋', label:'Assessment' },
  { id:'learn',       icon:'📚', label:'Learn' },
  { id:'tools',       icon:'🛠️',  label:'Tools' },
  { id:'emergency',   icon:'🆘', label:'Emergency Fund' },
  { id:'checkin',     icon:'✅', label:'Check-in' },
  { id:'progress',    icon:'📈', label:'Progress' },
  { id:'booking',     icon:'📅', label:'Book Session' },
  { id:'my-bookings', icon:'🗓️', label:'My Bookings' },
  { id:'badges',      icon:'🏆', label:'Badges' },
  { id:'profile',     icon:'👤', label:'My Profile' },
];
```

Navigation is hash-based: `window.location.hash = '#dashboard'`

Views are registered in the `VIEWS` object: `VIEWS['dashboard'] = function() {...}`

---

## Badge & Points System

14 badges defined in `BADGE_DEFS`. Award with `awardBadge('badge_id')`.
Points saved to Supabase `badges` table via `saveBadges()`.

| Badge ID | Trigger |
|---|---|
| `first_login` | Completes onboarding |
| `first_assessment` | Completes first assessment |
| `high_scorer` | Overall score ≥ 75 |
| `ef_started` | Opens Emergency Fund |
| `ef_halfway` | Emergency fund 50% funded |
| `ef_complete` | Emergency fund 100% funded |
| `check_in_1` | First monthly check-in |
| `check_in_3` | 3 check-ins completed |
| `booked_session` | Books a coaching session |

---

## Key Functions Reference

```javascript
go('view-name')           // Navigate to a view
openTool('filename.html') // Open a standalone tool page
awardBadge('badge_id')    // Award a badge + points
showToast('message')      // Show bottom toast notification
scoreBand(score)          // Returns { label, cls, color } for a score
svgGauge(score, color)    // Returns SVG gauge HTML
fmtDate(isoString)        // Format date to "16 Jun 2026"
loadAllData()             // Reload all user data from Supabase
saveUser()                // Save state.user to Supabase profiles
saveBadges()              // Save badges + points to Supabase
loadEF() / saveEF(data)   // Emergency fund Supabase read/write
```

---

## Coding Rules

1. **No frameworks** — plain HTML, CSS, JavaScript only
2. **No external libraries** beyond what is already imported (Supabase, Chart.js)
3. **Mobile first** — sidebar hides on mobile, bottom nav shows instead (breakpoint: 768px)
4. **Follow existing patterns** — new views go in `VIEWS['name'] = function() {...}`
5. **New tool pages** follow the same standalone HTML pattern as existing tools
6. **Currency** always formatted as BWP Pula — use `P` prefix (e.g. P4,500)
7. **Always test on dev branch** before merging to main
8. **Commit messages** should be clear and descriptive

---

## Git Workflow

```bash
# Start a session
git checkout dev
git pull origin dev

# After making changes
git add .
git commit -m "Brief description of what changed"
git push origin dev
# → Netlify test site updates automatically

# When ready to go live
git checkout main
git merge dev
git push origin main
# → GitHub Pages live site updates automatically

# Switch back to dev
git checkout dev
```

---

## Priority Build List (in order)

1. **Migrate tool data to Supabase** — budget, goals, net worth, stress tracker, expense tracker all currently use localStorage only
2. **Admin dashboard** — for Key Wellness team to see all users and their wellness scores
3. **Push notifications / email reminders** — monthly check-in reminders
4. **Video content** — replace placeholder "Coming Soon" videos with real content
5. ~~**Advisor portal**~~ — ✅ built. See `ADVISOR-PORTAL-HANDOVER.md`

---

## Roles & Interfaces

Four interfaces, all sharing one Supabase project and one auth flow:

| Interface | File | Who gets in |
|---|---|---|
| Member portal | `index.html` | anyone with a `profiles` row |
| Advisor portal | `advisor.html` | a row in `advisors` (matched on email or user_id, `is_active`) |
| Admin | `admin.html` | a row in `admins` (matched on email) |
| HR dashboard | `employer.html` | a row in `employers` (email or user_id) |

Roles are **table membership, not a column**. A person can hold several —
`france@keywealth.co.bw` holds member + advisor + admin.

**Do not reintroduce hard redirects in `index.html`.** Routing goes through
`kwRouteByRole()`, which offers a choice to multi-role staff and stores it in
`sessionStorage` under `kw_interface`. Single-role staff still route straight
through, and plain members are never interrupted.

`bookings` is the single source of truth for sessions. Anything that creates a
session — member booking, advisor scheduling — must write there, or it will not
appear on the member's side and will not count in organisation utilisation
reporting.

**Onboarding a client company** starts on the admin **Organisations** tab (create
the org + invite code, then build its companies/sites on the **Companies & Sites**
sub-tab), then **Roles & Access** (grant their HR manager), then share the invite
code with the employer. All of it writes through admin-gated `SECURITY DEFINER`
RPCs — `organizations`, `admins` and `employers` stay SELECT-only under RLS.
Departments inside a site (`unit_departments`) are still set up with SQL.

**`org_units` is exactly two levels — company → site — and that is load-bearing.**
`kwUnitLabel()` reads a leaf's parent as the company and the leaf as the site;
members can only ever pick a leaf; a company with sites reports as a combined
multi-site view and shows no departments; and an active site under a closed
company is invisible in the picker. The `admin_unit_*` RPCs enforce all four.
Do not write to `org_units` directly (its `org_units_admin_all` RLS policy
predates the RPCs and bypasses every one of those guards).

---

## What NOT to Do

- Do not change the Supabase URL or anon key
- Do not add npm packages or build tools — this is a static HTML site
- Do not modify `main` branch directly
- Do not change the colour system without updating all references
- Do not break the existing auth flow in index.html
- Do not reintroduce `window.location.replace()` role redirects in index.html — use `kwRouteByRole()`
- Do not give advisors direct RLS read access to `profiles` / `assessments` / `checkins` — member financial data goes through the consent-gated RPCs only
- Do not create a separate table for advisor sessions — they belong in `bookings`
- Do not use `localStorage` for new features — use Supabase instead
