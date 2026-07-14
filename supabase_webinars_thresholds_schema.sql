-- ============================================================
-- Key Wellness — Org Webinars & Quarterly Thresholds: Batch 1 (schema)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor).
-- Run once; safe to re-run (IF NOT EXISTS / ON CONFLICT / OR REPLACE).
--
-- WARNING: dev and main share ONE Supabase project — this is
-- production-live the moment it is applied. Additive only: no DROP of
-- pre-existing objects, no destructive ALTER, no data rewrites.
-- Rollback: migrations/rollback-webinars-thresholds.sql SECTION A
-- (written and committed BEFORE this file, per project rule).
--
-- Batch 0 findings this file is shaped by
-- (BATCH-0-WEBINARS-THRESHOLDS-FINDINGS.md):
--   • Org table is `organizations`; members link via profiles.org_id.
--   • content_items already exists as the LMS lessons table — EXTENDED
--     here (kind/org_id/description/published), not duplicated. The
--     existing `video_path` column doubles as the webinar's VIMEO
--     reference ('<id>' or '<id>/<privacy-hash>') — see §8.
--   • bookings already has status/attended/attendance_confirmed_* —
--     nothing to add. checkins is already a server table — nothing to add.
--   • Budgets live in tool_data(tool='budget_planner') as a
--     {"budgets": {"YYYY-MM": ...}} blob — monthly_budgets is NOT created;
--     the quarterly budget record is the evidence-gated `budget_saved`
--     points ledger (see supabase_utilisation_rpcs.sql).
-- ============================================================


-- ── 1. organizations: per-org programme branding ────────────────
-- Default NULL = Key Wellness branding. Only Debswana gets a value.

alter table public.organizations
  add column if not exists program_name text,
  add column if not exists program_logo_path text;

-- Seed Debswana → Sedimosa. Harmless no-op (0 rows) if the Debswana org
-- has not been created yet — confirm the row exists (BUILD-NOTES item):
--   select id, name from organizations where name ilike '%debswana%';
update public.organizations
set program_name      = 'Sedimosa',
    program_logo_path = 'assets/img/sedimosa-logo.png'
where name ilike '%debswana%'
  and program_name is null;


-- Members cannot SELECT organizations under RLS (only admins/employers can,
-- and that protects the client roster + invite codes). The Learn page needs
-- ONLY the two branding fields for the member's own org — exposed via a
-- narrow RPC instead of widening the table policy.
create or replace function public.my_program_branding()
returns json
language sql security definer stable set search_path = public as $$
  select json_build_object(
    'program_name',      o.program_name,
    'program_logo_path', o.program_logo_path
  )
  from profiles p
  join organizations o on o.id = p.org_id
  where p.id = auth.uid();
$$;

grant execute on function public.my_program_branding() to authenticated;


-- ── 2. content_items: extend for org-scoped webinars ────────────
-- kind default 'lesson' + published default true keep the 26 live lesson
-- rows exactly as they are (visible, counted by the LMS). Webinar rows are
-- inserted with kind='webinar', an org_id (or NULL for all-member
-- webinars), and published=false until an admin publishes.

alter table public.content_items
  add column if not exists kind text not null default 'lesson',
  add column if not exists org_id uuid references public.organizations(id),
  add column if not exists description text,
  add column if not exists published boolean not null default true;

-- Named check constraint added separately so re-runs don't error.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'content_items_kind_check' and conrelid = 'public.content_items'::regclass
  ) then
    alter table public.content_items
      add constraint content_items_kind_check check (kind in ('lesson','webinar'));
  end if;
end $$;

create index if not exists content_items_kind_org_idx
  on public.content_items (kind, org_id) where kind = 'webinar';

