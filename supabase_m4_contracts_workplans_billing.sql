-- ============================================================
-- Key Wellness — M4: contracts, work plans, activities, billing handovers
--
-- Run AFTER M1 (service_line), M5 (is_staff, actions) and the support work
-- (is_ops_admin). Idempotent — safe to re-run.
-- Rollback: migrations/rollback-m4-contracts-workplans-billing.sql
-- Tests:    tests/m4-tests.sql        (local, PostgreSQL 17)
-- Verify:   tests/m4-verify-live.sql  (read-only, the SQL editor)
-- Plan:     docs/build/m4-billing-handovers-plan.md
--
-- ══ WHAT THIS DOES, IN PLAIN LANGUAGE ══════════════════════
--
-- Key Wellness does work for client organisations. Some pay a monthly
-- retainer; some are billed per engagement at prices agreed up front. At the
-- end of every month somebody has to tell Laone what to invoice. Today that is
-- Lone's memory and a spreadsheet. This makes it a record: what was agreed,
-- what was delivered, what was handed to Laone, and when.
--
-- ══ THE THING THAT DECIDES EVERYTHING ELSE ═════════════════
--
-- INVOICES ARE PRODUCED IN SAGE. This system never produces one and never
-- sees one. So the table is billing_handovers, and a row is THE HANDOVER —
-- "here is the work we did for BOPEU in August; please invoice it" — not the
-- invoice.
--
-- Which is why there is NO 'paid' state and NO 'overdue' anywhere. Both are
-- facts about a document we cannot read. A stale 'paid' is worse than no
-- 'paid', because a wrong answer gets acted on and a missing one gets checked.
-- There is no scan upload and no storage bucket either: the document lives in
-- Sage, and a photocopy here would be a second version of the truth.
--
-- 'invoiced' DOES exist and means something narrower than it looks: LONE HAS
-- CONFIRMED WITH LAONE THAT THE INVOICE EXISTS. She owns that follow-up, which
-- is what makes this flag safe when 'paid' is not.
--
--   BINDING WORDING RULE. The screen reads "Confirmed with Laone · 26 Aug",
--   never a bare "Invoiced". The system does not know an invoice exists; it
--   knows Lone said so, and when. Any label implying first-hand knowledge of
--   Sage is a defect. (ops.html line 641 currently reads "Invoices produced" —
--   that is one, and M7 fixes it.)
--
-- ══ WHAT WILL CHANGE, AND WHAT WILL NOT ════════════════════
-- Written BEFORE the apply, as the prediction to check the result against.
--
--   CHANGES
--     Five new tables appear, ALL EMPTY: org_contracts, contract_rates,
--     org_contacts, work_plans, billing_handovers.
--     program_activities gains twelve columns; bookings gains one. No row in
--     either table is added, removed or altered.
--     Fourteen functions appear. One EXISTING function is replaced —
--     tuesday_review_pack() — see the next block.
--     A daily job appears, which decides for itself whether today is the day
--     to prepare a handover.
--
--   DOES NOT CHANGE
--     No booking, no member, no report. org_report_data() must return
--     BYTE-IDENTICAL payloads before and after, and the test suite asserts
--     exactly that against all nine live org/period combinations.
--     No published report can move: publish_org_report() froze those into
--     org_reports.data_snapshot and HR reads the snapshot.
--     Nobody gains sight of anything new: every policy here is staff-read,
--     ops-admin-write. HR and members get no policy at all.
--
--   THE ONE RISK WORTH NAMING
--     tuesday_review_pack() IS ALREADY LIVE. This migration replaces it to add
--     the billing flag (section 15). If that is wrong, Lone's Tuesday review
--     shows a wrong flag or fails to load. No data is damaged — but her Tuesday
--     morning is. It therefore gets its own baseline, its own written
--     prediction and its own assertion.
--
--   HOW TO UNDO IT
--     migrations/rollback-m4-contracts-workplans-billing.sql drops everything
--     this created AND RESTORES tuesday_review_pack() TO ITS M5 BODY. It
--     DELETES contracts, work plans and handovers — there is no backup table,
--     because unlike M1's session_mode these are whole rows rather than an
--     overwritten column, so export first. It keeps every program_activities
--     row: this migration adds columns to that table, and the rollback drops
--     the columns rather than the rows.
--
-- ══ EIGHT THINGS TO KNOW ═══════════════════════════════════
--
-- (a) NOT EVERY CLIENT IS ON RETAINER. org_contracts.contract_kind splits
--     them; contract_rates is the rate card (format x service_line -> amount).
--     A per-engagement client MAY have activities with no work plan, so
--     program_activities.work_plan_id is nullable and that is legitimate.
--
-- (b) AN ORGANISATION CAN HAVE NO CONTRACT AT ALL and still have activities
--     and handovers. billing_handovers.contract_id is therefore NULLABLE for
--     an engagement handover. Delivered work is never lost because the
--     paperwork is behind: the handover is raised with a blank amount and an
--     action that names what is missing. (Decided 27 Aug 2026.)
--
-- (c) program_activities is EXTENDED IN PLACE and keeps its name.
--     docs/data-model-and-impact.md §3 calls the extended table
--     work_plan_activities, and the same paragraph requires the old columns to
--     survive so org_report_data() keeps counting. Those cannot both happen
--     through a rename. activity_type is UNTOUCHED — it is a reporting input
--     constrained to five values; the eight delivery formats live in a NEW
--     `format` column that nothing reads yet.
--
-- (d) THE HANDOVER IS PREPARED IN THE LAST WEEK OF THE MONTH IT COVERS.
--     _handover_period() returns the CURRENT month, and the job fires on
--     invoice.prepare_day (default 25).
--
-- (e) THE PACK IS LIVE, NOT A SNAPSHOT. Work delivered between the prepare day
--     and month end must still count, so the contents RECOMPUTE ON READ until
--     Lone marks it handed over. Marking it freezes the contents at that
--     moment and the next period starts from there. That is what covers_from
--     is for: a pack covers (previous handover, this handover], and THE
--     CALENDAR MONTH IS ONLY ITS LABEL. Nothing dropped, nothing counted twice
--     — a property of the arithmetic, not of anyone remembering to check.
--
-- (f) THE HANDOVER CARRIES NO DATE OF ITS OWN. It used to have a due_date, and
--     that existed only to derive 'overdue', which is gone. The ACTION that
--     tells Lone to hand the pack over is due at MONTH END — a date we
--     actually know, rather than a payment term we would be guessing at.
--     (Decided 27 Aug 2026.)
--
-- (g) THE TRANSITION TRIGGER FIRES ON A TRANSITION, NEVER ON ANY UPDATE.
--     docs/build/m1-service-line.md records why: a column backfill fires every
--     AFTER UPDATE trigger on bookings, and M1's fired
--     trg_award_session_attended 22 times. It was safe only because that
--     trigger is transition-guarded. An unguarded one here would raise a
--     handover for the entire back catalogue the next time anyone migrates a
--     column on bookings.
--
-- (h) THE M3 OBLIGATION. org_work_plan() and contract_position() are SECURITY
--     DEFINER and bypass row-level security. Today every activity is
--     financial. The moment counselling work appears on a work plan, France —
--     an admin who is not a counsellor — reads it through these two functions
--     no matter what policies M3 writes, because a SECURITY DEFINER function
--     runs as postgres and never consults them. M3 MUST GATE PSYCHOSOCIAL ROWS
--     INSIDE THEM, with the named tests:
--
--        "a France-type admin calling org_work_plan sees no psychosocial rows"
--        "a France-type admin calling contract_position sees no psychosocial rows"
--
--     That is three functions now carrying it: ops_timeline(), org_work_plan(),
--     contract_position().
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


