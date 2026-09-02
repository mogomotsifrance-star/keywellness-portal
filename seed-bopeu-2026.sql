-- ============================================================
-- Key Wellness — BOPEU: the real contract, work plan and programme
--
-- Source: "Bopeu workplan revised.docx", uploaded 27 Aug 2026. The nineteen
-- rows below are that document verbatim — not a specification, not
-- reconstructed. Read it beside this file if anything looks wrong.
--
-- SAFE TO RUN TWICE. Fixed ids, everything guarded.
--
-- ══ TWO THINGS THE DOCUMENT NEEDS AND THE SCHEMA CANNOT SAY ══
--
-- (1) THE PROGRAMME HAS THREE PILLARS — RESOLVED BY M6.
--
--     This file originally recorded the health screening and both wellness
--     challenges on the financial line as a placeholder, because service_line
--     admitted only 'financial' and 'psychosocial'. M6 added PHYSICAL as a
--     third, non-confidential line, so those three rows now sit where they
--     belong. The reasoning is kept below because it explains why they were
--     not simply filed as psychosocial.
--
--     WHAT REMAINS A PLACEHOLDER: the three "All Pillars" rows — the launch,
--     the baseline survey and the close-out. They are programme milestones
--     rather than sessions on any one line, and there is no line that means
--     "all of them". They stay on financial, still marked, still not a lie
--     anyone can act on: none is a member session.
--
--     THE ORIGINAL REASONING, KEPT:
--
--     service_line admits 'financial' and 'psychosocial'. BOPEU's programme
--     also has PHYSICAL and MEDICAL/PHYSICAL rows: the health screening and
--     the two wellness challenges. There is no service line for them.
--
--     Neither available value is true:
--       'psychosocial' hides them from France and from HR reporting, because
--                      M3 treats that line as confidential. A health screening
--                      is not confidential clinical content, and it would
--                      disappear INVISIBLY.
--       'financial'    puts them in HR's financial session totals, which is
--                      wrong but VISIBLE and correctable.
--
--     They are recorded as 'financial' and marked in `notes`, on the same
--     reasoning as the ownership rule: a visible wrong is fixed in ten
--     seconds, an invisible one surfaces months later. All three are state
--     'planned', so nothing counts them as delivered yet and the decision can
--     be taken before any of them is.
--
--     RESOLVED: M6 added the physical line, so those three rows now sit on it.
--     Adding a third service line is not a seed's business — it touches M3's
--     confidentiality boundary and every policy and definer function built on
--     the two-way split.
--
-- (2) FOUR ROWS ARE "PSYCHOSOCIAL & FINANCIAL". A ROW HAS ONE LINE.
--
--     Recorded as 'psychosocial', because all four titles LEAD with the
--     psychosocial content and carry the financial part as a clause.
--
--     DELIBERATELY NOT SPLIT INTO TWO ROWS. org_report_data counts
--     program_activities as touchpoints, so splitting one delivered session
--     into two rows would double-count it — one real session becoming two in
--     every figure BOPEU is ever shown. The pillar as given is preserved in
--     `notes` instead.
--
-- ══ WHAT IS DELIBERATELY LEFT EMPTY ════════════════════════
--
--   account_manager   NULL. "Lone, presumably" is not a confirmation, and the
--                     standing rule is that ownership is never guessed:
--                     configured, or absent-and-flagged.
--   practitioner_id / practitioner_kind
--                     NULL everywhere except the health screening, which is
--                     'vendor'. The document does not say who delivered any
--                     session. Guessing advisor-vs-counsellor from the pillar
--                     would put names against work nobody recorded.
--   attendee_count    0 everywhere. NOT NULL forces a number; the document
--                     records none. 0 means "not recorded", and it keeps every
--                     attendance figure honestly empty rather than invented.
--   document_url      NULL. The .docx is not in this repository and I do not
--                     know where it lives.
--
-- ══ STATUS IS TAKEN FROM THE DOCUMENT, NOT FROM THE CALENDAR ══
--
--   9 rows are marked Completed  -> state 'delivered'
--   10 rows are marked Planned   -> state 'planned'
--
--   TWO OF THE PLANNED ROWS ARE IN THE PAST (12 Aug, 26 Aug). They are NOT
--   flipped to delivered. The document says Planned, and "the date has passed"
--   is an inference, not a record. Lone confirms those, not the calendar.
-- ============================================================


