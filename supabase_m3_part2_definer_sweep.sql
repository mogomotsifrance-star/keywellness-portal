-- ============================================================
-- Key Wellness — M3 Part 2: the definer sweep
--
-- ══ APPLY THIS IMMEDIATELY AFTER PART 1, IN THE SAME SESSION ══
--
-- Part 1 writes the policies. THIS FILE IS WHAT MAKES THEM TRUE. Between the
-- two, the boundary exists on paper and a dozen functions walk through it.
--
-- Branch first. Rollback does not undo a disclosure.
-- Rollback: migrations/rollback-m3-counsellors.sql (covers both parts)
--
-- ══ THE PROBLEM, IN PLAIN LANGUAGE ═════════════════════════
--
-- A SECURITY DEFINER function runs as the database owner. It NEVER CONSULTS
-- ROW-LEVEL SECURITY AT ALL. So a perfect set of policies on `bookings` does
-- nothing about the seventeen such functions that read it.
--
-- The one that matters most: `advisor_clients_list` is gated on
-- `is_team_lead()` and reads `bookings` directly. The financial team lead
-- calls it every day. Without this file, "the financial team lead cannot read
-- a psychosocial booking" is false no matter what Part 1 says.
--
-- ══ HOW THIS FIXES IT, AND WHY THIS WAY ════════════════════
--
-- Not by editing seventeen function bodies by hand. That is fragile, it is
-- unreviewable, and — the real objection — THE NEXT FUNCTION SOMEBODY WRITES
-- FORGETS. A rule enforced by seventeen copies of itself is a rule that decays.
--
-- Instead:
--
--   1. ONE predicate holds the rule: kw_can_see_booking(bookings). It mirrors
--      Part 1's policies exactly, because it IS the same rule expressed once.
--
--   2. Every read of the table is rewritten LEXICALLY from
--            from bookings b
--      to
--            from (select * from bookings where kw_can_see_booking(bookings)) b
--      The alias survives, the columns are identical, and the filter cannot be
--      forgotten because it is inside the thing being read.
--
--   3. A post-condition asserts that EVERY definer function reading bookings
--      contains the predicate. A function added later without it FAILS THE
--      TEST SUITE rather than quietly leaking.
--
-- The substitution touches only `from bookings` and `join bookings` — never
-- `insert into bookings` or `update bookings`, which are writes and are
-- scoped by their own WHERE clauses (see section 4).
--
-- ══ WHAT WILL CHANGE, AND WHAT WILL NOT ════════════════════
--
--   CHANGES
--     Twelve functions stop returning psychosocial rows to people who should
--     not see them. Today every one of them returns everything.
--
--   DOES NOT CHANGE
--     Every booking that exists today is service_line 'financial'. On the
--     current data these functions return BYTE-IDENTICAL results before and
--     after — which is exactly what makes this safe to apply and exactly what
--     makes it untestable on live data alone. THE BRANCH MUST BE SEEDED WITH
--     PSYCHOSOCIAL ROWS or this file proves nothing.
--
--   IF IT IS WRONG
--     A practitioner cannot see their own client's session. Visible, annoying,
--     harmless. The other direction — a leak — is not undoable, which is why
--     this goes to a branch and why the matrix is read before merge.
-- ============================================================


-- ── 1. The rule, written once ───────────────────────────────
-- This MIRRORS the policies in Part 1 section 4. If you change one, change the
-- other — and the test suite asserts they agree by exercising both paths with
-- the same six people.

create or replace function kw_can_see_booking(b bookings)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select
    -- The member's own row, either line.
    b.user_id = auth.uid()

    -- The financial line: admin, the booking's advisor, the team lead, or an
    -- advisor with that client on their caseload.
    or (b.service_line = 'financial'
        and (is_admin()
          or b.advisor_id = current_advisor_id()
          or is_team_lead()
          or exists (select 1 from advisor_clients ac
                      where ac.advisor_id = current_advisor_id()
                        and (ac.member_user_id = b.user_id
                          or ac.id = b.advisor_client_id))))

    -- The psychosocial line: the booking's own counsellor, or a psychosocial
    -- admin. No clinical lead — there is no such role. No plain admin —
    -- France holds admin and is deliberately not a psychosocial admin.
    or (b.service_line = 'psychosocial'
        and (b.counsellor_id = current_counsellor_id()
          or is_psychosocial_admin()));
$$;

revoke all on function kw_can_see_booking(bookings) from public, anon, authenticated;


