-- ============================================================
-- ROLLBACK — Advisory Team Lead
-- Reverses supabase_advisor_team_lead.sql and restores the
-- single-advisor behaviour from supabase_advisor_rpcs.sql.
--
-- After running this, RE-APPLY supabase_advisor_rpcs.sql to put the
-- original advisor_clients_list / advisor_client_detail /
-- advisor_book_session / advisor_me / admin_advisor_roster bodies back.
-- ============================================================

-- ── Policies added by the team-lead migration ────────────────
drop policy if exists advisor_clients_lead_all    on advisor_clients;
drop policy if exists advisor_notes_lead_all      on advisor_notes;
drop policy if exists advisor_notes_on_my_client  on advisor_notes;
drop policy if exists bookings_lead_update        on bookings;

-- Restore the original booking select policy (owner + own clients only).
drop policy if exists bookings_advisor_select on bookings;
create policy bookings_advisor_select on bookings
  for select using (
    advisor_id = current_advisor_id()
    or exists (
      select 1 from advisor_clients ac
      where ac.advisor_id = current_advisor_id()
        and ac.member_user_id = bookings.user_id
    )
  );

-- ── RPCs ─────────────────────────────────────────────────────
-- The scoped two-argument list must go before the one-argument version
-- is restored, or calls become ambiguous.
drop function if exists advisor_clients_list(boolean, uuid);
drop function if exists advisor_caseload_summary();

-- ── Helpers (drop AFTER any policy that references them) ─────
drop function if exists can_manage_advisor(uuid);
drop function if exists is_team_lead();

-- ── The flag ─────────────────────────────────────────────────
-- Kept by default — dropping it loses who was appointed. Uncomment
-- only if you are certain.
-- alter table advisors drop column if exists is_team_lead;

-- ── Now re-run supabase_advisor_rpcs.sql ─────────────────────