-- RLS — THE security boundary for org webinars (frontend filtering is
-- presentation only; the webinar-url Edge Function re-checks through the
-- caller's RLS context).
--   • Lessons: visible to all authenticated members, exactly as before.
--   • Webinars: only when published AND (global OR the member's own org).
drop policy if exists content_items_readable on public.content_items;
create policy content_items_readable on public.content_items
  for select to authenticated
  using (
    kind = 'lesson'
    or (
      kind = 'webinar'
      and published = true
      and (
        org_id is null
        or org_id = (select p.org_id from public.profiles p where p.id = auth.uid())
      )
    )
  );

-- Admin manage surface (admin.html) creates/publishes webinar rows under
-- RLS with the existing is_admin() helper. Members still have no write path.
drop policy if exists content_items_admin_all on public.content_items;
create policy content_items_admin_all on public.content_items
  for all to authenticated
  using (is_admin())
  with check (is_admin());


-- ── 3. tool_usage_events: server-recorded meaningful tool usage ─
-- Written by tool pages on save/calculation-complete (never page open).
-- Deduping happens at evaluation/award time, not with unique constraints.

create table if not exists public.tool_usage_events (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  tool_key   text not null check (char_length(tool_key) between 1 and 60),
  event_type text not null default 'meaningful_use',
  created_at timestamptz not null default now()
);

create index if not exists tool_usage_events_user_time_idx
  on public.tool_usage_events (user_id, created_at);

alter table public.tool_usage_events enable row level security;

drop policy if exists tool_usage_own_insert on public.tool_usage_events;
create policy tool_usage_own_insert on public.tool_usage_events
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists tool_usage_own_read on public.tool_usage_events;
create policy tool_usage_own_read on public.tool_usage_events
  for select to authenticated
  using (user_id = auth.uid());


-- ── 4. video_watch_progress: server-side playback positions ─────
-- One row per (user, video). Fed only by record_video_progress()
-- (Batch 4, SECURITY DEFINER) — deliberately no INSERT/UPDATE policy.
-- Serves both LMS lessons (Learning credit) and webinars (resume only).

create table if not exists public.video_watch_progress (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references auth.users(id) on delete cascade,
  video_id             uuid not null references public.content_items(id) on delete cascade,
  max_position_seconds int not null default 0 check (max_position_seconds >= 0),
  duration_seconds     int check (duration_seconds > 0),
  completed_at         timestamptz,
  updated_at           timestamptz not null default now(),
  unique (user_id, video_id)
);

alter table public.video_watch_progress enable row level security;

drop policy if exists vwp_own_read on public.video_watch_progress;
create policy vwp_own_read on public.video_watch_progress
  for select to authenticated
  using (user_id = auth.uid());


-- ── 5. video_watch_credits: once-per-quarter Learning credit ────
-- The DB-level guarantee that a video earns Learning credit at most once
-- per member per quarter. Written only by record_video_progress().

create table if not exists public.video_watch_credits (
  user_id    uuid not null references auth.users(id) on delete cascade,
  video_id   uuid not null references public.content_items(id) on delete cascade,
  quarter    text not null check (quarter ~ '^[0-9]{4}-Q[1-4]$'),
  created_at timestamptz not null default now(),
  primary key (user_id, video_id, quarter)
);

alter table public.video_watch_credits enable row level security;

drop policy if exists vwc_own_read on public.video_watch_credits;
create policy vwc_own_read on public.video_watch_credits
  for select to authenticated
  using (user_id = auth.uid());


-- ── 6. threshold_config: adjustable qualification parameters ────
-- Changing a value is an UPDATE, never a migration. Points values stay in
-- points_catalog (the existing points-constants store — award_points()
-- reads it on every award); this table holds the structural thresholds.

create table if not exists public.threshold_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

insert into public.threshold_config (key, value) values
  ('sessions_attended_required',  '1'),
  ('learning_library_fraction',   '0.3333'),
  ('checkin_windows_required',    '6'),
  ('budget_months_required',      '3')
on conflict (key) do nothing;

alter table public.threshold_config enable row level security;

drop policy if exists threshold_config_readable on public.threshold_config;
create policy threshold_config_readable on public.threshold_config
  for select to authenticated using (true);
-- No write policy — staff-managed via SQL Editor, same as reward_thresholds.


-- ── 7. points_catalog: new quarterly-threshold event types ──────
-- All awards still flow through award_points() / the session_attended
-- trigger (Batch 5) — the client never supplies a points number.

insert into public.points_catalog (event_type, points, category) values
  ('budget_saved',     20, 'utilisation'),
  ('checkin_logged',   15, 'utilisation'),
  ('session_attended', 40, 'utilisation'),
  ('ef_tool_used',     25, 'utilisation'),
  ('tool_used',        10, 'utilisation')
on conflict (event_type) do nothing;

-- Locked points table: booking drops to the smaller award (attendance now
-- carries the larger one).
update public.points_catalog set points = 10 where event_type = 'session_booked';

-- Superseded event types — deactivated, not deleted (historical
-- points_events rows keep their FK target and their points):
--   monthly_checkin  → superseded by fortnight-window checkin_logged
--   tool_first_use   → superseded by meaningful-use ef_tool_used/tool_used
update public.points_catalog set active = false
  where event_type in ('monthly_checkin','tool_first_use');


-- ── 8. Webinar hosting ────────────────────────────────────────────
-- REVISED (2026-07-14, MD decision): webinars are hosted on VIMEO, not
-- Supabase Storage. No `webinars` bucket is created and no signed-URL
-- Edge Function is used. For kind='webinar' rows, `video_path` holds the
-- Vimeo reference ('<id>' or '<id>/<privacy-hash>' for unlisted videos).
-- The org boundary is unchanged: RLS on content_items (above) is what
-- keeps another org's Vimeo reference out of a member's hands, and the
-- Vimeo account must be set to hide videos from vimeo.com and restrict
-- embedding to the portal's domains (BUILD-NOTES manual step).


-- ── VERIFICATION CHECKLIST (run after applying) ──────────────────
-- 1. Lessons unaffected — as a logged-in member (browser console):
--      await sb.from('content_items').select('id,kind,published').eq('pathway_id',1);
--    Expect: 16 rows, all kind='lesson', published=true. Learn page renders
--    pathways exactly as before.
--
-- 2. RLS org scoping — seed one webinar for org A, one for org B, one with
--    org_id NULL (as admin or SQL Editor):
--      insert into content_items (title, kind, org_id, video_path, published)
--      values ('Test A', 'webinar', '<org-A-id>', 'test-a.mp4', true);
--    As a member of org A: sees Test A + NULL-org rows, never org B's.
--    As a member with org_id NULL: sees only NULL-org webinars.
--    Unpublished webinars: invisible to every member.
--
-- 3. Member write paths blocked (browser console as a member):
--      await sb.from('content_items').insert({title:'hack',kind:'webinar',video_path:'x'});
--      await sb.from('video_watch_progress').insert({user_id:'<self>',video_id:'<id>'});
--      await sb.from('video_watch_credits').insert({user_id:'<self>',video_id:'<id>',quarter:'2026-Q3'});
--      await sb.from('threshold_config').update({value:'99'}).eq('key','checkin_windows_required');
--    Expect: RLS error on all four.
--
-- 4. tool_usage_events member insert works for self, fails for others:
--      await sb.from('tool_usage_events').insert({user_id:'<self>',tool_key:'emergency_fund'});   -- ok
--      await sb.from('tool_usage_events').insert({user_id:'<someone-else>',tool_key:'x'});        -- RLS error
--
-- 5. threshold_config seeded:
--      select * from threshold_config order by key;   -- 4 rows, values as above
--
-- 6. Catalog:
--      select event_type, points, category, active from points_catalog order by event_type;
--    Expect: 5 new active utilisation rows; session_booked=10;
--    monthly_checkin + tool_first_use active=false; video_watched untouched (25).
--
-- 7. Vimeo scoping: as a member of org A, `select video_path from
--    content_items where kind='webinar'` returns only org A + NULL-org
--    rows — org B's Vimeo references are unreachable. On vimeo.com,
--    confirm a webinar link does NOT play when pasted into a browser
--    directly (privacy set to embed-only on allowed domains).
-- ─────────────────────────────────────────────────────────────────
