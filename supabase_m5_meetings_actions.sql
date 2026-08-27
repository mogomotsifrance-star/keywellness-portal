-- ============================================================
-- Key Wellness — M5: meetings, actions and reminders
-- From docs/data-model-and-impact.md §3 and §4, and
-- docs/operating-model.md §4.4 and §5.
--
-- Run in the Supabase SQL Editor. Idempotent — safe to re-run.
-- Rollback: migrations/rollback-m5-meetings-actions.sql
-- Tests:    tests/m5-tests.sql   (local, PostgreSQL 17)
-- Verify:   tests/m5-verify-live.sql (read-only, this editor)
--
-- This is the migration that fixes "decisions are not recorded anywhere; each
-- person has to remember their own actions" (operating-model.md §0). It ships
-- before the confidentiality work because an action ledger needs none of it.
--
-- WHAT THIS ADDS
--   organizations.is_test   one column, so the Tuesday roll-call can hide Test Co
--   meetings                tuesday_review | client | other
--   actions                 title, owner, due date, state, carried_from
--   action_reminders        the idempotency ledger behind the notifications
--   is_staff()              the single gate M3 extends with is_counsellor()
--   action_reminders_run()  the scheduled writer; pg_cron calls it
--   tuesday_review_open()   one-click "start Tuesday's review"
--   tuesday_review_pack()   the review screen's data
--   action_upsert()         create and edit
--
-- WHAT THIS DOES NOT ADD
--   No decisions table. Every decision that matters produces an action, and
--   meetings.notes carries the rare one that does not. Decided 26 Aug 2026:
--   a table with no reader is speculation. If "what did we decide about X"
--   ever gets asked, that is the signal to add it.
--
-- ── FOUR THINGS TO KNOW ─────────────────────────────────────
--
-- (a) DEPLOY PRECONDITION: Lone, Michelle and Laone need auth accounts.
--     actions.owner references auth.users because notifications.user_id does,
--     and you cannot remind a person who does not exist. Live today: all 4
--     admins have accounts, but only 2 of 5 advisors carry user_id and one
--     advisor has no account at all — that advisor cannot own an action.
--
-- (b) Laone is neither admin nor advisor, so is_staff() is false for her. The
--     actions read policy is therefore `is_staff() OR owner = auth.uid()`, so
--     an owner who is not staff reads their own actions and nothing else.
--     Without that clause she would receive a reminder about an action she
--     could not open. Whether she gets a proper role is M4's question.
--
-- (c) `unique nulls not distinct` on meetings is load-bearing. A tuesday_review
--     has org_id null, and PostgreSQL treats NULLs as DISTINCT in a unique
--     constraint by default — so a plain unique(kind, held_on, org_id) would
--     happily accept ten reviews for the same Tuesday. NULLS NOT DISTINCT is
--     PG15+; production is 17.6. This is what makes tuesday_review_open()
--     idempotent, and Prompt 3's one-click empty state safe to double-click.
--
-- (d) pg_cron IS installed on this project (confirmed 27 Aug 2026 against the
--     live database; an earlier note here said otherwise and was wrong). The
--     schedule block at the end therefore runs on the FIRST apply and there is
--     no second run to remember. The block stays guarded so this file still
--     applies cleanly to a database without the extension. The reminder
--     function is pure SQL and needs no pg_net.
--
-- ── WHAT THIS WILL CHANGE, AND WHAT IT WILL NOT ─────────────
-- Written BEFORE the apply, as the prediction to check the result against.
--
--   CHANGES
--     organizations gains an is_test column, false on every existing row.
--     Three new tables appear, all empty: meetings, actions, action_reminders.
--     Five new functions appear. Eight policies appear across meetings and
--     actions; action_reminders gets none, on purpose.
--     A daily job called kw-action-reminders is scheduled for 04:00 UTC,
--     which is 06:00 in Gaborone — before the working day, not during it.
--
--   DOES NOT CHANGE
--     No existing row in any existing table is read, written or deleted.
--     Booking counts, notification counts, points and every reporting figure
--     are untouched, because nothing here reads or writes bookings.
--     Nobody gains access to anything they could not already see: HR and
--     members get no policy at all, so row-level security denies them.
--
--   IF IT IS WRONG
--     The worst case is a table nobody can read, or a reminder that does not
--     fire. No existing data can be damaged, because nothing existing is
--     written to. Undo with migrations/rollback-m5-meetings-actions.sql,
--     which deletes the reminder notifications it wrote and drops everything
--     it created.
-- ============================================================


