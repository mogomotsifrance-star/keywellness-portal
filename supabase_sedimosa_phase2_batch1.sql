-- ============================================================
-- Key Wellness — Sedimosa Phase 2, Batch 1: migrations + seed corrections
-- Run ONCE in the Supabase SQL Editor (dashboard → SQL Editor).
-- Idempotent: schema uses IF NOT EXISTS, seed uses ON CONFLICT DO NOTHING,
-- seed corrections are safe to re-run.
--
-- PRODUCTION-LIVE the moment it is applied (dev and prod share one Supabase
-- project). Safe to land ahead of the frontend because nothing READS these
-- objects yet:
--   • unit_departments / webinar_views / notifications are brand-new
--   • profiles.gender / department_id / will_status are nullable, read by
--     nothing until Batch 2/4/6 frontend ships
--   • content_items.webinar_date is nullable; ordering keeps a created_at fallback
--   • the seed correction only deactivates a mis-seeded unit + renames one unit
--
-- ROLLBACK: migrations/rollback-sedimosa-phase2-batch1.sql
--   (written & committed BEFORE this file was applied, per rollback-first rule).
--
-- PREREQUISITE: supabase_org_units.sql must already be applied (org_units,
-- profiles.org_unit_id, is_admin(), current_member_org(), employer_org()).
-- Every DO block RAISEs visibly if a prerequisite row is missing — no silent
-- partial apply.
--
-- RUN ORDER INSIDE THIS FILE MATTERS: the Morupule→MCM rename (§2) happens
-- BEFORE the department seed (§5) so MCM departments attach to the new name.
-- ============================================================


-- ══════════════════════════════════════════════════════════════
-- 1. SCHEMA (additive)
-- ══════════════════════════════════════════════════════════════

-- 1a. Departments — a separate dimension on profiles, NOT org_units children.
--     A member's unit stays the company/site leaf; department is orthogonal.
create table if not exists unit_departments (
  id          uuid        primary key default gen_random_uuid(),
  unit_id     uuid        not null references org_units(id),
  name        text        not null,
  is_active   boolean     not null default true,
  sort_order  int         not null default 0,
  created_at  timestamptz not null default now(),
  unique (unit_id, name)
);
create index if not exists unit_departments_unit_idx on unit_departments(unit_id);

-- 1b. New profile dimensions. phone already exists (in saveUser() whitelist) —
--     IF NOT EXISTS makes it a no-op here; it is listed only for completeness.
alter table profiles
  add column if not exists gender text
    check (gender in ('male','female','prefer_not_to_say'));
alter table profiles
  add column if not exists department_id uuid references unit_departments(id);
alter table profiles
  add column if not exists phone text;          -- E.164; pre-existing, no-op
alter table profiles
  add column if not exists will_status text
    check (will_status in ('has_will','no_will','in_progress'));

create index if not exists profiles_department_idx on profiles(department_id);

-- 1c. Per-view webinar audit log (one row per view event; repeat views = repeat
--     rows). Distinct from video_watch_progress (resume/credit). Admin-only reads.
create table if not exists webinar_views (
  id          uuid        primary key default gen_random_uuid(),
  webinar_id  uuid        not null references public.content_items(id) on delete cascade,
  user_id     uuid        not null references auth.users(id) on delete cascade,
  viewed_at   timestamptz not null default now()
);
create index if not exists webinar_views_webinar_idx on webinar_views(webinar_id);
create index if not exists webinar_views_user_idx    on webinar_views(user_id);

-- 1d. In-app notification store. Mirrors every transactional email so phone-only
--     members (no email) still receive everything. INSERTs come from server-side
--     paths (the send-booking-email Edge Function, service role) — NO client
--     INSERT policy (see §4d + BUILD-NOTES). Members read own + mark read only.
create table if not exists notifications (
  id          uuid        primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users(id) on delete cascade,
  type        text        not null,          -- 'booking_received','booking_confirmed', …
  title       text        not null,
  body        text,
  created_at  timestamptz not null default now(),
  read_at     timestamptz null
);
create index if not exists notifications_user_time_idx on notifications(user_id, created_at desc);

-- 1e. Exact webinar date on content_items (webinars are content_items kind='webinar').
--     Nullable so the 26 existing lesson rows and any dateless webinars are unaffected;
--     ordering falls back to created_at until dates are backfilled (Batch 7).
alter table public.content_items
  add column if not exists webinar_date date;


