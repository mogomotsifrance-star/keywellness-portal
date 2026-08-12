-- ============================================================
-- Key Wellness — Advisor Portal: schema, roles and RLS
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (IF NOT EXISTS / OR REPLACE throughout)
--
-- Run order:
--   1. supabase_advisor_portal.sql   ← this file
--   2. supabase_advisor_rpcs.sql
--
-- Rollback: migrations/rollback-advisor-portal.sql
-- ============================================================
--
-- DESIGN NOTES (read before changing anything here)
--
-- * Advisors are Key Wellness staff and work across ALL client
--   organisations. There is deliberately no advisor→org mapping table.
--   Org slicing in reports still works because every report joins
--   bookings → profiles → profiles.org_id, exactly as it does today.
--
-- * An advisor's client record (`advisor_clients`) is advisor-owned and
--   does NOT require the person to have a portal login. `member_user_id`
--   is nullable. When that person later signs up with the same email the
--   record is linked automatically by trg_link_advisor_clients on
--   auth.users. This is the "advisors work with clients whether or not
--   they have signed up" requirement.
--
-- * `bookings` stays the single source of truth for sessions. Advisor
--   bookings are rows in `bookings` with booked_by='advisor', so the
--   existing org_report_data() session counts pick them up with no
--   change to those functions.
--
-- * Advisors NEVER get direct RLS read access to profiles, assessments
--   or any tool table. Member financial data reaches the advisor only
--   through the SECURITY DEFINER RPCs in supabase_advisor_rpcs.sql,
--   which check profiles.advisor_data_consent first.
-- ------------------------------------------------------------


-- ── 0. Preflight ─────────────────────────────────────────────
-- `bookings` RLS was configured in the Supabase dashboard and is not
-- captured in any repo file. We add policies to it below, which only
-- has any effect if RLS is enabled. Warn loudly rather than silently
-- enabling it (enabling it here could lock out flows we cannot see).

do $$
declare v_rls boolean;
begin
  select relrowsecurity into v_rls from pg_class where oid = 'public.bookings'::regclass;
  if not coalesce(v_rls, false) then
    raise warning 'bookings does NOT have row level security enabled. The advisor policies below will have no effect. Enable RLS on bookings before relying on them.';
  end if;
end $$;


-- ── 1. Advisors ──────────────────────────────────────────────
-- Mirrors the `employers` pattern: email is the durable identity
-- (an advisor row can be created before that person has ever logged in),
-- user_id is backfilled on first login.

create table if not exists advisors (
  id          uuid        primary key default gen_random_uuid(),
  user_id     uuid        null references auth.users(id) on delete set null,
  email       text        not null,
  full_name   text        not null,
  phone       text        null,
  title       text        null,          -- e.g. 'Financial Wellness Advisor'
  is_active   boolean     not null default true,
  created_by  uuid        null references auth.users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz null
);

create unique index if not exists advisors_email_uniq
  on advisors (lower(email));

create unique index if not exists advisors_user_id_uniq
  on advisors (user_id) where user_id is not null;

create index if not exists advisors_active_idx
  on advisors (is_active) where is_active;

alter table advisors enable row level security;


-- ── 2. Role helpers ──────────────────────────────────────────
-- security definer so they bypass RLS (avoids recursion inside policies)
-- stable so Postgres evaluates them once per statement

-- The advisor row id for the calling user, or null.
create or replace function current_advisor_id()
returns uuid
language sql security definer stable set search_path = public as $$
  select id from advisors
  where is_active
    and (user_id = auth.uid() or lower(email) = lower(auth.jwt() ->> 'email'))
  order by (user_id = auth.uid()) desc   -- prefer the user_id match
  limit 1;
$$;

create or replace function is_advisor()
returns boolean
language sql security definer stable set search_path = public as $$
  select current_advisor_id() is not null;
$$;

grant execute on function current_advisor_id() to authenticated;
grant execute on function is_advisor()         to authenticated;

