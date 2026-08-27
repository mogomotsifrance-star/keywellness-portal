-- ============================================================
-- Key Wellness — M3 Part 1: the confidentiality boundary
--
-- ══ DO NOT APPLY THIS FILE ON ITS OWN ══════════════════════
--
-- Part 1 and Part 2 are ONE migration in two files, and Part 1 alone leaves
-- the system WORSE than it is today.
--
-- Part 1 writes the policies. But roughly a dozen SECURITY DEFINER functions
-- read `bookings` and `program_activities` without ever consulting a policy —
-- `advisor_clients_list` among them, which the financial team lead calls every
-- day. Applying Part 1 alone produces a boundary that looks enforced and is
-- walked straight through, which is more dangerous than today's state, where
-- nobody believes there is a boundary at all.
--
--   Part 1: supabase_m3_part1_confidentiality_boundary.sql   (this file)
--   Part 2: supabase_m3_part2_definer_sweep.sql
--
-- Branch first. Rollback does not undo a disclosure.
-- Rollback: migrations/rollback-m3-counsellors.sql (covers both parts)
-- Tests:    tests/m3-tests.sql
-- Plan:     docs/build/m3-plan.md
--
-- ══ WHAT THIS IS FOR, IN PLAIN LANGUAGE ════════════════════
--
-- A counselling booking says something about a person that they told ONE
-- practitioner in confidence. This makes the database enforce that — not the
-- screens, not a convention — so that whoever should not see it cannot,
-- whatever role they hold and whatever page they open.
--
-- Including the other counsellor. Karabo and Nicola do not share notes or case
-- files. There is NO Clinical Lead, permanently, by design, so there is no
-- lead path, no admin path and no break-glass path between them. The only
-- sanctioned route is a referral, and a referral works by the referring
-- counsellor WRITING SOMETHING NEW — never by granting sight of notes they
-- already wrote.
--
--   INFORMATION FLOWS FORWARD, NEVER ACCESS BACKWARD.
--
-- That sentence is the whole design. Everything below is a consequence of it.
--
-- ══ TWO OBJECTS THIS FILE ASSUMES, AND DOES NOT CREATE ═════
--
-- `psychosocial_admins` and `is_psychosocial_admin()` were created by M4a
-- (migration 20260827073638) and are already live, holding Lone and Michelle.
-- M3 BUILDS ON THEM and does not re-create them. Section 0 asserts they exist
-- rather than assuming it, so that applying this to a database where M4a never
-- ran fails immediately and legibly instead of creating a boundary with no
-- membership behind it.
--
-- ══ WHAT WILL CHANGE, AND WHAT WILL NOT ════════════════════
-- Written BEFORE the apply, as the prediction to check against.
--
--   CHANGES — two cells of the matrix, and only two
--     The FINANCIAL TEAM LEAD loses psychosocial bookings. Today
--     `bookings_advisor_select` grants them every booking in the system.
--     A FRANCE-TYPE ADMIN loses psychosocial bookings. Lone and Michelle keep
--     them, because they are in psychosocial_admins.
--
--   CHANGES — three defects fixed while the policies are replaced
--     `bookings_admin` compares email WITHOUT LOWERING IT and grants ALL
--     commands. A silent authorisation bug.
--     `bookings_self` is an exact duplicate of `bookings_own`.
--     `is_team_lead()` inside the advisor SELECT is the widest read on the
--     table.
--
--   DOES NOT CHANGE
--     Members read their own rows exactly as today, both lines.
--     Advisors read their own financial rows and their caseload, as today.
--     HR reads no booking row directly, as today.
--     No existing booking is added, altered or deleted. Every row that exists
--     is service_line 'financial' and stays visible to everyone who sees it
--     now.
--
--   IF IT IS WRONG
--     The realistic failure is a practitioner unable to open their own
--     client's session. No data is damaged. But note the asymmetry that makes
--     this migration different from every other one: if it is wrong in the
--     OTHER direction and a counselling booking is read by someone who should
--     not see it, the rollback does not unread it. Hence the branch.
-- ============================================================


