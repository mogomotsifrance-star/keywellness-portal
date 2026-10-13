-- Full removal: supabase_document_access_log.sql (13 Oct 2026)
-- ============================================================
-- SQL EDITOR ONLY (the MCP tool cannot run DROP). Run rollback-document-access-log.sql
-- and revert the advisor.html commit first.
--
-- This DELETES the access record. Export it first if it may be needed:
--   select * from public.document_access_log order by created_at;
-- ============================================================
drop function if exists public.log_document_access(uuid, text, text);
drop table if exists public.document_access_log;           -- its triggers go with it
drop function if exists public.document_access_log_immutable();

-- Verify: both return null
-- select to_regclass('public.document_access_log');
-- select to_regprocedure('public.log_document_access(uuid,text,text)');
