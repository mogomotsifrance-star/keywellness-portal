-- ============================================================
-- ROLLBACK — supabase_admin_depts_rpcs.sql
-- Drops the Departments RPCs. Data is untouched: unit_departments rows
-- and profiles.department_id stay exactly as they are. The Departments
-- sub-tab shows its "run the SQL" notice again, and department lists go
-- back to being maintained with SQL.
--
-- NOT undone by this file (they are ordinary data changes, so reverse
-- them by hand if the whole batch is being abandoned):
--   • departments added or renamed through the UI
--   • members moved by admin_dept_reassign_members() — including any
--     moved to Unassigned (department_id set to NULL), which cannot be
--     reconstructed from this file alone
--   • sort_order renumbered in 10s inside any unit that was reordered
--
-- Note: unit_departments also carries a unit_departments_admin_all RLS
-- policy that predates these functions, so an admin can still write to
-- the table directly after this rollback — without the case-insensitive
-- duplicate guard, the parent-company reporting warning or the
-- strand-the-members warning the RPCs applied.
-- ============================================================

drop function if exists admin_depts_overview(uuid);
drop function if exists admin_dept_add(uuid, text[]);
drop function if exists admin_dept_copy_from(uuid, uuid);
drop function if exists admin_dept_rename(uuid, text);
drop function if exists admin_dept_set_active(uuid, boolean);
drop function if exists admin_dept_move(uuid, text);
drop function if exists admin_dept_reassign_members(uuid, uuid);
drop function if exists admin_dept_delete(uuid);
-- ============================================================
