-- ============================================================
-- Key Wellness — M4: contracts, work plans, activities, invoices
-- From docs/data-model-and-impact.md §3, with the 26 Aug decisions on
-- contract_kind and the rate card (CLAUDE_CONTEXT.md §2).
--
-- Run AFTER M1 (service_line) and M5 (is_staff, actions, organizations.is_test).
-- Idempotent — safe to re-run.
-- Rollback: migrations/rollback-m4-contracts-workplans-invoices.sql
-- Tests:    tests/m4-tests.sql   (local, PostgreSQL 17)
-- Verify:   tests/m4-verify-live.sql (read-only, this editor)
--
-- ══ SEVEN THINGS TO KNOW ═══════════════════════════════════
--
-- (a) NOT EVERY CLIENT IS ON RETAINER. Some are incidental, billed per
--     engagement at prices known in advance. org_contracts.contract_kind
--     splits them; contract_rates is the rate card (format x service_line ->
--     amount). A per-engagement client MAY have activities with no work plan,
--     so program_activities.work_plan_id is nullable and that is legitimate,
--     not a gap.
--
-- (b) program_activities is EXTENDED IN PLACE and keeps its name.
--     docs/data-model-and-impact.md §3 calls the extended table
--     work_plan_activities, but the same paragraph requires the old columns to
--     survive so org_report_data() keeps counting. Those cannot both happen
--     through a rename — org_report_data names program_activities directly.
--     activity_type is UNTOUCHED (it is a reporting input, constrained to five
--     values); the eight M4 values live in a NEW `format` column that nothing
--     reads yet.
--
-- (c) RETAINER INVOICES ARE BILLED IN ARREARS — the 1st-of-month job invoices
--     the month just ended, and the narrative is that month's delivered
--     activities. The alternative (billing the month ahead at the fixed
--     amount, with the previous month's delivery attaching to the REPORT
--     rather than the invoice) is recorded in the build record. The whole
--     difference is _invoice_period(); nothing else changes.
--
-- (d) OVERDUE IS DERIVED, never stored: state = 'sent' and due_date < today.
--     A stored overdue needs a job to maintain it and is wrong between runs.
--     Same reasoning as M5's carried label.
--
-- (e) THE TRANSITION TRIGGER FIRES ON A TRANSITION, NEVER ON ANY UPDATE.
--     docs/build/m1-service-line.md records that a column backfill fires every
--     AFTER UPDATE trigger on bookings — M1's backfill fired
--     trg_award_session_attended 22 times and was safe only because that
--     trigger is guarded on an attended-transition. This one must be guarded
--     the same way, or the next migration that touches bookings invoices the
--     entire back catalogue.
--
-- (f) TWO PARTIAL UNIQUE INDEXES ARE THE IDEMPOTENCY MECHANISM. Both invoice
--     jobs are re-runnable because the database refuses the duplicate, not
--     because the job remembers. Same shape as M5's
--     `unique nulls not distinct`.
--
-- (g) THE M3 OBLIGATION, AGAIN. org_work_plan() and contract_position() are
--     SECURITY DEFINER and bypass row-level security. Today every activity is
--     financial. The moment counselling work appears on a work plan, France
--     must not see it through these functions any more than through
--     ops_timeline(). M3 must gate psychosocial rows INSIDE both, and its
--     tests must include, by name:
--       "a France-type admin calling org_work_plan() sees no psychosocial rows"
--       "a France-type admin calling contract_position() sees no psychosocial rows"
-- ============================================================


-- ── 1. org_contracts ────────────────────────────────────────

