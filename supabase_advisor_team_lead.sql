-- ============================================================
-- Key Wellness — Advisory Team Lead
-- Run in the Supabase SQL Editor AFTER supabase_advisor_portal.sql
-- and supabase_advisor_rpcs.sql. Safe to re-run.
--
-- Adds a Team Lead for Financial Advisory: an advisor who keeps their own
-- caseload but can also see and work every other advisor's clients, so
-- they can supervise and step in during advisory.
--
-- Rollback: migrations/rollback-advisor-team-lead.sql
-- ============================================================
--
-- DESIGN NOTES
--
-- * A Team Lead IS an advisor (`advisors.is_team_lead`), not a separate
--   role. That keeps them inside the advisory relationship the member
--   consented to, and means they can carry clients of their own.
--
-- * Member consent covers the advisory TEAM, not one named individual.
--   advisor_client_detail() therefore honours the same
--   profiles.advisor_data_consent flag for a team lead. The consent
--   wording in My Profile is updated to say so — do not widen the access
--   without that wording change, or the consent stops being honest.
--
-- * Work a Team Lead does on someone else's client is attributed to the
--   TEAM LEAD, not to the owning advisor. Sessions they book carry their
--   advisor_id, and notes they write carry their advisor_id. The record
--   therefore shows who actually did what.
--
-- * Two visibility gaps in the original policies are fixed here: an
--   advisor could not see a booking or a note that someone else created
--   on their own non-member client. Co-advisory makes that unacceptable.
-- ------------------------------------------------------------


-- ── 1. The flag ──────────────────────────────────────────────

alter table advisors
  add column if not exists is_team_lead boolean not null default false;

create index if not exists advisors_team_lead_idx
  on advisors (is_team_lead) where is_team_lead;

comment on column advisors.is_team_lead is
  'Team Lead for Financial Advisory — sees and works every advisor''s caseload.';


-- ── 2. Role helper ───────────────────────────────────────────

create or replace function is_team_lead()
returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from advisors
    where id = current_advisor_id()
      and is_team_lead
  );
$$;

grant execute on function is_team_lead() to authenticated;

-- "May the caller act on this advisor's caseload?"
-- True for the advisor themselves, any team lead, and admins.
create or replace function can_manage_advisor(p_advisor_id uuid)
returns boolean
language sql security definer stable set search_path = public as $$
  select p_advisor_id is not null
     and (p_advisor_id = current_advisor_id() or is_team_lead() or is_admin());
$$;

grant execute on function can_manage_advisor(uuid) to authenticated;


-- ── 3. RLS: advisor_clients — team lead sees the whole book ──

drop policy if exists advisor_clients_lead_all on advisor_clients;
create policy advisor_clients_lead_all on advisor_clients
  for all using (is_team_lead()) with check (is_team_lead());


-- ── 4. RLS: advisor_notes ────────────────────────────────────
-- Two changes:
--   a) a team lead reads and writes notes on any client
--   b) an advisor now also sees notes OTHERS wrote on THEIR client —
--      previously a team lead's note was invisible to the advisor who
--      owns the case, which makes co-advisory unworkable.

drop policy if exists advisor_notes_lead_all on advisor_notes;
create policy advisor_notes_lead_all on advisor_notes
  for all using (is_team_lead()) with check (is_team_lead());

drop policy if exists advisor_notes_on_my_client on advisor_notes;
create policy advisor_notes_on_my_client on advisor_notes
  for select using (
    exists (
      select 1 from advisor_clients ac
      where ac.id = advisor_notes.client_id
        and ac.advisor_id = current_advisor_id()
    )
  );


-- ── 5. RLS: bookings ─────────────────────────────────────────
-- Same gap: an advisor could not see a booking made on their own
-- NON-MEMBER client by anyone else, because the old policy matched on
-- bookings.user_id, which is null for a client with no portal account.

drop policy if exists bookings_advisor_select on bookings;
create policy bookings_advisor_select on bookings
  for select using (
    advisor_id = current_advisor_id()
    or is_team_lead()
    or exists (
      select 1 from advisor_clients ac
      where ac.advisor_id = current_advisor_id()
        and (ac.member_user_id = bookings.user_id
             or ac.id = bookings.advisor_client_id)
    )
  );

drop policy if exists bookings_lead_update on bookings;
create policy bookings_lead_update on bookings
  for update using (is_team_lead()) with check (is_team_lead());


