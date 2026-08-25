-- ============================================================
-- Key Wellness — M1 fixture (local PostgreSQL 17 only)
--
-- Companion to tests/run-m1.sh and tests/m1-tests.sql. NOT a migration.
-- Never run this against Supabase.
--
-- The bookings table here is built from docs/build/00-live-schema-snapshot.md
-- §3 — all 24 live columns and all five live CHECK constraints — NOT from
-- tests/phase0-fixture.sql, which defines only 10 columns and is missing
-- session_type and session_mode, i.e. both columns M1 exists to migrate.
-- See docs/build/m1-service-line.md for the full column diff.
--
-- SEED PHILOSOPHY. This does not mirror live row-for-row, deliberately.
-- Against live data three of the four issued report periods return
-- insufficient_cohort, which would make a before/after comparison vacuous —
-- "null equals null" proves nothing. Every organisation here therefore clears
-- the 5-member cohort floor so org_report_data() returns real figures and the
-- regression assertion has something to bite on. What IS mirrored exactly is
-- the shape that matters to M1: the live session_type × session_mode
-- distribution (12 In-Person/null, 6 Virtual/null, 2 In-Person/physical,
-- 2 Individual/physical) and exactly one attended=true row on a Virtual
-- booking.
-- ============================================================

create schema if not exists auth;

create table auth.users (
  id         uuid primary key default gen_random_uuid(),
  email      text,
  created_at timestamptz not null default now()
);

-- Stand-ins for Supabase's auth helpers, driven by session settings so a test
-- can act as any role. Same pattern as tests/phase0-fixture.sql.
create or replace function auth.uid() returns uuid
language sql stable as $$ select nullif(current_setting('test.uid', true),'')::uuid $$;
create or replace function auth.jwt() returns jsonb
language sql stable as $$ select jsonb_build_object('email', coalesce(current_setting('test.email', true),'')) $$;

-- supabase_org_report_data_v4.sql revokes from these roles, so they must exist.
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon')         then create role anon;         end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='service_role')  then create role service_role;  end if;
end $$;


-- ── Tables ──────────────────────────────────────────────────

create table organizations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  invite_code text not null unique,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table org_units (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references organizations(id),
  parent_unit_id uuid references org_units(id),
  name           text not null,
  is_active      boolean not null default true,
  sort_order     integer not null default 0,
  created_at     timestamptz not null default now()
);

create table unit_departments (
  id         uuid primary key default gen_random_uuid(),
  unit_id    uuid not null references org_units(id),
  name       text not null,
  is_active  boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table admins (email text primary key);

create table employers (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid,
  org_id     uuid not null references organizations(id),
  email      text,
  created_at timestamptz not null default now()
);

create table advisors (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid,
  email        text not null,
  full_name    text not null,
  is_active    boolean not null default true,
  is_team_lead boolean not null default false,
  created_at   timestamptz not null default now()
);

create table advisor_clients (
  id             uuid primary key default gen_random_uuid(),
  advisor_id     uuid not null references advisors(id),
  member_user_id uuid,
  first_name     text not null,
  org_id         uuid references organizations(id),
  org_unit_id    uuid references org_units(id),
  no_org         boolean not null default false,
  status         text not null default 'active',
  created_at     timestamptz not null default now()
);

create table profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  org_id        uuid references organizations(id),
  org_unit_id   uuid references org_units(id),
  department_id uuid references unit_departments(id),
  gender        text,
  last_score    integer,
  live_score    numeric,
  joined_at     timestamptz default now()
);

-- bookings: all 24 live columns, in live order, with the live constraints.
create table bookings (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid references auth.users(id),
  user_name                text,
  user_email               text,
  requested_date           text,
  session_type             text,
  status                   text default 'pending',
  created_at               timestamptz default now(),
  service                  text,
  updated_at               timestamptz,
  requested_time           text,
  client_seen_confirmation boolean not null default false,
  attended                 boolean,
  attendance_confirmed_by  uuid,
  attendance_confirmed_at  timestamptz,
  session_mode             text,
  client_type              text default 'member',
  advisor_id               uuid references advisors(id),
  advisor_client_id        uuid references advisor_clients(id),
  booked_by                text not null default 'member',
  member_response          text,
  member_response_at       timestamptz,
  member_response_note     text,
  advisor_seen_response    boolean not null default false,
  constraint bookings_session_mode_check
    check (session_mode = any (array['physical','virtual'])),
  constraint bookings_booked_by_chk
    check (booked_by = any (array['member','advisor','admin'])),
  constraint bookings_client_type_check
    check (client_type = any (array['member','dependent'])),
  constraint bookings_member_response_chk
    check (member_response is null or member_response = any
           (array['accepted','declined','reschedule_requested']))
);

