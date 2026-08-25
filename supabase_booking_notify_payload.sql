-- ============================================================
-- Key Wellness — booking_notify_payload()
-- Server-side resolution of "who gets notified about this booking".
--
-- Run in the Supabase SQL Editor BEFORE deploying the rewritten
-- send-booking-email Edge Function. Safe to re-run. Inert until called.
--
-- Rollback: migrations/rollback-booking-notify-payload.sql
-- ============================================================
--
-- WHY
--
-- send-booking-email took its recipient straight from the request body
-- (`to: [email]`) and never validated the caller's JWT. verify_jwt = true
-- looks like authentication but is not: it only proves the caller holds a
-- JWT signed with the project secret, and the published anon key is one.
-- Anyone who copied the anon key out of view-source could send mail from
-- Key Wellness <noreply@keywellness.co.bw> to any address they liked.
--
-- This function is the other half of the fix. The Edge Function stops
-- accepting a recipient and asks here instead, passing only a booking id.
--
-- TWO RULES IT ENFORCES
--
-- 1. AUTHORISATION. Only the member the booking belongs to, an advisor
--    entitled to it (can_manage_advisor covers team leads), or an admin
--    can trigger a notification for it. Reuses the existing gates rather
--    than restating them in TypeScript, so there is one definition.
--
-- 2. THE RECIPIENT IS DERIVED FROM IDENTITY, NEVER FROM INPUT. It comes
--    from auth.users for a member, or advisor_clients for a non-member
--    client — the same rule advisor_book_session() already applies when
--    it stamps bookings.user_email.
--
--    Note this deliberately does NOT trust bookings.user_email. A member
--    self-booking through index.html writes that column themselves, so it
--    is caller-supplied data one step removed. Reading auth.users instead
--    closes that path too. (bookings.user_email stays as the display
--    value the admin panel shows; it is simply not used to address mail.)
--
-- PHONE ACCOUNTS. Phone signups sit behind a synthetic, non-routable
-- address at @phone.keywellness.co.bw. Returning it would bounce every
-- time, so notify_email comes back null and the caller skips the send and
-- relies on the in-app notification — matching the existing behaviour for
-- members with no email.
-- ------------------------------------------------------------

create or replace function booking_notify_payload(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  b       bookings%rowtype;
  v_email text;
begin
  select * into b from bookings where id = p_booking_id;
  if b.id is null then
    raise exception 'booking not found';
  end if;

  -- Each arm is coalesced to false INDIVIDUALLY. Written as a bare
  -- `if not (A or B or C)`, an unauthenticated caller makes auth.uid()
  -- null, which makes A null and can_manage_advisor() null, so the whole
  -- expression is null -- and PL/pgSQL does not take an `if null` branch.
  -- The raise would be skipped and the payload returned. Caught in testing
  -- before deploy, against a live booking. Do not "simplify" this back.
  if not (
       coalesce(b.user_id = auth.uid(), false)
    or coalesce(can_manage_advisor(b.advisor_id), false)
    or coalesce(is_admin(), false)
  ) then
    raise exception 'not authorised';
  end if;

  if b.user_id is not null then
    select u.email into v_email from auth.users u where u.id = b.user_id;
  end if;
  if v_email is null and b.advisor_client_id is not null then
    select ac.email into v_email from advisor_clients ac where ac.id = b.advisor_client_id;
  end if;
  if v_email is not null
     and lower(v_email) like '%@phone.keywellness.co.bw' then
    v_email := null;
  end if;

  return jsonb_build_object(
    'booking_id',   b.id,
    'user_id',      b.user_id,
    'notify_email', v_email,
    'full_name',    coalesce(b.user_name, ''),
    'first_name',   split_part(coalesce(b.user_name, ''), ' ', 1),
    'phone',        (select p.phone from profiles p where p.id = b.user_id),
    'service',      coalesce(b.service, ''),
    'session_type', b.session_type,
    'session_mode', b.session_mode,
    'date',         b.requested_date,
    'time',         b.requested_time,
    'status',       b.status
  );
end;
$$;

-- Gated internally, so authenticated is the right grant. anon is revoked
-- because nothing unauthenticated has any business here — and because a
-- new function is executable by PUBLIC until told otherwise (see
-- CLAUDE.md, Roles & Interfaces).
revoke execute on function booking_notify_payload(uuid) from public, anon;
grant  execute on function booking_notify_payload(uuid) to authenticated;


-- ── Verification ─────────────────────────────────────────────
--
-- 1. Grants: anon false, authenticated true.
--   select has_function_privilege('anon','public.booking_notify_payload(uuid)','EXECUTE')          as anon_can,
--          has_function_privilege('authenticated','public.booking_notify_payload(uuid)','EXECUTE') as auth_can;
--
-- 2. A member gets their own booking, and is refused someone else's:
--   -- signed in as the member
--   select booking_notify_payload('<their booking id>');   -- expect payload
--   select booking_notify_payload('<another member''s>');  -- expect 'not authorised'
--
-- 3. notify_email is resolved, not echoed. Point a booking's user_email at
--    a throwaway address and confirm the payload still returns the address
--    on auth.users:
--   select b.user_email as stored, booking_notify_payload(b.id) ->> 'notify_email' as resolved
--     from bookings b where b.id = '<booking id>';
--
-- 4. A phone account yields null, so the caller skips the send:
--   select booking_notify_payload('<phone member booking>') ->> 'notify_email';  -- expect null
-- ============================================================
