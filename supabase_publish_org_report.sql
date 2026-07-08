-- ============================================================
-- Key Wellness — Organisation Utilisation Report Pipeline
-- Batch 4: publish_org_report() RPC
-- Run this AFTER supabase_org_reports.sql (Batch 1) and
-- supabase_org_report_data.sql (Batch 2) in the Supabase SQL Editor.
-- Safe to re-run (CREATE OR REPLACE).
--
-- Design notes recorded in BUILD-NOTES.md ("Batch 4 — publish_org_report()
-- RPC + publish UI"). Rollback was recorded there before this file was
-- written.
-- ============================================================

create or replace function publish_org_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row      org_reports;
  v_snapshot jsonb;
begin
  if not is_admin() then
    raise exception 'not authorised';
  end if;

  select * into v_row from org_reports where id = p_report_id;
  if not found then
    raise exception 'report not found';
  end if;

  if v_row.status = 'published' then
    raise exception 'report is already published';
  end if;

  -- Reuse the exact same public RPC the builder preview already called,
  -- so the snapshot can never diverge from what the counsellor reviewed.
  v_snapshot := org_report_data(v_row.org_id, v_row.period_start, v_row.period_end);

  if coalesce((v_snapshot->>'insufficient_cohort')::boolean, false) then
    raise exception 'cannot publish: organisation has fewer than 5 enrolled members for this period';
  end if;

  update org_reports
  set data_snapshot = v_snapshot,
      status        = 'published',
      published_by  = auth.uid(),
      published_at  = now(),
      updated_at    = now()
  where id = p_report_id;
end;
$$;


-- ── VERIFICATION QUERIES ─────────────────────────────────────
-- Run these per Batch 4's checklist.

-- 1. Publish a real draft (as an admin/counsellor test account, via the
--    admin UI or directly):
--    select publish_org_report('<draft-report-id>');
--    then: select status, data_snapshot, published_at, published_by
--          from org_reports where id = '<draft-report-id>';
--    -- data_snapshot must match a fresh call to
--    -- org_report_data(org_id, period_start, period_end) for that report.

-- 2. Second publish attempt on the same report must fail visibly:
--    select publish_org_report('<same-report-id>');
--    -- expect: report is already published

-- 3. Publish attempt on a report whose org has < 5 members must fail:
--    -- expect: cannot publish: organisation has fewer than 5 enrolled members...

-- 4. Post-publish edit attempt (as the same admin, direct client update,
--    not via RPC) must be blocked by the Batch 1 RLS policy:
--    await window._toolSb.from('org_reports').update({ narrative: {} }).eq('id', '<same-report-id>');
--    -- expect { data: [], error: null } — 0 rows updated.

-- 5. Grep a real published snapshot case-insensitively for the banned
--    score-direction term from points_catalog (see BUILD-NOTES.md Batch
--    0/2): zero matches.

-- 6. Rollback: drop function if exists publish_org_report(uuid);
-- ─────────────────────────────────────────────────────────────