-- Backfill advisors.user_id on first login, same as trg_backfill_employer.
create or replace function backfill_advisor_user_id()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update advisors
     set user_id = new.id,
         updated_at = now()
   where user_id is null
     and lower(email) = lower(new.email);
  return new;
end;
$$;

drop trigger if exists trg_backfill_advisor on auth.users;
create trigger trg_backfill_advisor
  after insert on auth.users
  for each row
  execute function backfill_advisor_user_id();


-- ── 3. Member consent for advisor data access ────────────────
-- Separate from the existing consent_accepted (which covers the platform
-- itself). This one is specifically "my advisor may see my financial data"
-- and defaults to false — the advisor sees contact details and sessions
-- only until the member turns it on in My Profile.

alter table profiles
  add column if not exists advisor_data_consent    boolean not null default false,
  add column if not exists advisor_data_consent_at timestamptz null;


-- ── 4. Advisor clients ───────────────────────────────────────
-- Advisor-owned record. member_user_id is NULL until (and unless) that
-- person registers on the portal with a matching email.

create table if not exists advisor_clients (
  id             uuid        primary key default gen_random_uuid(),
  advisor_id     uuid        not null references advisors(id) on delete cascade,
  member_user_id uuid        null references auth.users(id) on delete set null,
  first_name     text        not null,
  last_name      text        null,
  email          text        null,
  phone          text        null,
  org_id         uuid        null references organizations(id),  -- denormalised for admin filtering
  -- The advisor's working consultation record. This is the nested object
  -- the advisor portal UI already uses (personal, income, liabilities,
  -- assets, savings, risk, budget, notes, documents…). Held as jsonb so
  -- the whole prototype UI works unchanged while the data lives
  -- server-side under RLS instead of in localStorage. It is the ADVISOR's
  -- record of the consultation — distinct from the member's own portal
  -- data, which is never written here.
  assessment     jsonb       not null default '{}'::jsonb,
  source         text        not null default 'advisor_added'
                   check (source in ('advisor_added','admin_assigned','booking_claim')),
  status         text        not null default 'active'
                   check (status in ('active','archived')),
  linked_at      timestamptz null,
  created_by     uuid        null references auth.users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz null
);

-- Explicit ALTERs so a re-run on an existing table still picks up new columns.
alter table advisor_clients
  add column if not exists assessment jsonb not null default '{}'::jsonb;

-- One advisor cannot hold the same member twice.
create unique index if not exists advisor_clients_member_uniq
  on advisor_clients (advisor_id, member_user_id)
  where member_user_id is not null;

-- …nor the same email twice.
create unique index if not exists advisor_clients_email_uniq
  on advisor_clients (advisor_id, lower(email))
  where email is not null;

create index if not exists advisor_clients_advisor_idx on advisor_clients (advisor_id);
create index if not exists advisor_clients_member_idx  on advisor_clients (member_user_id)
  where member_user_id is not null;
create index if not exists advisor_clients_org_idx     on advisor_clients (org_id);

alter table advisor_clients enable row level security;


-- ── 4a. Auto-link: advisor_clients → registered member ───────
-- Two directions, because either side can arrive first.

-- (a) Client added by advisor for someone who ALREADY has a login.
create or replace function link_advisor_client_on_insert()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_uid uuid;
begin
  if new.member_user_id is null and new.email is not null then
    select id into v_uid from auth.users
     where lower(email) = lower(new.email)
     limit 1;
    if v_uid is not null then
      new.member_user_id := v_uid;
      new.linked_at := now();
    end if;
  end if;

  -- Keep org_id in step with the member's org whenever we know it.
  if new.member_user_id is not null and new.org_id is null then
    select org_id into new.org_id from profiles where id = new.member_user_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_link_advisor_client on advisor_clients;
create trigger trg_link_advisor_client
  before insert or update of email, member_user_id on advisor_clients
  for each row
  execute function link_advisor_client_on_insert();

