# Design directions and the chosen language — Tuesday review and ops workspace

**25 Aug 2026 · governs all `ops.html` work. Canvas with the boards: https://claude.ai/code/artifact/c7bc44db-dc0a-4f35-bdf6-092a8dfa0f81**

This document supersedes the design section of charter rev 1 (§5: bento grid, sand/oatmeal, sage, teal, terracotta). That section is withdrawn. Charter rev 2 §4 (the design directive) and this document are the only design authorities for the operating system.

---

## 1. The frame

**Purpose.** Let the team walk every client's work plan in one pass on Tuesday, decide what needs deciding, and leave with every action recorded, owned and dated; then let Lone, on any other day, see what needs her, what she is waiting on, and what is coming.

**Audience and context.** Lone, Michelle, five practitioners; one screen projected or shared on a Tuesday morning for 60–90 minutes; France reads it afterwards; glanced at daily on a laptop. Operations, not marketing.

**Hierarchy.** First: what needs a decision. Second: what is coming this fortnight. Third: what was done.

**Density.** High. A list ordered by urgency answers "what do I do next" better than a chart; charts belong to the account file and management views, not here.

---

## 2. The four directions explored (kept for the record, page 2 of the canvas)

| | Composition | Type | Strength | Trade-off |
|---|---|---|---|---|
| **A · The Ledger** | One continuous document; each client a three-column entry (identity · dated activities · last week's actions); rules, not boxes | Newsreader serif for names, Nunito text | Calm, printable, nothing hidden; hardest to mistake for a SaaS dashboard | Long scroll; no sense of the meeting's pace; exceptions found by reading |
| **B · The Fortnight** | Ten-day grid, one lane per work plan, activities as marks; beneath it unscheduled promises, capacity, decisions | Nunito lanes, IBM Plex Sans grid | Clashes and gaps visible at a glance | Undated things fall into footnotes; the retainer is invisible |
| **C · The Round** | Split view: numbered roll-call with progress (left), the client under discussion in full (centre), actions being written live (right), "Next" advances | Public Sans, very large client name, uppercase section labels | Directly fixes "decisions are not recorded"; progress is felt | Weak outside the meeting; the most application-like |
| **D · Exceptions First** | Organised by the decision needed, not by client: seven named questions with counts; on-track clients one quiet line | Archivo condensed heavy, Source Sans | Makes "Tuesday shrinks to the exceptions" real; most distinctive | Asks for trust in the rules before the team has reason to; drops the walk-every-client ritual |

**Decision (Tshenolo, 25 Aug): C for the meeting mode.** Tshenolo noted C lacks the at-a-glance overview outside the meeting; the daily view below answers that in C's own language rather than by reviving the earlier card dashboard, which the charter rules out.

---

## 3. The chosen language

```
Direction:    Operational typography — a working document, not a dashboard
Personality:  calm, exact, unhurried, plain-spoken
Typography:   Public Sans throughout (Google Fonts; fallback Segoe UI, system-ui).
              Client name 40px/800 letter-spaced -0.02em; section labels 13px/700 uppercase
              tracked .08em in ink-2; body 14px/400 line-height 1.45; dates and counts
              tabular-nums. No second family on ops screens.
Layout:       Three columns on desktop: 230px roll-call/queue · fluid centre · 340px side
              panel on white. Rows are separated by 1px rules (#D8D7D3), never boxed.
              Sections are label + rule, not headed boxes.
Colour:       paper #FBFAF7 ground · ink #1C1D1F text · ink-2 #4A4C52 secondary ·
              grey #808185 tertiary/financial marker · rule #D8D7D3 ·
              Key Wellness green #397E2B — ONLY the psychosocial marker and the current
              position (roll-call bar) · Key Wellness yellow #F0C90A — ONLY "needs a
              decision" (roll-call flag, inline .need label, owner underline).
              No other colour. No status colour scale. Nothing is red.
Service line: a 9px square before the activity — filled green = psychosocial, outlined
              grey = financial. Never a coloured pill.
Density:      high; nothing collapses behind a click on the meeting screen
Motion:       none beyond focus/hover; no transitions on "Next"
Avoid:        cards, KPI tiles, rounded containers (>2px), shadows, gradients, pills,
              sidebar shell, icons on headings, emoji, "Welcome back", traffic lights
```

**The charter's §17 question, answered.** What makes this unmistakably Key Wellness: the two brand colours doing exactly one job each on an otherwise ink-and-paper page, the service-line square, and the roll-call — a meeting device, not a navigation device. Would another model produce this from the same prompt: not without the charter; the default is a card grid, which this deliberately is not.

---

## 4. The two screens (what `ops.html` builds first)

### 4.1 Tuesday review — meeting mode (Main board on the canvas)

- **Left — roll-call.** Date and clock; numbered list of work plans in review order; done ones struck through in grey; the current one bold with a 3px green left bar; a yellow 8px square on any plan that has something needing a decision; below the list, "Then: capacity · new actions".
- **Centre — the client under discussion.** Kicker (n of N · lines · plan period and month); client name at 40px; one line of facts (account manager, HR contact, headcount) with any yellow `.need` label inline; sections **Since last Tuesday**, **Coming up on the plan**, **Retainer**; each a label, a rule, and rows of `date · marker · text · state`; a black "Next: <client> →" button.
- **Right — actions being written** on a white panel: actions for this client (title bold, owner · due · carried-from), an input "Type an action for <client>…", then **This meeting so far** listing clients already passed with their action counts.
- **Empty state (no meeting yet today):** the centre shows one line and one action — "Start Tuesday's review" — which creates the meeting and loads last week's open actions per client into the right panel.

### 4.2 Daily view — Lone (DailyLone board)

Same three columns, different contents:

- **Left.** Day and name; **Needs me · n** as a numbered, yellow-flagged list ordered by urgency (the selected one with the green bar); **Waiting on others · n** (Laone, HR contacts, practitioners) unnumbered; **Tuesday's actions · x of y done**.
- **Centre.** "Today and the rest of the week · N work plans"; day name at 40px; sections **Today**, **Thursday**, **Friday**, **Next week**, **On plans, without a date** — rows as above, yellow `.need` in the state column where a decision is missing.
- **Right.** The selected item with its facts and next step and an input; **Capacity · this fortnight** per practitioner as "9 of 10" text lines, no bars; **This month** in two lines (touchpoints delivered, invoices produced of total).

Practitioner and France variants use the same structure with different defaults and are not in this release.

---

## 5. Where visual representation does belong

Not on these two screens. It belongs to: retainer position (delivered vs expected for the period), the practitioner capacity grid, the account file and HR reports (trends, funnel, theme distribution — the financial indicators already specified), France's management view (renewals on a timeline), the work-plan detail (a per-client calendar in direction B's grammar), and flyers. Those get a data-visualisation language written when they are built, under the `dataviz` discipline, in the same ink-paper-green-yellow system.

---

## 6. Review checklist before any ops screen ships

Render it and answer in one line each: remove the wordmark — does it still read as designed, not templated; what is the design idea; is the hierarchy obvious in three seconds; what was left out; does type alone carry hierarchy; does every colour have its one job; why this layout for this task; is it one system with the other screen; can Lone do the thing without effort; would another model produce this screen from the same prompt — if yes, redesign before delivering.
