-- ============================================================
-- ROLLBACK — supabase_admin_orgs_rpcs.sql
-- Drops the Organisations tab RPCs. Data is untouched: any
-- organisation created through the UI stays exactly as it is —
-- remove those by hand if they were mistakes.
-- The admin.html Organisations tab will show its "run the SQL"
-- notice again, and new organisations go back to being created
-- with an INSERT in the Supabase SQL Editor.
-- ============================================================

drop function if exists admin_orgs_overview();
drop function if exists admin_org_suggest_code(text);
drop function if exists admin_org_create(text, text, text, text);
drop function if exists admin_org_update(uuid, text, text, text, text, boolean);
drop function if exists admin_org_set_active(uuid, boolean);
drop function if exists admin_org_delete(uuid);
drop function if exists admin_org_has_dependents(uuid);
-- ============================================================