-- ── 1. organizations.is_test ────────────────────────────────
-- Test Co owns all four issued reports and 13 of 22 bookings. It must not
-- appear in the Tuesday roll-call. One column now rather than a proposal in
-- Prompt 6: shipping the first screen Lone sees with a test organisation in
-- it is the wrong first impression. Prompt 6 inherits this flag.
--
-- Set it in the deploy note, not here — this migration does not name
-- organisations.

alter table organizations add column if not exists is_test boolean not null default false;

comment on column organizations.is_test is
  'Excludes the organisation from ops surfaces (Tuesday roll-call, work plans). '
  'Reporting RPCs are unaffected. Set by hand; see docs/build/m5-meetings-actions.md.';


-- ── 2. is_staff() ───────────────────────────────────────────
-- One place for "may this person see the ops workspace". M3 adds
-- `or is_counsellor()` here and nowhere else.
--
-- Gated helpers like this are deliberately granted to authenticated — the
-- check lives inside the policy that calls it. See CLAUDE.md, Roles &
-- Interfaces.

create or replace function is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select is_admin() or is_advisor();     -- M3: or is_counsellor()
$$;

grant execute on function is_staff() to authenticated;


-- ── 3. meetings ─────────────────────────────────────────────

create table if not exists meetings (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null default 'tuesday_review',
  held_on     date not null,
  org_id      uuid references organizations(id),
  attendees   uuid[] not null default '{}'::uuid[],
  title       text,
  notes       text,
  created_by  uuid not null references auth.users(id),
  created_at  timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'meetings_kind_check') then
    alter table meetings add constraint meetings_kind_check
      check (kind in ('tuesday_review','client','other'));
  end if;

  -- NULLS NOT DISTINCT: see note (c). Without it this constraint does nothing
  -- for the weekly review, which is the only kind that has org_id null.
  if not exists (select 1 from pg_constraint where conname = 'meetings_one_per_kind_date_org') then
    alter table meetings add constraint meetings_one_per_kind_date_org
      unique nulls not distinct (kind, held_on, org_id);
  end if;
end $$;

comment on column meetings.attendees is
  'auth.users ids. No foreign key: PostgreSQL cannot reference an array element.';
comment on column meetings.notes is
  'Carries the occasional decision that produces no action. There is no '
  'decisions table by design — see the header.';


-- ── 4. actions ──────────────────────────────────────────────

create table if not exists actions (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  owner        uuid not null references auth.users(id),
  due_date     date not null,
  state        text not null default 'open',
  org_id       uuid references organizations(id),
  meeting_id   uuid references meetings(id) on delete set null,
  activity_id  uuid,
  carried_from uuid references actions(id) on delete set null,
  created_by   uuid not null references auth.users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  done_at      timestamptz
);

comment on column actions.activity_id is
  'work_plan_activities(id) once M4 exists. Deliberately no FK yet — the table '
  'does not exist, and M4 adds the constraint rather than M5 guessing at it.';
comment on column actions.carried_from is
  'The predecessor when an unfinished Tuesday action is re-issued. The '
  'predecessor moves to state dropped; "carried" is DERIVED as '
  'exists(select 1 from actions s where s.carried_from = a.id), which is what '
  'separates a carried action from an abandoned one without a fourth state.';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'actions_state_check') then
    alter table actions add constraint actions_state_check
      check (state in ('open','done','dropped'));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'actions_title_not_blank') then
    alter table actions add constraint actions_title_not_blank
      check (length(btrim(title)) > 0);
  end if;

  -- done and done_at move together, in both directions.
  if not exists (select 1 from pg_constraint where conname = 'actions_done_at_agrees_with_state') then
    alter table actions add constraint actions_done_at_agrees_with_state
      check ((state = 'done') = (done_at is not null));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'actions_no_self_carry') then
    alter table actions add constraint actions_no_self_carry
      check (carried_from is distinct from id);
  end if;
end $$;

create index if not exists actions_open_due_idx  on actions (due_date) where state = 'open';
create index if not exists actions_org_idx       on actions (org_id);
create index if not exists actions_meeting_idx   on actions (meeting_id);
create index if not exists actions_owner_idx     on actions (owner);
create index if not exists actions_carried_idx   on actions (carried_from) where carried_from is not null;


