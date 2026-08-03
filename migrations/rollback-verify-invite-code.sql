-- ============================================================
-- ROLLBACK — verify_invite_code()
-- Reverses supabase_verify_invite_code.sql. Safe: the Batch 2 signup frontend
-- calls this RPC inside a try/catch and falls back to the signup trigger's own
-- code resolution if it is absent, so dropping it never breaks signup.
-- ============================================================
drop function if exists verify_invite_code(text);
-- ============================================================