-- ── 6. RPCs ──────────────────────────────────────────────────
-- advisor_clients_list gains a scope argument. The old one-argument
-- version must be DROPPED first — leaving both in place makes a
-- one-argument call ambiguous and PostgREST returns an error.

drop function if exists advisor_clients_list(boolean);

create or replace function advisor_clients_list(
  p_include_archived boolean default false,
  p_advisor_id       uuid    default null   -- null = own caseload, or the
                                            -- whole book for a team lead
)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_advisor uuid    := current_advisor_id();
  v_lead    boolean := is_team_lead();
  v_scope   uuid;
  v_all     boolean := false;
  v_out     jsonb;
begin
  if v_advisor is null and not is_admin() then
    raise exception 'not authorised';
  end if;

  if p_advisor_id is null then
    -- A team lead (or admin) with no scope asked for the whole book.
    if v_lead or is_admin() then
      v_all := true;
    else
      v_scope := v_advisor;
    end if;
  else
    if not can_manage_advisor(p_advisor_id) then
      raise exception 'not authorised for that advisor';
    end if;
    v_scope := p_advisor_id;
  end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.last_name, t.first_name), '[]'::jsonb)
    into v_out
  from (
    select
      ac.id,
      ac.first_name,
      ac.last_name,
      ac.email,
      ac.phone,
      ac.status,
      ac.source,
      ac.assessment,
      ac.created_at,
      ac.updated_at,
      ac.member_user_id,
      ac.member_user_id is not null                as is_member,
      ac.linked_at,
      o.name                                       as org_name,
      ac.org_id,
      -- Who owns this case. Only meaningful when looking beyond your own.
      ac.advisor_id,
      adv.full_name                                as advisor_name,
      ac.advisor_id = v_advisor                    as is_mine,
      coalesce(p.advisor_data_consent, false)      as has_consent,
      (select count(*) from bookings b
        where (ac.member_user_id is not null and b.user_id = ac.member_user_id)
           or b.advisor_client_id = ac.id)         as sessions_total,
      (select count(*) from bookings b
        where ((ac.member_user_id is not null and b.user_id = ac.member_user_id)
            or b.advisor_client_id = ac.id)
          and b.attended is true)                  as sessions_attended,
      (select max(b.requested_date::text) from bookings b
        where ((ac.member_user_id is not null and b.user_id = ac.member_user_id)
            or b.advisor_client_id = ac.id))       as last_session_date,
      (select count(*) from bookings b
        where b.advisor_client_id = ac.id
          and b.booked_by = 'advisor'
          and b.member_response = 'declined')      as declined_count,
      case when coalesce(p.advisor_data_consent, false)
           then p.last_score end                   as wellness_score,
      case when coalesce(p.advisor_data_consent, false)
           then p.last_cat_scores end              as wellness_cat_scores
    from advisor_clients ac
    join advisors adv       on adv.id = ac.advisor_id
    left join profiles      p on p.id = ac.member_user_id
    left join organizations o on o.id = coalesce(ac.org_id, p.org_id)
    where (v_all or ac.advisor_id = v_scope)
      and (p_include_archived or ac.status = 'active')
  ) t;

  return v_out;
end;
$$;

grant execute on function advisor_clients_list(boolean, uuid) to authenticated;


