-- ============================================================
-- Key Wellness — Company Units (Sedimosa sub-org structure), Batch 1
-- Run ONCE in the Supabase SQL Editor (dashboard → SQL Editor).
-- Safe to re-run: schema uses IF NOT EXISTS, seed uses ON CONFLICT DO
-- NOTHING, the account move is idempotent.
--
-- PRODUCTION-LIVE the moment it is applied (dev and prod share one
-- Supabase project). Safe because nothing READS these objects yet:
--   • org_units / hr_unit_scope are brand-new (no code paths touch them)
--   • profiles.org_unit_id is nullable and read by nothing until the
--     frontend ships (Batch 2)
--   • the account move touches only Tshenolo's own test account
--
-- ROLLBACK: migrations/rollback-org-units.sql (written & committed BEFORE
-- this file was applied, per the additive-only / rollback-first rule).
--
-- Self-resolving: Sedimosa is resolved by name, Test Co by invite_code,
-- Tshenolo by email — no UUIDs are hardcoded. Every section RAISEs
-- visibly if a prerequisite row is missing (no silent partial apply).
-- ============================================================


-- ══════════════════════════════════════════════════════════════
-- 1. SCHEMA (additive)
-- ══════════════════════════════════════════════════════════════

-- 1a. Company units under an organisation. A unit with children is a
--     drill-down node (e.g. Debswana); only a leaf is member-selectable
--     — that rule is enforced in the frontend (Batch 2), not here, so
--     the tree stays flexible.
create table if not exists org_units (
  id             uuid        primary key default gen_random_uuid(),
  org_id         uuid        not null references organizations(id),
  parent_unit_id uuid        null references org_units(id),
  name           text        not null,
  is_active      boolean     not null default true,
  sort_order     int         not null default 0,
  created_at     timestamptz not null default now(),
  unique (org_id, name)
);

create index if not exists org_units_org_idx    on org_units(org_id);
create index if not exists org_units_parent_idx on org_units(parent_unit_id);

-- 1b. A member's chosen leaf unit. Nullable — orgs without units (Test
--     Co) and pre-existing members simply leave it NULL.
alter table profiles
  add column if not exists org_unit_id uuid references org_units(id);

create index if not exists profiles_org_unit_idx on profiles(org_unit_id);

-- 1c. HR manager -> unit scope. unit_id NULL = whole-org scope (the fund
--     Wellness Manager). Identity mirrors the employers table's
--     email-first / user_id-backfill pattern (see supabase_employer_email.sql),
--     so a manager can be scoped by email BEFORE they ever register — at
--     least one of hr_user_id / hr_email must be present. All report
--     scoping is resolved server-side inside SECURITY DEFINER RPCs
--     (Batch 3); this table is never trusted from the client.
create table if not exists hr_unit_scope (
  id          uuid        primary key default gen_random_uuid(),
  hr_user_id  uuid        null references auth.users(id) on delete cascade,
  hr_email    text        null,
  org_id      uuid        not null references organizations(id),
  unit_id     uuid        null references org_units(id),
  created_at  timestamptz not null default now(),
  constraint hr_unit_scope_identity_present check (hr_user_id is not null or hr_email is not null)
);