create table program_activities (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references organizations(id),
  activity_type  text not null,
  title          text not null,
  activity_date  date not null,
  attendee_count integer not null,
  delivery_mode  text,
  notes          text,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  constraint program_activities_activity_type_check
    check (activity_type = any (array['group_intervention','education_talk','webinar','clinic','other'])),
  constraint program_activities_delivery_mode_check
    check (delivery_mode = any (array['physical','virtual','hybrid'])),
  constraint program_activities_attendee_count_check check (attendee_count >= 0)
);

create table org_reports (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references organizations(id),
  period_start  date not null,
  period_end    date not null,
  period_label  text not null,
  status        text not null default 'draft',
  narrative     jsonb not null default '{}'::jsonb,
  data_snapshot jsonb,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  published_by  uuid,
  published_at  timestamptz,
  unit_id       uuid references org_units(id),
  constraint org_reports_status_check check (status = any (array['draft','published']))
);

create table content_items (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  kind         text not null default 'lesson',
  org_id       uuid references organizations(id),
  published    boolean not null default true,
  webinar_date date,
  created_at   timestamptz not null default now(),
  constraint content_items_kind_check check (kind = any (array['lesson','webinar']))
);

create table assessments (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  score      integer not null,
  cat_scores jsonb,
  created_at timestamptz default now()
);

create table points_catalog (
  event_type text primary key,
  points     integer not null,
  active     boolean not null default true,
  category   text not null default 'utilisation'
);

create table points_events (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  event_type text not null references points_catalog(event_type),
  ref_id     text not null,
  points     integer not null,
  season     text not null,
  created_at timestamptz not null default now(),
  unique (user_id, event_type, ref_id)
);

create table threshold_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);
insert into threshold_config (key, value) values
  ('indicator.low_base','5'::jsonb),
  ('sessions_attended_required','1'::jsonb);


-- ── Helpers, matching the live definitions closely enough ───

create or replace function _suppress_count(v int) returns jsonb
language sql immutable as $$
  select case
    when v is null then jsonb_build_object('value', 0, 'suppressed', false)
    when v < 3     then jsonb_build_object('value', null, 'suppressed', true)
    else                jsonb_build_object('value', v, 'suppressed', false)
  end;
$$;

create or replace function _suppress_count(v bigint) returns jsonb
language sql immutable as $$
  select case
    when v is null then jsonb_build_object('value', 0, 'suppressed', false)
    when v < 3     then jsonb_build_object('value', null, 'suppressed', true)
    else                jsonb_build_object('value', v, 'suppressed', false)
  end;
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path to 'public','auth' as $$
  select exists (select 1 from admins where lower(email) = lower(auth.jwt() ->> 'email'));
$$;

create or replace function employer_org() returns uuid
language sql stable security definer set search_path to 'public','auth' as $$
  select org_id from employers
   where user_id = auth.uid() or lower(email) = lower(auth.jwt() ->> 'email')
   limit 1;
$$;

create or replace function current_member_org() returns uuid
language sql stable security definer set search_path to 'public','auth' as $$
  select org_id from profiles where id = auth.uid();
$$;

create or replace function is_advisor() returns boolean
language sql stable security definer set search_path to 'public','auth' as $$
  select exists (select 1 from advisors a
                  where a.is_active
                    and (a.user_id = auth.uid()
                      or lower(a.email) = lower(auth.jwt() ->> 'email')));
$$;

create or replace function current_advisor_id() returns uuid
language sql stable security definer set search_path to 'public','auth' as $$
  select id from advisors a
   where a.is_active
     and (a.user_id = auth.uid() or lower(a.email) = lower(auth.jwt() ->> 'email'))
   limit 1;
$$;

create or replace function is_team_lead() returns boolean
language sql stable security definer set search_path to 'public','auth' as $$
  select exists (select 1 from advisors a
                  where a.is_active and a.is_team_lead
                    and (a.user_id = auth.uid()
                      or lower(a.email) = lower(auth.jwt() ->> 'email')));
$$;

create or replace function unit_descendants(p_unit_id uuid)
returns table(id uuid) language sql stable as $$
  with recursive t as (
    select u.id from org_units u where u.id = p_unit_id
    union all
    select c.id from org_units c join t on c.parent_unit_id = t.id
  ) select id from t;
$$;

create or replace function hr_scoped_unit_ids() returns uuid[]
language sql stable security definer set search_path to 'public','auth' as $$
  select null::uuid[];   -- no unit-scoped HR in this fixture
$$;

create or replace function hr_unit_in_scope(p_org_id uuid, p_unit_id uuid)
returns boolean language sql stable security definer set search_path to 'public','auth' as $$
  select is_admin() or coalesce(employer_org() = p_org_id, false);