create table if not exists org_contracts (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references organizations(id),
  contract_kind     text not null default 'retainer',
  included_lines    text[] not null default array['financial'],
  retainer_amount   numeric(12,2),
  billing_frequency text not null default 'monthly',
  covered_headcount integer,
  account_manager   uuid references auth.users(id),
  start_date        date not null,
  end_date          date,
  notice_period_days integer,
  auto_renew        boolean not null default false,
  reporting_cadence text,
  currency          text not null default 'BWP',
  status            text not null default 'draft',
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname='org_contracts_kind_check') then
    alter table org_contracts add constraint org_contracts_kind_check
      check (contract_kind in ('retainer','per_engagement'));
  end if;
  if not exists (select 1 from pg_constraint where conname='org_contracts_status_check') then
    alter table org_contracts add constraint org_contracts_status_check
      check (status in ('draft','active','closed'));
  end if;
  if not exists (select 1 from pg_constraint where conname='org_contracts_freq_check') then
    alter table org_contracts add constraint org_contracts_freq_check
      check (billing_frequency in ('monthly'));
  end if;
  -- A retainer without an amount cannot be invoiced; a per-engagement
  -- contract has no single amount to hold. Say so in the schema rather than
  -- discovering it on the first of the month.
  if not exists (select 1 from pg_constraint where conname='org_contracts_amount_agrees_with_kind') then
    alter table org_contracts add constraint org_contracts_amount_agrees_with_kind
      check ((contract_kind = 'retainer') = (retainer_amount is not null));
  end if;
  if not exists (select 1 from pg_constraint where conname='org_contracts_dates_check') then
    alter table org_contracts add constraint org_contracts_dates_check
      check (end_date is null or end_date >= start_date);
  end if;
end $$;

create index if not exists org_contracts_org_idx on org_contracts (org_id, status);


-- ── 2. contract_rates — the rate card ───────────────────────
-- Per-engagement prices are known in advance, so they are recorded rather
-- than negotiated per invoice.

create table if not exists contract_rates (
  contract_id  uuid not null references org_contracts(id) on delete cascade,
  format       text not null,
  service_line text not null default 'financial',
  amount       numeric(12,2) not null,
  primary key (contract_id, format, service_line)
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname='contract_rates_line_check') then
    alter table contract_rates add constraint contract_rates_line_check
      check (service_line in ('financial','psychosocial'));
  end if;
  if not exists (select 1 from pg_constraint where conname='contract_rates_amount_check') then
    alter table contract_rates add constraint contract_rates_amount_check
      check (amount >= 0);
  end if;
end $$;


-- ── 3. org_contacts ─────────────────────────────────────────
-- M4 needs only "who is the HR contact". receives_flyers and direct_to_staff
-- are here because M6 reads them and adding a column later to a table with
-- rows is more disruptive than carrying two booleans nothing reads yet.

create table if not exists org_contacts (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references organizations(id),
  name            text not null,
  email           text,
  phone           text,
  role            text,
  receives_flyers boolean not null default true,
  direct_to_staff boolean not null default false,
  created_at      timestamptz not null default now()
);

create index if not exists org_contacts_org_idx on org_contacts (org_id);


-- ── 4. work_plans ───────────────────────────────────────────

create table if not exists work_plans (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references organizations(id),
  contract_id  uuid references org_contracts(id),
  title        text not null,
  period_start date not null,
  period_end   date not null,
  status       text not null default 'draft',
  authored_by  uuid references auth.users(id),
  agreed_with  uuid references org_contacts(id),
  document_url text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname='work_plans_status_check') then
    alter table work_plans add constraint work_plans_status_check
      check (status in ('draft','agreed','active','closed'));
  end if;
  if not exists (select 1 from pg_constraint where conname='work_plans_period_check') then
    alter table work_plans add constraint work_plans_period_check
      check (period_end >= period_start);
  end if;
end $$;

create index if not exists work_plans_org_idx on work_plans (org_id, period_start desc);


-- ── 5. program_activities, extended in place ────────────────
-- See note (b). activity_type, title, activity_date, attendee_count and
-- delivery_mode are NOT touched: org_report_data() counts these rows and
-- reads those columns.

alter table program_activities add column if not exists work_plan_id  uuid references work_plans(id);
alter table program_activities add column if not exists format        text;
alter table program_activities add column if not exists planned_month date;
alter table program_activities add column if not exists planned_date  date;
alter table program_activities add column if not exists scheduled_at  timestamptz;
alter table program_activities add column if not exists delivered_at  timestamptz;
alter table program_activities add column if not exists state         text not null default 'delivered';
alter table program_activities add column if not exists practitioner_kind text;
alter table program_activities add column if not exists practitioner_id   uuid;
alter table program_activities add column if not exists org_unit_id   uuid references org_units(id);
alter table program_activities add column if not exists webinar_id    uuid references content_items(id);
alter table program_activities add column if not exists notes         text;

