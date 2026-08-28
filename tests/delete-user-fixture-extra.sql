-- ============================================================
-- Key Wellness — delete-user fixture (local PostgreSQL 17 only)
--
-- Loaded ON TOP of tests/m5-fixture.sql, tests/m5a-fixture-extra.sql and
-- supabase_support_audit.sql, by tests/run-delete-user.sh. NOT a migration.
-- Never run this against Supabase.
--
-- Tables and FK delete rules are transcribed from the live database as read on
-- 28 Aug 2026. THE DELETE RULES ARE THE POINT OF THIS FIXTURE: the whole
-- feature is about which references cascade, which null themselves, and which
-- block. A fixture that said `on delete cascade` where live says NO ACTION
-- would test nothing and pass while doing it.
--
--   cascade   assessments, badges, checkins, tool_usage_events, profiles,
--             employers.user_id, hr_unit_scope.hr_user_id
--   set null  advisor_clients.member_user_id, advisors.user_id
--   NO ACTION everything else — each one fails the delete until the plan deals
--             with it, and that failure is what is under test
--   no key    tool_data, ai_chat_usage, org_headcount_reports.reported_by —
--             these do not block anything, they orphan quietly, which is worse
--
-- ── The cast ────────────────────────────────────────────────
-- m5-fixture seeds Lone + Michelle (admins), Kefilwe + Katlo (advisors),
-- Laone (accountant), one member, one HR user. This adds three:
--
--   Naledi  naledi@keywellness.test  ...011  holds EVERY role and authored one
--                                            of everything. The staff delete.
--   orphan  orphan@example.test      ...012  signed up, never onboarded, so no
--                                            profiles row and invisible to the
--                                            users table. Found by address.
--   Zex     zex@example.test         ...013  a second member, never deleted,
--                                            so the assertions can show the
--                                            delete hit one account and not
--                                            the table.
--
-- Lone (...009) is the admin who does the deleting throughout.
-- ============================================================


-- ── Keys m5-fixture leaves off, which this feature turns on ──
-- m5-fixture declares these columns as bare uuids. The delete rule is the
-- whole subject here, so they are given the rules live actually has.

alter table employers add constraint employers_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete cascade;

alter table advisors  add constraint advisors_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

alter table advisors  add column created_by uuid references auth.users(id);

alter table program_activities add constraint program_activities_created_by_fkey
  foreign key (created_by) references auth.users(id);

-- m5a-fixture's bookings carries neither column this feature depends on: the
-- member link is what makes a booking member data, and the confirmer is an
-- audit trail that has to survive the member being deleted.
alter table bookings add column attendance_confirmed_by uuid references auth.users(id);
alter table bookings add column user_name  text;
alter table bookings add column user_email text;


-- ── Member data that cascades ───────────────────────────────

create table assessments (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  score      integer not null,
  cat_scores jsonb,
  created_at timestamptz not null default now()
);

create table badges (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  earned_badge_ids jsonb default '[]'::jsonb,
  points           integer default 0
);

create table checkins (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  score      integer,
  created_at timestamptz not null default now()
);

create table tool_usage_events (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  tool       text,
  created_at timestamptz not null default now()
);


-- ── Member data with NO foreign key at all ──────────────────

create table tool_data (
  user_id    uuid not null,
  tool       text not null,
  data       jsonb,
  updated_at timestamptz default now(),
  primary key (user_id, tool)
);

create table ai_chat_usage (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null,
  used_at      timestamptz not null default now(),
  input_tokens integer
);


-- ── Member data behind a NO ACTION key ──────────────────────

create table reward_fulfilments (
  id           bigint generated always as identity primary key,
  org_id       uuid not null references organizations(id),
  user_id      uuid not null references auth.users(id),
  season       text not null,
  category     text not null,
  note         text,
  fulfilled_by uuid not null references auth.users(id),
  created_at   timestamptz not null default now()
);


-- ── Caseloads: records that outlive the account ─────────────

create table advisor_clients (
  id             uuid primary key default gen_random_uuid(),
  advisor_id     uuid not null references advisors(id) on delete cascade,
  member_user_id uuid references auth.users(id) on delete set null,
  email          text,
  first_name     text not null,
  assessment     jsonb not null default '{}'::jsonb,
  source         text not null default 'advisor_added',
  status         text not null default 'active',
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now()
);

