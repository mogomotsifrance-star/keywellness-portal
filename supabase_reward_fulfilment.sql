-- ============================================================
-- Key Wellness — HR Reward Fulfilment RPCs (Rewards-reshape Batch 5)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (CREATE TABLE IF NOT EXISTS, CREATE OR
-- REPLACE FUNCTION).
--
-- reward_fulfilments was already created by supabase_rewards_reshape.sql
-- (Batch 4) — re-declared here IF NOT EXISTS so this file is
-- self-contained. No direct policies exist for authenticated; all reads
-- and writes go through the two RPCs below.
-- ============================================================

create table if not exists public.reward_fulfilments (
  id bigint generated always as identity primary key,
  org_id uuid not null references public.organizations(id),
  user_id uuid not null references auth.users(id),
  season text not null,
  category text not null check (category in ('utilisation','learning','progress','overall')),
  note text check (char_length(note) <= 200),
  fulfilled_by uuid not null,
  created_at timestamptz not null default now(),
  unique (org_id, user_id, season, category)
);

alter table public.reward_fulfilments enable row level security;


-- ── record_reward_fulfilment() ──────────────────────────────────
-- Employer-only (mirrors org_overview()'s gate, but resolved via
-- employer_org() with no org-param override — this is a narrow write
-- path, not requested to support an admin-on-behalf-of flow). Validates
-- the target user belongs to the caller's org, is opted in, and (for
-- category rewards, not 'overall') is CURRENTLY qualified in that
-- category for that season before allowing the write.
-- Idempotent via the unique constraint — a double-click returns
-- recorded:false with the already-existing row, not an error.

-- Root-cause fix for the "column reference ... is ambiguous" (42702) error
-- that kept resurfacing here: the previous RETURNS TABLE named its OUT
-- columns org_id/user_id/season/category — the SAME names as real columns
-- on reward_fulfilments — so PL/pgSQL's implicit OUT-parameter variables
-- were ambiguous against those table columns wherever referenced, in ways
-- that kept slipping past manual re-qualification (Postgres's own "cannot
-- change return type" error path meant a clean drop was never forced, so
-- earlier fixes kept fighting the same class of collision instead of
-- removing it). Since employer.html's confirmReward() never reads the
-- returned row by field name (it only checks `error`), the row is returned
-- as a single composite column instead — this makes the collision
-- structurally impossible rather than merely avoided.
drop function if exists public.record_reward_fulfilment(uuid, text, text, text);

create or replace function public.record_reward_fulfilment(
  p_user_id uuid,
  p_season text,
  p_category text,
  p_note text default null
)
returns table (
  recorded   boolean,
  fulfilment reward_fulfilments
)
language plpgsql security definer set search_path = public as $$
declare
  v_org                 uuid;
  v_target_org          uuid;
  v_opted_in            boolean;
  v_joined_at           timestamptz;
  v_points              bigint;
  v_first_season_points int;
  v_returning_points    int;
  v_is_first_season     boolean;
  v_qualified           boolean;
  v_row                 reward_fulfilments%rowtype;
  v_recorded            boolean;
