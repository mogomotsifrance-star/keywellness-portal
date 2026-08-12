-- ============================================================
-- Key Wellness — Advisor Portal: RPCs
-- Run in the Supabase SQL Editor AFTER supabase_advisor_portal.sql.
-- Safe to re-run (create or replace throughout).
--
-- Every function that returns a member's own financial data is
-- SECURITY DEFINER and checks profiles.advisor_data_consent first.
-- Advisors have no direct RLS read on profiles/assessments/checkins —
-- these functions are the only path, which is what makes the consent
-- toggle actually enforceable rather than cosmetic.
-- ============================================================


-- ══════════════════════════════════════════════════════════════
-- SECTION A — Advisor self
-- ══════════════════════════════════════════════════════════════

create or replace function advisor_me()
returns jsonb
language sql security definer stable set search_path = public as $$
  select case when a.id is null then null else jsonb_build_object(
    'id',        a.id,
    'full_name', a.full_name,
    'email',     a.email,
    'phone',     a.phone,
    'title',     a.title,
    'is_active', a.is_active
  ) end
  from advisors a
  where a.id = current_advisor_id();
$$;

grant execute on function advisor_me() to authenticated;


-- ══════════════════════════════════════════════════════════════
-- SECTION B — Client list
-- Returns every client this advisor holds, with session counts and,
-- ONLY where the member has consented, their headline wellness figures.
-- ══════════════════════════════════════════════════════════════

create or replace function advisor_clients_list(p_include_archived boolean default false)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_advisor uuid := current_advisor_id();
  v_out     jsonb;
begin
  if v_advisor is null then
    raise exception 'not authorised';
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
      ac.assessment,          -- the advisor's own consultation record
      ac.created_at,
      ac.updated_at,
      ac.member_user_id,
      ac.member_user_id is not null                as is_member,
      ac.linked_at,
      o.name                                       as org_name,
      ac.org_id,
      coalesce(p.advisor_data_consent, false)      as has_consent,
      -- Session counts (self-booked by the member OR booked by any advisor)
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
      -- Consent-gated headline figures only
      case when coalesce(p.advisor_data_consent, false)
           then p.last_score end                   as wellness_score,
      case when coalesce(p.advisor_data_consent, false)
           then p.last_cat_scores end              as wellness_cat_scores
    from advisor_clients ac
    left join profiles      p on p.id = ac.member_user_id
    left join organizations o on o.id = coalesce(ac.org_id, p.org_id)
    where ac.advisor_id = v_advisor
      and (p_include_archived or ac.status = 'active')
  ) t;

  return v_out;
end;
$$;

grant execute on function advisor_clients_list(boolean) to authenticated;


-- ══════════════════════════════════════════════════════════════
-- SECTION C — Client detail
-- The consent gate lives here. Without consent the advisor gets
-- contact details and session history and nothing else.
-- ══════════════════════════════════════════════════════════════

create or replace function advisor_client_detail(p_client_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_advisor  uuid := current_advisor_id();
  v_client   advisor_clients%rowtype;
  v_consent  boolean := false;
  v_profile  jsonb   := null;
  v_assess   jsonb   := null;
  v_checkins jsonb   := '[]'::jsonb;
  v_sessions jsonb   := '[]'::jsonb;
  v_notes    jsonb   := '[]'::jsonb;
  v_org      text;
begin
  if v_advisor is null then
    raise exception 'not authorised';
  end if;

  select * into v_client from advisor_clients
   where id = p_client_id and advisor_id = v_advisor;

  if v_client.id is null then
    raise exception 'client not found';
  end if;

  if v_client.member_user_id is not null then
    select coalesce(p.advisor_data_consent, false), o.name
      into v_consent, v_org
      from profiles p
      left join organizations o on o.id = p.org_id
     where p.id = v_client.member_user_id;
  end if;

  -- Sessions are always visible: the advisor scheduled or delivered them.
  select coalesce(jsonb_agg(row_to_json(s)::jsonb order by s.requested_date desc nulls last), '[]'::jsonb)
    into v_sessions
  from (
    select b.id, b.service, b.session_type, b.session_mode,
           b.requested_date, b.requested_time, b.status,
           b.booked_by, b.member_response, b.member_response_at, b.member_response_note,
           b.attended, b.attendance_confirmed_at, b.created_at,
           b.advisor_id = v_advisor as is_mine
    from bookings b
    where (v_client.member_user_id is not null and b.user_id = v_client.member_user_id)
       or b.advisor_client_id = v_client.id
  ) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', n.id, 'body', n.body, 'booking_id', n.booking_id,
           'created_at', n.created_at) order by n.created_at desc), '[]'::jsonb)
    into v_notes
  from advisor_notes n
  where n.client_id = v_client.id and n.advisor_id = v_advisor;

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
        from assessments
        where user_id = v_client.member_user_id
        order by created_at desc
        limit 1
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
        'org_name',   coalesce(v_org, null),
        'created_at', v_client.created_at
    ),
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