-- updated_at is maintained by trigger, not only by action_upsert(), because
-- admins can update the table directly under actions_owner_update.
create or replace function kw_touch_actions()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_actions_touch on actions;
create trigger trg_actions_touch
  before update on actions
  for each row execute function kw_touch_actions();


-- ── 5. action_reminders — the idempotency ledger ────────────
-- Reminders are delivered as rows in notifications, but notifications has no
-- natural key to dedupe on and a member may read or delete one. This table is
-- the memory; notifications is the delivery. The primary key does the whole
-- job of "a double-fire writes nothing twice".

create table if not exists action_reminders (
  action_id       uuid not null references actions(id) on delete cascade,
  kind            text not null,
  sent_at         timestamptz not null default now(),
  notification_id uuid references notifications(id) on delete set null,
  primary key (action_id, kind)
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'action_reminders_kind_check') then
    alter table action_reminders add constraint action_reminders_kind_check
      check (kind in ('due_in_3','due_tomorrow','overdue'));
  end if;
end $$;


-- ── 6. RLS ──────────────────────────────────────────────────
-- HR and members get no policy at all, so RLS denies them by default — the
-- same shape program_activities already uses.

alter table meetings          enable row level security;
alter table actions           enable row level security;
alter table action_reminders  enable row level security;

drop policy if exists meetings_staff_read   on meetings;
create policy meetings_staff_read on meetings
  for select using (is_staff());

drop policy if exists meetings_staff_insert on meetings;
create policy meetings_staff_insert on meetings
  for insert with check (is_staff() and created_by = auth.uid());

drop policy if exists meetings_staff_update on meetings;
create policy meetings_staff_update on meetings
  for update using (is_staff()) with check (is_staff());

drop policy if exists meetings_admin_delete on meetings;
create policy meetings_admin_delete on meetings
  for delete using (is_admin());

-- `or owner = auth.uid()` is not a convenience. Laone (the accountant) owns
-- invoice actions from M4 and is neither admin nor advisor; without this
-- clause she receives a reminder about an action she cannot open.
drop policy if exists actions_staff_read on actions;
create policy actions_staff_read on actions
  for select using (is_staff() or owner = auth.uid());

drop policy if exists actions_staff_insert on actions;
create policy actions_staff_insert on actions
  for insert with check (is_staff() and created_by = auth.uid());

drop policy if exists actions_owner_update on actions;
create policy actions_owner_update on actions
  for update using  (owner = auth.uid() or created_by = auth.uid() or is_admin())
             with check (owner = auth.uid() or created_by = auth.uid() or is_admin());

drop policy if exists actions_admin_delete on actions;
create policy actions_admin_delete on actions
  for delete using (is_admin());

-- action_reminders: RLS on, NO policy. Reachable only from SECURITY DEFINER
-- functions running as postgres. Not even an admin selects from it directly.
--
-- RLS with no policy already denies every row, but Supabase's default
-- privileges hand `authenticated` a table-level grant on anything created in
-- this schema. Revoking it means a future policy added here by accident does
-- not silently open the ledger — two independent locks, not one.
revoke all on table action_reminders from anon, authenticated;


-- ── 7. The derived carried label ───────────────────────────
-- Internal. A raw 'dropped' is ambiguous — it means abandoned OR carried —
-- and only the existence of a successor separates the two. Every RPC returns
-- the label so no screen has to re-derive it and get it wrong.

