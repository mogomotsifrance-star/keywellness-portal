-- ============================================================
-- Key Wellness — Employer / Organisation Multi-Tenancy Migration
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (all statements use IF NOT EXISTS / OR REPLACE)
-- ============================================================

-- ── 0. Prerequisites ─────────────────────────────────────────
-- Confirmed from live codebase:
--   profiles PK is `id` (uuid, references auth.users)
--   assessments columns: user_id, score, cat_scores (jsonb), answers, created_at
--   admins table has an `email` column
--   No existing auth.users trigger; profiles are created lazily via saveUser() upsert
-- ─────────────────────────────────────────────────────────────


-- ── 1. Organisations table ────────────────────────────────────

create table if not exists organizations (
  id          uuid        primary key default gen_random_uuid(),
  name        text        not null,
  invite_code text        unique not null,
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now()
);


-- ── 2. Add org_id to profiles ────────────────────────────────

alter table profiles
  add column if not exists org_id uuid references organizations(id);


-- ── 3. Employers table ───────────────────────────────────────

create table if not exists employers (
  user_id    uuid        primary key references auth.users(id) on delete cascade,
  org_id     uuid        not null references organizations(id) on delete cascade,
  created_at timestamptz not null default now()
);


-- ── 4. Server-side role helpers ───────────────────────────────
-- security definer so they bypass RLS (avoids recursion in policies)
-- stable so Postgres evaluates them once per statement

-- Admin check — matches the existing `admins` table (email column confirmed)
create or replace function is_admin()
returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from admins
    where lower(email) = lower(auth.jwt() ->> 'email')
  );
$$;

-- Returns the org this user manages as HR (null if not an employer)
create or replace function employer_org()
returns uuid
language sql security definer stable set search_path = public as $$
  select org_id from employers where user_id = auth.uid();
$$;


-- ── 5. RLS — member data tables ──────────────────────────────
-- Pattern: user sees own rows; admin sees all; employer sees nothing here.
-- Deliberately NO employer policy on these tables.

-- profiles
alter table profiles enable row level security;