-- ══════════════════════════════════════════════════════════════
-- 2. SEED CORRECTIONS (non-destructive, idempotent)
--    Sedimosa has 7 top-level companies, not 8. DBGSS IS DeBeers.
-- ══════════════════════════════════════════════════════════════
do $$
declare
  v_org      uuid;
  v_debeers  uuid;
  v_dbgss    uuid;
  v_moved    int;
begin
  select id into v_org from organizations where name ilike '%sedimosa%' limit 1;
  if v_org is null then
    raise exception 'Sedimosa organisation not found — cannot apply seed corrections.';
  end if;

  -- 2a. Rename Morupule -> Morupule Coal Mine (MCM). Must precede §5 seed.
  update org_units set name = 'Morupule Coal Mine (MCM)'
   where org_id = v_org and name = 'Morupule';
  raise notice 'Rename Morupule -> MCM: % row(s).', (case when found then 1 else 0 end);

  -- 2b. Reassign any profiles on the mis-seeded DeBeers unit to DBGSS BEFORE
  --     deactivating it (non-destructive; SQL Editor runs as postgres so the
  --     set-once org_unit_id guard permits the move).
  select id into v_debeers from org_units where org_id = v_org and name = 'DeBeers';
  select id into v_dbgss   from org_units where org_id = v_org and name = 'DBGSS';

  if v_debeers is not null then
    if v_dbgss is null then
      raise exception 'DBGSS unit missing — cannot reassign DeBeers members. Aborting.';
    end if;

    update profiles set org_unit_id = v_dbgss where org_unit_id = v_debeers;
    get diagnostics v_moved = row_count;
    if v_moved > 0 then
      raise notice 'Reassigned % profile(s) from DeBeers -> DBGSS.', v_moved;
    else
      raise notice 'No profiles were on DeBeers (expected).';
    end if;

    -- 2c. Deactivate the wrong unit (never delete — members could reference it).
    update org_units set is_active = false where id = v_debeers;
    raise notice 'Deactivated DeBeers unit %.', v_debeers;
  else
    raise notice 'DeBeers unit not present (already corrected?).';
  end if;
end $$;


-- ══════════════════════════════════════════════════════════════
-- 3. RLS
-- ══════════════════════════════════════════════════════════════

-- 3a. unit_departments — authenticated members read active departments of
--     THEIR OWN org's units (during onboarding); HR + admin read their org's;
--     no member writes; admin manages.
alter table unit_departments enable row level security;

drop policy if exists unit_departments_read on unit_departments;
create policy unit_departments_read on unit_departments
  for select
  using (
    is_active = true
    and unit_id in (
      select u.id from org_units u
      where u.org_id = current_member_org()
         or u.org_id = employer_org()
         or is_admin()
    )
  );

drop policy if exists unit_departments_admin_all on unit_departments;
create policy unit_departments_admin_all on unit_departments
  for all
  using  (is_admin())
  with check (is_admin());

-- 3b. webinar_views — members INSERT their own rows only; SELECT is Key Wellness
--     ADMIN ONLY (never HR, never employers). No update/delete for anyone.
alter table webinar_views enable row level security;

drop policy if exists webinar_views_own_insert on webinar_views;
create policy webinar_views_own_insert on webinar_views
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists webinar_views_admin_read on webinar_views;
create policy webinar_views_admin_read on webinar_views
  for select to authenticated
  using (is_admin());

-- 3c. notifications — members SELECT + UPDATE(read_at) their OWN rows only.
--     NO insert policy: rows are written server-side (service role bypasses RLS)
--     by the Edge Function, keeping email↔notification parity automatic and
--     avoiding a client that could forge notifications for other users.
alter table notifications enable row level security;

drop policy if exists notifications_own_read on notifications;
create policy notifications_own_read on notifications
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists notifications_own_update on notifications;
create policy notifications_own_update on notifications
  for update to authenticated
  using  (user_id = auth.uid())
  with check (user_id = auth.uid());

