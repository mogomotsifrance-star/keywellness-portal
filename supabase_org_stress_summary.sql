-- ============================================================
-- Key Wellness — org_stress_summary() RPC (Batch 1, Stress Card feature)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (CREATE OR REPLACE).
--
-- Purely additive: one new function. Nothing existing is altered.
-- Rollback (recorded in BUILD-NOTES.md before this file was run):
--   drop function if exists org_stress_summary(int);
--
-- Schema notes (full detail in BATCH-0-FINDINGS.md):
--   • Source is `stress_logs` (user_id, level, tags, notes, created_at) — fed by the
--     fortnightly Check-in flow in index.html (VIEWS['checkin']), NOT the
--     `financial_stress_tracker` tool's tool_data blob (a different, unrelated
--     stress signal on the OPPOSITE numeric scale — see BATCH-0-FINDINGS.md).
--   • level is 1-10 where LOWER = MORE stressed (1 = "Barely coping", 10 =
--     "Completely at ease" — index.html's stressLabel array). This RPC's bands
--     use the corrected direction: level <=3 = High, 4-6 = Moderate, >=7 = Low.
--     org_financial_indicators() (already shipped) has this backwards — a
--     separate, pre-existing bug, NOT fixed here (see BUILD-NOTES.md).
--   • tags is assumed to be a Postgres text[] (a fixed 8-value list defined in
--     index.html's STRESS_TAGS — not free text, so safe to surface as causes).
--     Verify the actual column type before running this file — see the
--     verification query at the bottom of this file. If it's jsonb instead,
--     swap unnest(sl.tags) for jsonb_array_elements_text(sl.tags) below.
--   • org_id does not exist on stress_logs directly — attaches via
--     profiles.org_id, joined on user_id (same pattern as
--     org_financial_indicators()).
--   • No employee/dependent distinction exists on stress_logs — dependents have
--     no login/profile in this schema, so no filter is needed or possible.
--
-- Structurally incapable of returning a per-member row: every value returned
-- is an aggregate (count/percentage) computed inside the function body. No
-- raw score, member id, or free-text field (notes) is ever selected into the
-- output.
-- ============================================================

create or replace function public.org_stress_summary(p_window_days int default 90)
returns json
language plpgsql security definer set search_path = public as $$
declare
  target_org      uuid;
  v_cohort_n      int;
  v_low_n         bigint;
  v_moderate_n    bigint;
  v_high_n        bigint;
  v_bands         json;
  v_causes        json;
begin
  -- ── Auth: HR only, own org, resolved server-side — never a caller-supplied
  --    org id (no target_org parameter exists on this function). ───────────
  target_org := employer_org();

  if target_org is null then
    raise exception 'not authorised';
  end if;

  -- ── Cohort + bands: latest check-in per member within the window, org
  --    members only. Same lateral-join-per-member pattern as
  --    org_financial_indicators() (repeated below for causes rather than
  --    cached in a temp table, matching that file's convention). ──────────
  with latest as (
    select m.id as user_id, c.level
    from (
      select p.id from profiles p where p.org_id = target_org
    ) m
    cross join lateral (
      select sl.level
      from stress_logs sl
      where sl.user_id = m.id
        and sl.created_at >= now() - (p_window_days || ' days')::interval
      order by sl.created_at desc
      limit 1
    ) c
  )
  select
    count(*),
    count(*) filter (where level >= 7),
    count(*) filter (where level between 4 and 6),
    count(*) filter (where level <= 3)
  into v_cohort_n, v_low_n, v_moderate_n, v_high_n
  from latest;

  -- ── Cohort guard: <5 distinct members → flag only, nothing else ──────────
  if v_cohort_n < 5 then
    return json_build_object('insufficient_cohort', true);
  end if;

  -- ── Bands (corrected direction — see header notes) ───────────────────────
  v_bands := json_build_object(
    'low',      json_build_object('count', _suppress_count(v_low_n),      'pct', _suppress_rate(v_low_n::int, v_cohort_n)),
    'moderate', json_build_object('count', _suppress_count(v_moderate_n), 'pct', _suppress_rate(v_moderate_n::int, v_cohort_n)),
    'high',     json_build_object('count', _suppress_count(v_high_n),     'pct', _suppress_rate(v_high_n::int, v_cohort_n))
  );

  -- ── Top 3 causes: count members (not check-ins) per cause, filter to
  --    count>=3 BEFORE ranking, so "fewer than 3 causes" happens by a cause
  --    not clearing the bar — never by ranking then blanking a slot. ───────
  with latest as (
    select m.id as user_id, c.tags
    from (
      select p.id from profiles p where p.org_id = target_org
    ) m
    cross join lateral (
      select sl.tags
      from stress_logs sl
      where sl.user_id = m.id
        and sl.created_at >= now() - (p_window_days || ' days')::interval
      order by sl.created_at desc
      limit 1
    ) c
  ),
  cause_counts as (
    select tag as cause, count(distinct user_id) as cnt
    from latest, unnest(tags) as tag
    group by tag
    having count(distinct user_id) >= 3
    order by count(distinct user_id) desc
    limit 3
  )
  select coalesce(json_agg(
    json_build_object(
      'cause',        cause,
      'member_count', _suppress_count(cnt),
      'pct',          _suppress_rate(cnt::int, v_cohort_n)
    ) order by cnt desc
  ), '[]'::json)
  into v_causes
  from cause_counts;

  return json_build_object(
    'insufficient_cohort', false,
    'cohort_size',         v_cohort_n,
    'window_days',         p_window_days,
    'bands',               v_bands,
    'top_causes',          v_causes
  );
end;
$$;

grant execute on function public.org_stress_summary(int) to authenticated;


-- ── VERIFICATION QUERIES ─────────────────────────────────────────
-- Run these in the Supabase SQL editor / via sb.rpc() in the browser console.

-- 0. FIRST — confirm tags is text[], not jsonb, before trusting this file's
--    unnest(sl.tags) call:
--    select column_name, data_type, udt_name
--    from information_schema.columns
--    where table_name = 'stress_logs' and column_name = 'tags';
--    Expect: data_type = 'ARRAY', udt_name = '_text'. If data_type = 'jsonb'
--    instead, replace `unnest(tags) as tag` above with
--    `jsonb_array_elements_text(tags) as tag` and re-run this file.

-- 1. As an HR user of an org with >=5 members who have checked in within the
--    default 90-day window — expect a full result:
--    await sb.rpc('org_stress_summary');
--    Confirm: no user_id, no raw `level`, no `notes` anywhere in the response.

-- 2. As an HR user of an org with <5 qualifying check-ins — expect ONLY:
--    { "insufficient_cohort": true }

-- 3. As a member (non-employer, non-admin) — expect an error:
--    await sb.rpc('org_stress_summary'); → "not authorised"

-- 4. Cross-org isolation — as employer of org A, confirm org B's data never
--    appears (cohort_size, bands, and causes should all reflect org A only).

-- 5. grep this file for the word "improvement" — expect zero matches.