drop policy if exists profiles_own on profiles;
create policy profiles_own on profiles
  for all
  using  (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists profiles_admin_read on profiles;
create policy profiles_admin_read on profiles
  for select
  using (is_admin());

-- assessments
alter table assessments enable row level security;

drop policy if exists assessments_own on assessments;
create policy assessments_own on assessments
  for all
  using  (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists assessments_admin_read on assessments;
create policy assessments_admin_read on assessments
  for select
  using (is_admin());

-- checkins
alter table checkins enable row level security;

drop policy if exists checkins_own on checkins;
create policy checkins_own on checkins
  for all
  using  (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists checkins_admin_read on checkins;
create policy checkins_admin_read on checkins
  for select
  using (is_admin());

-- badges
alter table badges enable row level security;

drop policy if exists badges_own on badges;
create policy badges_own on badges
  for all
  using  (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists badges_admin_read on badges;
create policy badges_admin_read on badges
  for select
  using (is_admin());

-- emergency_fund
alter table emergency_fund enable row level security;

drop policy if exists ef_own on emergency_fund;
create policy ef_own on emergency_fund
  for all
  using  (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists ef_admin_read on emergency_fund;
create policy ef_admin_read on emergency_fund
  for select
  using (is_admin());


-- ── 6. Lock org_id from client writes ────────────────────────
-- Non-admins cannot change their own org_id after signup.
-- The trigger forces NEW.org_id = OLD.org_id for all non-admin updates.

create or replace function lock_org_id()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then
    NEW.org_id := OLD.org_id;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_lock_org_id on profiles;
create trigger trg_lock_org_id
  before update on profiles
  for each row
  execute function lock_org_id();


-- ── 7. organizations RLS ──────────────────────────────────────
-- Admins see all orgs (for the admin dashboard dropdown).
-- Employers see only their own org row.
-- No other roles can read — protects the client roster.

alter table organizations enable row level security;

drop policy if exists orgs_admin_all on organizations;
create policy orgs_admin_all on organizations
  for select
  using (is_admin());

drop policy if exists orgs_own on organizations;
create policy orgs_own on organizations
  for select
  using (id = employer_org());


-- ── 8. employers RLS ─────────────────────────────────────────

alter table employers enable row level security;

drop policy if exists employers_admin_all on employers;
create policy employers_admin_all on employers
  for all
  using  (is_admin())
  with check (is_admin());

drop policy if exists employers_self_read on employers;
create policy employers_self_read on employers
  for select
  using (user_id = auth.uid());


-- ── 9. Aggregate-only RPC for HR dashboards ──────────────────
-- Single entry point; enforces authz + cohort guard (n ≥ 5) internally.
-- Employers call: select org_overview('their-org-uuid')
-- Returns suppressed JSON if fewer than 5 enrolled members.

create or replace function org_overview(target_org uuid)
returns json
language plpgsql security definer set search_path = public as $$
declare
  n      int;
  result json;
begin
  -- Auth: admin, or the HR manager of THIS org only.
  -- coalesce(...,false) is REQUIRED: for a non-employer, employer_org() is NULL,
  -- so `employer_org() = target_org` is NULL, `false OR NULL` is NULL, and
  -- `IF NOT NULL` skips the raise — letting unauthorised users through. Coalescing
  -- the comparison to false closes that hole.
  if not (is_admin() or coalesce(employer_org() = target_org, false)) then
    raise exception 'not authorised';
  end if;

  select count(*) into n
  from profiles
  where org_id = target_org;

  -- Cohort guard: suppress all output for groups < 5
  if n < 5 then
    return json_build_object(
      'suppressed',    true,
      'n_employees',   n,
      'message',       'Too few participants to display aggregates while protecting individual privacy.'
    );
  end if;

  -- Per-dimension averages: cat_scores is a jsonb object keyed by dimension name.
  -- We extract all keys from the most-recent assessment per member and average across the org.
  -- Dimensions currently in use: budgeting, saving, debt, protection, emergency, retirement, investing, behaviour
  -- (derived from wellness_assessment.html — adapt keys if they change)
  select json_build_object(
    'n_employees',         n,
    'participation_pct',   round(
                             100.0 * count(a.user_id)::numeric / nullif(n, 0),
                             1
                           ),
    'avg_score',           round(avg(a.score)::numeric, 1),
    'avg_by_dimension',    (
      select json_object_agg(
        dim_key,
        round(avg_val::numeric, 1)
      )
      from (
        select
          dim.key   as dim_key,
          avg(dim.value::text::numeric) as avg_val
        from profiles p2
        cross join lateral (
          select * from assessments a3
          where a3.user_id = p2.id
          order by a3.created_at desc
          limit 1
        ) latest
        cross join lateral jsonb_each(latest.cat_scores) as dim(key, value)
        where p2.org_id = target_org
        group by dim.key
      ) dims
    )
  ) into result
  from profiles p
  left join lateral (
    select *
    from assessments a2
    where a2.user_id = p.id
    order by a2.created_at desc
    limit 1
  ) a on true
  where p.org_id = target_org;

  return result;
end;
$$;


-- ── 10. Invite-code resolution on signup ─────────────────────
-- Profiles are created lazily in the frontend (saveUser() upsert).
-- We handle org resolution in a BEFORE INSERT trigger on auth.users
-- so the org_id is stamped at account-creation time, before saveUser() runs.
-- If a trigger named handle_new_user already exists, this replaces the function
-- and the trigger — merge any existing profile-creation logic here.

create or replace function handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  code     text;
  resolved uuid;
begin
  code := upper(coalesce(new.raw_user_meta_data ->> 'invite_code', ''));

  if code <> '' then
    select id into resolved
    from organizations
    where upper(invite_code) = code
      and is_active = true;
    -- If code is unknown or inactive, resolved stays null → public member
  end if;

  -- Only sets org_id; other profile columns are written by saveUser() on first login.
  insert into profiles (id, org_id)
  values (new.id, resolved)
  on conflict (id) do update
    set org_id = coalesce(profiles.org_id, excluded.org_id);

  return new;
end;
$$;

-- Drop existing trigger with this name if present, then recreate.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function handle_new_user();


-- ── DONE ─────────────────────────────────────────────────────
-- Manual steps after running this migration:
--
-- 1. Create an org and its shared staff code:
--      insert into organizations (name, invite_code) values ('Acme Corp', 'ACME-7F3K2');
--    Hand 'ACME-7F3K2' to the client; employees enter it in the "Company code"
--    field at signup and are auto-tagged with this org_id.
--
-- 2. Onboard an HR manager (two steps — mirrors how admins are set up):
--    a) The HR person self-registers on the portal with email + password,
--       leaving the "Company code" field BLANK (org_id stays NULL — HR is a
--       manager OF the org, not a counted member, so they must not be enrolled).
--    b) An admin then links them, using the UUID from Supabase → Auth → Users:
--         insert into employers (user_id, org_id) values ('<hr-user-uuid>', '<org-uuid>');
--    On their next login, index.html routes them to employer.html (no member
--    onboarding/consent/welcome), exactly as admins are routed to admin.html.
-- ─────────────────────────────────────────────────────────────
