-- ============================================================
-- Key Wellness — extra fixture for the M3 suite
--
-- WHY THIS FILE EXISTS. M3's sweep must filter twelve SECURITY DEFINER
-- functions, and nine of them live in the advisor-portal migrations. Loading
-- those into the test stack immediately failed on `column a.phone does not
-- exist` — the fixture's advisor tables are a RECONSTRUCTION and had drifted
-- from live.
--
-- That is not a nuisance, it is the whole risk in miniature: without the
-- advisor portal in the stack the sweep filtered 3 of 12 and reported success
-- for the three. The nine that actually leak to the financial team lead would
-- never have been touched, and the suite would have been green.
--
-- Columns below are taken from the LIVE information_schema on 27 Aug 2026, not
-- from what the tests happen to need. See CLAUDE_CONTEXT.md §3.2.
-- ============================================================

-- ── advisors, as live has it ────────────────────────────────
alter table advisors add column if not exists phone      text;
alter table advisors add column if not exists title      text;
alter table advisors add column if not exists created_by uuid;
alter table advisors add column if not exists updated_at timestamptz not null default now();

-- ── advisor_clients, as live has it ─────────────────────────
alter table advisor_clients add column if not exists first_name   text;
alter table advisor_clients add column if not exists last_name    text;
alter table advisor_clients add column if not exists email        text;
alter table advisor_clients add column if not exists phone        text;
alter table advisor_clients add column if not exists org_id       uuid;
alter table advisor_clients add column if not exists assessment   jsonb;
alter table advisor_clients add column if not exists source       text;
alter table advisor_clients add column if not exists status       text;
alter table advisor_clients add column if not exists linked_at    timestamptz;
alter table advisor_clients add column if not exists created_by   uuid;
alter table advisor_clients add column if not exists created_at   timestamptz not null default now();
alter table advisor_clients add column if not exists updated_at   timestamptz not null default now();
alter table advisor_clients add column if not exists org_unit_id  uuid;
alter table advisor_clients add column if not exists no_org       boolean not null default false;
alter table advisor_clients add column if not exists org_mismatch boolean not null default false;

-- ── advisor_notes, as live has it ───────────────────────────
create table if not exists advisor_notes (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid,
  advisor_id uuid,
  booking_id uuid,
  body       text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  origin     text
);

-- ── A financial advisor who is the TEAM LEAD ────────────────
-- Thato exists so that "the financial team lead cannot read a psychosocial
-- booking" has somebody to be false about. Without a real team lead the
-- assertion passes vacuously, which is the failure mode this whole suite is
-- written against.

insert into advisors (id, user_id, email, full_name, is_active, is_team_lead)
values ('0ad00000-0000-0000-0000-0000000000aa',
        '00000000-0000-0000-0000-0000000000cc',
        'thato@keywellness.co.bw', 'Thato', true, true)
on conflict (id) do nothing;