-- program_activities carries service_line too (M1). A psychosocial activity is
-- a group session, a clinic, a talk — it names no individual, but it names an
-- organisation as receiving counselling, which is itself the fact.
create or replace function kw_can_see_activity(a program_activities)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select a.service_line = 'financial'
      or is_psychosocial_admin()
      or is_counsellor();
$$;

revoke all on function kw_can_see_activity(program_activities) from public, anon, authenticated;


-- ── 2. The sweep ────────────────────────────────────────────
-- Explicit function list, so this cannot run away across the schema. Each
-- name is here because section 2 of docs/build/m3-plan.md found it reading
-- one of the two tables while granted to `authenticated`.

do $$
declare
  r      record;
  v_def  text;
  v_new  text;
  n      int := 0;
begin
  for r in
    select p.oid, p.proname
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname in (
         -- read bookings
         'admin_advisor_roster', 'advisor_client_detail', 'advisor_client_notes',
         'advisor_clients_list', 'advisor_pending_responses',
         'advisor_session_breakdown', 'booking_notify_payload',
         'ops_timeline', 'session_source_trend',
         -- read program_activities
         'activity_upsert', 'contract_position', 'org_work_plan'
       )
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := v_def;

    -- Reads only. `insert into bookings` and `update bookings` are untouched:
    -- they are writes, scoped by their own WHERE clauses. See section 4.
    v_new := regexp_replace(v_new, '(\mfrom\s+)bookings(\s+)(\w+)',
             '\1(select * from bookings where kw_can_see_booking(bookings))\2\3', 'gi');
    v_new := regexp_replace(v_new, '(\mjoin\s+)bookings(\s+)(\w+)',
             '\1(select * from bookings where kw_can_see_booking(bookings))\2\3', 'gi');

    v_new := regexp_replace(v_new, '(\mfrom\s+)program_activities(\s+)(\w+)',
             '\1(select * from program_activities where kw_can_see_activity(program_activities))\2\3', 'gi');
    v_new := regexp_replace(v_new, '(\mjoin\s+)program_activities(\s+)(\w+)',
             '\1(select * from program_activities where kw_can_see_activity(program_activities))\2\3', 'gi');

    if v_new = v_def then
      raise exception 'M3: % was listed for the sweep but nothing matched. Its '
                      'read does not use the expected `from <table> <alias>` '
                      'shape and needs rewriting BY HAND — do not skip it.',
                      r.proname;
    end if;

    execute v_new;
    n := n + 1;
    raise notice 'M3: % filtered', r.proname;
  end loop;

  if n <> 12 then
    raise exception 'M3: expected to filter 12 functions, filtered %', n;
  end if;
  raise notice 'M3: % function(s) filtered.', n;
end $$;


-- ── 3. The reporting split ──────────────────────────────────
-- _org_report_period_data counts `bookings`. The day a counselling booking
-- exists it lands in the session totals HR reads, silently and with no
-- decision having been taken.
--
-- It is not in the sweep above because it is NOT granted to `authenticated` —
-- it is reached through org_report_data(), which is gated. So it does not leak
-- rows; it MISCOUNTS them, which is a different fault with the same cause.
--
-- HR sees psychosocial as AGGREGATE ONLY, minimum base 5, ALWAYS — no
-- internal no-floor view, unlike the financial indicators. Decided 25 Aug.
-- The cleanest expression of that here: the session figures HR reads count
-- the FINANCIAL line only, and psychosocial reaches HR through theme_counts()
-- and nowhere else.

do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = '_org_report_period_data';

  if v_def is null then
    raise exception 'M3: _org_report_period_data is missing';
  end if;

  v_new := regexp_replace(v_def, '(\mfrom\s+)bookings(\s+)(\w+)',
           '\1(select * from bookings where service_line = ''financial'')\2\3', 'gi');
  v_new := regexp_replace(v_new, '(\mjoin\s+)bookings(\s+)(\w+)',
           '\1(select * from bookings where service_line = ''financial'')\2\3', 'gi');

  if v_new = v_def then
    raise exception 'M3: _org_report_period_data does not use the expected '
                    'shape — split it BY HAND rather than shipping HR a number '
                    'that silently includes counselling.';
  end if;

  execute v_new;
  raise notice 'M3: _org_report_period_data now counts the financial line only.';
end $$;


-- ── 4. The five that are safe by construction ───────────────
-- These read or write bookings and are NOT in the sweep, because each is
-- already scoped to the caller's own row. "Probably safe by construction" is
-- the phrase that precedes an incident, so each is asserted rather than
-- assumed — and the assertions live in tests/m3-tests.sql, not only here.
--
--   advisor_book_session         writes with advisor_id = current_advisor_id();
--                                a psychosocial booking has advisor_id null,
--                                so it cannot create or reach one.
--   advisor_mark_response_seen   updates where advisor_id = current_advisor_id().
--   member_respond_booking       updates where user_id = auth.uid().
--   award_points                 reads the caller's own bookings for points.
--   kw_booking_drives_activity   a trigger; runs on a row already being written.

