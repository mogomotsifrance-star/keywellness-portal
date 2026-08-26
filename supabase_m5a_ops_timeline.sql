-- ============================================================
-- Key Wellness — M5a: ops_timeline()
--
-- One SECURITY DEFINER read behind the Tuesday review's "Since last Tuesday"
-- and "Coming up" sections, and the daily view's centre column.
--
-- Run AFTER supabase_m1_service_line.sql and supabase_m5_meetings_actions.sql
-- (it reads service_line, and is gated by is_staff()).
-- Idempotent — safe to re-run.
-- Rollback: migrations/rollback-m5a-ops-timeline.sql
-- Tests:    tests/m5a-tests.sql   (local, PostgreSQL 17)
-- Verify:   tests/m5a-verify-live.sql (read-only, this editor)
--
-- ── WHY THIS IS A FUNCTION AND NOT THREE PAGE QUERIES ───────
--
-- (a) An advisor would otherwise see a smaller world, silently.
--     bookings_advisor_select limits an advisor to their own bookings and the
--     clients on their caseload; program_activities_admin_all is admin-only.
--     A practitioner opening ops.html would get a partial timeline with
--     nothing on the page to say so. One definer read gives every staff
--     member the same answer.
--
-- (b) bookings.requested_date is TEXT, and live holds '2099-12-31'. Date
--     filtering belongs in SQL behind a defensive cast, not in JavaScript
--     against a column that can hold anything. See _ops_as_date().
--
-- ── THE OBLIGATION THIS CREATES FOR M3 ──────────────────────
--
-- SECURITY DEFINER runs as postgres and therefore BYPASSES row-level
-- security. Today that is harmless: every booking is service_line
-- 'financial', so there is nothing a staff member should not see.
--
-- M3 changes that. The moment counselling bookings exist, the confidentiality
-- boundary M3 builds into the bookings POLICIES does not apply here, because
-- this function never consults them. **M3 must gate psychosocial rows inside
-- ops_timeline() itself**, using whichever mechanism it picks for the admin
-- split, and M3's tests must include:
--
--     "a France-type admin calling ops_timeline() sees no psychosocial rows"
--
-- Without that, France reads every counselling booking through this function
-- while the policy that was supposed to stop him sits unused. This is exactly
-- the shape of the finding in docs/build/00-live-schema-snapshot.md §11 F6 —
-- a boundary that looks enforced but is routed around.
-- ============================================================


-- ── 1. The defensive date cast ──────────────────────────────
-- bookings.requested_date is free text. Anything that is not an ISO date
-- returns null rather than raising, so one malformed row cannot take the
-- Tuesday review down mid-meeting.

-- The shape matters. A regex alone is not enough: to_date() is lenient and
-- silently rolls '2026-13-45' over into 2027-02-14 rather than refusing it,
-- so a typo would become a plausible-looking date on the Tuesday screen.
-- Casting inside an exception block is the only version that returns null for
-- input that merely looks like a date.
create or replace function _ops_as_date(p_text text)
returns date
language plpgsql
immutable
as $$
begin
  if p_text is null or p_text !~ '^\d{4}-\d{2}-\d{2}$' then
    return null;
  end if;
  return p_text::date;
exception when others then
  return null;
end $$;

revoke all on function _ops_as_date(text) from public, anon, authenticated;


-- ── 2. ops_timeline() ───────────────────────────────────────
-- Called twice by the page: once for the week behind ("Since last Tuesday")
-- and once for the fortnight ahead ("Coming up").
--
-- Test organisations are excluded HERE, not on the page. A caller cannot
-- forget to filter, and a second surface built later inherits the exclusion
-- for free.

create or replace function ops_timeline(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_out jsonb;
begin
  if not is_staff() then
    raise exception 'not authorised';
  end if;

  if p_to < p_from then
    raise exception 'p_to must not be before p_from';
  end if;

  with items as (
    -- Sessions. bookings has no org_id; attribution runs through the member's
    -- profile, which is how org_report_data() counts them too.
    select p.org_id,
           'booking'::text                          as kind,
           b.id,
           coalesce(_ops_as_date(b.requested_date),
                    b.created_at::date)             as on_date,
           b.service_line,
           coalesce(nullif(btrim(b.service), ''), 'Session') as title,
           coalesce(ad.full_name, '')               as practitioner,
           b.session_mode                           as mode,
           b.session_format                         as format,
           case when b.attended is true  then 'attended'
                when b.attended is false then 'did not attend'
                else coalesce(b.status, 'pending') end as state,
           null::int                                as attendee_count
      from bookings b
      left join profiles p  on p.id  = b.user_id
      left join advisors ad on ad.id = b.advisor_id

    union all

    -- Delivered group work: talks, clinics, webinars run as activities.
    select a.org_id,
           'activity',
           a.id,
           a.activity_date,
           a.service_line,
           a.title,
           '',
           a.delivery_mode,
           a.activity_type,
           'delivered',
           a.attendee_count
      from program_activities a

    union all

    -- Webinars as content, which is where their date lives.
    select c.org_id,
           'webinar',
           c.id,
           c.webinar_date,
           c.service_line,
           c.title,
           '',
           null,
           'webinar',
           case when c.published then 'published' else 'draft' end,
           null::int
      from content_items c
     where c.kind = 'webinar' and c.webinar_date is not null
  ),
  windowed as (
    select * from items
     where on_date is not null
       and on_date between p_from and p_to
  )
  select jsonb_build_object(
    'from', p_from,
    'to',   p_to,
    'organisations', coalesce((
      select jsonb_agg(x order by x ->> 'name')
        from (
          select jsonb_build_object(
                   'org_id', o.id,
                   'name',   o.name,
                   'items',  coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'kind', w.kind, 'id', w.id, 'on_date', w.on_date,
                              'service_line', w.service_line, 'title', w.title,
                              'practitioner', w.practitioner, 'mode', w.mode,
                              'format', w.format, 'state', w.state,
                              'attendee_count', w.attendee_count
                            ) order by w.on_date, w.title)
                       from windowed w where w.org_id = o.id
                   ), '[]'::jsonb)
                 ) as x
            from organizations o
           where o.is_active
             and not o.is_test          -- excluded in here, never on the page
        ) s
    ), '[]'::jsonb),

    -- Sessions booked by someone with no organisation on their profile. They
    -- are real work and would otherwise vanish from the week entirely.
    'unassigned', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', w.kind, 'id', w.id, 'on_date', w.on_date,
               'service_line', w.service_line, 'title', w.title,
               'practitioner', w.practitioner, 'mode', w.mode,
               'format', w.format, 'state', w.state,
               'attendee_count', w.attendee_count
             ) order by w.on_date, w.title)
        from windowed w where w.org_id is null
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end $$;

grant execute on function ops_timeline(date, date) to authenticated;


-- ── 3. Post-conditions ──────────────────────────────────────

do $$
begin
  if has_function_privilege('anon', '_ops_as_date(text)', 'EXECUTE')
  or has_function_privilege('authenticated', '_ops_as_date(text)', 'EXECUTE') then
    raise exception 'M5a: _ops_as_date must not be callable by anon or authenticated';
  end if;

  if not has_function_privilege('authenticated', 'ops_timeline(date, date)', 'EXECUTE') then
    raise exception 'M5a: ops_timeline must be callable by authenticated';
  end if;

  raise notice 'M5a applied. Remember: M3 must gate psychosocial rows INSIDE '
               'ops_timeline() — it is SECURITY DEFINER and bypasses the '
               'bookings policies M3 splits by service line.';
end $$;
