-- Rollback: supabase_advisor_clients_member_read_off.sql (14 Oct 2026)
-- ============================================================
-- Written BEFORE the change was applied. Restores the exact policy text that
-- was live on 14 Oct 2026, read from pg_policies:
--   advisor_clients_member_read  FOR SELECT  TO public  USING ((member_user_id = auth.uid()))
-- Runs through the Supabase MCP tool (no DROP).
--
-- Effect: a member linked to a client record can again read that whole
-- advisor_clients row (advisor notes, figures, documents).
-- ============================================================
alter policy advisor_clients_member_read on public.advisor_clients
  using ((member_user_id = auth.uid()));

comment on policy advisor_clients_member_read on public.advisor_clients is null;

-- Verify:
-- select qual from pg_policies where tablename = 'advisor_clients' and policyname = 'advisor_clients_member_read';
--   -> (member_user_id = auth.uid())