-- (b) Someone the advisor already added later signs up.
create or replace function link_advisor_clients_on_signup()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update advisor_clients
     set member_user_id = new.id,
         linked_at      = now(),
         updated_at     = now()
   where member_user_id is null
     and email is not null
     and lower(email) = lower(new.email);
  return new;
end;
$$;

drop trigger if exists trg_link_advisor_clients on auth.users;
create trigger trg_link_advisor_clients
  after insert on auth.users
  for each row
  execute function link_advisor_clients_on_signup();


-- ── 5. Advisor notes ─────────────────────────────────────────
-- Private to the authoring advisor (and admins). Never shown to the member.

create table if not exists advisor_notes (
  id         uuid        primary key default gen_random_uuid(),
  client_id  uuid        not null references advisor_clients(id) on delete cascade,
  advisor_id uuid        not null references advisors(id) on delete cascade,
  booking_id uuid        null,                       -- optional: note attached to a session
  body       text        not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz null
);

create index if not exists advisor_notes_client_idx on advisor_notes (client_id, created_at desc);

alter table advisor_notes enable row level security;


-- ── 6. Bookings: advisor columns ─────────────────────────────
-- NOTE: no CREATE TABLE for bookings exists in this repo — it was created
-- in the Supabase dashboard. These are additive columns only.

alter table bookings
  add column if not exists advisor_id           uuid references advisors(id),
  add column if not exists advisor_client_id    uuid references advisor_clients(id),
  add column if not exists booked_by            text not null default 'member',
  add column if not exists member_response      text,
  add column if not exists member_response_at   timestamptz,
  add column if not exists member_response_note text,
  add column if not exists advisor_seen_response boolean not null default false;

-- Constraints added separately so re-runs do not fail on duplicates.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'bookings_booked_by_chk') then
    alter table bookings add constraint bookings_booked_by_chk
      check (booked_by in ('member','advisor','admin'));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'bookings_member_response_chk') then
    alter table bookings add constraint bookings_member_response_chk
      check (member_response is null
             or member_response in ('accepted','declined','reschedule_requested'));
  end if;
end $$;

create index if not exists bookings_advisor_idx on bookings (advisor_id)
  where advisor_id is not null;
create index if not exists bookings_booked_by_idx on bookings (booked_by);

-- Existing rows predate the advisor portal and are all self-booked.
update bookings set booked_by = 'member' where booked_by is null;


-- ── 7. RLS: advisors ─────────────────────────────────────────

drop policy if exists advisors_admin_all on advisors;
create policy advisors_admin_all on advisors
  for all using (is_admin()) with check (is_admin());

-- An advisor can read the roster (needed to show "who else is on the team"
-- and to reassign a client) but can only edit their own row.
drop policy if exists advisors_self_read on advisors;
create policy advisors_self_read on advisors
  for select using (is_advisor());

drop policy if exists advisors_self_update on advisors;
create policy advisors_self_update on advisors
  for update using (id = current_advisor_id())
  with check (id = current_advisor_id() and is_active);


-- A member may read the advisor attached to their own booking — enough to
-- show "scheduled by <name>" on My Bookings. Not the whole roster.
drop policy if exists advisors_member_read on advisors;
create policy advisors_member_read on advisors
  for select using (
    exists (
      select 1 from bookings b
      where b.advisor_id = advisors.id
        and b.user_id = auth.uid()
    )
  );


-- ── 8. RLS: advisor_clients ──────────────────────────────────

drop policy if exists advisor_clients_admin_all on advisor_clients;
create policy advisor_clients_admin_all on advisor_clients
  for all using (is_admin()) with check (is_admin());

drop policy if exists advisor_clients_own on advisor_clients;
create policy advisor_clients_own on advisor_clients
  for select using (advisor_id = current_advisor_id());

drop policy if exists advisor_clients_own_insert on advisor_clients;
create policy advisor_clients_own_insert on advisor_clients
  for insert with check (advisor_id = current_advisor_id());