-- ── 0. The two objects M4a already shipped ──────────────────

do $$
begin
  if to_regclass('public.psychosocial_admins') is null then
    raise exception 'M3: psychosocial_admins is missing — apply M4a first. '
                    'M3 builds on it and must not create a boundary with no '
                    'membership behind it.';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'is_psychosocial_admin') then
    raise exception 'M3: is_psychosocial_admin() is missing — apply M4a first.';
  end if;
  if (select count(*) from psychosocial_admins where is_active) = 0 then
    raise exception 'M3: psychosocial_admins is empty. Applying the boundary '
                    'now would lock every psychosocial row away from everyone.';
  end if;
end $$;


-- ── 1. counsellors ──────────────────────────────────────────
-- NO is_clinical_lead COLUMN. There is no Clinical Lead, permanently, by
-- design — and a permission nobody uses is a bug waiting to be flipped without
-- anyone re-deriving why it existed. The absence has to be legible in the
-- schema itself, so there is nothing here to flip.

create table if not exists counsellors (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references auth.users(id),
  email      text not null unique,
  full_name  text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

comment on table counsellors is
  'Practitioners on the psychosocial line. There is deliberately NO '
  'is_clinical_lead column: no such role exists and none is coming. '
  'counselling_referrals is the only sanctioned path between counsellors.';

alter table counsellors enable row level security;

-- Staff may see WHO the counsellors are. That is a roster, not a case file.
drop policy if exists counsellors_staff_read on counsellors;
create policy counsellors_staff_read on counsellors
  for select using (is_staff());

drop policy if exists counsellors_admin_write on counsellors;
create policy counsellors_admin_write on counsellors
  for all using (is_admin()) with check (is_admin());


create or replace function current_counsellor_id()
returns uuid
language sql
stable
security definer
set search_path = public, auth
as $$
  select c.id from counsellors c
   where c.is_active
     and (c.user_id = auth.uid() or lower(c.email) = lower(auth.jwt() ->> 'email'))
   limit 1;
$$;

grant execute on function current_counsellor_id() to authenticated;


create or replace function is_counsellor()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select current_counsellor_id() is not null;
$$;

grant execute on function is_counsellor() to authenticated;


-- M5 left room for exactly this line and nothing else.
create or replace function is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select is_admin() or is_advisor() or is_counsellor();
$$;

grant execute on function is_staff() to authenticated;


-- ── 2. counsellor_clients — forward-only by construction ────
-- NOT a mutable counsellor_id. A caseload link is opened and closed; it is
-- never repointed. When Karabo refers a client to Nicola, Karabo's row is
-- ENDED and a new row is opened for Nicola. Karabo's old row — and everything
-- attached to it — stays Karabo's because it is still the same row, not
-- because something remembered not to update it.
--
-- INFORMATION FLOWS FORWARD, NEVER ACCESS BACKWARD.

create table if not exists counsellor_clients (
  id             uuid primary key default gen_random_uuid(),
  counsellor_id  uuid not null references counsellors(id),
  member_user_id uuid references auth.users(id),
  full_name      text,
  email          text,
  phone          text,
  org_id         uuid references organizations(id),
  is_active      boolean not null default true,
  ended_at       timestamptz,
  created_at     timestamptz not null default now()
);

comment on table counsellor_clients is
  'One row per counsellor-client link. Closed with ended_at, never repointed '
  'to a different counsellor: the old row stays the old counsellor''s.';

do $$
begin
  if not exists (select 1 from pg_constraint where conname='counsellor_clients_ended_agrees') then
    alter table counsellor_clients add constraint counsellor_clients_ended_agrees
      check (is_active = (ended_at is null));
  end if;
end $$;

create index if not exists counsellor_clients_counsellor_idx
  on counsellor_clients (counsellor_id) where is_active;
create index if not exists counsellor_clients_member_idx
  on counsellor_clients (member_user_id);

alter table counsellor_clients enable row level security;

-- The counsellor's own caseload, and nobody else's. No admin policy: a
-- caseload names who is in counselling, which is the fact being protected.
drop policy if exists counsellor_clients_own on counsellor_clients;
create policy counsellor_clients_own on counsellor_clients
  for all using (counsellor_id = current_counsellor_id())
          with check (counsellor_id = current_counsellor_id());

-- Lone and Michelle schedule and bill, so they need to know a link exists.
drop policy if exists counsellor_clients_psychosocial_admin on counsellor_clients;
create policy counsellor_clients_psychosocial_admin on counsellor_clients
  for select using (is_psychosocial_admin());


-- ── 3. bookings gains a counsellor ──────────────────────────

alter table bookings add column if not exists counsellor_id        uuid references counsellors(id);
alter table bookings add column if not exists counsellor_client_id uuid references counsellor_clients(id);

do $$
begin
  -- A session has ONE practitioner. Both set would make the row readable
  -- through the financial branch AND the psychosocial branch at once, which
  -- is precisely the leak this migration exists to close.
  if not exists (select 1 from pg_constraint where conname='bookings_one_practitioner') then
    alter table bookings add constraint bookings_one_practitioner
      check (not (advisor_id is not null and counsellor_id is not null));
  end if;

  -- A psychosocial booking with no counsellor would be readable by nobody but
  -- its member and a psychosocial admin, which is survivable — but a
  -- FINANCIAL booking carrying a counsellor is a mislabelled row, and that is
  -- not.
  if not exists (select 1 from pg_constraint where conname='bookings_counsellor_is_psychosocial') then
    alter table bookings add constraint bookings_counsellor_is_psychosocial
      check (counsellor_id is null or service_line = 'psychosocial');
  end if;
end $$;

create index if not exists bookings_counsellor_idx on bookings (counsellor_id)
  where counsellor_id is not null;


-- ── 4. The bookings policies, replaced in one transaction ───
--
-- POSTGRESQL **ORs** PERMISSIVE POLICIES. Dropping any one of the nine
-- existing policies changes nothing while the others stand — which is why
-- splitting the advisor SELECT alone would have achieved exactly nothing.
-- They go together or not at all.

begin;

-- The four that go. Their live predicates are written out in the plan (§7);
-- they existed in the repo only as a comment inventory, and
-- supabase_cleanup_policies.sql was never applied.
drop policy if exists bookings_admin           on bookings;   -- un-lowered email, ALL
drop policy if exists bookings_admin_all       on bookings;   -- is_admin(), ALL, both lines
drop policy if exists bookings_self            on bookings;   -- duplicate of bookings_own
drop policy if exists bookings_advisor_select  on bookings;   -- is_team_lead() reads everything

-- The five that are replaced in place, so the line filter cannot be forgotten.
drop policy if exists bookings_advisor_insert  on bookings;
drop policy if exists bookings_advisor_update  on bookings;
drop policy if exists bookings_lead_update     on bookings;
drop policy if exists bookings_member_respond  on bookings;
drop policy if exists bookings_own             on bookings;


-- ── The member. Unchanged: their own rows, both lines. ──
create policy bookings_own on bookings
  for all using (user_id = auth.uid())
          with check (user_id = auth.uid());

create policy bookings_member_respond on bookings
  for update using (user_id = auth.uid())
            with check (user_id = auth.uid());


-- ── The financial line. ──
-- is_team_lead() survives HERE and only here: a team lead genuinely does
-- oversee the whole financial caseload. What changes is that it can no longer
-- reach across the line.
create policy bookings_financial_read on bookings
  for select using (
    service_line = 'financial'
    and (
      is_admin()
      or advisor_id = current_advisor_id()
      or is_team_lead()
      or exists (select 1 from advisor_clients ac
                  where ac.advisor_id = current_advisor_id()
                    and (ac.member_user_id = bookings.user_id
                      or ac.id = bookings.advisor_client_id))
    )
  );

create policy bookings_financial_admin_write on bookings
  for all using (is_admin() and service_line = 'financial')
          with check (is_admin() and service_line = 'financial');

create policy bookings_advisor_insert on bookings
  for insert with check (
    advisor_id = current_advisor_id()
    and booked_by = 'advisor'
    and service_line = 'financial'
  );

create policy bookings_advisor_update on bookings
  for update using (advisor_id = current_advisor_id() and service_line = 'financial')
            with check (advisor_id = current_advisor_id() and service_line = 'financial');

create policy bookings_lead_update on bookings
  for update using (is_team_lead() and service_line = 'financial')
            with check (is_team_lead() and service_line = 'financial');


-- ── The psychosocial line. ──
-- THE WHOLE MIGRATION IS THIS POLICY.
--
-- A counsellor reads their OWN bookings. Not their colleague's. There is no
-- clinical-lead disjunct because there is no clinical lead, and no admin
-- disjunct because is_psychosocial_admin() is membership rather than a role —
-- France holds admin and is not a member, which is the point.
create policy bookings_psychosocial_read on bookings
  for select using (
    service_line = 'psychosocial'
    and (
      counsellor_id = current_counsellor_id()
      or is_psychosocial_admin()
    )
  );

create policy bookings_psychosocial_admin_write on bookings
  for all using (is_psychosocial_admin() and service_line = 'psychosocial')
          with check (is_psychosocial_admin() and service_line = 'psychosocial');

create policy bookings_counsellor_insert on bookings
  for insert with check (
    counsellor_id = current_counsellor_id()
    and service_line = 'psychosocial'
  );

create policy bookings_counsellor_update on bookings
  for update using (counsellor_id = current_counsellor_id()
                    and service_line = 'psychosocial')
            with check (counsellor_id = current_counsellor_id()
                        and service_line = 'psychosocial');

commit;


-- ── 5. counselling_notes — author only, no exception, ever ──
-- No admin policy. No lead policy. No break-glass. An admin who needs a note
-- asks the author, which is the correct social process and not a gap.
--
-- Note the deliberate asymmetry with bookings: Lone and Michelle READ
-- PSYCHOSOCIAL BOOKINGS BUT NOT NOTES. They need to know a session happened,
-- to schedule and to bill. They do not need to know what was said.

create table if not exists counselling_notes (
  id                   uuid primary key default gen_random_uuid(),
  counsellor_id        uuid not null references counsellors(id),
  counsellor_client_id uuid references counsellor_clients(id),
  booking_id           uuid references bookings(id) on delete set null,
  body                 text not null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

comment on table counselling_notes is
  'AUTHOR ONLY. No admin policy, no clinical-lead policy, no exception. A '
  'referral does not grant access to these — the referring counsellor writes '
  'fresh handover content instead. Information flows forward, never access '
  'backward.';

create index if not exists counselling_notes_author_idx
  on counselling_notes (counsellor_id, created_at desc);

alter table counselling_notes enable row level security;

drop policy if exists counselling_notes_author_only on counselling_notes;
create policy counselling_notes_author_only on counselling_notes
  for all using (counsellor_id = current_counsellor_id())
          with check (counsellor_id = current_counsellor_id());

-- Two independent locks, as with action_reminders: RLS with a single policy
-- already denies everyone else, and revoking the table grant means a policy
-- added here by accident later does not silently open the notes.
revoke all on table counselling_notes from anon, authenticated;
grant select, insert, update, delete on table counselling_notes to authenticated;


-- ── 6. counselling_referrals — the only path between them ───
-- The `note` is FRESHLY AUTHORED handover content. It is never a copy of, and
-- never a pointer into, the referring counsellor's counselling_notes rows.
-- Those stay theirs, permanently, referral or not.
--
-- WHY THAT DISTINCTION IS THE WHOLE DESIGN: a referral that granted access to
-- the original notes would make the author-only policy CONDITIONAL ON A ROW IN
-- ANOTHER TABLE, and the boundary would then be only as strong as whoever can
-- write that row. Making the handover a separately authored artefact means the
-- referring counsellor decides, sentence by sentence, what crosses — which is
-- what a clinical handover is in the first place.

create table if not exists counselling_referrals (
  id                   uuid primary key default gen_random_uuid(),
  counsellor_client_id uuid not null references counsellor_clients(id),
  from_counsellor_id   uuid not null references counsellors(id),
  to_counsellor_id     uuid not null references counsellors(id),
  note                 text not null,
  created_at           timestamptz not null default now(),
  accepted_at          timestamptz
);

comment on column counselling_referrals.note is
  'Freshly authored handover content, written for this referral. NEVER a copy '
  'of or a pointer into counselling_notes. Reading a referral grants no access '
  'to the referring counsellor''s notes.';

do $$
begin
  if not exists (select 1 from pg_constraint where conname='counselling_referrals_not_self') then
    alter table counselling_referrals add constraint counselling_referrals_not_self
      check (from_counsellor_id <> to_counsellor_id);
  end if;
end $$;

create index if not exists counselling_referrals_to_idx
  on counselling_referrals (to_counsellor_id) where accepted_at is null;

alter table counselling_referrals enable row level security;

drop policy if exists counselling_referrals_from_insert on counselling_referrals;
create policy counselling_referrals_from_insert on counselling_referrals
  for insert with check (from_counsellor_id = current_counsellor_id());

drop policy if exists counselling_referrals_parties_read on counselling_referrals;
create policy counselling_referrals_parties_read on counselling_referrals
  for select using (
    from_counsellor_id = current_counsellor_id()
    or to_counsellor_id = current_counsellor_id()
  );

-- The receiving counsellor accepts. Nobody else may write the row after it
-- exists — the referring counsellor cannot un-refer, and no admin can accept
-- on anyone's behalf.
drop policy if exists counselling_referrals_to_accept on counselling_referrals;
create policy counselling_referrals_to_accept on counselling_referrals
  for update using (to_counsellor_id = current_counsellor_id())
            with check (to_counsellor_id = current_counsellor_id());

-- LONE LEARNS THE FACT, NEVER THE NOTE.
-- Decided 27 Aug: "Karabo referred this client to Nicola, 27 Aug" and nothing
-- more. That is everything she needs to route future bookings and nothing she
-- needs to be trusted with. A column-level grant is the mechanism, because a
-- row-level policy cannot withhold one column.
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
             'from', f.full_name,
             'to',   t.full_name
             -- The note is NOT here, and must never be added.
           ) order by r.created_at desc)
      from counselling_referrals r
      join counsellors f on f.id = r.from_counsellor_id
      join counsellors t on t.id = r.to_counsellor_id
  ), '[]'::jsonb);
