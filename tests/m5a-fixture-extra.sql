-- ============================================================
-- Key Wellness — M5a fixture, loaded ON TOP of tests/m5-fixture.sql
--
-- m5-fixture.sql brings auth, organizations, admins, advisors, employers,
-- profiles and notifications. M5a additionally reads bookings,
-- program_activities and content_items, so this adds those three.
--
-- They are declared as M1 leaves them — service_line present and defaulted,
-- session_format on bookings, requested_date still TEXT — because M5a is
-- tested against the post-M1 world, which is the only world it ships into.
-- ============================================================

create table bookings (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid references auth.users(id),
  requested_date text,                       -- still text after M1, by design
  session_type   text,
  status         text default 'pending',
  created_at     timestamptz default now(),
  service        text,
  attended       boolean,
  session_mode   text,
  advisor_id     uuid references advisors(id),
  booked_by      text not null default 'member',
  service_line   text not null default 'financial',
  session_format text,
  constraint bookings_service_line_check
    check (service_line in ('financial','psychosocial')),
  constraint bookings_session_format_check
    check (session_format in ('one_on_one','couple','group','talk','webinar','wellness_day')),
  constraint bookings_session_mode_check
    check (session_mode = any (array['physical','virtual']))
);

create table program_activities (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references organizations(id),
  activity_type  text not null,
  title          text not null,
  activity_date  date not null,
  attendee_count integer not null,
  delivery_mode  text,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  service_line   text not null default 'financial',
  constraint program_activities_service_line_check
    check (service_line in ('financial','psychosocial')),
  constraint program_activities_activity_type_check
    check (activity_type = any (array['group_intervention','education_talk','webinar','clinic','other'])),
  constraint program_activities_delivery_mode_check
    check (delivery_mode = any (array['physical','virtual','hybrid']))
);

create table content_items (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  kind         text not null default 'lesson',
  org_id       uuid references organizations(id),
  published    boolean not null default true,
  webinar_date date,
  created_at   timestamptz not null default now(),
  service_line text not null default 'financial',
  constraint content_items_kind_check check (kind = any (array['lesson','webinar'])),
  constraint content_items_service_line_check
    check (service_line in ('financial','psychosocial'))
);

grant select, insert, update, delete
  on bookings, program_activities, content_items to authenticated;


-- ── Seed ────────────────────────────────────────────────────
-- The window under test is 2026-08-24 .. 2026-08-30.
--
--   BOPEU     one booking inside, one outside, one webinar inside
--   Sedimosa  one activity inside, one psychosocial booking inside
--   Test Co   one of everything inside — none of it may ever appear
--   no org    one booking inside, from the member with no profile org
--
-- Plus the two rows that exist to break things: a booking whose
-- requested_date is not a date at all, and one that looks like a date but
-- is not (month 13). Both must be treated as having no date, not rolled
-- over into a plausible one.

insert into bookings (id, user_id, requested_date, service, service_line, session_format,
                      session_mode, attended, advisor_id, created_at)
values
  -- BOPEU: the member profile carries org_id, which is how attribution works
  ('0b000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000e',
   '2026-08-26','Budget Planning Session','financial','one_on_one','physical', true,
   (select id from advisors where email='kefilwe@keywealth.co.bw'), timestamptz '2026-08-01'),
  -- outside the window
  ('0b000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000000e',
   '2026-09-20','Follow-up','financial','one_on_one','virtual', null, null, timestamptz '2026-08-01'),
  -- unparseable date -> falls back to created_at, which is inside the window
  ('0b000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-00000000000e',
   'next Tuesday','Ad-hoc chat','financial','one_on_one', null, null, null, timestamptz '2026-08-25'),
  -- looks like a date, is not: month 13. Must NOT roll over to 2027-02-14.
  ('0b000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-00000000000e',
   '2026-13-45','Typo booking','financial','one_on_one', null, null, null, timestamptz '2026-08-27');

-- Sedimosa needs a member whose profile points at it.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1','sed-member@example.test'),
  ('00000000-0000-0000-0000-0000000000a2','testco-member@example.test'),
  ('00000000-0000-0000-0000-0000000000a3','noorg-member@example.test');

insert into profiles (id, org_id) values
  ('00000000-0000-0000-0000-0000000000a1','0a000000-0000-0000-0000-0000000000d0'),
  ('00000000-0000-0000-0000-0000000000a2','0a000000-0000-0000-0000-0000000000c0'),
  ('00000000-0000-0000-0000-0000000000a3', null);

insert into bookings (id, user_id, requested_date, service, service_line, session_format, created_at)
values
  -- Sedimosa, psychosocial. M3 will have to hide this one from France.
  ('0b000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-0000000000a1',
   '2026-08-27','Counselling session','psychosocial','one_on_one', timestamptz '2026-08-01'),
  -- Test Co: must never surface
  ('0b000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-0000000000a2',
   '2026-08-27','Test Co session','financial','one_on_one', timestamptz '2026-08-01'),
  -- no organisation at all
  ('0b000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-0000000000a3',
   '2026-08-28','Unattributed session','financial','one_on_one', timestamptz '2026-08-01');

insert into program_activities (org_id, activity_type, title, activity_date,
                                attendee_count, delivery_mode, service_line)
values
  ('0a000000-0000-0000-0000-0000000000d0','education_talk','Debt awareness talk',
   date '2026-08-25', 40, 'physical', 'financial'),
  ('0a000000-0000-0000-0000-0000000000c0','education_talk','Test Co talk',
   date '2026-08-25', 10, 'physical', 'financial');

insert into content_items (title, kind, org_id, published, webinar_date, service_line)
values
  ('Managing debt', 'webinar', '0a000000-0000-0000-0000-0000000000b0', true,
   date '2026-08-28', 'financial'),
  ('Test Co webinar', 'webinar', '0a000000-0000-0000-0000-0000000000c0', true,
   date '2026-08-28', 'financial'),
  ('A lesson, not a webinar', 'lesson', null, true, null, 'financial');

-- Either side of today, for the delivery-state mapping. Relative to
-- current_date so the assertion does not rot as the calendar moves.
insert into content_items (title, kind, org_id, published, webinar_date, service_line)
values
  ('Webinar still to come', 'webinar', '0a000000-0000-0000-0000-0000000000b0',
   true, current_date + 5, 'financial'),
  ('Webinar already run',   'webinar', '0a000000-0000-0000-0000-0000000000b0',
   true, current_date - 5, 'financial'),
  -- unpublished, and still to come: publication is editorial, the state
  -- column is about delivery
  ('Webinar not published yet', 'webinar', '0a000000-0000-0000-0000-0000000000b0',
   false, current_date + 6, 'financial');

insert into bookings (id, user_id, requested_date, service, service_line,
                      session_format, created_at)
values ('0b000000-0000-0000-0000-00000000000a',
        '00000000-0000-0000-0000-00000000000e',
        to_char(current_date + 4, 'YYYY-MM-DD'), 'A session still to come',
        'financial', 'one_on_one', now());