$$;

create or replace function kw_threshold(p_key text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select value from threshold_config where key = p_key;
$$;


-- ── Seed ────────────────────────────────────────────────────
-- Three organisations, mirroring the live names so the build record and the
-- live verification read the same. Eight members each, all created well
-- before the earliest period so every period clears the cohort floor.

insert into admins (email) values ('admin@keywellness.co.bw');

insert into organizations (id, name, invite_code) values
  ('00000000-0000-0000-0000-0000000000b0', 'BOPEU',    'BOPEU-TEST'),
  ('00000000-0000-0000-0000-0000000000d0', 'Sedimosa', 'SED-TEST'),
  ('00000000-0000-0000-0000-0000000000c0', 'Test Co',  'TESTCO-TEST');

-- Eight members per organisation.
do $$
declare
  o  record;
  i  int;
  uid uuid;
begin
  for o in select id, name from organizations order by name loop
    for i in 1..8 loop
      uid := gen_random_uuid();
      insert into auth.users (id, email, created_at)
        values (uid, lower(replace(o.name,' ','')) || i || '@example.test', timestamptz '2026-01-05 09:00+02');
      insert into profiles (id, org_id, gender, last_score)
        values (uid, o.id, case when i % 2 = 0 then 'female' else 'male' end, 50 + i);
      insert into assessments (user_id, score, created_at)
        values (uid, 50 + i, timestamptz '2026-02-01 09:00+02');
    end loop;
  end loop;
end $$;

-- Bookings: the live session_type x session_mode distribution exactly.
--   12 In-Person / null mode      6 Virtual / null mode
--    2 In-Person / physical       2 Individual / physical
-- and exactly one attended = true, on a Virtual row, inside Q3 2026.
do $$
declare
  testco uuid := '00000000-0000-0000-0000-0000000000c0';
  sed    uuid;
  u      uuid;
  i      int;
begin
  select id into sed from organizations where name = 'Sedimosa';

  -- 12 In-Person, no mode: 7 in Q3 (Test Co), 5 in the Apr-Jun window.
  for i in 1..12 loop
    select id into u from profiles where org_id = case when i <= 7 then testco else sed end limit 1 offset (i % 8);
    insert into bookings (user_id, session_type, session_mode, attended, created_at, requested_date, booked_by)
      values (u, 'In-Person', null, null,
              case when i <= 7 then timestamptz '2026-07-08 10:00+02'
                               else timestamptz '2026-06-23 10:00+02' end,
              '2026-07-16', 'member');
  end loop;

  -- 6 Virtual, no mode. The last one is the single attended = true row.
  for i in 1..6 loop
    select id into u from profiles where org_id = case when i <= 3 then testco else sed end limit 1 offset (i % 8);
    insert into bookings (user_id, session_type, session_mode, attended, created_at, requested_date, booked_by)
      values (u, 'Virtual', null, case when i = 6 then true else null end,
              timestamptz '2026-07-22 10:00+02', '2026-07-24', 'member');
  end loop;

  -- 2 In-Person that already carry physical, and 2 Individual likewise.
  -- These four are the reason rollback restores from a backup table rather
  -- than blanket-nulling by session_type.
  for i in 1..2 loop
    select id into u from profiles where org_id = testco limit 1 offset i;
    insert into bookings (user_id, session_type, session_mode, attended, created_at, requested_date, booked_by)
      values (u, 'In-Person', 'physical', case when i = 1 then false else null end,
              timestamptz '2026-07-08 11:00+02', '2026-07-23', 'member');
    insert into bookings (user_id, session_type, session_mode, attended, created_at, requested_date, booked_by)
      values (u, 'Individual', 'physical', null,
              timestamptz '2026-08-17 11:00+02', '2026-08-20', 'member');
  end loop;
end $$;

insert into program_activities (org_id, activity_type, title, activity_date, attendee_count, delivery_mode, created_by)
select id, 'education_talk', 'Budgeting basics', date '2026-07-15', 24, 'physical', null
  from organizations where name = 'Test Co';

insert into content_items (title, kind, org_id, published, webinar_date)
select 'Managing debt', 'webinar', id, true, date '2026-07-20'
  from organizations where name = 'Test Co';

insert into org_reports (org_id, period_start, period_end, period_label, status, created_by)
select id, date '2026-01-01', date '2026-03-31', 'Q1 2026 (Jan–Mar)', 'draft', null
  from organizations where name = 'Test Co';
insert into org_reports (org_id, period_start, period_end, period_label, status, created_by)
select id, date '2026-07-01', date '2026-09-30', 'Q3 2026 (Jul–Sep)', 'draft', null
  from organizations where name = 'Test Co';
