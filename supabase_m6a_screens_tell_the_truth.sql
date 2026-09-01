-- ============================================================
-- Key Wellness — M6a: two screens that state things they do not know
--
-- Run AFTER M6. Idempotent. Rollback: migrations/rollback-m6a-screens.sql
--
-- ══ BOTH FOUND BY OPENING THE SCREENS AGAINST REAL DATA ═════
--
-- (1) ops_timeline() REPORTS EVERY ACTIVITY AS "delivered".
--
--     M5a hard-codes the literal 'delivered' for the activity branch. That was
--     true when it was written — every program_activities row was historical.
--     BOPEU's programme is the first with FUTURE work in it, and the Tuesday
--     review now shows all nineteen rows as delivered, including the ten that
--     are planned and the health screening nobody has confirmed happened.
--
--     Lone would open her Tuesday review and read a year of work as done.
--
-- (2) contract_position() RETURNS THE RETAINER AS A BARE NUMBER.
--
--     M4b added amount_is_approximate precisely so that "approximately
--     P18,000" could be said out loud. The RPC feeding the screen drops the
--     flag and returns 18000.00, so the screen shows an exact-looking figure —
--     the same defect one layer up, which is what M4b's own comment warned
--     about.
--
-- ══ WHAT WILL CHANGE, AND WHAT WILL NOT ════════════════════
--
--   CHANGES
--     ops_timeline's activity rows carry their REAL state.
--     contract_position carries amount_is_approximate and amount_note.
--
--   DOES NOT CHANGE
--     No row, no policy, no grant. Booking rows in ops_timeline are untouched —
--     their state was already derived, not hard-coded. Every activity that IS
--     delivered still reads delivered.
--
--   IF IT IS WRONG
--     A Tuesday review showing the wrong word against a session. Visible
--     immediately to the person who ran it.
-- ============================================================


-- ── 1. ops_timeline tells the truth about state ─────────────
-- Rewritten from its own definition so ONLY the hard-coded literal changes.
-- The mapping keeps the vocabulary the screen already uses: pending,
-- scheduled, attended, delivered, cancelled.

do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'ops_timeline';

  if v_def is null then raise exception 'M6a: ops_timeline is missing'; end if;

  -- Already done. A second apply must be a no-op, not a failure: this file is
  -- applied, reviewed and applied again while iterating.
  if v_def ~ 'case a\.state' then
    raise notice 'M6a: ops_timeline already reports real states.';
    return;
  end if;

  -- WHITESPACE-TOLERANT ON PURPOSE. A function created from a CRLF file keeps
  -- carriage returns inside prosrc, so a literal replace() written with plain
  -- newlines misses it and the migration reports "could not find" against a
  -- function that plainly contains the text. Match the shape, not the bytes.
  v_new := regexp_replace(v_def,
    '(a\.activity_type,\s*)''delivered'',(\s*a\.attendee_count)',
    '\1case a.state when ''planned'' then ''pending'' when ''scheduled'' then ''scheduled'' when ''reported'' then ''delivered'' when ''cancelled'' then ''cancelled'' else ''delivered'' end,\2');

  if v_new = v_def then
    raise exception 'M6a: could not find the hard-coded state in ops_timeline. '
                    'Rewrite it BY HAND rather than leaving the Tuesday review '
                    'calling planned work delivered.';
  end if;

  execute v_new;
  raise notice 'M6a: ops_timeline reports each activity''s real state.';
end $$;


-- ── 2. contract_position carries the qualifier ──────────────
-- A number marked approximate and then handed to a screen bare is the same
-- defect one layer up.

do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'contract_position';

  if v_def is null then raise exception 'M6a: contract_position is missing'; end if;

  -- Already done. Without this the qualifier is appended AGAIN on every run,
  -- duplicating the key in the payload.
  if v_def ~ 'amount_is_approximate' then
    raise notice 'M6a: contract_position already carries the qualifier.';
    return;
  end if;

  v_new := regexp_replace(v_def,
    '(''retainer_amount'',\s*c\.retainer_amount,)',
    '\1 ''amount_is_approximate'', c.amount_is_approximate, ''amount_note'', c.amount_note,');

  if v_new = v_def then
    raise exception 'M6a: could not find retainer_amount in contract_position. '
                    'Add the qualifier BY HAND — the screen must not show a '
                    'working figure as an exact one.';
  end if;

  execute v_new;
  raise notice 'M6a: contract_position carries amount_is_approximate.';
end $$;


-- ── 3. Post-conditions ──────────────────────────────────────

do $$
begin
  if (select prosrc from pg_proc where proname = 'ops_timeline') !~ 'a\.state' then
    raise exception 'M6a: ops_timeline still does not read the activity state';
  end if;

  -- And the literal must be gone, not merely joined by a case expression.
  if (select prosrc from pg_proc where proname = 'ops_timeline')
     ~ 'a\.activity_type,\s*''delivered''' then
    raise exception 'M6a: ops_timeline still hard-codes delivered';
  end if;

  if (select prosrc from pg_proc where proname = 'contract_position')
     !~ 'amount_is_approximate' then
    raise exception 'M6a: contract_position still drops the approximate flag';
  end if;

  raise notice 'M6a applied. The Tuesday review reports real states, and the '
               'retainer figure travels with the fact that it is approximate.';
end $$;
