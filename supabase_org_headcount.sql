-- ============================================================
-- Key Wellness — Employer-managed Headcount (Rewards-reshape Batch 7)
-- Run this in the Supabase SQL Editor (dashboard → SQL Editor)
-- Run once; safe to re-run (CREATE TABLE IF NOT EXISTS, CREATE OR
-- REPLACE FUNCTION).
--
-- org_headcount_reports was already created by supabase_rewards_reshape.sql
-- (Batch 4) — re-declared here IF NOT EXISTS so this file is
-- self-contained.
--
-- Design: append-only log, not an editable column. "Current" headcount is
-- the latest row by created_at — so past quarters keep their own
-- denominator for reporting, and every change is auditable. The UI (Batch
-- 6's season-summary header in employer.html) makes this feel like a
-- simple edit even though each save appends a new row.
--
-- GUARD RULE: reported_headcount is self-reported and unverified. It is
-- used ONLY as a display denominator (activation % in org_rewards_summary,
-- Batch 4). It must NEVER feed the ≥5 cohort guard, cell suppression, or
-- any privacy logic — those stay pegged to actual registered/assessed
-- member counts (profiles/assessments row counts). Confirmed by grep: no
-- reference to org_headcount_reports exists in org_overview(),
-- org_financial_indicators(), or any suppression logic in this codebase.
--
-- Per-department headcounts: explicitly out of scope, deferred until a
-- client requests department breakdowns.
-- ============================================================

create table if not exists public.org_headcount_reports (
  id bigint generated always as identity primary key,
  org_id uuid not null references public.organizations(id),
  headcount int not null check (headcount > 0 and headcount < 1000000),
  reported_by uuid not null,
  created_at timestamptz not null default now()
);

alter table public.org_headcount_reports enable row level security;
-- No policies for authenticated. Reads arrive via org_rewards_summary
-- (supabase_rewards_reshape.sql); writes only via set_org_headcount() below.


-- ── set_org_headcount() ─────────────────────────────────────────
-- Employer path: ALWAYS resolves and uses the caller's own org via
-- employer_org() — any p_org_id they pass is ignored. This is the guard
-- against an employer of org A setting org B's headcount even by supplying
-- org B's uuid.
-- Admin path: is_admin() staff may set it on a client's behalf during
-- onboarding, but MUST supply an explicit p_org_id (no ambiguous default).

create or replace function public.set_org_headcount(p_headcount int, p_org_id uuid default null)
returns table (
  id           bigint,
  org_id       uuid,
  headcount    int,
  reported_by  uuid,
  created_at   timestamptz
)
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid;
  v_row org_headcount_reports%rowtype;
begin
  if p_headcount is null or p_headcount <= 0 or p_headcount >= 1000000 then
    raise exception 'headcount must be a whole number greater than 0';
  end if;

  if is_admin() then
    if p_org_id is null then
      raise exception 'p_org_id is required for admin callers';
    end if;
    v_org := p_org_id;
  else
    v_org := employer_org();
    if v_org is null then
      raise exception 'not authorised';
    end if;
  end if;

  insert into org_headcount_reports (org_id, headcount, reported_by)
  values (v_org, p_headcount, auth.uid())
  returning * into v_row;

  return query select v_row.id, v_row.org_id, v_row.headcount, v_row.reported_by, v_row.created_at;
end;
$$;

grant execute on function public.set_org_headcount(int, uuid) to authenticated;


-- ── VERIFICATION QUERIES ─────────────────────────────────────────
-- Run these as real users via the browser console (window._toolSb.rpc(...)).

-- 1. Direct client insert fails (no policies on org_headcount_reports):
--    await window._toolSb.from('org_headcount_reports').insert({org_id:'...',headcount:100,reported_by:'...'});
--    Expect: an error, no row inserted.

-- 2. Employer sets and updates headcount — each update creates a NEW row:
--    await window._toolSb.rpc('set_org_headcount', { p_headcount: 1240 });
--    await window._toolSb.rpc('set_org_headcount', { p_headcount: 1255 });
--    select count(*) from org_headcount_reports where org_id = '<that org>';  -- expect >= 2
--    Confirm org_rewards_summary().reported_headcount reflects the LATEST
--    value (1255) and reported_headcount_updated_at is the second call's time.

-- 3. Non-employer, non-admin caller rejected:
--    await window._toolSb.rpc('set_org_headcount', { p_headcount: 100 });
--    Expect: "not authorised".
--    Admin without p_org_id: expect "p_org_id is required for admin callers".
--    Admin with p_org_id: succeeds for the specified org.

-- 4. Cross-org isolation — as employer of org A:
--    await window._toolSb.rpc('set_org_headcount', { p_headcount: 999, p_org_id: '<org-B-uuid>' });
--    Expect: the row is still written against org A (p_org_id is ignored for
--    employer callers), NOT org B. Verify via
--    select org_id from org_headcount_reports order by created_at desc limit 1;

-- 5. No headcount reported yet — org_rewards_summary().reported_headcount is
--    null; the Rewards tab's participation strip degrades to the
--    registered/opted-in copy and shows the "add headcount" prompt (Batch 6).

-- 6. Grep confirmation — headcount must never leak into privacy-sensitive logic:
--    grep -n "org_headcount_reports" supabase_*.sql
--    Expect: only appears in this file and supabase_rewards_reshape.sql
--    (org_rewards_summary's reported_headcount field). Never in
--    supabase_financial_indicators.sql or supabase_multitenancy.sql's
--    cohort-guard logic.
-- ─────────────────────────────────────────────────────────────
