# Key Wellness — Operating Model Map & Journeys (draft 2)

**TEAM 02 (Business Architect) and TEAM 08 (Service Designer) deliverable · 25 Aug 2026 · draft 2 after Tshenolo's corrections.**

Built only from what Tshenolo has said and what is in the project docs and repo. Every statement not directly stated is tagged **[A#]** — an assumption. Correct any of them in a line; a wrong assumption here becomes a wrong screen later. Where the charter says "never assume the current process is the correct process", the box marked **Challenge** says what TEAM 29 would push on.

## 0. Corrections received 25 Aug (now stated facts, no longer assumptions)

| Was | Now |
|---|---|
| A21 "programme" as the unit | **The work plan.** Each client gets a work plan listing all scheduled activities for a period. Lone produces it as a Word/Excel/PDF per client. The Tuesday meeting reviews work plans. |
| Deliverable types unknown | The EAP retainer covers **talks (virtual or physical), one-on-ones, group counselling, webinars, wellness days, awareness infographics/flyers, and others** — each one either Financial or Psychosocial. |
| A1 France invoices | **Laone, the accountant, invoices from the accounting tool.** Retainers bill monthly but Lone often has to remind Laone. Lone passes the session count to Laone. |
| Billing model | **Fixed monthly retainer.** Session counts feed the invoice narrative/reporting, not the amount. |
| A13 psychosocial bookings | Confirmed: **group sessions and one-on-ones are booked by phone or email**, outside the portal. |
| A15 Tuesday outputs | Confirmed and worse: **decisions are not recorded anywhere; each person has to remember their own actions.** |
| A5 Michelle makes flyers | **Nobody does.** Flyers were designed by a marketing agency whose contract was recently terminated. The system should auto-generate them: branded PDF/PNG from a template plus an email-ready HTML version. |

Three consequences for the design:

1. **The work plan is the spine of the System of Work.** Not "programme", not "bookings": a per-client, per-period plan of activities, each tagged Financial or Psychosocial, each with a state (planned → scheduled → delivered → reported). Tuesday walks the work plans. Utilisation, reports, flyers and invoices all hang off it.
2. **The monthly invoice can be automatic in everything but the sending.** Fixed amount, fixed date, per client: the system creates the invoice line, attaches the month's delivered activities as the narrative, and hands it to Laone as a task with the numbers already there. Lone stops reminding; the system does. Laone stays in the accounting tool.
3. **Flyer generation is a real capability gap, not a nice-to-have.** With the agency gone, "awareness infographics/flyers" is a retainer deliverable with no producer. Template-driven generation (topic → tips → branded PDF/PNG + HTML email) fills a hole in delivery, not just admin.

---

## 1. The organisation as it operates today

### 1.1 People and what they hold in their heads

| Person | Role | What only they know today (the knowledge the system must capture) |
|---|---|---|
| France | MD; also a financial advisor; Team Lead for Financial Advisory in the portal | Retainer terms, renewals, pricing, client relationships at director level. **[A2]** France does not attend the Tuesday meeting because he is client-facing / selling that morning, so Tuesday outputs reach him second-hand. |
| Lone | Programs Coordinator (sales and admin) | Each client's work plan (she authors it), what is scheduled, what is promised; the monthly session count for Laone. **[A3]** Lone chairs or drives the Tuesday review. **[A4]** Lone is the main point of contact for client HR. |
| Michelle | Admin support | Bookings, logistics, follow-ups. **[A5]** Michelle confirms venues/links and handles phone/email bookings. |
| Laone | Accountant | Invoices from the accounting tool (stated). Depends on Lone for the monthly reminder and the session count. |
| Kefilwe, Kealeboga, Katlo | Financial advisors | Their own caseloads, consultation findings, who needs follow-up. Kealeboga authors client reports (BOPEU, LEA, Morula) — stated. **[A6]** Each advisor writes the report for the clients they served. |
| Karabo (senior), Nicola | Counsellors | Their caseloads, session content, risk. **[A7]** Counselling notes today are on paper or personal files, not in any shared system. **[A8]** Karabo informally supervises Nicola. |
| Tshenolo | Product owner for the platform; co-builds with Kealeboga | The portal, its data, the reports' structure. |

### 1.2 Client base

10–30 organisations on retainer (stated). Known: Hollard (both lines **[A9]**), BOPEU (both), LEA (both — financial couple referred to psychosocial, stated), Morula Capital Partners (financial **[A10]**), Debswana (**[A11]** individual financial reviews; line mix unknown). Retainers are fixed and billed monthly (stated); the work plan differs per client; session counts are reported, not billed.

### 1.3 Where the facts live today

| Fact | Lives in | Fragility |
|---|---|---|
| Who is booked where | Portal `bookings` for financial one-on-ones; **phone or email** for psychosocial group and one-on-one sessions (stated) | Psychosocial bookings are invisible to utilisation figures |
| Retainer terms, value, renewal | **[A14]** contract PDFs + France's memory; `org_contracts` exists in spec, not populated | Cannot compute cost per touchpoint; renewal dates are not surfaced |
| What was agreed on Tuesday | Nowhere (stated) — each person remembers their own actions | Actions are lost; nobody can see the whole set |
| Work plan and its activity status | Lone's Word/Excel/PDF per client (stated) | Static document; delivery state lives in heads. Flyers: no producer since the agency contract ended (stated) |
| What happened in a session | Advisors: `advisor_clients.assessment` jsonb + `advisor_notes`. Counsellors: **[A7]** | Psychosocial delivery cannot be reported at all today |
| Which report is due / issued | **[A17]** memory + email sent-items | Under a retainer the report is the visible deliverable; its lateness is invisible |
| Invoices sent / paid | Accounting tool, operated by Laone (stated) | Retainers bill monthly but Lone has to remind Laone; ops cannot see whether a client is overdue |

---

## 2. The operating rhythm

```text
 MON        TUE                    WED–FRI                       MONTHLY / QUARTERLY
 ───        ───                    ───────                       ───────────────────
 prep   ┌─ Work-plan review ─┐    engagements run:              • utilisation reports per client
 [A19]  │  everyone except   │    one-on-ones, group sessions,  • Lone reminds Laone; Laone invoices
        │  France            │    webinars, counselling         • renewal conversations [A20]
        │  every work plan:  │
        │  what's coming,    │    follow-ups, flyers,
        │  who does what     │    report drafting
        └────────┬───────────┘
                 │ outputs: decisions, actions, owners, deadlines  (stated: not recorded; each remembers their own)
                 ▼
        France informed after the fact [A2]
```

**Challenge (TEAM 29):** the Tuesday meeting works because it is the only place the whole picture exists. If the system holds the whole picture continuously, Tuesday should shrink from "reconstruct the state of every work plan" to "decide the exceptions". The design target is a Tuesday that takes half the time because the review pass is already prepared.

---

## 3. The core entities and how they relate (draft, TEAM 13)

```text
ORGANISATION ──< CLIENT RELATIONSHIP (account manager, HR contacts, sites/departments — exist in admin.html)
      │
      └──< RETAINER (value, frequency, included lines, renewal, notice, fair-use expectation)
               │
               └──< WORK PLAN  (stated: per client, per period, all scheduled activities; Lone authors it)
                    │
                    ├──< ACTIVITY  (talk · one-on-one · couple · group counselling · webinar · wellness day ·
                    │       │        awareness flyer/infographic · other) — each Financial or Psychosocial;
                    │       │        state planned → scheduled → delivered → reported
                    │       │   a scheduled activity is a booking with practitioner, mode, date, attendee count
                    │       └──< SESSION RECORD (financial: consultation jsonb + notes;
                    │                             psychosocial: confidential note + theme tags)
                    ├──< CAMPAIGN / FLYER  (pre-webinar, post-webinar, announcement)
                    ├──< REPORT (period, status, author, issued date)
                    └──< INVOICE (period, amount, sent, due, paid)

MEETING (Tuesday review, client meeting) ──< DECISION ──< ACTION (owner, deadline, programme link)

PRACTITIONER (advisor | counsellor) ── AVAILABILITY ── capacity ceiling [A22: ceilings not defined today]
```

**The work plan is the entity the portal lacks.** It has organisations and bookings; it has no plan that the bookings fulfil. Adding it turns "what is booked" into "what was promised, what is scheduled, what is done".

---

## 4. The journeys

Each journey lists the steps, who does it today, where it breaks, and what the future state should be. Steps are the charter's; the contents are draft.

### 4.1 Client journey — Prospect → Client → Retainer → Programme → Service → Engagement → Reporting → Renewal

| Step | Today | Breaks | Future state |
|---|---|---|---|
| Prospect → Client | France/Lone sell **[A23]** | Nothing recorded until the org is created in admin | A client relationship record from proposal stage, with the lines quoted |
| Retainer | Contract signed, PDF filed **[A14]** | Terms not in the system; renewal invisible | `org_contracts` populated at signing; renewal and notice dates drive tasks automatically |
| Work plan | Lone drafts a Word/Excel/PDF per client (stated) | Static; delivery state not tracked | Work plan as a live record: activities, line, dates, practitioner, state |
| Service / Engagement | Webinars scheduled with HR; one-on-ones booked by members or advisors; counselling booked **[A13]** | Counselling and group sessions outside the record | All engagement types are bookings on one table with `service_line` and `session_type` |
| Reporting | Advisor authors utilisation report from portal data + memory **[A6]** | Late or forgotten; psychosocial not reportable | Report status tracked; psychosocial panel generated at base ≥ 5 |
| Renewal | France, from memory **[A20]** | No evidence pack (touchpoints, cost per touchpoint, under/over-service) | Renewal task 60 days before notice, with the account file as the evidence |

### 4.2 Practitioner journey — Availability → Assignment → Appointment → Service → Follow-up → Reporting

| Step | Advisor today | Counsellor today | Future state |
|---|---|---|---|
| Availability | **[A24]** not recorded; members request a time and advisor confirms | **[A25]** arranged by Michelle/Lone by WhatsApp | Practitioner sets availability windows; booking checks them |
| Assignment | Admin assigns or advisor adds client (stated) | **[A26]** Lone/Michelle assigns by who is free | Assignment rule per line; counsellor continuity (same counsellor for a case) enforced |
| Appointment | `bookings`, member can decline/reschedule, advisor confirms attendance (stated) | **[A13]** outside system | Same flow for both lines; counselling subject shown to admin as "Counselling session" only |
| Service | Consultation record in jsonb; notes attributed | **[A7]** private notes | Counselling note: author-only + senior counsellor; theme tags for aggregation |
| Follow-up | Advisor's memory **[A27]** | Counsellor's memory **[A27]** | Follow-up is a task with a deadline, created from the session record |
| Reporting | Advisor writes the client report **[A6]** | None | Report drafted from data; practitioner adds narrative |

**Challenge:** advisors and counsellors should never have to attend Tuesday to find out what they are doing this week. Their home answers it.

### 4.3 Administrative journey — Request → Allocation → Scheduling → Delivery → Tracking → Reporting → Billing

| Step | Today | Future state |
|---|---|---|
| Request | HR contact emails/WhatsApps Lone **[A4]**; member self-books | Requests land in one queue with the programme they belong to |
| Allocation | Lone/Michelle decide by availability **[A26]** | "Who has capacity" view; allocation recorded |
| Scheduling | Calendar + confirmation messages **[A13]** | Booking creates the calendar entry and the confirmation |
| Delivery | Happens; attendance confirmed by advisor (stated) or **[A28]** not recorded for groups | Attendance and attendee counts captured for every engagement type |
| Tracking | Tuesday meeting | Programme view shows planned vs delivered per client continuously |
| Reporting | Advisor writes; Lone sends **[A29]** | Report status: due → drafting → review → issued |
| Billing | Laone invoices from the accounting tool after Lone reminds her and gives the session count (stated) | On the 1st, the system creates the month's invoice line per retainer with the delivered activities attached, as a task for Laone; Lone no longer reminds; status recorded; overdue creates a task |

### 4.4 Internal decision journey — Meeting → Decision → Action → Owner → Deadline → Completion

| Step | Today | Future state |
|---|---|---|
| Meeting | Tuesday, everyone except France; client meetings ad hoc | Meeting record with attendees and the work plans reviewed |
| Decision | Spoken, not recorded (stated) | One line per decision, attached to a work plan activity or client |
| Action / Owner / Deadline | Each person remembers their own (stated) | Created in the meeting, owner and date mandatory |
| Completion | Asked about next Tuesday | Reminders 3 days / 1 day / overdue **[A30]**; next Tuesday opens with last week's actions and their state |

**Challenge:** the honest measure of this journey is "what share of Tuesday actions are done by the next Tuesday". Nobody knows that number today. It should be the first number the system produces.

### 4.5 Webinar journey — Concept → Planning → Content → Flyer → Approval → Distribution → Registration → Event → Follow-up

| Step | Today | Future state |
|---|---|---|
| Concept | Client asks for a topic, or Key Wellness proposes from its deck library (stated: Financial Resilience deck) **[A31]** | Topic library with reusable content and tips |
| Planning | Date agreed with HR by Lone **[A4]** | Webinar record on the programme; presenter allocated |
| Content | Presenter's deck **[A32]** | Linked from the topic |
| Flyer | Nobody since the agency contract ended (stated); previously agency-designed | Generated from the topic's tips on a Key Wellness brand template — PDF/PNG plus HTML email — pre and post variants; approval step before send |
| Approval | **[A33]** France or Lone approves informally | Approval step recorded (who, when) |
| Distribution | Emailed/WhatsApped to HR contact **[A34]** | Sent to HR contact; log of what went where. Open: members directly? |
| Registration | HR circulates; **[A35]** headcount known only on the day | Registration count where available; otherwise attendee count entered after |
| Event | Delivered | Attendance recorded → touchpoints |
| Follow-up | Post-webinar flyer (stated); **[A36]** one-on-one demand follows | Post flyer scheduled automatically; one-on-one bookings attributed to the webinar |

**Stated and important:** one-on-one bookings depend on whether clients book webinars. The webinar is the top of the funnel for individual sessions. That link (webinar → individual bookings) is a management-intelligence question the system should answer per client.

---

## 5. What the Tuesday review needs to see (draft of the System of Work's anchor)

For each active work plan, in one pass:

1. Client · line · retainer period position (month 7 of 12) · account manager
2. Next activities on the plan (date, type, line, practitioner, mode, flyer state) and anything planned but not yet scheduled
3. Last week's actions for this client and their state
4. Anything requiring a decision: unassigned engagement, unconfirmed booking, report due, invoice overdue, renewal window
5. Utilisation so far vs what the retainer implies (under/over-service flag)

Then, outside the per-programme pass: practitioner capacity for the coming two weeks, and the list of new actions created in this meeting.

This is a *review pass*, not a dashboard. The design exploration (TEAM 06/07/12) will explore at least: a ledger/timeline that walks programmes in order; a calendar-first two-week view with programmes as lanes; a split-view workspace (programme list left, detail right, actions bottom). Card grids are excluded by the charter §4.

---

## 6. Processes to eliminate or simplify before digitising (TEAM 29)

| Process | Proposal |
|---|---|
| Reconstructing work-plan status every Tuesday | Eliminate; the system holds it continuously |
| Asking "was the flyer sent?" | Eliminate; flyer state on the webinar record |
| Confirming bookings by WhatsApp | Simplify; booking sends the confirmation |
| Writing utilisation reports from scratch | Simplify; generated skeleton + narrative |
| France re-learning work-plan state after Tuesday | Eliminate; Tuesday outputs are visible to him the same day |
| Lone reminding Laone to invoice | Automate; the month's invoice line and narrative are created on the 1st as Laone's task |
| Chasing invoices from memory | Automate; overdue invoice creates a task |
| Producing flyers by hand (or not at all) | Automate; generated from topic tips on the brand template, with an approval step |

---

## 7. Assumptions index — please correct in one line each

A1 ~~France invoices~~ resolved: Laone · A2 why France misses Tuesday · A3 Lone drives Tuesday · A4 Lone is HR's contact · A5 Michelle handles phone/email bookings and logistics · A6 serving advisor writes the report · A7 counselling notes are private/paper · A8 Karabo informally supervises · A9 Hollard both lines · A10 Morula financial only · A11 Debswana line mix · A12 ~~billing frequency~~ resolved: fixed monthly · A13 ~~resolved~~: phone/email · A14 contracts as PDFs · A15 ~~resolved~~: not captured at all · A16 webinar tracking in WhatsApp/email · A17 report status in memory · A18 ~~resolved~~: accounting tool, Laone · A19 Monday prep · A20 renewals from memory · A21 ~~resolved~~: the work plan · A22 no capacity ceilings · A23 France/Lone sell · A24 advisor availability not recorded · A25 counsellor scheduling by WhatsApp · A26 allocation by who is free · A27 follow-ups from memory · A28 group attendance not recorded · A29 Lone sends reports · A30 reminder cadence · A31 topics from client or deck library · A32 deck per presenter · A33 informal approval · A34 distribution via HR contact · A35 headcount on the day · A36 webinars drive one-on-one demand.

Also open: flyer recipients (HR only or opted-in members); counselling theme list (Karabo/Nicola to confirm); who becomes Clinical Lead (France to decide).