create or replace function _action_label(p_id uuid, p_state text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
           when p_state = 'dropped'
                and exists (select 1 from actions s where s.carried_from = p_id)
             then 'carried'
           else p_state
         end;
$$;

-- Every `_`-prefixed SECURITY DEFINER helper needs this, in the same migration
-- that creates it. Postgres grants EXECUTE to PUBLIC by default, so declining
-- to write a GRANT locks nothing. See CLAUDE.md, Roles & Interfaces.
revoke all on function _action_label(uuid, text) from public, anon, authenticated;


-- ── 8. action_reminders_run() — the scheduled writer ────────
-- Called by pg_cron as postgres. Revoked from everyone else.
--
-- p_today exists so the tests can drive the clock without freezing it. It
-- defaults to the Gaborone date, not UTC: a reminder must fire on a Botswana
-- day or it lands a day early for half the year's worth of edge cases.
--
-- 'overdue' fires ONCE. A daily nag trains people to ignore it; a standing
-- overdue list belongs on the daily view, which is a screen, not a message.

create or replace function action_reminders_run(p_today date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_today   date := coalesce(p_today, (now() at time zone 'Africa/Gaborone')::date);
  r         record;
  v_kind    text;
  v_note    uuid;
  v_sent    jsonb := jsonb_build_object('due_in_3', 0, 'due_tomorrow', 0, 'overdue', 0);
  v_scanned int  := 0;
  v_skipped int  := 0;
begin
  for r in
    select a.id, a.title, a.owner, a.due_date, o.name as org_name
      from actions a
      left join organizations o on o.id = a.org_id
     where a.state = 'open'
  loop
    v_scanned := v_scanned + 1;

    v_kind := case
                when r.due_date - v_today = 3 then 'due_in_3'
                when r.due_date - v_today = 1 then 'due_tomorrow'
                when r.due_date - v_today < 0 then 'overdue'
              end;

    if v_kind is null then
      continue;
    end if;

    -- The ledger decides. If this row already exists the reminder has been
    -- sent and no notification is written, which is what makes a second run
    -- in the same day a genuine no-op.
    insert into action_reminders (action_id, kind)
    values (r.id, v_kind)
    on conflict (action_id, kind) do nothing;

    if not found then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    insert into notifications (user_id, type, title, body)
    values (
      r.owner,
      'action_' || v_kind,
      case v_kind
        when 'due_in_3'      then 'Action due in 3 days'
        when 'due_tomorrow'  then 'Action due tomorrow'
        else                      'Action overdue'
      end,
      r.title
        || coalesce(' · ' || r.org_name, '')
        || ' · due ' || to_char(r.due_date, 'DD Mon YYYY')
    )
    returning id into v_note;

    update action_reminders
       set notification_id = v_note
     where action_id = r.id and kind = v_kind;

    v_sent := jsonb_set(v_sent, array[v_kind],
                        to_jsonb((v_sent ->> v_kind)::int + 1));
  end loop;

  return jsonb_build_object(
    'today',               v_today,
    'scanned',             v_scanned,
    'sent',                v_sent,
    'skipped_already_sent', v_skipped
  );
end $$;

revoke all on function action_reminders_run(date) from public, anon, authenticated;


-- ── 9. tuesday_review_open() ────────────────────────────────
-- Prompt 3's one-click empty state. Idempotent on the unique constraint, so a
-- double-click reopens the same meeting rather than forking the morning.
-- Returns the meeting plus last week's still-open actions, ready to carry.

create or replace function tuesday_review_open(p_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_date    date := coalesce(p_date, (now() at time zone 'Africa/Gaborone')::date);
  v_id      uuid;
  v_created boolean := false;
  v_prev    uuid;
begin
  if not is_staff() then
    raise exception 'not authorised';
  end if;

  select id into v_id
    from meetings
   where kind = 'tuesday_review' and held_on = v_date and org_id is null;

  if v_id is null then
    insert into meetings (kind, held_on, org_id, created_by)
    values ('tuesday_review', v_date, null, auth.uid())
    on conflict do nothing
    returning id into v_id;

    v_created := v_id is not null;

    -- Lost the race, or the row already existed: read it back.
    if v_id is null then
      select id into v_id
        from meetings
       where kind = 'tuesday_review' and held_on = v_date and org_id is null;
    end if;
  end if;

  select id into v_prev
    from meetings
   where kind = 'tuesday_review' and org_id is null and held_on < v_date
   order by held_on desc
   limit 1;

  return jsonb_build_object(
    'meeting_id',    v_id,
    'held_on',       v_date,
    'created',       v_created,
    'previous_meeting_id', v_prev,
    'carry_candidates', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',       a.id,
               'title',    a.title,
               'owner',    a.owner,
               'due_date', a.due_date,
               'org_id',   a.org_id,
               'org_name', o.name
             ) order by o.name nulls last, a.due_date)
        from actions a
        left join organizations o on o.id = a.org_id
       where a.state = 'open'
         and v_prev is not null
         and a.meeting_id = v_prev
    ), '[]'::jsonb)
  );
end $$;

