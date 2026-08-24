-- Minimal replica of the live schema, enough to exercise Phase 0.
-- Companion fixture for tests/run-phase0.sh. NOT a migration — this is a
-- minimal stand-in for the live schema so Phase 0 can be exercised on a
-- throwaway local database. Never run it against Supabase.
create schema if not exists auth;

create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  created_at timestamptz not null default now()
);

-- Stand-ins for Supabase's auth helpers.
create or replace function auth.uid() returns uuid
language sql stable as $$ select nullif(current_setting('test.uid', true),'')::uuid $$;
create or replace function auth.jwt() returns jsonb
language sql stable as $$ select jsonb_build_object('email', coalesce(current_setting('test.email', true),'')) $$;

create table organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table org_units (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id),
  parent_unit_id uuid references org_units(id),
  name text not null,
  is_active boolean not null default true,
  sort_order int default 0,
  created_at timestamptz not null default now()
);

create table admins (email text primary key);

create table advisors (
  id uuid primary key default gen_random_uuid(),
  user_id uuid,
  email text,
  full_name text,
  is_active boolean not null default true,
  is_team_lead boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table profiles (
  id uuid primary key references auth.users(id),
  org_id uuid references organizations(id),
  org_unit_id uuid references org_units(id),
  first_name text, last_name text,
  monthly_income numeric, monthly_debt numeric,
  last_score int, last_cat_scores jsonb,
  advisor_data_consent boolean default false,
  joined_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table advisor_clients (
  id uuid primary key default gen_random_uuid(),
  advisor_id uuid not null references advisors(id) on delete cascade,
  member_user_id uuid references auth.users(id) on delete set null,
  first_name text, last_name text, email text, phone text,
  org_id uuid references organizations(id),
  assessment jsonb,
  source text not null default 'advisor_added'
    check (source in ('advisor_added','admin_assigned','booking_claim')),
  status text not null default 'active' check (status in ('active','archived')),
  linked_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table bookings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid,
  advisor_id uuid references advisors(id),
  advisor_client_id uuid references advisor_clients(id),
  requested_date text,
  attended boolean,
  booked_by text,
  member_response text,
  status text,
  created_at timestamptz not null default now()
);

create table threshold_config (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
insert into threshold_config (key, value) values
  ('sessions_attended_required','1'::jsonb),
  ('budget_months_required','3'::jsonb);

-- Role helpers, matching the live definitions closely enough to test.
create or replace function is_admin() returns boolean
language sql stable security definer set search_path to 'public','auth' as $$
  select exists (select 1 from admins where lower(email) = lower(auth.jwt() ->> 'email'));
$$;

create or replace function current_advisor_id() returns uuid
language sql stable security definer set search_path to 'public','auth' as $$
  select id from advisors
   where is_active and (user_id = auth.uid() or lower(email) = lower(auth.jwt() ->> 'email'))
   order by (user_id = auth.uid()) desc limit 1;
$$;

create or replace function is_team_lead() returns boolean
language sql stable security definer set search_path to 'public','auth' as $$
  select exists (select 1 from advisors
                  where is_active and is_team_lead
                    and (user_id = auth.uid() or lower(email) = lower(auth.jwt() ->> 'email')));
$$;

create or replace function can_manage_advisor(p_advisor_id uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select p_advisor_id is not null
     and (p_advisor_id = current_advisor_id() or is_team_lead() or is_admin());
$$;

-- The pre-Phase-0 insert trigger, exactly as it stands live.
create or replace function link_advisor_client_on_insert() returns trigger
language plpgsql security definer set search_path to 'public','auth' as $$
declare v_uid uuid;
begin
  if new.member_user_id is null and new.email is not null then
    select id into v_uid from auth.users where lower(email) = lower(new.email) limit 1;
    if v_uid is not null then new.member_user_id := v_uid; new.linked_at := now(); end if;
  end if;
  if new.member_user_id is not null and new.org_id is null then
    select org_id into new.org_id from profiles where id = new.member_user_id;
  end if;
  return new;
end $$;

create trigger trg_link_advisor_client_on_insert
  before insert on advisor_clients
  for each row execute function link_advisor_client_on_insert();

create or replace function advisor_clients_list(
  p_include_archived boolean default false, p_advisor_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin return '[]'::jsonb; end $$;

do $$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end $$;

-- Added for Phase 0a: advisor role helper and the two member-add RPCs
-- as they stood BEFORE 0a, so the fix is exercised against the real bug.
create or replace function is_advisor() returns boolean
language sql stable security definer set search_path to 'public','auth' as $$
  select exists (select 1 from advisors
                  where is_active
                    and (user_id = auth.uid() or lower(email) = lower(auth.jwt() ->> 'email')));
$$;

create or replace function advisor_add_member_client(p_member_user_id uuid) returns uuid
language plpgsql security definer set search_path to 'public','auth' as $$
declare v_advisor uuid := current_advisor_id(); v_id uuid;
        v_email text; v_fn text; v_ln text; v_org uuid;
begin
  if v_advisor is null then raise exception 'not authorised'; end if;
  select id into v_id from advisor_clients
   where advisor_id = v_advisor and member_user_id = p_member_user_id;
  if v_id is not null then return v_id; end if;
  select u.email, p.first_name, p.last_name, p.org_id
    into v_email, v_fn, v_ln, v_org
    from auth.users u left join profiles p on p.id = u.id where u.id = p_member_user_id;
  if v_email is null then raise exception 'member not found'; end if;
  insert into advisor_clients
    (advisor_id, member_user_id, first_name, last_name, email, org_id, source, linked_at, created_by)
  values (v_advisor, p_member_user_id, coalesce(v_fn, split_part(v_email,'@',1)), v_ln,
          v_email, v_org, 'advisor_added', now(), auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create or replace function admin_assign_client(p_advisor_id uuid, p_member_user_id uuid) returns uuid
language plpgsql security definer set search_path to 'public','auth' as $$
declare v_id uuid; v_email text; v_fn text; v_ln text; v_org uuid;
begin
  if not is_admin() then raise exception 'not authorised'; end if;
  select id into v_id from advisor_clients
   where advisor_id = p_advisor_id and member_user_id = p_member_user_id;
  if v_id is not null then return v_id; end if;
  select u.email, p.first_name, p.last_name, p.org_id
    into v_email, v_fn, v_ln, v_org
    from auth.users u left join profiles p on p.id = u.id where u.id = p_member_user_id;
  if v_email is null then raise exception 'member not found'; end if;
  insert into advisor_clients
    (advisor_id, member_user_id, first_name, last_name, email, org_id, source, linked_at, created_by)
  values (p_advisor_id, p_member_user_id, coalesce(v_fn, split_part(v_email,'@',1)), v_ln,
          v_email, v_org, 'admin_assigned', now(), auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- ── Added for Phase 1: the tables the indicator library reads ──
create table assessments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  score int,
  cat_scores jsonb,
  answers jsonb,
  created_at timestamptz not null default now()
);

create table emergency_fund (
  user_id uuid primary key references auth.users(id),
  monthly numeric,
  current_savings numeric,
  contribution numeric,
  target_months int,
  updated_at timestamptz default now()
);

create table stress_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  level int,
  tags text[],
  notes text,
  created_at timestamptz not null default now()
);

alter table profiles
  add column if not exists monthly_expenses numeric,
  add column if not exists essential_expenses numeric,
  add column if not exists monthly_savings numeric,
  add column if not exists total_assets numeric,
  add column if not exists total_liabilities numeric,
  add column if not exists will_status text,
  add column if not exists live_cat_scores jsonb,
  add column if not exists live_score_at timestamptz;

-- The org_units tree walk, as it stands live.
create or replace function unit_descendants(p_unit_id uuid)
returns table(id uuid) language sql stable set search_path to 'public' as $$
  with recursive tree as (
    select ou.id from org_units ou where ou.id = p_unit_id
    union all
    select c.id from org_units c join tree t on c.parent_unit_id = t.id
  )
  select id from tree;
$$;
