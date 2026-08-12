-- ============================================================
-- ROLLBACK — Advisor Portal
-- Reverses supabase_advisor_portal.sql + supabase_advisor_rpcs.sql
--
-- ⚠ DESTRUCTIVE. Dropping advisor_clients / advisor_notes loses all
--   advisor caseload data and working notes. Take a backup first:
--
--     create table _bk_advisor_clients as select * from advisor_clients;
--     create table _bk_advisor_notes   as select * from advisor_notes;
--     create table _bk_advisors        as select * from advisors;
--
-- Bookings created by advisors are NOT deleted — they are real sessions
-- and stay in org utilisation reporting. Only the advisor linkage columns
-- are dropped, which reverts those rows to looking self-booked.
-- ============================================================

-- ── RPCs ─────────────────────────────────────────────────────
drop function if exists admin_advisor_roster();
drop function if exists session_source_trend(uuid, date, date);
drop function if exists advisor_session_breakdown(uuid, date, date);
drop function if exists admin_assign_client(uuid, uuid);
drop function if exists member_respond_booking(uuid, text, text);
drop function if exists advisor_book_session(uuid, text, text, date, text, text, text);
drop function if exists advisor_add_member_client(uuid);
drop function if exists advisor_search_members(text);
drop function if exists advisor_client_detail(uuid);
drop function if exists advisor_clients_list(boolean);
drop function if exists advisor_me();

-- ── Policies ─────────────────────────────────────────────────
-- ALL policies must go before any table or column they reference.
-- advisors_member_read reads bookings.advisor_id, and bookings_advisor_select
-- reads advisor_clients — so dropping columns or tables first fails with
-- "cannot drop ... because other objects depend on it".
drop policy if exists bookings_advisor_select  on bookings;
drop policy if exists bookings_advisor_insert  on bookings;
drop policy if exists bookings_advisor_update  on bookings;
drop policy if exists bookings_member_respond  on bookings;

drop policy if exists advisors_admin_all       on advisors;
drop policy if exists advisors_self_read       on advisors;
drop policy if exists advisors_self_update     on advisors;
drop policy if exists advisors_member_read     on advisors;

drop policy if exists advisor_clients_admin_all   on advisor_clients;
drop policy if exists advisor_clients_own         on advisor_clients;
drop policy if exists advisor_clients_own_insert  on advisor_clients;
drop policy if exists advisor_clients_own_update  on advisor_clients;
drop policy if exists advisor_clients_own_delete  on advisor_clients;
drop policy if exists advisor_clients_member_read on advisor_clients;

drop policy if exists advisor_notes_admin_all on advisor_notes;
drop policy if exists advisor_notes_own       on advisor_notes;

-- ── Triggers ─────────────────────────────────────────────────
drop trigger  if exists trg_link_advisor_clients on auth.users;
drop trigger  if exists trg_backfill_advisor     on auth.users;
drop trigger  if exists trg_link_advisor_client  on advisor_clients;
drop function if exists link_advisor_clients_on_signup();
drop function if exists link_advisor_client_on_insert();
drop function if exists backfill_advisor_user_id();

-- ── Booking columns ──────────────────────────────────────────
alter table bookings drop constraint if exists bookings_booked_by_chk;
alter table bookings drop constraint if exists bookings_member_response_chk;

alter table bookings
  drop column if exists advisor_id,
  drop column if exists advisor_client_id,
  drop column if exists booked_by,
  drop column if exists member_response,
  drop column if exists member_response_at,
  drop column if exists member_response_note,
  drop column if exists advisor_seen_response;

-- ── Tables ───────────────────────────────────────────────────
drop table if exists advisor_notes;
drop table if exists advisor_clients;
drop table if exists advisors;

-- ── Role helpers (drop AFTER everything that references them) ──
drop function if exists is_advisor();
drop function if exists current_advisor_id();

-- ── Member consent column ────────────────────────────────────
-- Kept by default: dropping it loses a record of consent the member gave.
-- Uncomment only if you are certain.
-- alter table profiles
--   drop column if exists advisor_data_consent,
--   drop column if exists advisor_data_consent_at;