-- Client detail — a team lead may open any client. The CONSENT GATE IS
-- UNCHANGED: they still only see financial data where the member has
-- agreed to share it with their advisory team.
create or replace function advisor_client_detail(p_client_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_advisor  uuid    := current_advisor_id();
  v_lead     boolean := is_team_lead();
  v_client   advisor_clients%rowtype;
  v_owner    text;
  v_consent  boolean := false;
  v_profile  jsonb   := null;
  v_assess   jsonb   := null;
  v_checkins jsonb   := '[]'::jsonb;
  v_sessions jsonb   := '[]'::jsonb;
  v_notes    jsonb   := '[]'::jsonb;
  v_org      text;
begin
  if v_advisor is null and not is_admin() then
    raise exception 'not authorised';
  end if;

  select * into v_client from advisor_clients where id = p_client_id;
  if v_client.id is null then
    raise exception 'client not found';
  end if;
  if not can_manage_advisor(v_client.advisor_id) then
    raise exception 'not authorised for that client';
  end if;

  select full_name into v_owner from advisors where id = v_client.advisor_id;

  if v_client.member_user_id is not null then
    select coalesce(p.advisor_data_consent, false), o.name
      into v_consent, v_org
      from profiles p
      left join organizations o on o.id = p.org_id
     where p.id = v_client.member_user_id;
  end if;

  select coalesce(jsonb_agg(row_to_json(s)::jsonb order by s.requested_date desc nulls last), '[]'::jsonb)
    into v_sessions
  from (
    select b.id, b.service, b.session_type, b.session_mode,
           b.requested_date, b.requested_time, b.status,
           b.booked_by, b.member_response, b.member_response_at, b.member_response_note,
           b.attended, b.attendance_confirmed_at, b.created_at,
           b.advisor_id = v_advisor as is_mine,
           (select full_name from advisors a2 where a2.id = b.advisor_id) as advisor_name
    from bookings b
    where (v_client.member_user_id is not null and b.user_id = v_client.member_user_id)
       or b.advisor_client_id = v_client.id
  ) s;

  -- Notes on this client from anyone on the team, attributed.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', n.id, 'body', n.body, 'booking_id', n.booking_id,
           'created_at', n.created_at,
           'author', (select full_name from advisors a3 where a3.id = n.advisor_id),
           'is_mine', n.advisor_id = v_advisor) order by n.created_at desc), '[]'::jsonb)
    into v_notes
  from advisor_notes n
  where n.client_id = v_client.id;

  if v_consent then
    select to_jsonb(p) - 'id' into v_profile
      from (
        select first_name, last_name, phone, age, employment, goals,
               monthly_income, monthly_expenses, gross_income, net_income,
               other_income, essential_expenses, monthly_debt, total_debt_balance,
               total_assets, total_liabilities, total_savings, monthly_savings,
               last_score, last_cat_scores, fin_updated_at, joined_at
        from profiles where id = v_client.member_user_id
      ) p;

    select to_jsonb(a) into v_assess
      from (
        select score, cat_scores, created_at
        from assessments where user_id = v_client.member_user_id
        order by created_at desc limit 1
      ) a;

    select coalesce(jsonb_agg(jsonb_build_object(
             'score', c.score, 'created_at', c.created_at) order by c.created_at desc), '[]'::jsonb)
      into v_checkins
    from (
      select score, created_at from checkins
      where user_id = v_client.member_user_id
      order by created_at desc limit 12
    ) c;
  end if;

  return jsonb_build_object(
    'client', jsonb_build_object(
        'id', v_client.id,
        'first_name', v_client.first_name,
        'last_name',  v_client.last_name,
        'email',      v_client.email,
        'phone',      v_client.phone,
        'status',     v_client.status,
        'source',     v_client.source,
        'is_member',  v_client.member_user_id is not null,
        'linked_at',  v_client.linked_at,
        'org_name',   v_org,
        'created_at', v_client.created_at,
        'advisor_id', v_client.advisor_id,
        'advisor_name', v_owner,
        'is_mine',    v_client.advisor_id = v_advisor
    ),
    'viewer', jsonb_build_object('is_team_lead', v_lead, 'advisor_id', v_advisor),
    'has_consent',      v_consent,
    'profile',          v_profile,
    'latest_assessment',v_assess,
    'checkins',         v_checkins,
    'sessions',         v_sessions,
    'notes',            v_notes
  );
end;
$$;

grant execute on function advisor_client_detail(uuid) to authenticated;