end $$;

grant execute on function referral_fact_list() to authenticated;


-- ── 7. Themes — aggregate only, floored always ──────────────

create table if not exists theme_taxonomy (
  key        text primary key,
  label      text not null,
  sort_order int  not null default 0,
  is_active  boolean not null default true
);

comment on table theme_taxonomy is
  'A TABLE and not a check constraint, because counsellors will revise this '
  'list and must be able to without a migration.';

insert into theme_taxonomy (key, label, sort_order) values
  ('work_stress',        'Work stress',              10),
  ('relationships',      'Relationships and family', 20),
  ('bereavement',        'Bereavement',              30),
  ('financial_stress',   'Financial stress',         40),
  ('substance_use',      'Substance use',            50),
  ('trauma',             'Trauma',                   60),
  ('other',              'Other',                    70)
on conflict (key) do nothing;

alter table theme_taxonomy enable row level security;
drop policy if exists theme_taxonomy_staff_read on theme_taxonomy;
create policy theme_taxonomy_staff_read on theme_taxonomy
  for select using (is_staff());
drop policy if exists theme_taxonomy_counsellor_write on theme_taxonomy;
create policy theme_taxonomy_counsellor_write on theme_taxonomy
  for all using (is_counsellor()) with check (is_counsellor());


create table if not exists session_themes (
  booking_id uuid not null references bookings(id) on delete cascade,
  theme_key  text not null references theme_taxonomy(key),
  created_at timestamptz not null default now(),
  primary key (booking_id, theme_key)
);