comment on column program_activities.work_plan_id is
  'NULL is legitimate. A per-engagement client may have activities that belong '
  'to no work plan — see CLAUDE_CONTEXT.md, "Not every client is on retainer".';
comment on column program_activities.state is
  'Defaults to delivered because every row that existed before M4 describes '
  'work already done — org_report_data() has been counting them as touchpoints.';
comment on column program_activities.format is
  'The eight M4 values. activity_type is deliberately left alone: it is a '
  'reporting input constrained to five values that org_report_data() reads.';

do $$
begin
  if not exists (select 1 from pg_constraint where conname='program_activities_state_check') then
    alter table program_activities add constraint program_activities_state_check
      check (state in ('planned','scheduled','delivered','reported','cancelled'));
  end if;
  if not exists (select 1 from pg_constraint where conname='program_activities_format_check') then
    alter table program_activities add constraint program_activities_format_check
      check (format is null or format in
        ('talk','one_on_one','couple','group','webinar','wellness_day','flyer','other'));
  end if;
  if not exists (select 1 from pg_constraint where conname='program_activities_practitioner_kind_check') then
    alter table program_activities add constraint program_activities_practitioner_kind_check
      check (practitioner_kind is null or practitioner_kind in ('advisor','counsellor'));
  end if;
end $$;

create index if not exists program_activities_plan_idx  on program_activities (work_plan_id);
create index if not exists program_activities_state_idx on program_activities (state);

-- The link M1 deliberately left out: the column existed nowhere, and M4 adds
-- both the column and its constraint rather than M1 guessing at the target.
alter table bookings add column if not exists activity_id uuid;

do $$
begin
  if not exists (select 1 from pg_constraint where conname='bookings_activity_id_fkey') then
    alter table bookings add constraint bookings_activity_id_fkey
      foreign key (activity_id) references program_activities(id) on delete set null;
  end if;
end $$;

create index if not exists bookings_activity_idx on bookings (activity_id);


-- ── 6. invoices ─────────────────────────────────────────────
-- No 'overdue' state — see note (d). It is derived.

create table if not exists invoices (
  id           uuid primary key default gen_random_uuid(),
  contract_id  uuid not null references org_contracts(id),
  org_id       uuid not null references organizations(id),
  kind         text not null,
  period_start date,
  period_end   date,
  activity_id  uuid references program_activities(id) on delete set null,
  amount       numeric(12,2),
  currency     text not null default 'BWP',
  due_date     date,
  state        text not null default 'to_produce',
  produced_by  uuid references auth.users(id),
  scan_path    text,
  sent_at      timestamptz,
  paid_at      timestamptz,
  action_id    uuid references actions(id) on delete set null,
  narrative    jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname='invoices_kind_check') then
    alter table invoices add constraint invoices_kind_check
      check (kind in ('retainer','engagement'));
  end if;
  if not exists (select 1 from pg_constraint where conname='invoices_state_check') then
    alter table invoices add constraint invoices_state_check
      check (state in ('to_produce','sent','paid','cancelled'));
  end if;
  -- A retainer invoice covers a period; an engagement invoice covers one
  -- activity. Neither shape makes sense as the other.
  if not exists (select 1 from pg_constraint where conname='invoices_shape_agrees_with_kind') then
    alter table invoices add constraint invoices_shape_agrees_with_kind
      check ((kind = 'retainer'   and period_start is not null and activity_id is null)
          or (kind = 'engagement' and activity_id  is not null));
  end if;
end $$;

-- THE IDEMPOTENCY MECHANISM. Both jobs are re-runnable because the database
-- refuses the duplicate, not because the job remembers what it did.
create unique index if not exists invoices_one_per_retainer_period
  on invoices (contract_id, period_start) where kind = 'retainer';
create unique index if not exists invoices_one_per_activity
  on invoices (activity_id) where kind = 'engagement';

create index if not exists invoices_state_idx on invoices (state, due_date);
create index if not exists invoices_org_idx   on invoices (org_id, created_at desc);


-- ── 7. Who the accountant is ────────────────────────────────
-- A config key rather than a role table: there is exactly one accountant, and
-- threshold_config already exists for precisely this kind of setting.