do $$
declare r record;
begin
  for r in
    select p.proname, p.prosrc
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname in ('advisor_book_session','advisor_mark_response_seen',
                         'member_respond_booking','award_points')
  loop
    if r.prosrc !~* '(auth\.uid\(\)|current_advisor_id\(\))' then
      raise exception 'M3: % touches bookings and is scoped by NEITHER '
                      'auth.uid() nor current_advisor_id(). It is not safe by '
                      'construction and must join the sweep.', r.proname;
    end if;
  end loop;
  raise notice 'M3: the four self-scoped functions are scoped as claimed.';
end $$;


-- ── 5. The M4/M5 staff tables ───────────────────────────────
-- These are readable by is_staff(), which as of Part 1 is EVERY ADVISOR AND
-- EVERY COUNSELLOR. The leak runs both ways:
--
--   a financial advisor would read counselling activities off a work plan;
--   a counsellor would read every client's commercial terms.
--
-- Checked before changing anything (27 Aug): NO call site anywhere reads
-- org_contracts or contract_rates — not admin.html, not ops.html, no function,
-- no policy. `account_manager` is read by nothing and no contract row exists.
-- So is_admin()-only is right as written and cannot be a regression: there is
-- nothing today that it could regress.

drop policy if exists org_contracts_staff_read on org_contracts;
create policy org_contracts_admin_read on org_contracts
  for select using (is_admin());

drop policy if exists contract_rates_staff_read on contract_rates;
create policy contract_rates_admin_read on contract_rates
  for select using (is_admin());

drop policy if exists org_contacts_staff_read on org_contacts;
create policy org_contacts_admin_read on org_contacts
  for select using (is_admin());

-- work_plans, actions and meetings stay is_staff(): a counsellor genuinely
-- attends Tuesday, owns actions and appears on work plans. What they must not
-- see is what a client PAYS, which is the three tables above.


-- ── 6. kw_unit_label, and the anon sweep ────────────────────
-- SECURITY DEFINER and callable by `anon`, reading org_units. An
-- unauthenticated caller with a unit id gets back "Company — Site".
--
-- Not psychosocial and not urgent — but M3 is the migration already auditing
-- exactly this class of thing, and leaving it would mean knowing about it and
-- walking past.

revoke execute on function kw_unit_label(uuid) from anon;


-- ── 7. Post-conditions ──────────────────────────────────────

do $$
declare bad text;
begin
  -- EVERY definer function granted to authenticated that reads bookings must
  -- carry the predicate. This is the assertion that stops the rule decaying:
  -- a function added next year without it fails here.
  select string_agg(p.proname, ', ') into bad
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and p.prosrc ~* '\mfrom\s+bookings\M|\mjoin\s+bookings\M'
     and p.prosrc !~* '\mkw_can_see_booking\M'
     -- the self-scoped four, justified in section 4
     and p.proname not in ('advisor_book_session','advisor_mark_response_seen',
                           'member_respond_booking','award_points');
  if bad is not null then
    raise exception 'M3: these functions read bookings without the visibility '
                    'predicate: %', bad;
  end if;

  select string_agg(p.proname, ', ') into bad
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and p.prosrc ~* '\mfrom\s+program_activities\M|\mjoin\s+program_activities\M'
     and p.prosrc !~* '\mkw_can_see_activity\M'
     and p.proname not in ('kw_booking_drives_activity');
  if bad is not null then
    raise exception 'M3: these functions read program_activities without the '
                    'visibility predicate: %', bad;
  end if;

  -- The helpers themselves must not be reachable.
  if has_function_privilege('anon', 'kw_can_see_booking(bookings)', 'EXECUTE')
  or has_function_privilege('authenticated', 'kw_can_see_booking(bookings)', 'EXECUTE') then
    raise exception 'M3: kw_can_see_booking must not be callable directly';
  end if;

  if has_function_privilege('anon', 'kw_unit_label(uuid)', 'EXECUTE') then
    raise exception 'M3: kw_unit_label is still anon-callable';
  end if;

  raise notice 'M3 Part 2 applied. The boundary is now enforced in the '
               'policies AND in every definer function that reads through '
               'them. Seed the branch with psychosocial rows before believing '
               'any of it: on today''s data every booking is financial, so '
               'every result is byte-identical either way.';
end $$;