-- ── 1. The contract ─────────────────────────────────────────
-- P18,000/month, APPROXIMATE. M4b exists so this can be said out loud rather
-- than written as 18000.00 and read forever after as exact.

insert into org_contracts (
  id, org_id, contract_kind, retainer_amount,
  amount_is_approximate, amount_note,
  billing_frequency, included_lines, currency,
  start_date, status, account_manager)
select '0d000000-0000-0000-0000-00000000b0e1',
       o.id, 'retainer', 18000,
       true,
       'APPROXIMATE. Given by Tshenolo as "approximately P18,000/month"; not '
       || 'taken from a signed fee schedule. Confirm against the executed '
       || 'contract before any handover is billed from it. This is NOT the '
       || 'P49,210/month figure in the fee-quote example — that document is a '
       || 'different, unnamed client and none of its line items belong here.',
       'monthly',
       array['financial','psychosocial'],
       'BWP',
       date '2026-05-20',   -- programme launch; inferred, no contract date on file
       'active',
       null                 -- account_manager: unconfirmed, deliberately null
  from organizations o where o.name = 'BOPEU'
on conflict (id) do nothing;


-- ── 2. The work plan ────────────────────────────────────────

insert into work_plans (
  id, org_id, contract_id, title, period_start, period_end, status, document_url)
select '0e000000-0000-0000-0000-00000000b0e1',
       o.id, '0d000000-0000-0000-0000-00000000b0e1',
       'BOPEU Wellness Programme 2026',
       date '2026-05-20', date '2026-11-18',
       'active',
       null   -- "Bopeu workplan revised.docx" — location unknown
  from organizations o where o.name = 'BOPEU'
on conflict (id) do nothing;


-- ── 3. The nineteen activities ──────────────────────────────

do $$
declare
  v_org  uuid;
  v_plan uuid := '0e000000-0000-0000-0000-00000000b0e1';
  -- created_by is NOT NULL on live and nullable in the fixture, so the local
  -- run could not catch this. It is an audit field — who entered the row — and
  -- these were entered on Tshenolo's instruction from the document he
  -- supplied, so that account is the honest value.
  v_by   uuid := (select id from auth.users where email = 'tnmokgwetsi@gmail.com');
  r      record;