insert into threshold_config (key, value)
values ('invoice.accountant_user_id', 'null'::jsonb)
on conflict (key) do nothing;

insert into threshold_config (key, value)
values ('invoice.due_days', '30'::jsonb)
on conflict (key) do nothing;


-- ── 8. RLS ──────────────────────────────────────────────────

alter table org_contracts  enable row level security;
alter table contract_rates enable row level security;
alter table org_contacts   enable row level security;
alter table work_plans     enable row level security;
alter table invoices       enable row level security;

drop policy if exists org_contracts_staff_read on org_contracts;
create policy org_contracts_staff_read on org_contracts for select using (is_staff());
drop policy if exists org_contracts_admin_write on org_contracts;
create policy org_contracts_admin_write on org_contracts for all
  using (is_ops_admin()) with check (is_ops_admin());

drop policy if exists contract_rates_staff_read on contract_rates;
create policy contract_rates_staff_read on contract_rates for select using (is_staff());
drop policy if exists contract_rates_admin_write on contract_rates;
create policy contract_rates_admin_write on contract_rates for all
  using (is_ops_admin()) with check (is_ops_admin());

drop policy if exists org_contacts_staff_read on org_contacts;
create policy org_contacts_staff_read on org_contacts for select using (is_staff());
drop policy if exists org_contacts_admin_write on org_contacts;
create policy org_contacts_admin_write on org_contacts for all
  using (is_ops_admin()) with check (is_ops_admin());

drop policy if exists work_plans_staff_read on work_plans;
create policy work_plans_staff_read on work_plans for select using (is_staff());
drop policy if exists work_plans_admin_write on work_plans;
create policy work_plans_admin_write on work_plans for all
  using (is_ops_admin()) with check (is_ops_admin());

-- The Laone clause, restated. She owns the to_produce action and is not
-- staff; a plain is_ops_admin() read would send her an action about an
-- invoice she cannot open. Exactly the M5 actions_staff_read lesson.
drop policy if exists invoices_read on invoices;
create policy invoices_read on invoices for select using (
  is_ops_admin()
  or exists (select 1 from actions a where a.id = invoices.action_id and a.owner = auth.uid())
);
drop policy if exists invoices_admin_write on invoices;
create policy invoices_admin_write on invoices for all
  using (is_ops_admin()) with check (is_ops_admin());

-- HR gets no policy at all on any of these. Deferred deliberately: a
-- contract summary is a new HR-facing surface and needs the charter's
-- no-blame review before it exists. See the build record.


-- ── 9. The billing period ───────────────────────────────────
-- ARREARS. Changing to advance billing means changing THIS FUNCTION and
-- nothing else. See note (c) and the build record.

create or replace function _invoice_period(p_run_date date)
returns table (period_start date, period_end date)
language sql
immutable
as $$
  -- The month just ended, relative to the run date.
  select (date_trunc('month', p_run_date::timestamp) - interval '1 month')::date,
         (date_trunc('month', p_run_date::timestamp) - interval '1 day')::date;
$$;

revoke all on function _invoice_period(date) from public, anon, authenticated;


-- ── 10. Who owns the invoice action ─────────────────────────
-- Never skip an invoice and never fail the job. If the accountant is unset or
-- their account is gone, an ops admin gets the action with a title saying so.