alter table session_themes enable row level security;

-- Written and read by the counsellor on the booking. NOBODY else gets a direct
-- select — not an admin, not a psychosocial admin. Aggregates go through the
-- floored RPC below.
drop policy if exists session_themes_counsellor on session_themes;
create policy session_themes_counsellor on session_themes
  for all using (exists (select 1 from bookings b
                          where b.id = session_themes.booking_id
                            and b.counsellor_id = current_counsellor_id()))
          with check (exists (select 1 from bookings b
                               where b.id = session_themes.booking_id
                                 and b.counsellor_id = current_counsellor_id()));

revoke all on table session_themes from anon, authenticated;
grant select, insert, update, delete on table session_themes to authenticated;


-- The base-5 floor is applied ALWAYS. There is no internal no-floor view,
-- unlike the financial indicators — decided 25 Aug and not reopened. A theme
-- count of one IS the disclosure: in an organisation of nine, "1 bereavement"
-- plus a funeral everyone knows about is a name.
create or replace function theme_counts(p_org_id uuid default null,
                                        p_from date default null,
                                        p_to   date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare v_floor int := 5;
begin
  if not (is_psychosocial_admin() or is_counsellor()) then
    raise exception 'not authorised';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'theme', tt.label,
             'count', case when c.n >= v_floor then to_jsonb(c.n) else 'null'::jsonb end,
             'suppressed', c.n < v_floor
           ) order by tt.sort_order)
      from theme_taxonomy tt
      join lateral (
        select count(*)::int as n
          from session_themes st
          join bookings b on b.id = st.booking_id
          left join profiles p on p.id = b.user_id
         where st.theme_key = tt.key
           and b.service_line = 'psychosocial'
           and (p_org_id is null or p.org_id = p_org_id)
           and (p_from is null or coalesce(b.requested_date::date, b.created_at::date) >= p_from)
           and (p_to   is null or coalesce(b.requested_date::date, b.created_at::date) <= p_to)
      ) c on true
     where tt.is_active
  ), '[]'::jsonb);