begin
  select id into v_org from organizations where name = 'BOPEU';
  if v_org is null then raise exception 'BOPEU does not exist'; end if;
  if v_by is null then
    raise exception 'BOPEU seed: no account to record as created_by. '
                    'program_activities.created_by is NOT NULL.';
  end if;

  for r in
    select * from (values
    -- id_suffix, activity_date, planned_month, activity_type, format,
    -- service_line, state, practitioner_kind, title, notes
    ('01', date '2026-05-20', null::date, 'other', 'webinar', 'financial',
     'delivered', null,
     'Introduction to the BOPEU Wellness Programme, Objectives & Support Resources',
     'Pillar as given: All Pillars. A programme milestone, not a member '
     || 'session. service_line=financial is a [PLACEHOLDER-LINE] — see the '
     || 'three-pillar gap in this file''s header.'),

    ('02', date '2026-05-27', null, 'other', 'campaign', 'financial',
     'delivered', null,
     'Release of Baseline Wellness & Needs Assessment Survey',
     'Pillar as given: All Pillars. Self-Directed — recorded as campaign, '
     || 'like the two challenges: there is no delivery moment. '
     || 'service_line=financial is a [PLACEHOLDER-LINE].'),

    ('03', date '2026-06-03', null, 'education_talk', 'talk', 'psychosocial',
     'delivered', null,
     'Understanding Mental Health at Work & Available Support Systems', null),

    ('04', date '2026-06-17', null, 'group_intervention', 'group', 'psychosocial',
     'delivered', null,
     'Psychosocial Adjustment to Work Demands, Emotional Well-Being, Coping '
     || 'Skills and Financial Wellbeing by Career Stage',
     'Pillar as given: Psychosocial & Financial. Recorded as psychosocial — '
     || 'the title leads with it. NOT split into two rows: org_report_data '
     || 'counts activities as touchpoints, so a split would double-count one '
     || 'real session.'),

    ('05', date '2026-06-24', null, 'education_talk', 'talk', 'financial',
     'delivered', null,
     'Managing Personal Finances in a High Cost of Living Environment', null),

    ('06', date '2026-07-08', null, 'education_talk', 'talk', 'psychosocial',
     'delivered', null,
     'Managing Workload Stress, Burnout & Fatigue (Mid-Year Pressure Management)',
     null),

    ('07', date '2026-07-15', null, 'group_intervention', 'group', 'psychosocial',
     'delivered', null,
     'Emotional Resilience, Coping with Workplace Demands & Financial '
     || 'Behaviour Change',
     'Pillar as given: Psychosocial & Financial. Recorded as psychosocial; '
     || 'not split — see row 04.'),

    ('08', date '2026-07-22', null, 'education_talk', 'talk', 'financial',
     'delivered', null,
     'Practical Budgeting, Debt Management & Financial Decision Making', null),

    ('09', date '2026-07-29', null, 'group_intervention', 'group', 'psychosocial',
     'delivered', null,
     'Resilience, Coping Skills & Work-Life Integration',
     'Pillar as given: Psychosocial & Financial, though the topic is entirely '
     || 'psychosocial. Recorded as psychosocial; not split — see row 04.'),

    ('10', date '2026-08-12', null, 'education_talk', 'talk', 'financial',
     'planned', null,
     'Building Financial Resilience: Savings, Emergency Funds & Income Protection',
     'Document status: Planned, though the date has passed. NOT flipped to '
     || 'delivered — that is Lone''s confirmation to give, not an inference '
     || 'from the calendar.'),

    ('11', date '2026-08-26', null, 'clinic', 'wellness_day', 'physical',
     'planned', 'vendor',
     'Basic Health Screening (BP, BMI, Blood Glucose, Health Risk Review)',
     'Pillar as given: Medical / Physical. Recorded on the PHYSICAL line, '
     || 'added by M6 — non-confidential, so France can see it, which is right: '
     || 'a health screening is not clinical confidence. '
     || 'Delivered by an external provider — practitioner_kind=vendor, so it '
     || 'is not counted as Key Wellness practitioner time. '
     || 'Document status Planned though the date has passed; NOT flipped.'),

    ('12', date '2026-09-01', date '2026-09-01', 'other', 'campaign', 'physical',
     'planned', null,
     'Healthy Living Challenge: Walking, Physical Activity & Healthy Eating Habits',
     'Runs 01–30 Sep 2026. activity_date is NOT NULL so it holds the range '
     || 'start; planned_month carries the month. Pillar as given: Physical — '
     || 'Recorded on the PHYSICAL line, added by M6. '
     || 'Self-directed: no practitioner, and whether a vendor coordinates it '
     || 'is not recorded in the document.'),

    ('13', date '2026-09-16', null, 'education_talk', 'talk', 'psychosocial',
     'planned', null,
     'Workplace Victimization, Bullying, Harassment & Psychological Safety in '
     || 'the Workplace', null),

    ('14', date '2026-10-01', date '2026-10-01', 'other', 'campaign', 'physical',
     'planned', null,
     'Wellness Habits Challenge (Movement, Sleep & Hydration)',
     'Runs 01–31 Oct 2026. Same treatment as row 12: range start in '
     || 'activity_date, month in planned_month, Recorded on the PHYSICAL '
     || 'line, added by M6.'),

    ('15', date '2026-10-07', null, 'group_intervention', 'group', 'psychosocial',
     'planned', null,
     'Pinktober Women''s Wellness Forum: Breast Health, Emotional Well-Being, '
     || 'Work-Life Balance & Women''s Health',
     'Pillar as given: Psychosocial / Physical. Recorded as psychosocial — it '
     || 'is a facilitated group session with emotional content, unlike the '
     || 'self-directed physical challenges.'),

    ('16', date '2026-10-21', null, 'education_talk', 'talk', 'financial',
     'planned', null,
     'Understanding Credit, Loans, Garnishments & Financial Obligations', null),

    ('17', date '2026-11-04', null, 'group_intervention', 'group', 'psychosocial',
     'planned', null,
     'Suicide Prevention, Psychological Distress, Early Intervention & '
     || 'Financial Stress Awareness',
     'Pillar as given: Psychosocial & Financial. Recorded as psychosocial; '
     || 'not split — see row 04.'),

    ('18', date '2026-11-10', null, 'education_talk', 'talk', 'psychosocial',
     'planned', null,
     'Men''s Mental Health, Emotional Expression & Help-Seeking (Movember Focus)',
     null),

    ('19', date '2026-11-18', null, 'other', 'webinar', 'financial',
     'planned', null,
     'Programme Review, Employee Feedback & Sustainability of Wellness Practices',
     'Pillar as given: All Pillars. Close-out milestone, not a member session. '
     || 'service_line=financial is a [PLACEHOLDER-LINE].')
    ) as t(id_suffix, activity_date, planned_month, activity_type, format,
           service_line, state, practitioner_kind, title, notes)
  loop
    insert into program_activities (
      id, org_id, work_plan_id, activity_type, title, activity_date,
      planned_date, planned_month, attendee_count, service_line, format,
      state, delivered_at, practitioner_kind, notes, created_by)
    values (
      ('0f0b0000-0000-0000-0000-0000000000' || r.id_suffix)::uuid,
      v_org, v_plan, r.activity_type, r.title, r.activity_date,
      case when r.planned_month is null then r.activity_date end,
      r.planned_month,
      0,                                   -- not recorded in the document
      r.service_line, r.format, r.state,
      case when r.state = 'delivered' then r.activity_date::timestamptz end,
      r.practitioner_kind, r.notes, v_by)
    on conflict (id) do nothing;
  end loop;