create or replace function _invoice_action_owner()
returns table (owner uuid, needs_reassigning boolean)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_id uuid;
begin
  select nullif(value #>> '{}', '')::uuid into v_id
    from threshold_config where key = 'invoice.accountant_user_id';

  if v_id is not null and exists (select 1 from auth.users u where u.id = v_id) then
    return query select v_id, false;
    return;
  end if;

  -- Fall back to any admin with an account. Deterministic so the same person
  -- gets it each run rather than a different one each month.
  return query
    select u.id, true
      from admins a join auth.users u on lower(u.email) = lower(a.email)
     order by u.email
     limit 1;
end $$;

revoke all on function _invoice_action_owner() from public, anon, authenticated;


-- ── 11. The engagement invoice ──────────────────────────────
-- Created when a per-engagement activity is delivered. A format with no rate
-- still produces an invoice, with a null amount and an action that names the
-- gap: never block the delivery of real work because billing metadata is
-- missing.

create or replace function _invoice_for_activity(p_activity_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  a          record;
  c          record;
  v_amount   numeric(12,2);
  v_owner    uuid;
  v_reassign boolean;
  v_due      int;
  v_invoice  uuid;
  v_action   uuid;
  v_title    text;
begin
  select * into a from program_activities where id = p_activity_id;
  if not found then return null; end if;

  select * into c
    from org_contracts
   where org_id = a.org_id and contract_kind = 'per_engagement' and status = 'active'
     and a.activity_date >= start_date
     and (end_date is null or a.activity_date <= end_date)
   order by start_date desc
   limit 1;
  if not found then return null; end if;          -- not a per-engagement client

  select amount into v_amount
    from contract_rates
   where contract_id = c.id
     and format = coalesce(a.format, '')
     and service_line = a.service_line;

  select owner, needs_reassigning into v_owner, v_reassign from _invoice_action_owner();
  select coalesce((value #>> '{}')::int, 30) into v_due
    from threshold_config where key = 'invoice.due_days';

  insert into invoices (contract_id, org_id, kind, activity_id, amount, currency,
                        due_date, state, narrative)
  values (c.id, a.org_id, 'engagement', a.id, v_amount, c.currency,
          (current_date + coalesce(v_due, 30)), 'to_produce',
          jsonb_build_object('activity', a.title, 'format', a.format,
                             'service_line', a.service_line,
                             'delivered_on', a.activity_date))
  on conflict (activity_id) where kind = 'engagement' do nothing
  returning id into v_invoice;

  if v_invoice is null then return null; end if;  -- already invoiced

  v_title := 'Produce invoice: ' || coalesce(a.title, 'engagement');
  if v_amount is null then
    v_title := v_title || ' — no rate on file for ' || coalesce(a.format, '(no format)');
  end if;
  if v_reassign then
    v_title := v_title || ' — needs reassigning, no accountant is set';
  end if;

  if v_owner is not null then
    insert into actions (title, owner, due_date, state, org_id, activity_id, created_by)
    values (v_title, v_owner, (current_date + coalesce(v_due, 30)), 'open',
            a.org_id, a.id, v_owner)
    returning id into v_action;

    update invoices set action_id = v_action where id = v_invoice;
  end if;

  return v_invoice;
end $$;

revoke all on function _invoice_for_activity(uuid) from public, anon, authenticated;


-- ── 12. The transition trigger ──────────────────────────────
-- FIRES ON A TRANSITION, NEVER ON ANY UPDATE. See note (e): M1's backfill
-- fired every AFTER UPDATE trigger on bookings 22 times and was safe only
-- because trg_award_session_attended is guarded the same way.

create or replace function kw_booking_drives_activity()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_state text;
begin
  if new.activity_id is null then
    return new;
  end if;

  -- Linking a booking to an activity schedules it.
  if tg_op = 'INSERT'
     or new.activity_id is distinct from old.activity_id then
    update program_activities
       set state = 'scheduled', scheduled_at = coalesce(scheduled_at, now())
     where id = new.activity_id and state = 'planned';
  end if;

  -- The FIRST confirmed attendance delivers it. Later attendances do not
  -- re-deliver and must not re-invoice — decided 26 Aug.
  if new.attended is true
     and (tg_op = 'INSERT' or old.attended is distinct from true) then
    select state into v_state from program_activities where id = new.activity_id;

    if v_state in ('planned','scheduled') then
      update program_activities
         set state = 'delivered', delivered_at = coalesce(delivered_at, now())
       where id = new.activity_id;

      -- Per-engagement clients invoice on delivery. The function is a no-op
      -- for a retainer client and idempotent on the partial unique index.
      perform _invoice_for_activity(new.activity_id);
    end if;
  end if;

  return new;
end $$;

drop trigger if exists trg_booking_drives_activity on bookings;
create trigger trg_booking_drives_activity
  after insert or update of activity_id, attended on bookings
  for each row execute function kw_booking_drives_activity();


-- ── 13. The monthly retainer job ────────────────────────────

create or replace function invoices_run_monthly(p_run_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_run      date := coalesce(p_run_date, (now() at time zone 'Africa/Gaborone')::date);
  v_start    date;
  v_end      date;
  v_owner    uuid;
  v_reassign boolean;
  v_due      int;
  c          record;
  v_invoice  uuid;
  v_action   uuid;
  v_created  int := 0;
  v_skipped  int := 0;
  v_title    text;
begin
  select period_start, period_end into v_start, v_end from _invoice_period(v_run);
  select owner, needs_reassigning into v_owner, v_reassign from _invoice_action_owner();
  select coalesce((value #>> '{}')::int, 30) into v_due
    from threshold_config where key = 'invoice.due_days';

  for c in
    select * from org_contracts
     where contract_kind = 'retainer'          -- per-engagement invoices on delivery
       and status = 'active'
       and billing_frequency = 'monthly'
       and start_date <= v_end
       and (end_date is null or end_date >= v_start)
  loop
    insert into invoices (contract_id, org_id, kind, period_start, period_end,
                          amount, currency, due_date, state, narrative)
    values (c.id, c.org_id, 'retainer', v_start, v_end,
            c.retainer_amount, c.currency, (v_run + coalesce(v_due, 30)), 'to_produce',
            -- The narrative is the month's delivered work. In arrears, that is
            -- the period being invoiced; see note (c).
            jsonb_build_object(
              'period', to_char(v_start, 'Mon YYYY'),
              'delivered', coalesce((
                select jsonb_agg(jsonb_build_object('title', pa.title, 'on', pa.activity_date,
                                                    'attendees', pa.attendee_count)
                                  order by pa.activity_date)
                  from program_activities pa
                 where pa.org_id = c.org_id
                   and pa.state in ('delivered','reported')
                   and pa.activity_date between v_start and v_end), '[]'::jsonb)))
    on conflict (contract_id, period_start) where kind = 'retainer' do nothing
    returning id into v_invoice;

    if v_invoice is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_title := 'Produce ' || to_char(v_start, 'Mon YYYY') || ' invoice';
    if v_reassign then
      v_title := v_title || ' — needs reassigning, no accountant is set';
    end if;

    if v_owner is not null then
      insert into actions (title, owner, due_date, state, org_id, created_by)
      values (v_title, v_owner, (v_run + coalesce(v_due, 30)), 'open', c.org_id, v_owner)
      returning id into v_action;
      update invoices set action_id = v_action where id = v_invoice;
    end if;

    v_created := v_created + 1;
  end loop;

  return jsonb_build_object('run_date', v_run, 'period_start', v_start, 'period_end', v_end,
                            'created', v_created, 'already_present', v_skipped,
                            'owner_needs_reassigning', v_reassign);
end $$;

revoke all on function invoices_run_monthly(date) from public, anon, authenticated;


-- ── 14. The RPCs the screens need ───────────────────────────

create or replace function contract_position(p_org_id uuid, p_as_of date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_as_of date := coalesce(p_as_of, (now() at time zone 'Africa/Gaborone')::date);
  c       record;
begin
  if not is_staff() then raise exception 'not authorised'; end if;

  select * into c
    from org_contracts
   where org_id = p_org_id and status = 'active'
     and start_date <= v_as_of and (end_date is null or end_date >= v_as_of)
   order by start_date desc limit 1;

  if not found then
    return jsonb_build_object('kind', null, 'reason', 'no active contract recorded');
  end if;

  -- TWO SHAPES. "Delivered vs expected" is meaningless for a client who is
  -- billed per engagement — there is no period allowance to be under or over.
  if c.contract_kind = 'retainer' then
    return jsonb_build_object(
      'kind', 'retainer',
      'period_start', date_trunc('month', v_as_of)::date,
      'retainer_amount', c.retainer_amount,
      'currency', c.currency,
      'delivered', (select count(*) from program_activities pa
                     where pa.org_id = p_org_id and pa.state in ('delivered','reported')
                       and pa.activity_date >= date_trunc('month', v_as_of)::date),
      'planned',   (select count(*) from program_activities pa
                     where pa.org_id = p_org_id and pa.state in ('planned','scheduled')),
      'covered_headcount', c.covered_headcount);
  end if;

  return jsonb_build_object(
    'kind', 'per_engagement',
    'currency', c.currency,
    'delivered_count', (select count(*) from program_activities pa
                         where pa.org_id = p_org_id and pa.state in ('delivered','reported')),
    'invoiced_value',  (select coalesce(sum(i.amount), 0) from invoices i
                         where i.org_id = p_org_id and i.kind = 'engagement'),
    'uninvoiced_count',(select count(*) from program_activities pa
                         where pa.org_id = p_org_id and pa.state in ('delivered','reported')
                           and not exists (select 1 from invoices i
                                            where i.activity_id = pa.id)),
    'rates_on_file',   (select count(*) from contract_rates r where r.contract_id = c.id));
end $$;

grant execute on function contract_position(uuid, date) to authenticated;


create or replace function org_work_plan(p_org_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  if not is_staff() then raise exception 'not authorised'; end if;

  return jsonb_build_object(
    'org_id', p_org_id,
    'contract', contract_position(p_org_id),
    'plans', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', w.id, 'title', w.title, 'status', w.status,
               'period_start', w.period_start, 'period_end', w.period_end,
               'activities', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', pa.id, 'title', pa.title, 'state', pa.state,
                          'format', pa.format, 'service_line', pa.service_line,
                          'planned_month', pa.planned_month,
                          'activity_date', pa.activity_date,
                          'attendee_count', pa.attendee_count)
                        order by coalesce(pa.activity_date, pa.planned_month, pa.planned_date))
                   from program_activities pa where pa.work_plan_id = w.id), '[]'::jsonb))
             order by w.period_start desc)
        from work_plans w where w.org_id = p_org_id), '[]'::jsonb),
    -- A per-engagement client may have activities on no plan at all. They are
    -- real work and must not disappear because there is no plan to hang them on.
    'unplanned', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pa.id, 'title', pa.title, 'state', pa.state,
               'format', pa.format, 'service_line', pa.service_line,
               'activity_date', pa.activity_date)
             order by pa.activity_date)
        from program_activities pa
       where pa.org_id = p_org_id and pa.work_plan_id is null), '[]'::jsonb));