begin
  v_org := employer_org();
  if v_org is null then
    raise exception 'not authorised';
  end if;

  if p_category not in ('utilisation','learning','progress','overall') then
    raise exception 'invalid category: %', p_category;
  end if;

  if p_note is not null and char_length(p_note) > 200 then
    raise exception 'note too long (max 200 characters)';
  end if;

  select p.org_id, p.leaderboard_opt_in, u.created_at
  into v_target_org, v_opted_in, v_joined_at
  from profiles p
  join auth.users u on u.id = p.id
  where p.id = p_user_id;

  if v_target_org is null or v_target_org <> v_org then
    raise exception 'member does not belong to your organisation';
  end if;

  if not coalesce(v_opted_in, false) then
    raise exception 'member has not opted in to share rewards data';
  end if;

  -- 'overall' (top-N headline prizes) has no per-category qualification bar.
  if p_category <> 'overall' then
    select coalesce(sum(pe.points), 0) into v_points
    from points_events pe
    join points_catalog pc on pc.event_type = pe.event_type
    where pe.user_id = p_user_id
      and pe.season = p_season and pe.season <> 'legacy'
      and pc.category = p_category;

    select rt.first_season_points, rt.returning_points
    into v_first_season_points, v_returning_points
    from reward_thresholds rt where rt.category = p_category;

    v_is_first_season := (to_char(v_joined_at, 'YYYY"-Q"Q') = to_char(now(), 'YYYY"-Q"Q'));
    v_qualified := v_points >= (case when v_is_first_season
                                      then v_first_season_points
                                      else v_returning_points end);

    if not v_qualified then
      raise exception 'member is not currently qualified in category: %', p_category;
    end if;
  end if;

  insert into reward_fulfilments as rf (org_id, user_id, season, category, note, fulfilled_by)
  values (v_org, p_user_id, p_season, p_category, p_note, auth.uid())
  on conflict (org_id, user_id, season, category) do nothing
  returning rf.* into v_row;

  if v_row.id is null then
    -- Already recorded — idempotent no-op, return the existing row.
    v_recorded := false;
    select rf2.* into v_row from reward_fulfilments rf2
    where rf2.org_id = v_org and rf2.user_id = p_user_id and rf2.season = p_season and rf2.category = p_category;
  else
    v_recorded := true;
  end if;

  return query select v_recorded, v_row;
end;
$$;

grant execute on function public.record_reward_fulfilment(uuid, text, text, text) to authenticated;


-- ── org_reward_history() ────────────────────────────────────────
-- Employer-only, same narrow gate as above. All seasons if p_season is null.

create or replace function public.org_reward_history(p_season text default null)
returns table (
  first_name   text,
  last_name    text,
  email        text,
  category     text,
  note         text,
  season       text,
  fulfilled_at timestamptz
)
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid;
begin
  v_org := employer_org();
  if v_org is null then
    raise exception 'not authorised';
  end if;

  return query
  -- auth.users.email is character varying(255); the RETURNS TABLE declares
  -- email as text — cast explicitly (see org_rewards() for the same fix and
  -- full explanation).
  select p.first_name, p.last_name, u.email::text as email, rf.category, rf.note, rf.season, rf.created_at
  from reward_fulfilments rf
  join profiles p on p.id = rf.user_id
  join auth.users u on u.id = p.id
  where rf.org_id = v_org
    and (p_season is null or rf.season = p_season)
  order by rf.created_at desc;
end;
$$;

grant execute on function public.org_reward_history(text) to authenticated;


-- ── VERIFICATION QUERIES ─────────────────────────────────────────
-- Run these as real users via the browser console — while on employer.html
-- (HR/employer login), typing `sb.rpc(...)` directly (sb is a page-level
-- const, not window._toolSb — that only exists on the standalone tool pages).

-- 1. Direct client insert fails (no policies on reward_fulfilments):
--    await sb.from('reward_fulfilments').insert({org_id:'...',user_id:'...',season:'2026-Q3',category:'utilisation',fulfilled_by:'...'});
--    Expect: an error, no row inserted.

-- 2. Non-qualified / non-opted-in member rejected:
--    As the employer, call record_reward_fulfilment for a member who is
--    below the category threshold, or not opted in — expect an exception,
--    no row inserted.

-- 3. Idempotent double-click (data[0].fulfilment holds the row; recorded
--    flags which call actually inserted it):
--    const a = await sb.rpc('record_reward_fulfilment', {p_user_id:'...', p_season:'2026-Q3', p_category:'utilisation', p_note:'P500 voucher'});
--    const b = await sb.rpc('record_reward_fulfilment', {p_user_id:'...', p_season:'2026-Q3', p_category:'utilisation', p_note:'P500 voucher'});
--    Expect: a.data[0].recorded === true; b.data[0].recorded === false; both
--    a.data[0].fulfilment.id and b.data[0].fulfilment.id are the SAME id —
--    confirm via
--    `select count(*) from reward_fulfilments where user_id='...' and category='utilisation' and season='2026-Q3';` → 1.

-- 4. Cross-org isolation — as employer of org A, call org_reward_history();
--    confirm no org B fulfilments appear. As a member (non-employer):
--    await sb.rpc('org_reward_history'); expect "not authorised".
-- ─────────────────────────────────────────────────────────────