-- 3d. Belt-and-braces: an own-rows UPDATE could in principle rewrite title/body.
--     Restrict non-admin updates to the read_at column only (the intended
--     "mark as read" action). Admins/service role are unrestricted.
create or replace function guard_notification_update()
returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user in ('authenticated','anon') and not is_admin() then
    if NEW.user_id    is distinct from OLD.user_id
    or NEW.type       is distinct from OLD.type
    or NEW.title      is distinct from OLD.title
    or NEW.body       is distinct from OLD.body
    or NEW.created_at is distinct from OLD.created_at then
      raise exception 'notifications: members may only update read_at'
        using errcode = 'check_violation';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_guard_notification_update on notifications;
create trigger trg_guard_notification_update
  before update on notifications
  for each row execute function guard_notification_update();


-- ══════════════════════════════════════════════════════════════
-- 4. SET-ONCE GUARD on profiles.gender + department_id
-- ══════════════════════════════════════════════════════════════
-- Same pattern as trg_lock_org_unit_id: an end-user (authenticated/anon) may set
-- gender and department_id exactly once (NULL -> value); any later CHANGE by an
-- end-user is rejected — corrections are admin-mediated (locked decision 4 & 7).
-- will_status is deliberately NOT covered: it updates on every assessment retake.
-- SECURITY INVOKER on purpose (reads current_user to tell end-users from
-- privileged roles). saveUser()'s upsert must write these via NULL->value only.
create or replace function lock_profile_dims()
returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user in ('authenticated','anon') and not is_admin() then
    if OLD.gender is not null
       and NEW.gender is distinct from OLD.gender then
      raise exception 'gender is set-once; changes are admin-mediated'
        using errcode = 'check_violation';
    end if;
    if OLD.department_id is not null
       and NEW.department_id is distinct from OLD.department_id then
      raise exception 'department_id is set-once; transfers are admin-only'
        using errcode = 'check_violation';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_lock_profile_dims on profiles;
create trigger trg_lock_profile_dims
  before update on profiles
  for each row execute function lock_profile_dims();


-- ══════════════════════════════════════════════════════════════
-- 5. DEPARTMENT SEED (idempotent) — expected total 161 rows
--    6×22 (shared) + DTCB 7 + DBGSS 10 + MCM 12 = 161
-- ══════════════════════════════════════════════════════════════
do $$
declare
  v_org   uuid;
  v_unit  uuid;
  su      text;
  d       text;
  i       int;
  -- Shared 22-department list (spelling normalised: "Project Management",
  -- "Safety and Sustainability" — flagged in BUILD-NOTES for client confirmation).
  shared_depts text[] := array[
    'Audit','Corporate Affairs','Engineering','Finance','Human Resources',
    'Information Technology','Management','MRM','Open Pit','Ore Processing',
    'Project Management','Projects Portfolio','Risk Management',
    'Safety and Sustainability','Security','Supply Chain (SCM)',
    'Technical Services','Techno Economic','Underground','Naledi',
    'Mining','Health Services'
  ];
  -- Units that receive the shared list (Debswana PARENT is excluded — never a leaf).
  shared_units text[] := array['Sesiro','Mmila','DPF','DCC','Jwaneng','Orapa'];
  dtcb_depts text[] := array[
    'Managing Directors Office','Human Resources','Security','Finance',
    'Technical Services','Operations','Transformation'
  ];
  dbgss_depts text[] := array[
    'Corporate Affairs','EXCO','Facilities','Finance','Information Management',
    'Human Resources','Product Planning','Product Delivery','Sales','Security'
  ];
  mcm_depts text[] := array[
    'Engineering','Beneficiation','Technical Services','Mining',
    'Safety and Sustainability','Commercial','Sales, Marketing and Logistics',
    'Internal Audit','Human Resources','Legal and Governance',
    'Corporate Services','Strategy and Projects'
  ];
