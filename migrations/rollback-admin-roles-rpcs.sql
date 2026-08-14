-- ============================================================
-- ROLLBACK — supabase_admin_roles_rpcs.sql
-- Drops the Roles & Access RPCs. Data is untouched: any role rows
-- granted through the UI (admins / employers / hr_unit_scope) stay
-- exactly as they are — remove those by hand if they were mistakes.
-- The admin.html Roles tab will show its "run the SQL" notice again.
-- ============================================================

drop function if exists admin_roles_overview();
drop function if exists admin_role_grant_admin(text);
drop function if exists admin_role_revoke_admin(text);
drop function if exists admin_role_grant_hr(text, uuid, uuid);
drop function if exists admin_role_revoke_hr(uuid);
-- ============================================================
