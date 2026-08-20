-- ============================================================
-- Key Wellness — Advisor Portal UX pass
-- Run in the Supabase SQL Editor AFTER:
--   supabase_advisor_portal.sql
--   supabase_advisor_rpcs.sql
--   supabase_advisor_team_lead.sql
-- Safe to re-run.
--
-- Three things:
--   1. Notes become ONE attributed timeline in advisor_notes, and the
--      old unattributed notes inside advisor_clients.assessment are
--      migrated across.
--   2. A client can be reassigned to another advisor, with the move
--      recorded on the timeline.
--   3. Advisors get told when a member declines or asks to move a
--      session (the advisor_seen_response column finally gets used).
--
-- Rollback: migrations/rollback-advisor-ux.sql
-- ============================================================


-- ── 1. Notes: one attributed timeline ────────────────────────

alter table advisor_notes
  add column if not exists origin text not null default 'advisor'
    check (origin in ('advisor','session','migrated','system'));

create index if not exists advisor_notes_advisor_idx on advisor_notes (advisor_id);

-- Read the timeline for one client. Everyone who may work the case sees
-- every note on it, attributed — that is the point of co-advisory.
create or replace function advisor_client_notes(p_client_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_advisor uuid := current_advisor_id();
  v_owner   uuid;
  v_out     jsonb;
begin
  select advisor_id into v_owner from advisor_clients where id = p_client_id;
  if v_owner is null then
    raise exception 'client not found';
  end if;
  if not can_manage_advisor(v_owner) then
    raise exception 'not authorised for that client';
  end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.created_at desc), '[]'::jsonb)
    into v_out
  from (
    select n.id, n.body, n.origin, n.booking_id, n.created_at, n.updated_at,
           a.full_name              as author,
           n.advisor_id = v_advisor as is_mine,
           b.service                as booking_service,
           b.requested_date         as booking_date
    from advisor_notes n
    left join advisors a on a.id = n.advisor_id
    left join bookings b on b.id = n.booking_id
    where n.client_id = p_client_id
  ) t;

  return v_out;
end;
$$;

grant execute on function advisor_client_notes(uuid) to authenticated;