begin
  select id into v_org from organizations where name ilike '%sedimosa%' limit 1;
  if v_org is null then raise exception 'Sedimosa org not found — cannot seed departments.'; end if;

  -- 5a. Shared list across the 6 units
  foreach su in array shared_units loop
    select id into v_unit from org_units where org_id = v_org and name = su;
    if v_unit is null then raise exception 'Unit % not found under Sedimosa — aborting seed.', su; end if;
    i := 0;
    foreach d in array shared_depts loop
      i := i + 10;
      insert into unit_departments (unit_id, name, sort_order)
      values (v_unit, d, i)
      on conflict (unit_id, name) do nothing;
    end loop;
  end loop;

  -- 5b. DTCB
  select id into v_unit from org_units where org_id = v_org and name = 'DTCB';
  if v_unit is null then raise exception 'DTCB unit not found — aborting seed.'; end if;
  i := 0;
  foreach d in array dtcb_depts loop
    i := i + 10;
    insert into unit_departments (unit_id, name, sort_order) values (v_unit, d, i)
    on conflict (unit_id, name) do nothing;
  end loop;

  -- 5c. DBGSS
  select id into v_unit from org_units where org_id = v_org and name = 'DBGSS';
  if v_unit is null then raise exception 'DBGSS unit not found — aborting seed.'; end if;
  i := 0;
  foreach d in array dbgss_depts loop
    i := i + 10;
    insert into unit_departments (unit_id, name, sort_order) values (v_unit, d, i)
    on conflict (unit_id, name) do nothing;
  end loop;

  -- 5d. MCM (resolved by the NEW name set in §2a)
  select id into v_unit from org_units where org_id = v_org and name = 'Morupule Coal Mine (MCM)';
  if v_unit is null then raise exception 'MCM unit not found (rename in §2a did not run?) — aborting seed.'; end if;
  i := 0;
  foreach d in array mcm_depts loop
    i := i + 10;
    insert into unit_departments (unit_id, name, sort_order) values (v_unit, d, i)
    on conflict (unit_id, name) do nothing;
  end loop;

  raise notice 'Department seed complete.';
end $$;


-- ══════════════════════════════════════════════════════════════
-- 6. VERIFICATION (run after applying; eyeball each result)
-- ══════════════════════════════════════════════════════════════

-- 6a. Active top-level Sedimosa units = exactly 7 (Debswana + MCM, DBGSS, DTCB,
--     DPF, Mmila, Sesiro); DeBeers inactive; Morupule renamed:
select u.name, u.sort_order, u.is_active,
       (select name from org_units p where p.id = u.parent_unit_id) as parent
from org_units u
where u.org_id = (select id from organizations where name ilike '%sedimosa%' limit 1)
order by u.is_active desc, u.sort_order;
-- Expect: 10 active (7 top-level + Jwaneng/Orapa/DCC), 1 inactive (DeBeers);
--         'Morupule Coal Mine (MCM)' present, no bare 'Morupule'.

-- 6b. Department count = exactly 161:
select count(*) as dept_total from unit_departments
where unit_id in (select id from org_units
  where org_id = (select id from organizations where name ilike '%sedimosa%' limit 1));

-- 6c. Per-unit department counts (spot-check the lists):
select ou.name as unit, count(ud.id) as depts
from org_units ou
left join unit_departments ud on ud.unit_id = ou.id
where ou.org_id = (select id from organizations where name ilike '%sedimosa%' limit 1)
group by ou.name order by ou.name;
-- Expect: Sesiro/Mmila/DPF/DCC/Jwaneng/Orapa = 22 each; DTCB = 7; DBGSS = 10;
--         Morupule Coal Mine (MCM) = 12; Debswana = 0; DeBeers = 0.

-- 6d. New profiles columns present:
select column_name, data_type from information_schema.columns
where table_schema='public' and table_name='profiles'
  and column_name in ('gender','department_id','phone','will_status');

-- 6e. New tables + column present:
select to_regclass('public.unit_departments') as unit_departments,
       to_regclass('public.webinar_views')    as webinar_views,
       to_regclass('public.notifications')     as notifications;
select column_name from information_schema.columns
where table_schema='public' and table_name='content_items' and column_name='webinar_date';

-- 6f. RLS smoke tests (BROWSER console, logged in — NOT SQL Editor which bypasses RLS):
--     Member of Sedimosa/Mmila, department picker fetch:
--       await sb.from('unit_departments').select('name').eq('unit_id','<Mmila-unit-id>'); // 22 rows
--     A Test Co member must see ZERO Sedimosa departments:
--       await sb.from('unit_departments').select('name');  // -> []
--     A member must NOT read webinar_views or others' notifications:
--       await sb.from('webinar_views').select('*');        // -> [] (admin-only)
--       await sb.from('notifications').select('*');         // -> only own rows
-- ============================================================
