-- ============================================================
-- Key Wellness — M3b: declining a referral
--
-- Run AFTER M3a. Idempotent — safe to re-run.
-- Rollback: migrations/rollback-m3b-referral-decline.sql
-- Tests:    tests/m3-tests.sql (assertions 50–57)
--
-- ══ WHAT THIS IS FOR, IN PLAIN LANGUAGE ════════════════════
--
-- Karabo refers a client to Nicola. Nicola does not take the case.
--
-- Before this, that outcome had no way to be recorded. The referral simply sat
-- unaccepted, and Karabo could not tell "Nicola said no" from "Nicola has not
-- looked yet" — so she would keep assuming the case had moved on while still
-- holding it herself. A silence that two people read differently is worse than
-- either answer.
--
-- ══ A BARE "DECLINED". NO REASON FIELD. ════════════════════
--
-- Decided 28 Aug 2026, and the absence is the design rather than an omission
-- to fill in later:
--
--   A reason field would be a SECOND CHANNEL FOR CLINICAL CONTENT, sitting
--   outside counselling_notes and its author-only policy — readable by both
--   counsellors, and one schema change away from being readable by more. The
--   whole M3 boundary is that what a counsellor learns about a client lives in
--   their own notes and crosses only in a handover they wrote on purpose. A
--   free-text "why I won't take this" is exactly that content, entering by a
--   side door.
--
--   So the record is: Nicola declined, on this date. If Karabo needs to know
--   why, she asks Nicola — which is a conversation between two clinicians and
--   not a database column.
--
-- The post-conditions ENFORCE the absence: this migration refuses to apply if
-- a reason column exists on counselling_referrals, so the field cannot be
-- added later without somebody deliberately removing the check that says why
-- it must not be.
--
-- ══ WHAT WILL CHANGE, AND WHAT WILL NOT ════════════════════
--
--   CHANGES
--     counselling_referrals gains ONE column: declined_at, and a constraint
--     that a referral cannot be both accepted and declined.
--     One new function: referral_decline(uuid).
--     TWO EXISTING FUNCTIONS ARE REPLACED:
--       referral_accept()    — now refuses a referral already declined
--       referral_fact_list() — now shows declined_on alongside accepted_on
--
--   DOES NOT CHANGE
--     No caseload link. Declining leaves the client exactly where they are:
--     with the referring counsellor, who never stopped being responsible.
--     No booking, no note, no policy, no other grant.
--
--   IF IT IS WRONG
--     The realistic failure is a decline that will not record — visible and
--     harmless. There is no dangerous direction here: declining grants nobody
--     access to anything.
-- ============================================================


-- ── 1. The column, and the mutual exclusion ─────────────────

alter table counselling_referrals add column if not exists declined_at timestamptz;

comment on column counselling_referrals.declined_at is
  'When the receiving counsellor declined. A BARE FACT: there is deliberately '
  'no reason column. A reason would be a second channel for clinical content '
  'outside counselling_notes and its author-only policy. If the referrer needs '
  'to know why, she asks — that is a conversation, not a column.';

do $$
begin
  -- A referral has ONE outcome. Both set is not a state anyone should be able
  -- to reach, and leaving it reachable means every reader has to decide which
  -- one wins.
  if not exists (select 1 from pg_constraint
                  where conname = 'counselling_referrals_one_outcome') then
    alter table counselling_referrals add constraint counselling_referrals_one_outcome
      check (not (accepted_at is not null and declined_at is not null));
  end if;
end $$;

create index if not exists counselling_referrals_open_idx
  on counselling_referrals (to_counsellor_id)
  where accepted_at is null and declined_at is null;


-- ── 2. referral_decline() ───────────────────────────────────
-- Same gate as accepting, for the same reason: only the counsellor a referral
-- was sent to may answer it. Not the referrer, and not an admin — declining a
-- case is as much a clinical decision as taking one.

