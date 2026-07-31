-- ============================================================
-- Key Wellness — Company Units, Batch 3a: HR unit-scope helpers
-- Run in the Supabase SQL Editor AFTER supabase_org_units.sql (Batch 1).
-- Safe to re-run (CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS).
--
-- PRODUCTION-LIVE on apply, but behaviour-neutral until an hr_unit_scope
-- row with a non-null unit_id exists: every resolver below returns NULL
-- ("whole-org, no narrowing") for admins and for existing whole-org
-- employers, so org_overview / org_financial_indicators / org_report_data
-- keep their current output until a company manager is actually seeded.
--
-- ROLLBACK: migrations/rollback-org-units-batch3.sql
-- ============================================================


-- ── 1. Descendants of a unit (inclusive) ─────────────────────
-- Debswana -> {Debswana, Jwaneng, Orapa, DCC}; a leaf -> {itself}.
-- Members only ever hold leaf units, so including the parent id is
-- harmless; it keeps the set correct if that ever changes.
create or replace function unit_descendants(p_unit_id uuid)
returns table(id uuid)
language sql stable set search_path = public as $$
  with recursive tree as (
    select ou.id from org_units ou where ou.id = p_unit_id
    union all
    select c.id from org_units c join tree t on c.parent_unit_id = t.id
  )
  select id from tree;
$$;


-- ── 2. Caller's scope, as a unit-id array (or NULL = whole org) ──
-- Resolution, in order:
--   • no hr_unit_scope row for the caller            -> NULL  (admins, existing
--                                                       whole-org employers)
--   • a row with unit_id NULL (fund Wellness Manager) -> NULL  (whole org)
--   • a row with unit_id set (company / Debswana mgr) -> that unit + descendants
-- A whole-org row always wins over a unit row for the same caller, so a
-- fund manager is never accidentally narrowed.
--
-- SECURITY DEFINER + STABLE: reads hr_unit_scope (members have no access to
-- it) and is evaluated once per statement.
create or replace function hr_scoped_unit_ids()
returns uuid[]
language plpgsql security definer stable set search_path = public as $$
declare
  v_unit uuid;
  v_ids  uuid[];
  v_found boolean := false;
begin
  select unit_id, true into v_unit, v_found
  from hr_unit_scope
  where hr_user_id = auth.uid()
     or lower(hr_email) = lower(auth.jwt() ->> 'email')
  order by (unit_id is null) desc   -- whole-org row first
  limit 1;

  if not v_found then return null; end if;   -- no scope row -> whole org
  if v_unit is null then return null; end if; -- explicit whole-org scope

  select array_agg(d.id) into v_ids from unit_descendants(v_unit) d;
  return v_ids;
end;
$$;

revoke all on function hr_scoped_unit_ids() from public, anon;
grant execute on function hr_scoped_unit_ids() to authenticated;
grant execute on function unit_descendants(uuid) to authenticated;


-- ── 3. Validate a client-supplied unit against the caller's scope ──
-- Used by the report builder's 4-arg org_report_data overload so a company
-- manager can never retrieve another company's data by forging p_unit_id.
--   • admin                         -> any unit belonging to p_org_id
--   • whole-org scope (fund/legacy) -> any unit belonging to p_org_id
--   • unit scope U                  -> only U or a descendant of U
-- Returns true if allowed. p_unit_id NULL (whole-org request) is validated
-- separately by the caller (only admins / whole-org scope may request it).
create or replace function hr_unit_in_scope(p_org_id uuid, p_unit_id uuid)
returns boolean
language plpgsql security definer stable set search_path = public as $$
declare
  v_scope uuid[];
  v_belongs boolean;
begin
  -- Unit must belong to the org in question.
  select exists(select 1 from org_units where id = p_unit_id and org_id = p_org_id)
    into v_belongs;
  if not v_belongs then return false; end if;

  if is_admin() then return true; end if;

  v_scope := hr_scoped_unit_ids();
  if v_scope is null then
    -- whole-org scope: any unit in the org is allowed, but the caller must
    -- actually be an employer of this org.
    return coalesce(employer_org() = p_org_id, false);
  end if;

  return p_unit_id = any(v_scope);
end;
$$;

revoke all on function hr_unit_in_scope(uuid, uuid) from public, anon;
grant execute on function hr_unit_in_scope(uuid, uuid) to authenticated;


-- ── 4. org_reports gains a unit dimension (additive) ─────────
-- NULL = whole-org report (fund manager / current behaviour). A published
-- snapshot now records which company scope it covers.
alter table org_reports
  add column if not exists unit_id uuid references org_units(id);

create index if not exists org_reports_unit_idx on org_reports(unit_id);


-- ── VERIFICATION ─────────────────────────────────────────────
-- 1. Descendants:
--    select name from org_units where id in (
--      select id from unit_descendants(
--        (select id from org_units where name='Debswana'
--          and org_id=(select id from organizations where name ilike '%sedimosa%'))));
--    -- expect: Debswana, Jwaneng, Orapa, DCC

-- 2. Resolver is behaviour-neutral for a normal employer (browser console,
--    logged in as an existing whole-org HR account):
--    await sb.rpc('hr_scoped_unit_ids');   -- expect null

-- 3. org_reports.unit_id exists:
--    select column_name from information_schema.columns
--    where table_name='org_reports' and column_name='unit_id';
-- ============================================================