create or replace function advisor_note_add(p_client_id uuid, p_body text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_advisor uuid := current_advisor_id();
  v_owner   uuid;
  v_id      uuid;
begin
  if v_advisor is null then raise exception 'not authorised'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'note is empty'; end if;

  select advisor_id into v_owner from advisor_clients where id = p_client_id;
  if v_owner is null then raise exception 'client not found'; end if;
  if not can_manage_advisor(v_owner) then raise exception 'not authorised for that client'; end if;

  insert into advisor_notes (client_id, advisor_id, body, origin)
  values (p_client_id, v_advisor, trim(p_body), 'advisor')
  returning id into v_id;
  return v_id;
end;
$$;

grant execute on function advisor_note_add(uuid, text) to authenticated;


-- Only the author may edit or delete their own note. A team lead can see
-- everything and add their own, but cannot rewrite someone else's record
-- of a consultation — that would destroy the audit value of attribution.
create or replace function advisor_note_update(p_note_id uuid, p_body text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_advisor uuid := current_advisor_id();
begin
  if v_advisor is null then raise exception 'not authorised'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'note is empty'; end if;

  update advisor_notes
     set body = trim(p_body), updated_at = now()
   where id = p_note_id and advisor_id = v_advisor;

  if not found then
    raise exception 'you can only edit your own notes';
  end if;
end;
$$;

create or replace function advisor_note_delete(p_note_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_advisor uuid := current_advisor_id();
begin
  if v_advisor is null then raise exception 'not authorised'; end if;
  delete from advisor_notes where id = p_note_id and advisor_id = v_advisor;
  if not found then
    raise exception 'you can only delete your own notes';
  end if;
end;
$$;

grant execute on function advisor_note_update(uuid, text) to authenticated;
grant execute on function advisor_note_delete(uuid)       to authenticated;


-- ── 1a. Migrate the old in-assessment notes ──────────────────
-- consultationNotes lived inside advisor_clients.assessment as an
-- unattributed array. Move each one into advisor_notes, credited to the
-- advisor who owns the case (they wrote them), keeping the original
-- timestamp. Then clear the array so nothing is shown twice.
--
-- Naturally idempotent: once the array is empty there is nothing to move.

do $$
declare
  r          record;
  n          jsonb;
  v_moved    int := 0;
  v_clients  int := 0;
begin
  for r in
    select id, advisor_id, assessment
    from advisor_clients
    where jsonb_typeof(assessment -> 'consultationNotes') = 'array'
      and jsonb_array_length(assessment -> 'consultationNotes') > 0
  loop
    for n in select * from jsonb_array_elements(r.assessment -> 'consultationNotes')
    loop
      if coalesce(trim(n ->> 'text'), '') <> '' then
        insert into advisor_notes (client_id, advisor_id, body, origin, created_at, updated_at)
        values (
          r.id,
          r.advisor_id,
          trim(n ->> 'text'),
          'migrated',
          coalesce((n ->> 'createdAt')::timestamptz, now()),
          (n ->> 'updatedAt')::timestamptz
        );
        v_moved := v_moved + 1;
      end if;
    end loop;

    update advisor_clients
       set assessment = jsonb_set(assessment, '{consultationNotes}', '[]'::jsonb),
           updated_at = now()
     where id = r.id;
    v_clients := v_clients + 1;
  end loop;

  raise notice 'Migrated % consultation note(s) across % client(s) into advisor_notes.', v_moved, v_clients;
end $$;


-- ── 2. Reassign a client to another advisor ──────────────────
-- Team lead or admin only. The move is written to the note timeline so
-- the case history explains itself later.

create or replace function advisor_reassign_client(
  p_client_id     uuid,
  p_to_advisor_id uuid,
  p_reason        text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := current_advisor_id();
  v_from    uuid;
  v_fromnm  text;
  v_tonm    text;
  v_actornm text;
  v_active  boolean;
begin
  if not (is_team_lead() or is_admin()) then
    raise exception 'only a team lead or an administrator can reassign a client';
  end if;

  select advisor_id into v_from from advisor_clients where id = p_client_id;
  if v_from is null then raise exception 'client not found'; end if;

  select full_name, is_active into v_tonm, v_active from advisors where id = p_to_advisor_id;
  if v_tonm is null then raise exception 'target advisor not found'; end if;
  if not v_active then raise exception 'cannot reassign to an inactive advisor'; end if;

  if v_from = p_to_advisor_id then
    return jsonb_build_object('ok', true, 'unchanged', true);
  end if;

  select full_name into v_fromnm  from advisors where id = v_from;
  select full_name into v_actornm from advisors where id = v_actor;

  update advisor_clients
     set advisor_id = p_to_advisor_id,
         updated_at = now()
   where id = p_client_id;

  insert into advisor_notes (client_id, advisor_id, body, origin)
  values (
    p_client_id,
    coalesce(v_actor, p_to_advisor_id),
    'Case reassigned from ' || coalesce(v_fromnm, 'an advisor') ||
    ' to ' || v_tonm ||
    coalesce(' by ' || v_actornm, '') ||
    coalesce('. Reason: ' || nullif(trim(p_reason), ''), '.'),
    'system'
  );

  -- Past sessions keep their original advisor_id on purpose: they record
  -- who actually delivered the session, not who holds the case now.

  return jsonb_build_object('ok', true, 'from', v_fromnm, 'to', v_tonm);
end;
$$;

grant execute on function advisor_reassign_client(uuid, uuid, text) to authenticated;


-- ── 3. Member responses the advisor has not seen ─────────────

create or replace function advisor_pending_responses()
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_advisor uuid := current_advisor_id();
  v_lead    boolean := is_team_lead();
  v_out     jsonb;
begin
  if v_advisor is null then raise exception 'not authorised'; end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.member_response_at desc), '[]'::jsonb)
    into v_out
  from (
    select b.id as booking_id, b.service, b.requested_date, b.requested_time,
           b.member_response, b.member_response_at, b.member_response_note,
           ac.id         as client_id,
           trim(coalesce(ac.first_name,'') || ' ' || coalesce(ac.last_name,'')) as client_name,
           ac.advisor_id,
           ac.advisor_id = v_advisor as is_mine
    from bookings b
    join advisor_clients ac on ac.id = b.advisor_client_id
    where b.booked_by = 'advisor'
      and b.member_response in ('declined','reschedule_requested')
      and coalesce(b.advisor_seen_response, false) = false
      and (v_lead or b.advisor_id = v_advisor or ac.advisor_id = v_advisor)
  ) t;

  return v_out;
end;
$$;

grant execute on function advisor_pending_responses() to authenticated;


create or replace function advisor_mark_response_seen(p_booking_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_advisor uuid := current_advisor_id();
  v_owner   uuid;
begin
  if v_advisor is null then raise exception 'not authorised'; end if;

  select ac.advisor_id into v_owner
    from bookings b
    join advisor_clients ac on ac.id = b.advisor_client_id
   where b.id = p_booking_id;

  if v_owner is null then raise exception 'booking not found'; end if;
  if not can_manage_advisor(v_owner) then raise exception 'not authorised for that booking'; end if;

  update bookings
     set advisor_seen_response = true, updated_at = now()
   where id = p_booking_id;
end;
$$;

grant execute on function advisor_mark_response_seen(uuid) to authenticated;



-- ── 4. Note counts for the Activity Report ───────────────────
-- The report counts a dated note as evidence of a session. Now that
-- notes live in advisor_notes rather than in the assessment blob, the
-- report needs them counted server-side rather than read from the
-- already-loaded client list. Scope follows advisor_clients_list().

create or replace function advisor_note_counts(
  p_month      text,                      -- 'YYYY-MM'
  p_advisor_id uuid default null
)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_advisor uuid    := current_advisor_id();
  v_lead    boolean := is_team_lead();
  v_scope   uuid;
  v_all     boolean := false;
  v_start   date;
  v_out     jsonb;
begin
  if v_advisor is null and not is_admin() then
    raise exception 'not authorised';
  end if;
  if p_month !~ '^\d{4}-\d{2}$' then
    raise exception 'month must be YYYY-MM';
  end if;
  v_start := to_date(p_month || '-01', 'YYYY-MM-DD');

  if p_advisor_id is null then
    if v_lead or is_admin() then v_all := true; else v_scope := v_advisor; end if;
  else
    if not can_manage_advisor(p_advisor_id) then
      raise exception 'not authorised for that advisor';
    end if;
    v_scope := p_advisor_id;
  end if;

  select coalesce(jsonb_object_agg(t.client_id, t.n), '{}'::jsonb)
    into v_out
  from (
    select n.client_id::text as client_id, count(*) as n
    from advisor_notes n
    join advisor_clients ac on ac.id = n.client_id
    where (v_all or ac.advisor_id = v_scope)
      and n.origin <> 'system'
      and (n.created_at at time zone 'Africa/Gaborone')::date >= v_start
      and (n.created_at at time zone 'Africa/Gaborone')::date <  (v_start + interval '1 month')
    group by n.client_id
  ) t;

  return v_out;
end;
$$;

grant execute on function advisor_note_counts(text, uuid) to authenticated;

-- ── Verification ─────────────────────────────────────────────
--   select advisor_client_notes('<client-uuid>');
--   select advisor_pending_responses();
--   select count(*) filter (where origin='migrated') as migrated_notes from advisor_notes;
--   select jsonb_array_length(assessment->'consultationNotes') from advisor_clients;  -- expect 0
-- ============================================================