create or replace function referral_decline(p_referral_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  r    counselling_referrals%rowtype;
  v_me uuid := current_counsellor_id();
  v_now timestamptz := now();
begin
  if v_me is null then
    raise exception 'only a counsellor can decline a referral';
  end if;

  select * into r from counselling_referrals where id = p_referral_id;
  if not found then raise exception 'no such referral'; end if;

  if r.to_counsellor_id <> v_me then
    raise exception 'only the counsellor a referral was sent to can decline it';
  end if;

  if r.accepted_at is not null then
    raise exception 'this referral was already accepted and cannot be declined';
  end if;

  -- Declining twice is somebody checking, not an error — the same reading of
  -- how people work that referral_accept and handover_confirm_invoiced use.
  if r.declined_at is not null then
    return jsonb_build_object('referral_id', r.id, 'already_declined', true,
                              'declined_at', r.declined_at);
  end if;

  update counselling_referrals set declined_at = v_now where id = r.id;

  -- THE CASELOAD IS UNTOUCHED. The client stays with the referring counsellor,
  -- who never stopped being responsible for them. Declining moves nothing.
  return jsonb_build_object(
    'referral_id',      r.id,
    'already_declined', false,
    'declined_at',      v_now,
    'note',             'The client remains with the referring counsellor. '
                        || 'No caseload link changed.');
end $$;

grant execute on function referral_decline(uuid) to authenticated;


-- ── 3. Accepting must refuse a declined referral ────────────
-- Otherwise a referral could be declined and then accepted, and the two
-- counsellors would disagree about who holds the case.

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

  if r.to_counsellor_id <> v_me then
    raise exception 'only the counsellor a referral was sent to can accept it';
  end if;

  -- NEW IN M3b.
  if r.declined_at is not null then
    raise exception 'this referral was declined and cannot then be accepted';
  end if;

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

  update counsellor_clients
     set is_active = false, ended_at = v_now
   where id = old_link.id and is_active;

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
    'note',             'The previous counsellor''s notes and bookings remain '
                        || 'theirs and are not readable through this referral.');
end $$;

grant execute on function referral_accept(uuid) to authenticated;


-- ── 4. Lone needs the outcome, not the reason ───────────────
-- She routes future bookings. A declined referral means THE CASE DID NOT MOVE,
-- and without that she would send the next booking to the wrong counsellor —
-- which is precisely the operational harm the fact-only decision exists to
-- avoid while still telling her nothing clinical.
--
-- Still no note. Still no reason, because there is none to leak.

create or replace function referral_fact_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  if not is_psychosocial_admin() then raise exception 'not authorised'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'referred_on', r.created_at::date,
             'accepted_on', r.accepted_at::date,
             'declined_on', r.declined_at::date,
             'outcome',     case when r.accepted_at is not null then 'accepted'
                                 when r.declined_at is not null then 'declined'
                                 else 'awaiting an answer' end,
             'from', f.full_name,
             'to',   t.full_name
             -- The note is NOT here, and must never be added. Neither is a
             -- reason, because none is recorded anywhere.
           ) order by r.created_at desc)
      from counselling_referrals r
      join counsellors f on f.id = r.from_counsellor_id
      join counsellors t on t.id = r.to_counsellor_id
  ), '[]'::jsonb);
end $$;

grant execute on function referral_fact_list() to authenticated;


-- ── 5. Post-conditions ──────────────────────────────────────

do $$
begin
  -- THE ABSENCE IS THE DESIGN, SO THE ABSENCE IS ASSERTED. Adding a reason
  -- field later would require deliberately deleting the check that says why it
  -- must not exist — which is the point.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public'
                and table_name = 'counselling_referrals'
                and column_name ~* 'reason|why|comment|note_on_decline') then
    raise exception 'M3b: counselling_referrals has a reason-shaped column. A '
                    'decline is a bare fact — a reason would be a second '
                    'channel for clinical content outside counselling_notes.';
  end if;

  if (select prosrc from pg_proc where proname = 'referral_decline')
     !~* '\mto_counsellor_id\M' then
    raise exception 'M3b: referral_decline does not check to_counsellor_id';
  end if;

  if (select prosrc from pg_proc where proname = 'referral_decline')
     ~* '\mis_admin\M|\mis_psychosocial_admin\M' then
    raise exception 'M3b: referral_decline is gated on a role. Declining a case '
                    'is a clinical decision, not an administrative one.';
  end if;

  -- Declining must not touch a caseload.
  if (select prosrc from pg_proc where proname = 'referral_decline')
     ~* '\minsert\s+into\s+counsellor_clients\M|\mupdate\s+counsellor_clients\M' then
    raise exception 'M3b: referral_decline writes to counsellor_clients. '
                    'Declining moves nothing — the client stays where they are.';
  end if;

  if not exists (select 1 from pg_constraint
                  where conname = 'counselling_referrals_one_outcome') then
    raise exception 'M3b: a referral could be both accepted and declined';
  end if;

  if (select prosrc from pg_proc where proname = 'referral_accept')
     !~* '\mdeclined_at\M' then
    raise exception 'M3b: referral_accept does not refuse a declined referral';
  end if;

  raise notice 'M3b applied. A decline is a bare fact with a date, and it moves '
               'nothing: the client stays with the counsellor who referred them.';
end $$;