-- ── 6. billing_handovers ────────────────────────────────────
-- A row is THE HANDOVER, not the invoice. See the header.
--
-- No due_date: it existed only to derive 'overdue', which is gone with it.
-- No paid_at, no scan_path: both describe a document in Sage that this system
-- cannot read.

create table if not exists billing_handovers (
  id           uuid primary key default gen_random_uuid(),
  -- NULLABLE on purpose. An organisation can have no contract at all and
  -- still have delivered work that must be handed over — header note (b).
  contract_id  uuid references org_contracts(id),
  org_id       uuid not null references organizations(id),
  kind         text not null,
  period_start date,
  period_end   date,
  activity_id  uuid references program_activities(id) on delete set null,
  amount       numeric(12,2),
  currency     text not null default 'BWP',
  state        text not null default 'to_prepare',
  prepared_by  uuid references auth.users(id),
  -- A pack covers (covers_from, handed_at] — the previous handover to this
  -- one. The calendar month is only its label. See header note (e).
  covers_from  timestamptz not null default now(),
  handed_at    timestamptz,
  -- Lone's record of her own follow-up: she asked Laone, and Laone confirmed
  -- the invoice exists in Sage. NOT a reading of Sage.
  invoice_confirmed_by uuid references auth.users(id),
  invoice_confirmed_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  action_id    uuid references actions(id) on delete set null,
  narrative    jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table billing_handovers is
  'The moment Lone hands Laone the numbers for a period or an engagement. '
  'NOT an invoice — billing_handovers are produced in Sage and this system never sees '
  'one. There is deliberately no paid state and no overdue.';
comment on column billing_handovers.invoice_confirmed_at is
  'When Lone confirmed with Laone that the invoice exists. Screens must read '
  '"Confirmed with Laone · 26 Aug", never a bare "Invoiced".';

do $$
begin
  if not exists (select 1 from pg_constraint where conname='billing_handovers_kind_check') then
    alter table billing_handovers add constraint billing_handovers_kind_check
      check (kind in ('retainer','engagement'));
  end if;

  -- to_prepare -> handed_over -> invoiced, and cancelled from any state.
  -- There is no 'paid' and no 'overdue', and there must never be one.
  if not exists (select 1 from pg_constraint where conname='billing_handovers_state_check') then
    alter table billing_handovers add constraint billing_handovers_state_check
      check (state in ('to_prepare','handed_over','invoiced','cancelled'));
  end if;

  -- A handed-over pack has frozen contents and a moment it was frozen at.
  if not exists (select 1 from pg_constraint where conname='billing_handovers_handed_at_agrees') then
    alter table billing_handovers add constraint billing_handovers_handed_at_agrees
      check (state in ('to_prepare','cancelled') or handed_at is not null);
  end if;

  -- The confirmation and its timestamp move together, in both directions.
  if not exists (select 1 from pg_constraint where conname='billing_handovers_confirmed_agrees') then
    alter table billing_handovers add constraint billing_handovers_confirmed_agrees
      check ((state = 'invoiced') = (invoice_confirmed_at is not null));
  end if;

  if not exists (select 1 from pg_constraint where conname='billing_handovers_cancelled_agrees') then
    alter table billing_handovers add constraint billing_handovers_cancelled_agrees
      check ((state = 'cancelled') = (cancelled_at is not null));
  end if;

  -- A retainer handover covers a period and must have a contract to be a
  -- retainer at all. An engagement handover covers one activity and may have
  -- no contract — note (b).
  if not exists (select 1 from pg_constraint where conname='billing_handovers_shape_agrees_with_kind') then
    alter table billing_handovers add constraint billing_handovers_shape_agrees_with_kind
      check ((kind = 'retainer'   and period_start is not null
                                  and activity_id is null
                                  and contract_id is not null)
          or (kind = 'engagement' and activity_id  is not null));
  end if;
end $$;

-- THE IDEMPOTENCY MECHANISM. Both jobs are re-runnable because the database
-- refuses the duplicate, not because the job remembers what it did.
create unique index if not exists billing_handovers_one_per_retainer_period
  on billing_handovers (contract_id, period_start) where kind = 'retainer';
create unique index if not exists billing_handovers_one_per_activity
  on billing_handovers (activity_id) where kind = 'engagement';

create index if not exists billing_handovers_state_idx on billing_handovers (state);
create index if not exists billing_handovers_org_idx   on billing_handovers (org_id, created_at desc);


-- ── 7. Who prepares the pack, and when ──────────────────────
-- An ops admin, configurable. threshold_config already exists for exactly
-- this kind of setting and needs no new table.
--
-- The keys keep their `invoice.` prefix because that is what they are ABOUT.
-- Renaming them to `handover.` would buy nothing and would strand anyone who
-- had already set one.

-- Null means "the first ops admin", which is Lone. Set it explicitly in the
-- deploy note; this migration names no person.
insert into threshold_config (key, value)
values ('invoice.prepared_by_user_id', 'null'::jsonb)
on conflict (key) do nothing;

-- The day of the month the pack is prepared. Last week of the month, for that
-- same month. Configurable without touching the cron schedule — see the job.
insert into threshold_config (key, value)
values ('invoice.prepare_day', '25'::jsonb)
on conflict (key) do nothing;

-- invoice.due_days is deliberately NOT created. It set a handover due_date
-- that existed only to derive 'overdue'. Both are gone: the action that tells
-- Lone to hand the pack over is due at MONTH END, which is a date we know.
delete from threshold_config where key = 'invoice.due_days';


-- ── 8. RLS ──────────────────────────────────────────────────

alter table org_contracts  enable row level security;
alter table contract_rates enable row level security;
alter table org_contacts   enable row level security;
alter table work_plans     enable row level security;
alter table billing_handovers enable row level security;

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

-- Ops admins only. An earlier draft carried an action-owner arm for the
-- accountant, but there is no accountant user: the pack is owned by an ops
-- admin by construction, so that arm protected nobody. A policy clause that
-- protects nobody is a claim about the system that is not true, so it is gone.
-- M5's actions_staff_read keeps the real version of that idea, where the owner
-- genuinely can be someone who is not staff.
drop policy if exists invoices_read on billing_handovers;          -- pre-rename name
drop policy if exists billing_handovers_read on billing_handovers;
create policy billing_handovers_read on billing_handovers
  for select using (is_ops_admin());
drop policy if exists invoices_admin_write on billing_handovers;   -- pre-rename name
drop policy if exists billing_handovers_admin_write on billing_handovers;
create policy billing_handovers_admin_write on billing_handovers for all
  using (is_ops_admin()) with check (is_ops_admin());

-- HR gets no policy at all on any of these. Deferred deliberately: a
-- contract summary is a new HR-facing surface and needs the charter's
-- no-blame review before it exists. See the build record.


-- ── 9. The billing period ───────────────────────────────────
-- THE CURRENT MONTH. The pack is prepared in the last week of the month it
-- covers — arrears means within-month here, not previous-month. See note (c).

create or replace function _handover_period(p_run_date date)
returns table (period_start date, period_end date)
language sql
immutable
as $$
  select date_trunc('month', p_run_date::timestamp)::date,
         (date_trunc('month', p_run_date::timestamp)
          + interval '1 month' - interval '1 day')::date;
$$;

revoke all on function _handover_period(date) from public, anon, authenticated;


-- ── 10. Who owns the handover action ────────────────────────
-- The pack is owned by an ops admin — Lone. If invoice.prepared_by_user_id is
-- unset, the first ops admin BY EMAIL, which is deterministic, so the same
-- person gets it every month rather than a different one each time.
--
-- There is no accountant user and no fallback for one, because Laone does not
-- use the platform at all. This can return null only if NO admin has an
-- account, which is a broken deployment rather than a case to design around —
-- the job reports owner_unresolved and the live check resolves the owner to a
-- real address before you apply anything.
create or replace function _handover_owner()
returns uuid
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare v_id uuid;
begin
  select nullif(value #>> '{}', '')::uuid into v_id
    from threshold_config where key = 'invoice.prepared_by_user_id';

  if v_id is not null and exists (select 1 from auth.users u where u.id = v_id) then
    return v_id;
  end if;

  select u.id into v_id
    from admins a join auth.users u on lower(u.email) = lower(a.email)
   order by u.email limit 1;

  return v_id;   -- may be null only if no admin has an account at all
end $$;

revoke all on function _handover_owner() from public, anon, authenticated;


-- ── 10a. The pack contents ──────────────────────────────────
-- Everything delivered in (p_from, p_to]. Pre-M4 rows carry no delivered_at,
-- so activity_date stands in for them.

create or replace function _pack_contents(p_org_id uuid, p_from timestamptz, p_to timestamptz)
returns jsonb
language sql
stable
security definer
set search_path = public, auth
as $$
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'count', count(*),
    'delivered', coalesce(jsonb_agg(jsonb_build_object(
        'id', pa.id, 'title', pa.title, 'on', pa.activity_date,
        'format', pa.format, 'service_line', pa.service_line,
        'attendees', pa.attendee_count) order by pa.activity_date), '[]'::jsonb))
    from program_activities pa
   where pa.org_id = p_org_id
     and pa.state in ('delivered','reported')
     and coalesce(pa.delivered_at, pa.activity_date::timestamptz) >  p_from
     and coalesce(pa.delivered_at, pa.activity_date::timestamptz) <= p_to;
$$;

revoke all on function _pack_contents(uuid, timestamptz, timestamptz)
  from public, anon, authenticated;


-- ── 11. The engagement handover ─────────────────────────────
-- Raised when a per-engagement activity is delivered.
--
-- TWO KINDS OF MISSING PAPERWORK, BOTH HANDLED THE SAME WAY. A format with no
-- rate on the card, and an organisation with no contract at all, both still
-- produce a handover — with a blank amount and an action that names exactly
-- what is missing. Never lose delivered work because the paperwork is behind.
-- (The second case decided 27 Aug 2026; see header note (b).)

create or replace function _handover_for_activity(p_activity_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  a          record;
  c          record;
  v_have_c   boolean := false;
  v_amount   numeric(12,2);
  v_owner    uuid;
  v_handover uuid;
  v_action   uuid;
  v_title    text;
  v_why      text := '';
  v_due      date;
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
  v_have_c := found;

  if v_have_c then
    -- A retainer client's delivered work is counted in the monthly pack, not
    -- handed over one activity at a time. Only per_engagement reaches here.
    select amount into v_amount
      from contract_rates
     where contract_id = c.id
       and format = coalesce(a.format, '')
       and service_line = a.service_line;
    if v_amount is null then
      v_why := ' — no rate on file for ' || coalesce(a.format, '(no format)');
    end if;
  else
    -- No per_engagement contract. If the organisation is on an ACTIVE
    -- RETAINER, this activity belongs in the monthly pack and must not be
    -- handed over separately, or it would be billed twice.
    if exists (select 1 from org_contracts
                where org_id = a.org_id and contract_kind = 'retainer'
                  and status = 'active'
                  and a.activity_date >= start_date
                  and (end_date is null or a.activity_date <= end_date)) then
      return null;
    end if;
    v_why := ' — no contract on file for this organisation';
  end if;

  v_owner := _handover_owner();

  -- Month end of the month the work was delivered in. The handover itself
  -- carries no date — header note (f).
  v_due := (date_trunc('month', a.activity_date::timestamp)
            + interval '1 month' - interval '1 day')::date;

  -- An engagement pack is one activity. There is nothing to recompute, so its
  -- contents are written once and handover_pack() returns them as stored.
  insert into billing_handovers (contract_id, org_id, kind, activity_id, amount,
                                 currency, state, covers_from, prepared_by, narrative)
  values (case when v_have_c then c.id end, a.org_id, 'engagement', a.id, v_amount,
          coalesce(case when v_have_c then c.currency end, 'BWP'), 'to_prepare',
          coalesce(a.delivered_at, a.activity_date::timestamptz), v_owner,
          jsonb_build_object('activity', a.title, 'format', a.format,
                             'service_line', a.service_line,
                             'delivered_on', a.activity_date))
  on conflict (activity_id) where kind = 'engagement' do nothing
  returning id into v_handover;

  if v_handover is null then return null; end if;  -- already handed over

  v_title := 'Hand to Laone: ' || coalesce(a.title, 'engagement') || v_why;

  if v_owner is not null then
    insert into actions (title, owner, due_date, state, org_id, activity_id, created_by)
    values (v_title, v_owner, v_due, 'open', a.org_id, a.id, v_owner)
    returning id into v_action;

    update billing_handovers set action_id = v_action where id = v_handover;
  end if;

  return v_handover;
end $$;

revoke all on function _handover_for_activity(uuid) from public, anon, authenticated;


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
      perform _handover_for_activity(new.activity_id);
    end if;
  end if;

  return new;
end $$;

drop trigger if exists trg_booking_drives_activity on bookings;
create trigger trg_booking_drives_activity
  after insert or update of activity_id, attended on bookings
  for each row execute function kw_booking_drives_activity();


-- ── 13. The monthly job ─────────────────────────────────────
-- Prepares the handover in the LAST WEEK OF THE MONTH IT COVERS, for that same
-- month. Not the 1st, and not the previous month.

create or replace function handovers_run_monthly(
  p_run_date            date default null,
  p_respect_prepare_day boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_run      date := coalesce(p_run_date, (now() at time zone 'Africa/Gaborone')::date);
  v_start    date;
  v_end      date;
  v_day      int;
  v_owner    uuid;
  c          record;
  v_from     timestamptz;
  v_handover uuid;
  v_action   uuid;
  v_created  int := 0;
  v_skipped  int := 0;
begin
  select coalesce((value #>> '{}')::int, 25) into v_day
    from threshold_config where key = 'invoice.prepare_day';

  -- cron calls this DAILY with p_respect_prepare_day := true, so the day stays
  -- configurable through threshold_config without rescheduling the job.
  if p_respect_prepare_day and extract(day from v_run)::int <> coalesce(v_day, 25) then
    return jsonb_build_object('run_date', v_run, 'skipped', true,
                              'reason', 'not the prepare day (' || coalesce(v_day, 25) || ')');
  end if;

  select period_start, period_end into v_start, v_end from _handover_period(v_run);
  v_owner := _handover_owner();

  for c in
    select * from org_contracts
     where contract_kind = 'retainer'          -- engagements are handed over on delivery
       and status = 'active'
       and billing_frequency = 'monthly'
       and start_date <= v_end
       and (end_date is null or end_date >= v_start)
  loop
    -- The pack starts where the LAST ONE WAS HANDED OVER, not at the month
    -- boundary. Work delivered after the previous handover still belongs to
    -- somebody, and this is the somebody. Nothing dropped, nothing counted
    -- twice.
    select coalesce(max(h.handed_at), v_start::timestamptz) into v_from
      from billing_handovers h
     where h.contract_id = c.id and h.kind = 'retainer';

    insert into billing_handovers (contract_id, org_id, kind, period_start, period_end,
                                   amount, currency, state, covers_from,
                                   prepared_by, narrative)
    values (c.id, c.org_id, 'retainer', v_start, v_end,
            c.retainer_amount, c.currency, 'to_prepare', v_from, v_owner,
            -- Deliberately EMPTY at creation. The pack is live: its contents
            -- come from handover_pack(), which recomputes until it is handed
            -- over. Storing them now would freeze work that has not happened.
            '{}'::jsonb)
    on conflict (contract_id, period_start) where kind = 'retainer' do nothing
    returning id into v_handover;

    if v_handover is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    -- Due at MONTH END. The handover carries no date of its own — note (f).
    if v_owner is not null then
      insert into actions (title, owner, due_date, state, org_id, created_by)
      values ('Hand ' || to_char(v_start, 'Mon YYYY') || ' numbers to Laone',
              v_owner, v_end, 'open', c.org_id, v_owner)
      returning id into v_action;
      update billing_handovers set action_id = v_action where id = v_handover;
    end if;

    v_created := v_created + 1;
  end loop;

  return jsonb_build_object('run_date', v_run, 'period_start', v_start,
                            'period_end', v_end, 'prepare_day', coalesce(v_day, 25),
                            'created', v_created, 'already_present', v_skipped,
                            'owner_unresolved', v_owner is null);
end $$;

revoke all on function handovers_run_monthly(date, boolean) from public, anon, authenticated;


-- ── 13a. The pack: live until handed over ───────────────────

create or replace function handover_pack(p_handover_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare h billing_handovers%rowtype;
begin
  if not is_staff() then raise exception 'not authorised'; end if;
  select * into h from billing_handovers where id = p_handover_id;
  if not found then raise exception 'no such handover'; end if;

  -- An engagement pack is one activity: nothing to recompute, ever.
  -- A retainer pack recomputes until it is frozen, so work delivered between
  -- the prepare day and the handover is still counted.
  if h.kind = 'engagement' or h.state <> 'to_prepare' then
    return jsonb_build_object('id', h.id, 'kind', h.kind, 'state', h.state,
                              'live', false, 'amount', h.amount,
                              'contents', h.narrative);
  end if;

  return jsonb_build_object('id', h.id, 'kind', h.kind, 'state', h.state,
                            'live', true, 'amount', h.amount,
                            'contents', _pack_contents(h.org_id, h.covers_from, now()));
end $$;

grant execute on function handover_pack(uuid) to authenticated;


-- ── 13b. Handing it over freezes it ─────────────────────────
-- Lone marks this herself. The moment she does, the contents stop moving and
-- the next pack starts from here.

create or replace function handover_mark_handed_over(p_handover_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare h billing_handovers%rowtype; v_contents jsonb; v_now timestamptz := now();
begin
  if not is_ops_admin() then raise exception 'not authorised'; end if;
  select * into h from billing_handovers where id = p_handover_id;
  if not found then raise exception 'no such handover'; end if;
  if h.state <> 'to_prepare' then
    raise exception 'this pack has already been handed over';
  end if;

  v_contents := case when h.kind = 'engagement' then h.narrative
                     else _pack_contents(h.org_id, h.covers_from, v_now) end;

  update billing_handovers
     set state = 'handed_over', handed_at = v_now,
         narrative = v_contents, updated_at = v_now
   where id = p_handover_id;

  -- The action that asked for it is done.
  update actions set state = 'done', done_at = v_now
   where id = h.action_id and state = 'open';

  return jsonb_build_object('id', p_handover_id, 'state', 'handed_over',
                            'handed_at', v_now, 'contents', v_contents);
end $$;

grant execute on function handover_mark_handed_over(uuid) to authenticated;


-- ── 13c. Lone's confirmation ────────────────────────────────
-- LONE HAS CONFIRMED WITH LAONE THAT THE INVOICE EXISTS. That is the whole
-- meaning of this state. It is not a reading of Sage, and the screen must not
-- imply that it is: "Confirmed with Laone · 26 Aug", never a bare "Invoiced".
--
-- There is no next state. No 'paid', because we cannot see whether it was.

create or replace function handover_confirm_invoiced(p_handover_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare h billing_handovers%rowtype; v_now timestamptz := now();
begin
  if not is_ops_admin() then raise exception 'not authorised'; end if;
  select * into h from billing_handovers where id = p_handover_id;
  if not found then raise exception 'no such handover'; end if;

  if h.state = 'invoiced' then
    -- Confirming twice is not an error; it is somebody checking. Say so, and
    -- leave the original moment where it is.
    return jsonb_build_object('id', p_handover_id, 'state', 'invoiced',
                              'already_confirmed', true,
                              'confirmed_at', h.invoice_confirmed_at);
  end if;

  if h.state <> 'handed_over' then
    raise exception 'the numbers must be handed to Laone before she can confirm an invoice';
  end if;

  update billing_handovers
     set state = 'invoiced',
         invoice_confirmed_by = auth.uid(),
         invoice_confirmed_at = v_now,
         updated_at = v_now
   where id = p_handover_id;

  return jsonb_build_object('id', p_handover_id, 'state', 'invoiced',
                            'already_confirmed', false, 'confirmed_at', v_now);
end $$;

grant execute on function handover_confirm_invoiced(uuid) to authenticated;


-- ── 13d. Cancelling, from any state ─────────────────────────
-- A reason is required. A cancelled handover with no reason is a hole in the
-- record that somebody has to reconstruct from memory later.

create or replace function handover_cancel(p_handover_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare h billing_handovers%rowtype; v_now timestamptz := now();
begin
  if not is_ops_admin() then raise exception 'not authorised'; end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'say why it is being cancelled';
  end if;

  select * into h from billing_handovers where id = p_handover_id;
  if not found then raise exception 'no such handover'; end if;
  if h.state = 'cancelled' then
    return jsonb_build_object('id', p_handover_id, 'state', 'cancelled',
                              'already_cancelled', true);
  end if;

  update billing_handovers
     set state = 'cancelled', cancelled_at = v_now,
         cancel_reason = left(btrim(p_reason), 500),
         -- The confirmation cannot survive the thing it confirmed.
         invoice_confirmed_by = null, invoice_confirmed_at = null,
         updated_at = v_now
   where id = p_handover_id;

  update actions set state = 'dropped', done_at = null
   where id = h.action_id and state = 'open';

  return jsonb_build_object('id', p_handover_id, 'state', 'cancelled',
                            'already_cancelled', false);
end $$;

grant execute on function handover_cancel(uuid, text) to authenticated;


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
    -- NOT "invoiced_value". We do not know what has been invoiced; we know
    -- what has been handed to Laone. The screen must say so.
    'handed_over_value', (select coalesce(sum(h.amount), 0) from billing_handovers h
                           where h.org_id = p_org_id and h.kind = 'engagement'
                             and h.state <> 'cancelled'),
    'confirmed_value',   (select coalesce(sum(h.amount), 0) from billing_handovers h
                           where h.org_id = p_org_id and h.kind = 'engagement'
                             and h.state = 'invoiced'),
    'not_handed_over_count', (select count(*) from program_activities pa
                         where pa.org_id = p_org_id and pa.state in ('delivered','reported')
                           and not exists (select 1 from billing_handovers h
                                            where h.activity_id = pa.id
                                              and h.state <> 'cancelled')),
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

    -- Marking an activity delivered BY HAND raises its handover too, once.
    -- The trigger covers the booking path; this covers the group work that
    -- never had a booking.
    if p_state = 'delivered' and v_was is distinct from 'delivered' then
      perform _handover_for_activity(v_id);
    end if;
  end if;

  select * into a from program_activities where id = v_id;
  return to_jsonb(a);
end $$;

grant execute on function activity_upsert(uuid, text, uuid, uuid, text, text, text, text,
                                          date, date, int, text) to authenticated;


-- ── 15. The flag on the Tuesday review ──────────────────────
--
-- WHAT LONE ASKED FOR: a retainer period past its prepare day with no invoiced
-- confirmation must surface on the Tuesday review as NEEDS A DECISION, reading
-- "August not confirmed invoiced".
--
-- It lives HERE, in the database, and not only on the screen. A flag that
-- exists only in the UI stops working the first time the UI is rebuilt, and
-- the assertion suite cannot see it at all.
--
-- ══ THIS REPLACES A FUNCTION THAT IS ALREADY LIVE ══════════
--
-- tuesday_review_pack() ships in M5 and is running in production. This section
-- replaces it. The body below is M5's, UNCHANGED, with one addition per
-- organisation: a 'billing' array, and billing folded into needs_decision.
--
-- What that means for the review screen:
--   BEFORE — needs_decision was true when the organisation had an open action
--            already past its due date.
--   AFTER  — it is ALSO true when a retainer period is past its prepare day
--            and Lone has not confirmed the invoice with Laone.
--   Nothing else about the returned shape changes. completion_rate,
--   last_week, open_now, open_count and unassigned are untouched.
--
-- If this is wrong, the Tuesday screen shows a wrong flag or fails to load.
-- No data is damaged. The rollback restores M5's body exactly.

create or replace function _billing_flags(p_org_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare v_day int;
begin
  select coalesce((value #>> '{}')::int, 25) into v_day
    from threshold_config where key = 'invoice.prepare_day';

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'handover_id', h.id,
             'period_start', h.period_start,
             'state', h.state,
             -- The words that appear on the screen, built here so every
             -- surface says the same thing.
             'label', to_char(h.period_start, 'FMMonth') || ' not confirmed invoiced'
           ) order by h.period_start)
      from billing_handovers h
     where h.org_id = p_org_id
       and h.kind = 'retainer'
       and h.state not in ('invoiced', 'cancelled')
       -- Past the prepare day of its own period. prepare_day 25 means the
       -- 25th of that month, so the period is late from the 26th onward.
       and current_date > (h.period_start + (coalesce(v_day, 25) - 1))
  ), '[]'::jsonb);
end $$;

revoke all on function _billing_flags(uuid) from public, anon, authenticated;


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
            -- NEW in M4.
            'billing', _billing_flags(o.id),
            'needs_decision', (
              exists (select 1 from actions a
                       where a.state = 'open' and a.org_id = o.id
                         and a.due_date < v_date)
              or jsonb_array_length(_billing_flags(o.id)) > 0   -- NEW in M4
            )
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


-- ── 16. The schedule ────────────────────────────────────────
-- Same guarded shape as M5, and pg_cron IS installed on this project
-- (confirmed 27 Aug 2026), so this runs on the first apply.
--
-- DAILY at 03:00 UTC, which is 05:00 Gaborone — an hour before the reminder
-- job at 04:00 UTC, so a handover action raised this morning can be reminded
-- about the same morning rather than waiting a day.

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- DAILY, and the function decides whether today is the prepare day. That
    -- keeps invoice.prepare_day configurable without rescheduling cron.
    execute $c$
      select cron.schedule('kw-monthly-handovers', '0 3 * * *',
                           $j$ select handovers_run_monthly(null, true) $j$)
    $c$;
    raise notice 'M4: pg_cron job kw-monthly-handovers runs daily; the prepare day '
                 'comes from threshold_config (invoice.prepare_day, default 25).';
  else
    raise notice 'M4: pg_cron is NOT installed here — no handover will ever be '
                 'raised. It IS installed on the live project; if you see this '
                 'on live, something has changed.';
  end if;
end $$;


-- ── 17. Post-conditions ─────────────────────────────────────
-- Cheap assertions so a bad apply fails loudly here rather than surfacing as a
-- wrong number weeks later.

do $$
declare n int;
begin
  -- The states, and the two that must never come back.
  if (select pg_get_constraintdef(oid) from pg_constraint
       where conname = 'billing_handovers_state_check') ~* '\mpaid\M' then
    raise exception 'M4: billing_handovers must have no paid state — Sage owns that';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint
       where conname = 'billing_handovers_state_check') ~* '\moverdue\M' then
    raise exception 'M4: billing_handovers must have no overdue state — it is not knowable here';
  end if;

  -- Nothing anywhere may claim to know what Sage holds.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'billing_handovers'
                and column_name in ('scan_path', 'paid_at', 'due_date')) then
    raise exception 'M4: billing_handovers carries a column that describes a document in Sage';
  end if;

  -- Ten policies across the five new tables.
  select count(*) into n from pg_policies
   where schemaname = 'public'
     and tablename in ('org_contracts','contract_rates','org_contacts',
                       'work_plans','billing_handovers');
  if n <> 10 then
    raise exception 'M4: expected 10 policies across the new tables, found %', n;
  end if;

  -- The trigger must be transition-guarded — header note (g).
  if not exists (select 1 from pg_proc
                  where proname = 'kw_booking_drives_activity'
                    and prosrc like '%old.%') then
    raise exception 'M4: the booking trigger does not read OLD and would fire on every update';
  end if;

  raise notice 'M4 applied. The handover is prepared on day % of the month it '
               'covers and stays LIVE until Lone hands it over. There is no '
               'paid state and no overdue: billing_handovers are produced in Sage. '
               'M3 must gate org_work_plan() and contract_position().',
    (select coalesce((value #>> '{}')::int, 25) from threshold_config
      where key = 'invoice.prepare_day');
end $$;