grant execute on function tuesday_review_open(date) to authenticated;


-- ── 10. tuesday_review_pack() ────────────────────────────────
-- What the review screen walks: operating-model.md §5, items 3 and 4, for
-- each organisation in turn. Work plans and retainer position arrive with M4;
-- this returns what exists now.
--
-- completion_rate is the number operating-model.md §4.4 says should be the
-- first the system produces — "what share of Tuesday actions are done by the
-- next Tuesday". Denominator is done + open + dropped-with-successor.
-- An action dropped on purpose is excluded: deciding not to do something is
-- not a failure to deliver.

create or replace function tuesday_review_pack(p_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Africa/Gaborone')::date);
  v_prev uuid;
  v_this uuid;
begin
  if not is_staff() then
    raise exception 'not authorised';
  end if;

  select id into v_this
    from meetings
   where kind = 'tuesday_review' and held_on = v_date and org_id is null;

  select id into v_prev
    from meetings
   where kind = 'tuesday_review' and org_id is null and held_on < v_date
   order by held_on desc
   limit 1;

  return jsonb_build_object(
    'as_of',               v_date,
    'meeting_id',          v_this,
    'previous_meeting_id', v_prev,

    'completion_rate', (
      select case when count(*) filter (where denom) = 0 then null
                  else round(100.0 * count(*) filter (where a.state = 'done')
                             / count(*) filter (where denom), 1)
             end
        from (
          select a.*,
                 (a.state in ('done','open')
                  or (a.state = 'dropped'
                      and exists (select 1 from actions s where s.carried_from = a.id))) as denom
            from actions a
           where v_prev is not null and a.meeting_id = v_prev
        ) a
    ),

    'organisations', coalesce((
      select jsonb_agg(x order by x ->> 'name')
        from (
          select jsonb_build_object(
            'org_id',   o.id,
            'name',     o.name,
            'last_week', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'id', a.id, 'title', a.title, 'owner', a.owner,
                       'due_date', a.due_date, 'state', a.state,
                       'label', _action_label(a.id, a.state)
                     ) order by a.due_date)
                from actions a
               where v_prev is not null and a.meeting_id = v_prev and a.org_id = o.id
            ), '[]'::jsonb),
            'open_now', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'id', a.id, 'title', a.title, 'owner', a.owner,
                       'due_date', a.due_date,
                       'overdue', a.due_date < v_date
                     ) order by a.due_date)
                from actions a
               where a.state = 'open' and a.org_id = o.id
            ), '[]'::jsonb),
            'open_count', (
              select count(*) from actions a
               where a.state = 'open' and a.org_id = o.id),
            'needs_decision', exists (
              select 1 from actions a
               where a.state = 'open' and a.org_id = o.id and a.due_date < v_date)
          ) as x
          from organizations o
         where o.is_active and not o.is_test
        ) s
    ), '[]'::jsonb),

    -- Actions that belong to no organisation still have to be walked.
    'unassigned', jsonb_build_object(
      'last_week', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', a.id, 'title', a.title, 'owner', a.owner,
                 'due_date', a.due_date, 'state', a.state,
                 'label', _action_label(a.id, a.state)
               ) order by a.due_date)
          from actions a
         where v_prev is not null and a.meeting_id = v_prev and a.org_id is null
      ), '[]'::jsonb),
      'open_now', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', a.id, 'title', a.title, 'owner', a.owner,
                 'due_date', a.due_date, 'overdue', a.due_date < v_date
               ) order by a.due_date)
          from actions a
         where a.state = 'open' and a.org_id is null
      ), '[]'::jsonb)
    )
  );
end $$;

grant execute on function tuesday_review_pack(date) to authenticated;


-- ── 11. action_upsert() ─────────────────────────────────────
-- Required arguments first and undefaulted, so PostgREST cannot resolve an
-- ambiguous call. advisor_clients_list learned that the hard way: a
-- one-argument call went ambiguous and the old overload had to be dropped.
--
-- On update, a null parameter means "leave alone". That means org_id and
-- meeting_id cannot be CLEARED through this RPC; nothing needs to yet, and
-- adding a sentinel for it now would be a guess.
--
-- Passing p_carried_from on insert carries an action forward: the successor
-- is created and the predecessor moves to dropped, in one statement pair, so
-- the two never disagree.