drop policy if exists advisor_clients_own_update on advisor_clients;
create policy advisor_clients_own_update on advisor_clients
  for update using (advisor_id = current_advisor_id())
  with check (advisor_id = current_advisor_id());

drop policy if exists advisor_clients_own_delete on advisor_clients;
create policy advisor_clients_own_delete on advisor_clients
  for delete using (advisor_id = current_advisor_id());

-- A member may see which advisors hold a record on them. Read-only, and it
-- is their own data — this is what makes the consent toggle meaningful.
drop policy if exists advisor_clients_member_read on advisor_clients;
create policy advisor_clients_member_read on advisor_clients
  for select using (member_user_id = auth.uid());


-- ── 9. RLS: advisor_notes ────────────────────────────────────
-- Deliberately NO member read policy. Notes are clinical/working notes.

drop policy if exists advisor_notes_admin_all on advisor_notes;
create policy advisor_notes_admin_all on advisor_notes
  for all using (is_admin()) with check (is_admin());

drop policy if exists advisor_notes_own on advisor_notes;
create policy advisor_notes_own on advisor_notes
  for all using (advisor_id = current_advisor_id())
  with check (advisor_id = current_advisor_id());


-- ── 10. RLS: bookings — advisor access ───────────────────────
-- Additive. Existing member and admin policies are untouched.

-- An advisor sees a booking if they own it, or if it belongs to one of
-- their linked clients (so they can see sessions the member booked directly).
drop policy if exists bookings_advisor_select on bookings;
create policy bookings_advisor_select on bookings
  for select using (
    advisor_id = current_advisor_id()
    or exists (
      select 1 from advisor_clients ac
      where ac.advisor_id = current_advisor_id()
        and ac.member_user_id = bookings.user_id
    )
  );

-- An advisor may only create bookings stamped with their own advisor_id.
drop policy if exists bookings_advisor_insert on bookings;
create policy bookings_advisor_insert on bookings
  for insert with check (
    advisor_id = current_advisor_id()
    and booked_by = 'advisor'
  );

-- An advisor may update their own bookings (reschedule, cancel, and
-- confirm attendance — which fires the existing trg_award_session_attended).
drop policy if exists bookings_advisor_update on bookings;
create policy bookings_advisor_update on bookings
  for update using (advisor_id = current_advisor_id())
  with check (advisor_id = current_advisor_id());

-- Members respond to advisor-scheduled sessions. The existing dashboard
-- policy already covers client_seen_confirmation; this makes the response
-- columns explicit and survives any tightening of that older policy.
drop policy if exists bookings_member_respond on bookings;
create policy bookings_member_respond on bookings
  for update using (user_id = auth.uid())
  with check (user_id = auth.uid());


-- ── 11. Grants ───────────────────────────────────────────────

grant select, insert, update, delete on advisor_clients to authenticated;
grant select, insert, update, delete on advisor_notes   to authenticated;
grant select, update                 on advisors        to authenticated;


-- ── 12. Verification ─────────────────────────────────────────
-- Run these after the migration and eyeball the output.
--
--   select * from advisors;
--   select is_advisor(), current_advisor_id();
--   select column_name, data_type, column_default
--     from information_schema.columns
--    where table_name = 'bookings' and column_name in
--      ('advisor_id','advisor_client_id','booked_by','member_response');
--   select tablename, policyname, cmd from pg_policies
--    where tablename in ('advisors','advisor_clients','advisor_notes','bookings')
--    order by tablename, policyname;
--
-- Seed the first advisor (also the admin/user/advisor test account):
--
--   insert into advisors (email, full_name, title)
--   values ('france@keywealth.co.bw', 'France Mogomotsi', 'Financial Wellness Advisor')
--   on conflict do nothing;
--
-- That account is already in `admins`; it needs a `profiles` row to see the
-- member interface, which it gets automatically on first sign-in.
-- ============================================================