end $$;


-- ── 4. What was actually recorded ───────────────────────────

do $$
declare n_all int; n_del int; n_plan int; n_psy int; n_placeholder int;
        n_decision int; n_physical int;
begin
  select count(*) into n_all from program_activities
   where work_plan_id = '0e000000-0000-0000-0000-00000000b0e1';
  select count(*) into n_del from program_activities
   where work_plan_id = '0e000000-0000-0000-0000-00000000b0e1' and state = 'delivered';
  select count(*) into n_plan from program_activities
   where work_plan_id = '0e000000-0000-0000-0000-00000000b0e1' and state = 'planned';
  select count(*) into n_psy from program_activities
   where work_plan_id = '0e000000-0000-0000-0000-00000000b0e1' and service_line = 'psychosocial';
  select count(*) into n_placeholder from program_activities
   where work_plan_id = '0e000000-0000-0000-0000-00000000b0e1'
     and notes like '%[PLACEHOLDER-LINE]%';
  select count(*) into n_decision from program_activities
   where work_plan_id = '0e000000-0000-0000-0000-00000000b0e1'
     and notes like '%[NEEDS-DECISION]%';

  if n_all <> 19 then
    raise exception 'BOPEU seed: expected 19 activities, found %', n_all;
  end if;
  if n_del <> 9 then
    raise exception 'BOPEU seed: the document marks 9 rows Completed, found % delivered', n_del;
  end if;
  if n_plan <> 10 then
    raise exception 'BOPEU seed: expected 10 planned, found %', n_plan;
  end if;

  -- An under-counting check is worse than none: the first version used a
  -- case-sensitive LIKE and reported 3 of 6, silently omitting the three
  -- PHYSICAL rows, which are the ones that actually need a decision.
  -- Three "All Pillars" milestones remain on a placeholder line. The three
  -- PHYSICAL rows no longer do: M6 gave them a real line.
  if n_placeholder <> 3 then
    raise exception 'BOPEU seed: expected 3 rows on a placeholder service line '
                    '(the All Pillars milestones), found %', n_placeholder;
  end if;
  if n_decision <> 0 then
    raise exception 'BOPEU seed: % row(s) still marked as needing a service-line '
                    'decision. M6 settled that.', n_decision;
  end if;

  select count(*) into n_physical from program_activities
   where work_plan_id = '0e000000-0000-0000-0000-00000000b0e1' and service_line = 'physical';
  if n_physical <> 3 then
    raise exception 'BOPEU seed: expected 3 activities on the PHYSICAL line, found %',
                    n_physical;
  end if;

  raise notice 'BOPEU: % activities (% delivered, % planned), % psychosocial.',
               n_all, n_del, n_plan, n_psy;
  raise notice 'BOPEU: % on the physical line; % All Pillars milestones remain '
               'on a placeholder line (no line means "all of them").',
               n_physical, n_placeholder;
end $$;
