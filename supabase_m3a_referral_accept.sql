-- ============================================================
-- Key Wellness — M3a: the referral accept flow
--
-- Run AFTER M3 Parts 1 and 2. Idempotent — safe to re-run.
-- Rollback: migrations/rollback-m3a-referral-accept.sql
-- Tests:    tests/m3-tests.sql (assertions 40–49)
--
-- ══ WHAT THIS IS FOR, IN PLAIN LANGUAGE ════════════════════
--
-- Karabo refers a client to Nicola. Nicola accepts. From that moment Nicola
-- is the client's counsellor for everything that happens NEXT.
--
-- What does NOT happen is the important half:
--
--   Nicola does not gain access to anything Karabo already wrote.
--   Not Karabo's notes, not Karabo's bookings, not Karabo's caseload row.
--   Not before the referral, not after accepting it, not ever.
--
--   INFORMATION FLOWS FORWARD, NEVER ACCESS BACKWARD.
--
-- The only thing that crosses is the handover note the referring counsellor
-- WROTE ON PURPOSE for this referral — a separately authored artefact, not a
-- window into the originals.
--
-- ══ HOW THAT IS MADE STRUCTURAL RATHER THAN REMEMBERED ═════
--
-- counsellor_clients is NOT repointed. There is no mutable counsellor_id to
-- update. Accepting:
--
--   1. CLOSES Karabo's link   (is_active = false, ended_at = now())
--   2. OPENS a new link for Nicola, copying the client's IDENTITY only —
--      name, contact, organisation, member id. Never a note, never a booking.
--
-- Karabo's old row and everything hanging off it stay Karabo's BECAUSE THEY
-- ARE STILL THE SAME ROWS. Nothing had to remember not to update them. That
-- is the difference between a guarantee and a convention.
--
-- Existing bookings keep pointing at Karabo's link and Karabo, so Nicola
-- cannot read them. That is not an oversight to fix later; it is the
-- behaviour.
--
-- ══ WHY THIS IS SECURITY DEFINER, AND WHAT GATES IT ════════
--
-- Accepting has to CLOSE A ROW THAT BELONGS TO THE REFERRING COUNSELLOR, and
-- counsellor_clients_own will not let Nicola touch Karabo's row. So the
-- function runs as the owner and gates itself:
--
--   only the counsellor named as to_counsellor_id may accept.
--
-- Not the referrer, not an admin, not a psychosocial admin. Lone can see THAT
-- a referral happened; she cannot accept one on anybody's behalf, because
-- accepting is a clinical decision about taking a case.
--
-- ══ WHAT WILL CHANGE, AND WHAT WILL NOT ════════════════════
--
--   CHANGES: one new function. No table, no column, no policy.
--   DOES NOT CHANGE: no existing row, no existing access. Until someone calls
--   it, nothing about this migration is observable.
--
--   IF IT IS WRONG: the realistic failure is a referral that cannot be
--   accepted, which is visible and harmless. The dangerous failure would be
--   accepting granting backward access, and assertions 44–46 exist to catch
--   exactly that.
-- ============================================================


-- ── 1. referral_accept() ────────────────────────────────────