create or replace function action_upsert(
  p_title        text,
  p_owner        uuid,
  p_due_date     date,
  p_id           uuid default null,
  p_state        text default null,
  p_org_id       uuid default null,
  p_meeting_id   uuid default null,
  p_activity_id  uuid default null,
  p_carried_from uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_id  uuid;
  v_row actions%rowtype;
begin
  if p_id is null then
    if not is_staff() then
      raise exception 'not authorised';
    end if;

    insert into actions (title, owner, due_date, state, org_id, meeting_id,
                         activity_id, carried_from, created_by, done_at)
    values (p_title, p_owner, p_due_date, coalesce(p_state, 'open'),
            p_org_id, p_meeting_id, p_activity_id, p_carried_from, auth.uid(),
            case when coalesce(p_state,'open') = 'done' then now() end)
    returning id into v_id;

    if p_carried_from is not null then
      update actions
         set state = 'dropped', done_at = null
       where id = p_carried_from and state = 'open';
    end if;
  else
    -- Re-checked here rather than trusting the policy alone: this function is
    -- SECURITY DEFINER and therefore bypasses RLS on its own writes.
    if not exists (
      select 1 from actions a
       where a.id = p_id
         and (a.owner = auth.uid() or a.created_by = auth.uid() or is_admin())
    ) then
      raise exception 'not authorised';
    end if;

    update actions a
       set title       = coalesce(p_title, a.title),
           owner       = coalesce(p_owner, a.owner),
           due_date    = coalesce(p_due_date, a.due_date),
           state       = coalesce(p_state, a.state),
           org_id      = coalesce(p_org_id, a.org_id),
           meeting_id  = coalesce(p_meeting_id, a.meeting_id),
           activity_id = coalesce(p_activity_id, a.activity_id),
           done_at     = case
                           when coalesce(p_state, a.state) = 'done'
                             then coalesce(a.done_at, now())
                           else null
                         end
     where a.id = p_id
    returning a.id into v_id;
  end if;

  select * into v_row from actions where id = v_id;

  return jsonb_build_object(
    'id', v_row.id, 'title', v_row.title, 'owner', v_row.owner,
    'due_date', v_row.due_date, 'state', v_row.state,
    'label', _action_label(v_row.id, v_row.state),
    'org_id', v_row.org_id, 'meeting_id', v_row.meeting_id,
    'carried_from', v_row.carried_from, 'done_at', v_row.done_at
  );
end $$;

grant execute on function action_upsert(text, uuid, date, uuid, text, uuid, uuid, uuid, uuid)
  to authenticated;


-- ── 12. The schedule ────────────────────────────────────────
-- pg_cron IS installed on this project (confirmed 27 Aug 2026), so this runs
-- on the first apply. The guard stays anyway: EXECUTE is mandatory rather than
-- stylistic, because a bare cron.schedule(...) fails to PARSE on a database
-- where the cron schema is absent, and this file must still apply there.
--
-- 04:00 UTC is 06:00 in Gaborone — before the working day, not during it.

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute $c$
      select cron.schedule('kw-action-reminders', '0 4 * * *',
                           $j$ select action_reminders_run() $j$)
    $c$;
    raise notice 'M5: pg_cron job kw-action-reminders scheduled for 04:00 UTC.';
  else
    raise notice 'M5: pg_cron is NOT installed here — reminders will not fire. '
                 'It IS installed on the live project; if you see this on live, '
                 'something has changed. Enable it in Database -> Extensions, '
                 'then re-run this file.';
  end if;
end $$;


-- ── 13. Post-conditions ─────────────────────────────────────

do $$
declare
  n int;
begin
  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename in ('meetings','actions');
  if n <> 8 then
    raise exception 'M5: expected 8 policies on meetings+actions, found %', n;
  end if;

  if exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'action_reminders') then
    raise exception 'M5: action_reminders must have no policy — it is definer-only';
  end if;

  select count(*) into n from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public'
     and c.relname in ('meetings','actions','action_reminders')
     and c.relrowsecurity;
  if n <> 3 then
    raise exception 'M5: RLS is not enabled on all three tables (found %)', n;
  end if;

  raise notice 'M5 applied. pg_cron: %.',
    case when exists (select 1 from pg_extension where extname='pg_cron')
         then 'scheduled' else 'NOT INSTALLED — reminders will not fire' end;
end $$;