-- Booking a session on someone else's client. The booking is stamped
-- with the CALLER's advisor_id, so reporting attributes the work to the
-- person who actually did it.
create or replace function advisor_book_session(
  p_client_id    uuid,
  p_service      text,
  p_session_type text,
  p_date         date,
  p_time         text,
  p_session_mode text default 'physical',
  p_note         text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_advisor uuid := current_advisor_id();
  v_client  advisor_clients%rowtype;
  v_email   text;
  v_id      uuid;
begin
  if v_advisor is null then
    raise exception 'not authorised';
  end if;
  if p_date is null or coalesce(trim(p_time), '') = '' then
    raise exception 'date and time are required';
  end if;
  if p_session_mode not in ('physical','virtual') then
    raise exception 'session_mode must be physical or virtual';
  end if;

  select * into v_client from advisor_clients where id = p_client_id;
  if v_client.id is null then
    raise exception 'client not found';
  end if;
  if not can_manage_advisor(v_client.advisor_id) then
    raise exception 'not authorised for that client';
  end if;

  select email into v_email from auth.users where id = v_client.member_user_id;

  insert into bookings (
    user_id, user_name, user_email,
    service, session_type, session_mode,
    requested_date, requested_time,
    status, booked_by, advisor_id, advisor_client_id,
    client_type, member_response, created_at
  ) values (
    v_client.member_user_id,
    trim(coalesce(v_client.first_name,'') || ' ' || coalesce(v_client.last_name,'')),
    coalesce(v_email, v_client.email),
    p_service, p_session_type, p_session_mode,
    p_date, p_time,
    'pending', 'advisor', v_advisor, v_client.id,
    'member', null, now()
  )
  returning id into v_id;

  if p_note is not null and trim(p_note) <> '' then
    insert into advisor_notes (client_id, advisor_id, booking_id, body)
    values (v_client.id, v_advisor, v_id, p_note);
  end if;

  return jsonb_build_object(
    'booking_id',   v_id,
    'is_member',    v_client.member_user_id is not null,
    'notify_email', coalesce(v_email, v_client.email),
    'on_behalf_of', case when v_client.advisor_id <> v_advisor
                         then (select full_name from advisors where id = v_client.advisor_id)
                    end
  );
end;
$$;

grant execute on function advisor_book_session(uuid, text, text, date, text, text, text) to authenticated;


-- advisor_me now reports the flag so the UI knows what to show.
create or replace function advisor_me()
returns jsonb
language sql security definer stable set search_path = public as $$
  select case when a.id is null then null else jsonb_build_object(
    'id',           a.id,
    'full_name',    a.full_name,
    'email',        a.email,
    'phone',        a.phone,
    'title',        a.title,
    'is_active',    a.is_active,
    'is_team_lead', a.is_team_lead
  ) end
  from advisors a
  where a.id = current_advisor_id();
$$;

grant execute on function advisor_me() to authenticated;


-- Roster gains the flag, so admin can see and set it.
create or replace function admin_advisor_roster()
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare v_out jsonb;
begin
  if not (is_admin() or is_team_lead()) then
    raise exception 'not authorised';
  end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.is_team_lead desc, t.full_name), '[]'::jsonb)
    into v_out
  from (
    select
      a.id, a.full_name, a.email, a.phone, a.title, a.is_active, a.is_team_lead,
      a.user_id is not null as has_logged_in,
      a.created_at,
      (select count(*) from advisor_clients ac
        where ac.advisor_id = a.id and ac.status = 'active')       as active_clients,
      (select count(*) from bookings b where b.advisor_id = a.id)  as sessions_booked,
      (select count(*) from bookings b
        where b.advisor_id = a.id and b.attended is true)          as sessions_attended
    from advisors a
  ) t;

  return v_out;
end;
$$;

grant execute on function admin_advisor_roster() to authenticated;


-- Team-wide caseload summary: one row per advisor, for the team lead's
-- "all clients" header and the admin Advisors screen.
create or replace function advisor_caseload_summary()
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare v_out jsonb;
begin
  if not (is_team_lead() or is_admin()) then
    raise exception 'not authorised';
  end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.active_clients desc), '[]'::jsonb)
    into v_out
  from (
    select
      a.id as advisor_id, a.full_name, a.is_active, a.is_team_lead,
      count(ac.id) filter (where ac.status = 'active')                     as active_clients,
      count(ac.id) filter (where ac.status = 'active'
                             and ac.member_user_id is not null)            as linked_clients,
      count(ac.id) filter (where ac.status = 'active'
                             and ac.member_user_id is null)                as unlinked_clients,
      max(ac.updated_at)                                                   as last_activity
    from advisors a
    left join advisor_clients ac on ac.advisor_id = a.id
    group by a.id, a.full_name, a.is_active, a.is_team_lead
  ) t;

  return v_out;
end;
$$;

grant execute on function advisor_caseload_summary() to authenticated;


-- ── 7. Appoint the Team Lead ─────────────────────────────────
-- Edit the email, then run. Admins can also toggle this from
-- Admin → Advisors once the HTML is deployed.
--
--   update advisors set is_team_lead = true, updated_at = now()
--    where lower(email) = lower('teamlead@keywealth.co.bw');
--
-- Verify:
--   select full_name, email, is_active, is_team_lead from advisors order by is_team_lead desc;
--   select is_advisor(), is_team_lead();          -- as that signed-in user
--   select advisor_caseload_summary();
-- ============================================================