create table counsellors (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references auth.users(id),
  email      text not null,
  full_name  text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table counsellor_clients (
  id             uuid primary key default gen_random_uuid(),
  counsellor_id  uuid not null references counsellors(id),
  member_user_id uuid references auth.users(id),
  email          text,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);


-- ── Role grants ─────────────────────────────────────────────

create table psychosocial_admins (
  email      text primary key,
  user_id    uuid references auth.users(id),
  full_name  text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table hr_unit_scope (
  id         uuid primary key default gen_random_uuid(),
  hr_user_id uuid references auth.users(id) on delete cascade,
  hr_email   text,
  org_id     uuid not null references organizations(id),
  unit_id    uuid,
  created_at timestamptz not null default now()
);


-- ── Everything a staff account authors ──────────────────────

create table actions (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  owner      uuid not null references auth.users(id),
  due_date   date not null,
  state      text not null default 'open',
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table meetings (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null default 'tuesday_review',
  held_on    date not null,
  attendees  uuid[] not null default '{}'::uuid[],
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table work_plans (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references organizations(id),
  title        text not null,
  period_start date not null,
  period_end   date not null,
  status       text not null default 'draft',
  authored_by  uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table org_contracts (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references organizations(id),
  contract_kind     text not null default 'retainer',
  included_lines    text[] not null default array['financial'],
  billing_frequency text not null default 'monthly',
  start_date        date not null,
  auto_renew        boolean not null default false,
  currency          text not null default 'BWP',
  status            text not null default 'draft',
  created_by        uuid references auth.users(id),
  account_manager   uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create table billing_handovers (
  id                   uuid primary key default gen_random_uuid(),
  org_id               uuid not null references organizations(id),
  kind                 text not null,
  currency             text not null default 'BWP',
  state                text not null default 'to_prepare',
  covers_from          timestamptz not null default now(),
  narrative            jsonb not null default '{}'::jsonb,
  prepared_by          uuid references auth.users(id),
  invoice_confirmed_by uuid references auth.users(id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create table org_reports (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references organizations(id),
  period_start date not null,
  period_end   date not null,
  period_label text not null,
  status       text not null default 'draft',
  narrative    jsonb not null default '{}'::jsonb,
  created_by   uuid not null references auth.users(id),
  published_by uuid references auth.users(id),
  service_line text not null default 'financial',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- reported_by is NOT NULL and carries NO foreign key. Both facts matter: it
-- cannot be nulled, so it has to be reassigned, and no constraint would have
-- stopped the delete from orphaning it.
create table org_headcount_reports (
  id          bigint generated always as identity primary key,
  org_id      uuid not null references organizations(id),
  headcount   integer not null,
  reported_by uuid not null,
  created_at  timestamptz not null default now()
);


-- ── Seed ────────────────────────────────────────────────────

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000011', 'naledi@keywellness.test'),
  ('00000000-0000-0000-0000-000000000012', 'orphan@example.test'),
  ('00000000-0000-0000-0000-000000000013', 'zex@example.test');

insert into profiles (id, org_id, first_name, last_name) values
  ('00000000-0000-0000-0000-000000000011', null, 'Naledi', 'Everything'),
  ('00000000-0000-0000-0000-000000000013', '0a000000-0000-0000-0000-0000000000b0', 'Zex', 'Member');
-- orphan@example.test deliberately has NO profiles row.

-- Naledi holds every role there is, by every keying the portal uses: some by
-- user_id, some by email, one by both. Deleting her has to clear all of them.
insert into admins (email) values ('naledi@keywellness.test');

insert into employers (user_id, org_id, email) values
  ('00000000-0000-0000-0000-000000000011', '0a000000-0000-0000-0000-0000000000d0',
   'naledi@keywellness.test');

insert into hr_unit_scope (hr_user_id, hr_email, org_id) values
  ('00000000-0000-0000-0000-000000000011', 'naledi@keywellness.test',
   '0a000000-0000-0000-0000-0000000000d0');

insert into advisors (user_id, email, full_name, is_active, is_team_lead, created_by) values
  ('00000000-0000-0000-0000-000000000011', 'naledi@keywellness.test', 'Naledi', true, false,
   '00000000-0000-0000-0000-000000000009');

insert into counsellors (user_id, email, full_name) values
  ('00000000-0000-0000-0000-000000000011', 'naledi@keywellness.test', 'Naledi');

insert into psychosocial_admins (email, user_id, full_name) values
  ('naledi@keywellness.test', '00000000-0000-0000-0000-000000000011', 'Naledi');

-- Kefilwe's roster row records Naledi as the person who added her. That
-- reference has to move, not vanish: who added an advisor is worth keeping.
update advisors set created_by = '00000000-0000-0000-0000-000000000011'
 where email = 'kefilwe@keywealth.co.bw';

-- One of everything Naledi authored.
insert into actions (title, owner, due_date, created_by) values
  ('Chase Sedimosa headcount', '00000000-0000-0000-0000-000000000011', '2026-09-30',
   '00000000-0000-0000-0000-000000000011');

insert into meetings (held_on, created_by) values
  ('2026-08-25', '00000000-0000-0000-0000-000000000011');

insert into work_plans (org_id, title, period_start, period_end, authored_by) values
  ('0a000000-0000-0000-0000-0000000000b0', 'BOPEU 2026 plan', '2026-01-01', '2026-12-31',
   '00000000-0000-0000-0000-000000000011');

insert into org_contracts (org_id, start_date, created_by, account_manager) values
  ('0a000000-0000-0000-0000-0000000000b0', '2026-01-01',
   '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000011');

insert into billing_handovers (org_id, kind, prepared_by, invoice_confirmed_by) values
  ('0a000000-0000-0000-0000-0000000000b0', 'retainer',
   '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000011');

insert into org_reports (org_id, period_start, period_end, period_label, status,
                         created_by, published_by) values
  ('0a000000-0000-0000-0000-0000000000b0', '2026-04-01', '2026-06-30', 'Q2 2026', 'published',
   '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000011');

insert into org_headcount_reports (org_id, headcount, reported_by) values
  ('0a000000-0000-0000-0000-0000000000b0', 420, '00000000-0000-0000-0000-000000000011');

insert into program_activities (org_id, activity_type, title, activity_date,
                                attendee_count, created_by) values
  ('0a000000-0000-0000-0000-0000000000b0', 'education_talk', 'Debt Management', '2026-08-26', 30,
   '00000000-0000-0000-0000-000000000011');

-- The member's own data, one row in every shape.
insert into assessments (user_id, score) values
  ('00000000-0000-0000-0000-00000000000e', 62),
  ('00000000-0000-0000-0000-000000000013', 71);
insert into badges (user_id, points) values
  ('00000000-0000-0000-0000-00000000000e', 140),
  ('00000000-0000-0000-0000-000000000013', 90);
insert into checkins (user_id, score) values
  ('00000000-0000-0000-0000-00000000000e', 60);
insert into tool_usage_events (user_id, tool) values
  ('00000000-0000-0000-0000-00000000000e', 'budget_planner');
insert into tool_data (user_id, tool, data) values
  ('00000000-0000-0000-0000-00000000000e', 'budget_planner', '{"income":9000}'::jsonb),
  ('00000000-0000-0000-0000-000000000013', 'goal_planner',   '{"goals":[]}'::jsonb);
insert into ai_chat_usage (user_id, input_tokens) values
  ('00000000-0000-0000-0000-00000000000e', 1200);

-- The member's booking, whose attendance Naledi confirmed. Deleting the member
-- deletes this row; deleting NALEDI must instead move the confirmer, which is
-- why Zex has a booking too — otherwise the reassign has nothing to bite on.
insert into bookings (user_id, requested_date, status, service, attended,
                      attendance_confirmed_by, user_name, user_email) values
  ('00000000-0000-0000-0000-00000000000e', '2026-08-26', 'confirmed', 'Coaching', true,
   '00000000-0000-0000-0000-000000000011', 'Boitumelo Member', 'member@example.test'),
  ('00000000-0000-0000-0000-000000000013', '2026-08-27', 'confirmed', 'Coaching', true,
   '00000000-0000-0000-0000-000000000011', 'Zex Member', 'zex@example.test');

insert into reward_fulfilments (org_id, user_id, season, category, fulfilled_by) values
  ('0a000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-00000000000e',
   '2026-H1', 'voucher', '00000000-0000-0000-0000-000000000011'),
  ('0a000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-000000000013',
   '2026-H1', 'voucher', '00000000-0000-0000-0000-000000000011');

-- Two caseloads on the member. The advisory one nulls itself through its own
-- key; the counselling one does not, and must be unlinked by the plan. Both
-- rows have to survive: the case is not the account.
insert into advisor_clients (advisor_id, member_user_id, email, first_name, created_by)
  select id, '00000000-0000-0000-0000-00000000000e', 'member@example.test', 'Boitumelo',
         '00000000-0000-0000-0000-000000000011'
    from advisors where email = 'kefilwe@keywealth.co.bw';

insert into counsellor_clients (counsellor_id, member_user_id, email)
  select id, '00000000-0000-0000-0000-00000000000e', 'member@example.test'
    from counsellors where email = 'naledi@keywellness.test';

-- Audit rows written BEFORE the migration runs, so the backfill of
-- actor_email / target_email is exercised rather than assumed.
insert into support_actions (actor, action, target_user, outcome, detail, created_at) values
  ('00000000-0000-0000-0000-000000000011', 'lookup', null, 'ok', 'q=boitumelo',
   now() - interval '20 minutes'),
  ('00000000-0000-0000-0000-000000000011', 'send_password_reset',
   '00000000-0000-0000-0000-00000000000e', 'ok', 'member@example.test',
   now() - interval '19 minutes');

grant select, insert, update, delete on all tables in schema public to authenticated;