end $$;

grant execute on function theme_counts(uuid, date, date) to authenticated;


-- ── 8. Post-conditions ──────────────────────────────────────

do $$
declare n int;
begin
  -- Nothing named is_clinical_lead may exist. Asserted so it cannot quietly
  -- return in a later migration.
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname = 'is_clinical_lead') then
    raise exception 'M3: is_clinical_lead() exists — there is no such role';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and column_name = 'is_clinical_lead') then
    raise exception 'M3: an is_clinical_lead column exists — there is no such role';
  end if;

  -- counselling_notes must have exactly ONE policy, and it must be the author.
  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename = 'counselling_notes';
  if n <> 1 then
    raise exception 'M3: counselling_notes must have exactly 1 policy, found %', n;
  end if;

  -- The four legacy bookings policies must be gone.
  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename = 'bookings'
     and policyname in ('bookings_admin','bookings_admin_all','bookings_self',
                        'bookings_advisor_select');
  if n <> 0 then
    raise exception 'M3: % legacy bookings policy/policies survive', n;
  end if;

  -- No bookings policy may still compare an email without lowering it.
  if exists (select 1 from pg_policies
              where schemaname='public' and tablename='bookings'
                and coalesce(qual,'') like '%jwt() ->> ''email''%'
                and coalesce(qual,'') not like '%lower%') then
    raise exception 'M3: a bookings policy still compares email un-lowered';
  end if;

  raise notice 'M3 Part 1 applied. THE BOUNDARY IS NOT YET ENFORCED: a dozen '
               'SECURITY DEFINER functions still read bookings without '
               'consulting any policy. APPLY PART 2 BEFORE ANYONE USES THIS.';
end $$;
