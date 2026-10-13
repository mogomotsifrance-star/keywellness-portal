-- Rollback: supabase_document_access_log.sql (13 Oct 2026)
-- ============================================================
-- Runs through the Supabase MCP tool (no DROP). Written BEFORE the
-- migration was applied.
--
-- Effect: nobody can write a log row any more. The page's View and
-- Download buttons then fail closed with "Could not record access", so
-- revert the advisor.html commit FIRST (the old Download link needs no RPC).
--
-- KEEPS the table and every row in it: it is the record of who opened which
-- member document. For full removal, run cleanup-document-access-log.sql in
-- the SQL editor once that record is no longer wanted.
-- ============================================================
revoke execute on function public.log_document_access(uuid, text, text) from public, anon, authenticated;

-- Verify:
-- select has_function_privilege('authenticated','public.log_document_access(uuid,text,text)','EXECUTE');  -- false
