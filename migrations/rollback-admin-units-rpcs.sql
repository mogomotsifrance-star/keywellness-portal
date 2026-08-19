-- ============================================================
-- ROLLBACK — supabase_admin_units_rpcs.sql
-- Drops the Companies & Sites RPCs. Data is untouched: org_units,
-- profiles.org_unit_id, unit_departments and hr_unit_scope stay exactly
-- as they are — undo any structural change by hand if it was a mistake.
-- The Companies & Sites sub-tab shows its "run the SQL" notice again,
-- and the structure goes back to being maintained with SQL.
--
-- Note: org_units also has an org_units_admin_all RLS policy that
-- predates these functions, so an admin can still write to the table
-- directly after this rollback — without the two-level, leaf and
-- cascade guards the RPCs applied.
-- ============================================================

drop function if exists admin_units_overview(uuid);
drop function if exists admin_unit_create(uuid, text, uuid);
drop function if exists admin_unit_update(uuid, text, uuid);
drop function if exists admin_unit_set_active(uuid, boolean);
drop function if exists admin_unit_move(uuid, text);
drop function if exists admin_unit_delete(uuid);
drop function if exists admin_unit_has_dependents(uuid);
-- ============================================================