-- ══════════════════════════════════════════════════════════════
-- SECTION D — Finding registered members to add as clients
-- Deliberately narrow: an exact email match, or a name prefix of at
-- least 3 characters. Capped at 20 rows. Advisors are Key Wellness
-- staff and work across all orgs, but that is not a licence to browse
-- the whole member base.
-- ══════════════════════════════════════════════════════════════

create or replace function advisor_search_members(p_q text)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_advisor uuid := current_advisor_id();
  v_q       text := lower(trim(coalesce(p_q, '')));
  v_out     jsonb;
begin
  -- Admins use this too, from the Advisors screen, to assign a member to
  -- an advisor. profiles has no email column, so an email search has to
  -- go through auth.users, which only a definer function can read.
  if v_advisor is null and not is_admin() then
    raise exception 'not authorised';
  end if;

  if length(v_q) < 3 then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb), '[]'::jsonb)
    into v_out
  from (
    select
      u.id                                                        as user_id,
      p.first_name,
      p.last_name,
      o.name                                                      as org_name,
      -- masked: enough to disambiguate, not a harvestable address
      regexp_replace(u.email, '(^.).*(@.*$)', '\1•••\2')          as email_masked,
      (v_advisor is not null and exists (
         select 1 from advisor_clients ac
          where ac.advisor_id = v_advisor and ac.member_user_id = u.id)) as already_client
    from auth.users u
    join profiles p on p.id = u.id
    left join organizations o on o.id = p.org_id
    where lower(u.email) = v_q
       or lower(coalesce(p.first_name,'') || ' ' || coalesce(p.last_name,'')) like v_q || '%'
       or lower(coalesce(p.last_name,'')) like v_q || '%'
    limit 20
  ) t;

  return v_out;
end;
$$;

grant execute on function advisor_search_members(text) to authenticated;