create or replace function referral_accept(p_referral_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  r        counselling_referrals%rowtype;
  old_link counsellor_clients%rowtype;
  v_me     uuid := current_counsellor_id();
  v_new    uuid;
  v_now    timestamptz := now();
begin
  if v_me is null then
    raise exception 'only a counsellor can accept a referral';
  end if;

  select * into r from counselling_referrals where id = p_referral_id;
  if not found then raise exception 'no such referral'; end if;

  -- ONLY THE RECEIVING COUNSELLOR. Deliberately not the referrer and not an
  -- admin: taking on a case is a clinical decision, not an administrative one.
  if r.to_counsellor_id <> v_me then
    raise exception 'only the counsellor a referral was sent to can accept it';
  end if;

  -- Accepting twice is somebody checking, not an error — the same reading of
  -- how people work that handover_confirm_invoiced uses. It must NOT open a
  -- second link.
  if r.accepted_at is not null then
    return jsonb_build_object(
      'referral_id', r.id, 'already_accepted', true,
      'accepted_at', r.accepted_at,
      'link_id', (select cc.id from counsellor_clients cc
                   where cc.counsellor_id = v_me and cc.is_active
                     and cc.member_user_id is not distinct from
                         (select member_user_id from counsellor_clients
                           where id = r.counsellor_client_id)
                   limit 1));
  end if;

  select * into old_link from counsellor_clients where id = r.counsellor_client_id;
  if not found then raise exception 'the referred caseload link no longer exists'; end if;

  -- 1. Close the referring counsellor's link. It is CLOSED, never repointed:
  --    the row stays theirs, and so does everything attached to it.
  update counsellor_clients
     set is_active = false, ended_at = v_now
   where id = old_link.id and is_active;

  -- 2. Open a new one for the receiver, carrying the client's IDENTITY only.
  --    Name, contact, organisation, member id. No note, no booking, no
  --    history. If the receiver somehow already holds an active link to this
  --    person, reuse it rather than stacking duplicates.
  select cc.id into v_new
    from counsellor_clients cc
   where cc.counsellor_id = v_me
     and cc.is_active
     and cc.member_user_id is not distinct from old_link.member_user_id
     and coalesce(lower(cc.email),'') = coalesce(lower(old_link.email),'')
   limit 1;

  if v_new is null then
    insert into counsellor_clients (counsellor_id, member_user_id, full_name,
                                    email, phone, org_id, is_active)
    values (v_me, old_link.member_user_id, old_link.full_name,
            old_link.email, old_link.phone, old_link.org_id, true)
    returning id into v_new;
  end if;

  update counselling_referrals set accepted_at = v_now where id = r.id;

  return jsonb_build_object(
    'referral_id',      r.id,
    'already_accepted', false,
    'accepted_at',      v_now,
    'closed_link_id',   old_link.id,
    'link_id',          v_new,
    -- Said out loud in the return value so no screen has to infer it and no
    -- reader has to take it on trust.
    'note',             'The previous counsellor''s notes and bookings remain '
                        || 'theirs and are not readable through this referral.');
end $$;

grant execute on function referral_accept(uuid) to authenticated;

comment on function referral_accept(uuid) is
  'Accepting closes the referring counsellor''s caseload link and opens a new '
  'one for the receiver, carrying the client''s identity only. It grants NO '
  'access to the referring counsellor''s notes or bookings, before or after.';


-- ── 2. Post-conditions ──────────────────────────────────────

do $$
begin
  -- The function must not have become a way to read notes.
  if (select prosrc from pg_proc where proname = 'referral_accept')
     ~* '\mcounselling_notes\M' then
    raise exception 'M3a: referral_accept references counselling_notes. A '
                    'referral must never touch the referring counsellor''s '
                    'notes.';
  end if;

  -- It must gate on the RECEIVER, not on a role.
  if (select prosrc from pg_proc where proname = 'referral_accept')
     !~* '\mto_counsellor_id\M' then
    raise exception 'M3a: referral_accept does not check to_counsellor_id';
  end if;
  if (select prosrc from pg_proc where proname = 'referral_accept')
     ~* '\mis_admin\M|\mis_psychosocial_admin\M' then
    raise exception 'M3a: referral_accept is gated on a role. Accepting a case '
                    'is a clinical decision, not an administrative one.';
  end if;

  -- counsellor_clients must still have no mutable counsellor_id path.
  if not exists (select 1 from pg_constraint
                  where conname = 'counsellor_clients_ended_agrees') then
    raise exception 'M3a: counsellor_clients_ended_agrees is missing — the '
                    'open/close guarantee is not enforced';
  end if;

  raise notice 'M3a applied. Accepting a referral moves the caseload FORWARD '
               'and grants nothing backward.';
end $$;