end $$;

grant execute on function org_work_plan(uuid) to authenticated;


create or replace function work_plan_upsert(
  p_org_id       uuid,
  p_title        text,
  p_period_start date,
  p_period_end   date,
  p_id           uuid default null,
  p_contract_id  uuid default null,
  p_status       text default null,
  p_document_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare v_id uuid; w work_plans%rowtype;
begin
  if not is_ops_admin() then raise exception 'not authorised'; end if;

  if p_id is null then
    insert into work_plans (org_id, title, period_start, period_end, contract_id,
                            status, document_url, authored_by)
    values (p_org_id, p_title, p_period_start, p_period_end, p_contract_id,
            coalesce(p_status,'draft'), p_document_url, auth.uid())
    returning id into v_id;
  else
    update work_plans
       set title = coalesce(p_title, title),
           period_start = coalesce(p_period_start, period_start),
           period_end = coalesce(p_period_end, period_end),
           contract_id = coalesce(p_contract_id, contract_id),
           status = coalesce(p_status, status),
           document_url = coalesce(p_document_url, document_url),
           updated_at = now()
     where id = p_id
    returning id into v_id;
  end if;

  select * into w from work_plans where id = v_id;
  return to_jsonb(w);
end $$;

grant execute on function work_plan_upsert(uuid, text, date, date, uuid, uuid, text, text)
  to authenticated;


create or replace function activity_upsert(
  p_org_id        uuid,
  p_title         text,
  p_id            uuid default null,
  p_work_plan_id  uuid default null,
  p_activity_type text default null,
  p_format        text default null,
  p_service_line  text default null,
  p_state         text default null,
  p_activity_date date default null,
  p_planned_month date default null,
  p_attendee_count int default null,
  p_delivery_mode text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare v_id uuid; a program_activities%rowtype; v_was text;
begin
  if not is_ops_admin() then raise exception 'not authorised'; end if;

  if p_id is null then
    insert into program_activities (org_id, title, work_plan_id, activity_type, format,
                                    service_line, state, activity_date, planned_month,
                                    attendee_count, delivery_mode, created_by)
    values (p_org_id, p_title, p_work_plan_id,
            coalesce(p_activity_type, 'other'), p_format,
            coalesce(p_service_line, 'financial'), coalesce(p_state, 'planned'),
            coalesce(p_activity_date, current_date), p_planned_month,
            coalesce(p_attendee_count, 0), p_delivery_mode, auth.uid())
    returning id into v_id;
  else
    select state into v_was from program_activities where id = p_id;

    update program_activities
       set title = coalesce(p_title, title),
           work_plan_id = coalesce(p_work_plan_id, work_plan_id),
           activity_type = coalesce(p_activity_type, activity_type),
           format = coalesce(p_format, format),
           service_line = coalesce(p_service_line, service_line),
           state = coalesce(p_state, state),
           activity_date = coalesce(p_activity_date, activity_date),
           planned_month = coalesce(p_planned_month, planned_month),
           attendee_count = coalesce(p_attendee_count, attendee_count),
           delivery_mode = coalesce(p_delivery_mode, delivery_mode),
           delivered_at = case when coalesce(p_state, state) = 'delivered'
                               then coalesce(delivered_at, now()) else delivered_at end
     where id = p_id
    returning id into v_id;

    -- Marking an activity delivered BY HAND invoices it too, once. The
    -- trigger covers the booking path; this covers the group work that never
    -- had a booking.
    if p_state = 'delivered' and v_was is distinct from 'delivered' then
      perform _invoice_for_activity(v_id);
    end if;
  end if;

  select * into a from program_activities where id = v_id;
  return to_jsonb(a);
end $$;

grant execute on function activity_upsert(uuid, text, uuid, uuid, text, text, text, text,
                                          date, date, int, text) to authenticated;


-- ── 15. The invoice-scans bucket ────────────────────────────
-- Guarded: the storage schema does not exist in a local test database, and
-- this migration must load there too.

do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'M4: no storage schema — skipping the invoice-scans bucket (local test run).';
    return;
  end if;

  insert into storage.buckets (id, name, public)
  values ('invoice-scans', 'invoice-scans', false)
  on conflict (id) do nothing;

  execute $p$ drop policy if exists invoice_scans_admin_all on storage.objects $p$;
  execute $p$
    create policy invoice_scans_admin_all on storage.objects for all
      using (bucket_id = 'invoice-scans' and is_ops_admin())
      with check (bucket_id = 'invoice-scans' and is_ops_admin())
  $p$;
  raise notice 'M4: invoice-scans bucket present and restricted to ops admins.';
end $$;


-- ── 16. The schedule ────────────────────────────────────────
-- Same guarded shape as M5. 03:00 UTC on the 1st is 05:00 Gaborone, before
-- the reminder job at 04:00 UTC so the new action can be reminded the same day.

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute $c$
      select cron.schedule('kw-monthly-invoices', '0 3 1 * *',
                           $j$ select invoices_run_monthly() $j$)
    $c$;
    raise notice 'M4: pg_cron job kw-monthly-invoices scheduled for 03:00 UTC on the 1st.';
  else
    raise notice 'M4: pg_cron is NOT installed — no invoice will be raised. '
                 'Enable it in Database -> Extensions, then re-run this file.';
  end if;
end $$;


-- ── 17. Post-conditions ─────────────────────────────────────

do $$
declare n int;
begin
  select count(*) into n from pg_indexes
   where schemaname='public'
     and indexname in ('invoices_one_per_retainer_period','invoices_one_per_activity');
  if n <> 2 then
    raise exception 'M4: the two partial unique indexes are the idempotency mechanism, found %', n;
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'trg_booking_drives_activity') then
    raise exception 'M4: the transition trigger is missing';
  end if;

  select count(*) into n from information_schema.columns
   where table_schema='public' and table_name='program_activities'
     and column_name in ('activity_type','title','activity_date','attendee_count','delivery_mode');
  if n <> 5 then
    raise exception 'M4: an org_report_data() input column was lost (found % of 5)', n;
  end if;

  raise notice 'M4 applied. Retainer billing is IN ARREARS — see note (c). '
               'M3 must gate org_work_plan() and contract_position().';
end $$;