-- Add a registered member to this advisor's caseload.
create or replace function advisor_add_member_client(p_member_user_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_advisor uuid := current_advisor_id();
  v_id      uuid;
  v_email   text;
  v_fn      text;
  v_ln      text;
  v_org     uuid;
begin
  if v_advisor is null then
    raise exception 'not authorised';
  end if;

  select id into v_id from advisor_clients
   where advisor_id = v_advisor and member_user_id = p_member_user_id;
  if v_id is not null then
    return v_id;   -- idempotent
  end if;

  select u.email, p.first_name, p.last_name, p.org_id
    into v_email, v_fn, v_ln, v_org
    from auth.users u
    left join profiles p on p.id = u.id
   where u.id = p_member_user_id;

  if v_email is null then
    raise exception 'member not found';
  end if;

  insert into advisor_clients
    (advisor_id, member_user_id, first_name, last_name, email, org_id, source, linked_at, created_by)
  values
    (v_advisor, p_member_user_id, coalesce(v_fn, split_part(v_email,'@',1)), v_ln,
     v_email, v_org, 'advisor_added', now(), auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function advisor_add_member_client(uuid) to authenticated;


-- ══════════════════════════════════════════════════════════════
-- SECTION E — Advisor books a session for a client
--
-- The booking is written to `bookings` — the same table members write
-- to — so it flows into org_report_data() session counts untouched.
--
-- Status: advisor bookings are NOT auto-confirmed. They land as
-- 'pending' with booked_by='advisor', and the member accepts, declines
-- or asks to reschedule from My Bookings. Acceptance flips status to
-- 'confirmed'.
-- ══════════════════════════════════════════════════════════════

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

  select * into v_client from advisor_clients
   where id = p_client_id and advisor_id = v_advisor;

  if v_client.id is null then
    raise exception 'client not found';
  end if;

  select email into v_email from auth.users where id = v_client.member_user_id;

  insert into bookings (
    user_id, user_name, user_email,
    service, session_type, session_mode,
    requested_date, requested_time,
    status, booked_by, advisor_id, advisor_client_id,
    client_type, member_response, created_at
  ) values (
    v_client.member_user_id,                                     -- NULL for a non-member client
    trim(coalesce(v_client.first_name,'') || ' ' || coalesce(v_client.last_name,'')),
    coalesce(v_email, v_client.email),
    p_service,
    p_session_type,
    p_session_mode,
    p_date,
    p_time,
    'pending',
    'advisor',
    v_advisor,
    v_client.id,
    'member',
    null,
    now()
  )
  returning id into v_id;

  if p_note is not null and trim(p_note) <> '' then
    insert into advisor_notes (client_id, advisor_id, booking_id, body)
    values (v_client.id, v_advisor, v_id, p_note);
  end if;

  return jsonb_build_object(
    'booking_id',  v_id,
    'is_member',   v_client.member_user_id is not null,
    'notify_email', coalesce(v_email, v_client.email)
  );
end;
$$;

grant execute on function advisor_book_session(uuid, text, text, date, text, text, text) to authenticated;


-- ══════════════════════════════════════════════════════════════
-- SECTION F — Member responds to an advisor-scheduled session
-- ══════════════════════════════════════════════════════════════

create or replace function member_respond_booking(
  p_booking_id uuid,
  p_response   text,
  p_note       text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_row bookings%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not authorised';
  end if;

  if p_response not in ('accepted','declined','reschedule_requested') then
    raise exception 'invalid response';
  end if;

  select * into v_row from bookings
   where id = p_booking_id and user_id = auth.uid();

  if v_row.id is null then
    raise exception 'booking not found';
  end if;

  if v_row.booked_by <> 'advisor' then
    raise exception 'only advisor-scheduled sessions can be responded to';
  end if;

  update bookings
     set member_response       = p_response,
         member_response_at    = now(),
         member_response_note  = nullif(trim(coalesce(p_note,'')), ''),
         advisor_seen_response = false,
         status = case
                    when p_response = 'accepted' then 'confirmed'
                    when p_response = 'declined' then 'cancelled'
                    else status
                  end,
         updated_at = now()
   where id = p_booking_id;

  return jsonb_build_object('ok', true, 'response', p_response);
end;
$$;

grant execute on function member_respond_booking(uuid, text, text) to authenticated;


-- ══════════════════════════════════════════════════════════════
-- SECTION G — Admin: assign a member to an advisor
-- ══════════════════════════════════════════════════════════════

create or replace function admin_assign_client(p_advisor_id uuid, p_member_user_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id    uuid;
  v_email text;
  v_fn    text;
  v_ln    text;
  v_org   uuid;
begin
  if not is_admin() then
    raise exception 'not authorised';
  end if;

  select id into v_id from advisor_clients
   where advisor_id = p_advisor_id and member_user_id = p_member_user_id;
  if v_id is not null then
    return v_id;
  end if;

  select u.email, p.first_name, p.last_name, p.org_id
    into v_email, v_fn, v_ln, v_org
    from auth.users u
    left join profiles p on p.id = u.id
   where u.id = p_member_user_id;

  if v_email is null then
    raise exception 'member not found';
  end if;

  insert into advisor_clients
    (advisor_id, member_user_id, first_name, last_name, email, org_id, source, linked_at, created_by)
  values
    (p_advisor_id, p_member_user_id, coalesce(v_fn, split_part(v_email,'@',1)), v_ln,
     v_email, v_org, 'admin_assigned', now(), auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function admin_assign_client(uuid, uuid) to authenticated;


-- ══════════════════════════════════════════════════════════════
-- SECTION H — Admin / HR reporting: per-advisor session breakdown
--
-- Companion to org_report_data(). Same authz rule (admin, or the HR
-- manager of that org) and the same period filter — bookings.created_at
-- between p_start and p_end — so the totals here reconcile with the
-- `sessions` block of the org report.
--
-- p_org_id NULL is admin-only and means "all organisations".
--
-- Small-cell suppression is NOT applied to advisor rows: this is
-- operational management data about STAFF, not member cohort data.
-- The member-level cohort guards in org_report_data() are unchanged.
-- ══════════════════════════════════════════════════════════════

create or replace function advisor_session_breakdown(
  p_org_id uuid,
  p_start  date,
  p_end    date
)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_rows   jsonb;
  v_totals jsonb;
begin
  if p_org_id is null then
    if not is_admin() then
      raise exception 'not authorised';
    end if;
  else
    if not (is_admin() or coalesce(employer_org() = p_org_id, false)) then
      raise exception 'not authorised';
    end if;
  end if;

  with scoped as (
    select b.*, a.full_name as advisor_name, a.is_active as advisor_active
    from bookings b
    left join profiles p  on p.id = b.user_id
    left join advisors a  on a.id = b.advisor_id
    where b.created_at::date between p_start and p_end
      and (p_org_id is null or p.org_id = p_org_id)
  )
  select
    coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.booked desc), '[]'::jsonb)
  into v_rows
  from (
    select
      coalesce(s.advisor_id::text, 'unassigned')            as advisor_id,
      coalesce(s.advisor_name, 'Unassigned / self-booked')  as advisor_name,
      coalesce(s.advisor_active, true)                      as advisor_active,
      count(*)                                              as booked,
      count(*) filter (where s.attended is true)            as attended,
      count(*) filter (where s.attended is false)           as no_show,
      count(*) filter (where s.attended is null)            as unconfirmed,
      count(*) filter (where s.status = 'cancelled')        as cancelled,
      count(*) filter (where s.member_response = 'declined')            as declined_by_member,
      count(*) filter (where s.member_response = 'reschedule_requested') as reschedule_requested,
      count(distinct coalesce(s.user_id::text, s.advisor_client_id::text)) as unique_clients,
      case when count(*) filter (where s.attended is not null) = 0 then null
           else round(100.0 * count(*) filter (where s.attended is true)
                      / count(*) filter (where s.attended is not null), 1)
      end                                                   as attendance_rate
    from scoped s
    group by 1, 2, 3
  ) t;

  with scoped as (
    select b.*
    from bookings b
    left join profiles p on p.id = b.user_id
    where b.created_at::date between p_start and p_end
      and (p_org_id is null or p.org_id = p_org_id)
  )
  select jsonb_build_object(
    'total_booked',    count(*),
    'total_attended',  count(*) filter (where attended is true),
    'advisor_sourced', count(*) filter (where booked_by = 'advisor'),
    'self_booked',     count(*) filter (where booked_by <> 'advisor'),
    'advisor_sourced_attended', count(*) filter (where booked_by = 'advisor' and attended is true),
    'self_booked_attended',     count(*) filter (where booked_by <> 'advisor' and attended is true),
    'advisor_sourced_pct', case when count(*) = 0 then null
                                else round(100.0 * count(*) filter (where booked_by = 'advisor') / count(*), 1) end,
    'declined_by_member',   count(*) filter (where member_response = 'declined'),
    'awaiting_response',    count(*) filter (where booked_by = 'advisor' and member_response is null and status = 'pending')
  )
  into v_totals
  from scoped;

  return jsonb_build_object(
    'org_id',       p_org_id,
    'period_start', p_start,
    'period_end',   p_end,
    'totals',       v_totals,
    'by_advisor',   v_rows
  );
end;
$$;

grant execute on function advisor_session_breakdown(uuid, date, date) to authenticated;


-- ══════════════════════════════════════════════════════════════
-- SECTION I — Monthly trend of advisor-sourced vs self-booked
-- Feeds the admin utilisation chart.
-- ══════════════════════════════════════════════════════════════

create or replace function session_source_trend(
  p_org_id uuid,
  p_start  date,
  p_end    date
)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare v_out jsonb;
begin
  if p_org_id is null then
    if not is_admin() then raise exception 'not authorised'; end if;
  else
    if not (is_admin() or coalesce(employer_org() = p_org_id, false)) then
      raise exception 'not authorised';
    end if;
  end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.month), '[]'::jsonb)
    into v_out
  from (
    select
      to_char(date_trunc('month', b.created_at at time zone 'Africa/Gaborone'), 'YYYY-MM') as month,
      count(*) filter (where b.booked_by = 'advisor')  as advisor_sourced,
      count(*) filter (where b.booked_by <> 'advisor') as self_booked,
      count(*) filter (where b.attended is true)       as attended
    from bookings b
    left join profiles p on p.id = b.user_id
    where b.created_at::date between p_start and p_end
      and (p_org_id is null or p.org_id = p_org_id)
    group by 1
  ) t;

  return v_out;
end;
$$;

grant execute on function session_source_trend(uuid, date, date) to authenticated;


-- ══════════════════════════════════════════════════════════════
-- SECTION J — Admin: advisor roster with live caseload counts
-- ══════════════════════════════════════════════════════════════

create or replace function admin_advisor_roster()
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare v_out jsonb;
begin
  if not is_admin() then
    raise exception 'not authorised';
  end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.full_name), '[]'::jsonb)
    into v_out
  from (
    select
      a.id, a.full_name, a.email, a.phone, a.title, a.is_active,
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


-- ══════════════════════════════════════════════════════════════
-- Verification
--   select advisor_me();
--   select advisor_clients_list();
--   select advisor_session_breakdown(null, current_date - 90, current_date);
--   select admin_advisor_roster();
-- ============================================================