-- Uniqueness that treats a NULL unit (whole-org scope) as a real value,
-- so a manager can't be double-scoped to the same (identity, org, unit).
create unique index if not exists hr_unit_scope_uid_uniq
  on hr_unit_scope (hr_user_id, org_id, coalesce(unit_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where hr_user_id is not null;
create unique index if not exists hr_unit_scope_email_uniq
  on hr_unit_scope (lower(hr_email), org_id, coalesce(unit_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where hr_email is not null;


-- ══════════════════════════════════════════════════════════════
-- 2. HELPER — caller's own org (security definer, bypasses profiles RLS)
-- ══════════════════════════════════════════════════════════════
-- Mirrors employer_org(). Used by org_units RLS so a member can list the
-- units of their own org during onboarding without any RLS recursion
-- against profiles.
create or replace function current_member_org()
returns uuid
language sql security definer stable set search_path = public as $$
  select org_id from profiles where id = auth.uid();
$$;


-- ══════════════════════════════════════════════════════════════
-- 3. RLS
-- ══════════════════════════════════════════════════════════════

-- 3a. org_units — any authenticated caller may SELECT active units of
--     THEIR OWN org (member during onboarding, HR, admin). No member
--     writes; admins may manage (for a future admin UI — seeding here is
--     done as `postgres` in the SQL Editor, which bypasses RLS anyway).
alter table org_units enable row level security;

drop policy if exists org_units_read on org_units;
create policy org_units_read on org_units
  for select
  using (
    is_active = true
    and (
      org_id = current_member_org()
      or org_id = employer_org()
      or is_admin()
    )
  );

drop policy if exists org_units_admin_all on org_units;
create policy org_units_admin_all on org_units
  for all
  using  (is_admin())
  with check (is_admin());

-- 3b. hr_unit_scope — members get nothing. Admin manages; a manager may
--     read only their own scope rows. Report scoping never relies on this
--     policy — it happens inside SECURITY DEFINER RPCs regardless.
alter table hr_unit_scope enable row level security;

drop policy if exists hr_unit_scope_admin_all on hr_unit_scope;
create policy hr_unit_scope_admin_all on hr_unit_scope
  for all
  using  (is_admin())
  with check (is_admin());

drop policy if exists hr_unit_scope_self_read on hr_unit_scope;
create policy hr_unit_scope_self_read on hr_unit_scope
  for select
  using (
    hr_user_id = auth.uid()
    or lower(hr_email) = lower(auth.jwt() ->> 'email')
  );


-- ══════════════════════════════════════════════════════════════
-- 4. SET-ONCE GUARD on profiles.org_unit_id
-- ══════════════════════════════════════════════════════════════
-- A member may set their unit exactly once (NULL -> leaf). Any later
-- CHANGE to a non-null org_unit_id by an end-user is rejected — transfers
-- are admin-only (locked decision 7). Admins (is_admin()) and privileged
-- roles (postgres in the SQL Editor, service_role from edge functions)
-- may transfer freely.
--
-- SECURITY INVOKER (not DEFINER) on purpose: the guard reads `current_user`
-- to tell an end-user (`authenticated`) apart from a privileged role, and
-- a DEFINER function would always report its owner instead. The existing
-- trg_lock_org_id covers org_id only and does NOT touch org_unit_id, so
-- this new trigger is required. saveUser()'s upsert omits org_unit_id
-- entirely, so NEW = OLD there and this never fires on a normal profile save.
create or replace function lock_org_unit_id()
returns trigger
language plpgsql set search_path = public as $$
begin
  if OLD.org_unit_id is not null
     and NEW.org_unit_id is distinct from OLD.org_unit_id
     and current_user in ('authenticated', 'anon')
     and not is_admin()
  then
    raise exception 'org_unit_id is set-once; company transfers are admin-only'
      using errcode = 'check_violation';
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_lock_org_unit_id on profiles;
create trigger trg_lock_org_unit_id
  before update on profiles
  for each row
  execute function lock_org_unit_id();


-- ══════════════════════════════════════════════════════════════
-- 5. SEED — Sedimosa's 11 units (idempotent)
-- ══════════════════════════════════════════════════════════════
-- 8 top-level companies + 3 Debswana children (Jwaneng / Orapa / DCC).
-- Debswana is a parent-only drill-down node (never a member's leaf).
do $$
declare
  v_org      uuid;
  v_debswana uuid;
begin
  select id into v_org from organizations where name ilike '%sedimosa%' limit 1;
  if v_org is null then
    raise exception 'Sedimosa organisation not found — cannot seed units. Create the org first.';
  end if;

  -- Top-level companies
  insert into org_units (org_id, parent_unit_id, name, sort_order) values
    (v_org, null, 'Debswana', 10),
    (v_org, null, 'Morupule', 20),
    (v_org, null, 'DBGSS',    30),
    (v_org, null, 'DTCB',     40),
    (v_org, null, 'DPF',      50),
    (v_org, null, 'Mmila',    60),
    (v_org, null, 'DeBeers',  70),
    (v_org, null, 'Sesiro',   80)
  on conflict (org_id, name) do nothing;

  -- Debswana children
  select id into v_debswana from org_units where org_id = v_org and name = 'Debswana';
  insert into org_units (org_id, parent_unit_id, name, sort_order) values
    (v_org, v_debswana, 'Jwaneng', 11),
    (v_org, v_debswana, 'Orapa',   12),
    (v_org, v_debswana, 'DCC',     13)
  on conflict (org_id, name) do nothing;

  raise notice 'Seeded Sedimosa units under org %.', v_org;
end $$;


-- ══════════════════════════════════════════════════════════════
-- 6. TEST-ACCOUNT MOVE — tshenolo@prolearn.co.bw -> Sedimosa / Mmila
-- ══════════════════════════════════════════════════════════════
-- trg_lock_org_id blocks org_id changes for non-admins, and the SQL
-- Editor runs as `postgres` (is_admin() = false), so we disable it for
-- this one move (documented footgun — see supabase_seed_test_org.sql).
-- The new trg_lock_org_unit_id does NOT need disabling: current_user here
-- is `postgres`, which the guard allows.
alter table profiles disable trigger trg_lock_org_id;

do $$
declare
  v_org  uuid;
  v_unit uuid;
  v_prof uuid;
begin
  select id into v_org from organizations where name ilike '%sedimosa%' limit 1;
  if v_org is null then raise exception 'Sedimosa org not found — aborting account move.'; end if;

  select id into v_unit from org_units where org_id = v_org and name = 'Mmila';
  if v_unit is null then raise exception 'Mmila unit not found under Sedimosa — aborting account move.'; end if;

  select p.id into v_prof
  from profiles p join auth.users u on u.id = p.id
  where lower(u.email) = 'tshenolo@prolearn.co.bw';
  if v_prof is null then raise exception 'tshenolo@prolearn.co.bw profile not found — aborting account move.'; end if;

  update profiles set org_id = v_org, org_unit_id = v_unit where id = v_prof;
  raise notice 'Moved profile % to Sedimosa (%) / Mmila (%).', v_prof, v_org, v_unit;
end $$;

alter table profiles enable trigger trg_lock_org_id;


-- ══════════════════════════════════════════════════════════════
-- 7. VERIFICATION (run after applying; eyeball each result)
-- ══════════════════════════════════════════════════════════════

-- 7a. Exactly 11 Sedimosa units, correct parents/sort:
select u.name, u.sort_order, u.is_active, p.name as parent
from org_units u
left join org_units p on p.id = u.parent_unit_id
where u.org_id = (select id from organizations where name ilike '%sedimosa%' limit 1)
order by u.sort_order;
-- Expect 11 rows; Jwaneng/Orapa/DCC show parent = 'Debswana'; all others parent = NULL.

-- 7b. Count is exactly 11:
select count(*) as sedimosa_unit_count
from org_units
where org_id = (select id from organizations where name ilike '%sedimosa%' limit 1);

-- 7c. Tshenolo now Sedimosa / Mmila:
select u.email, o.name as org, ou.name as unit
from profiles p
join auth.users u on u.id = p.id
left join organizations o on o.id = p.org_id
left join org_units ou on ou.id = p.org_unit_id
where lower(u.email) = 'tshenolo@prolearn.co.bw';
-- Expect org = Sedimosa, unit = Mmila.

-- 7d. Existing member counts (Sedimosa expected ~0 besides Tshenolo, Test Co unchanged):
select o.name, count(p.id) as members
from organizations o
left join profiles p on p.org_id = o.id
where o.name ilike '%sedimosa%' or o.invite_code = 'TEST-1234'
group by o.name;

-- 7e. RLS smoke test (run in the BROWSER console as a logged-in user, NOT
--     the SQL Editor which bypasses RLS):
--     A Test Co member must see ZERO Sedimosa units:
--       await sb.from('org_units').select('name');   // Test Co user -> []
--     Tshenolo (Sedimosa) must see the 8 top-level + drill-down units:
--       await sb.from('org_units').select('name');   // -> 11 rows

-- 7f. Set-once guard (browser console, as a member whose org_unit_id is set):
--     await sb.from('profiles').update({ org_unit_id: '<some-other-unit>' }).eq('id', '<self>');
--     // -> error "org_unit_id is set-once; company transfers are admin-only"
-- ============================================================
