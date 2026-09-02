-- ============================================================
-- Key Wellness — M4b: the shapes real data needs
--
-- Run AFTER M4a. Idempotent — safe to re-run.
-- Rollback: migrations/rollback-m4b-real-contract-shape.sql
-- Tests:    tests/m4b-tests.sql
--
-- ══ WHY THIS EXISTS ════════════════════════════════════════
--
-- Recording BOPEU's actual contract and programme — the first real data the
-- M4 schema has ever held — hit three walls in the first ten minutes. All
-- three are the same kind of mistake: a schema built from a specification
-- rather than from a document somebody actually has.
--
-- (a) THE SCHEMA CANNOT SAY "APPROXIMATELY".
--
--     BOPEU's retainer is confirmed at *approximately* P18,000/month. That is
--     the honest state of the fact, and org_contracts has nowhere to put it:
--     retainer_amount is numeric(12,2), and the constraint
--     org_contracts_amount_agrees_with_kind REQUIRES it to be non-null for a
--     retainer. So the only way to record the contract at all was to write
--     18000.00 — a number that reads as exact, that a monthly handover would
--     bill from, and that nobody would ever know to question.
--
--     A schema that can only store precise numbers does not thereby make the
--     world precise. It makes the imprecision invisible, which is worse than
--     refusing the row.
--
--     So: amount_is_approximate, and amount_note for the words. The handover
--     job and every screen must carry the flag through — a number marked
--     approximate that is displayed bare is the same defect one layer up.
--
-- (b) `campaign` IS NOT A FORMAT. It needed to be.
--
--     Two of BOPEU's nineteen rows are self-directed challenges — a walking
--     challenge and a movement challenge. Nobody delivers them at a time and a
--     place. They are not a talk, not a group session, not a wellness day, and
--     calling them 'other' loses the only thing that makes them different.
--
-- (c) `vendor` IS NOT A PRACTITIONER KIND. It needed to be.
--
--     Health screening is delivered by an external provider. practitioner_kind
--     admitted only 'advisor' and 'counsellor', both of which are Key Wellness
--     staff. Recording a vendor-delivered session as advisor-delivered would
--     inflate every capacity and utilisation figure that counts practitioner
--     time — quietly, and in the direction that flatters us.
--
-- ══ WHAT WILL CHANGE, AND WHAT WILL NOT ════════════════════
--
--   CHANGES
--     org_contracts gains two columns: amount_is_approximate (default false)
--     and amount_note.
--     program_activities.format admits 'campaign'.
--     program_activities.practitioner_kind admits 'vendor'.
--
--   DOES NOT CHANGE
--     No existing row. Every contract, activity and booking is untouched, and
--     the defaults are chosen so that existing rows keep exactly the meaning
--     they have now: amount_is_approximate false says "this number is exact",
--     which is what every current row implicitly claims.
--     No policy, no grant, no function.
--
--   NOT ADDED ON PURPOSE: `group_session`.
--     The spec for BOPEU's programme names a `group_session` format. The
--     schema already has `group`. Adding both would give two values for one
--     idea, and within a month half the rows would use each. The programme's
--     group sessions are recorded as `group`.
--
--   IF IT IS WRONG
--     The realistic failure is a widened check constraint that admits a value
--     nothing reads yet. Nothing can break: both are additive, and no existing
--     value is removed.
-- ============================================================


-- ── 1. "Approximately" is a fact about the number ───────────

alter table org_contracts add column if not exists amount_is_approximate boolean not null default false;
alter table org_contracts add column if not exists amount_note text;

comment on column org_contracts.amount_is_approximate is
  'TRUE when retainer_amount is a working figure rather than a signed one. '
  'Any screen or document showing the amount MUST show this too — a number '
  'marked approximate and then displayed bare is the same defect one layer up. '
  'The monthly handover carries it into the pack.';

comment on column org_contracts.amount_note is
  'The words behind the number: who gave it, how firm it is, what would make '
  'it exact. Free text on purpose — this is the part a person reads before '
  'sending a client an invoice.';

do $$
begin
  -- An approximate amount with no explanation is barely better than a precise
  -- lie: the next reader learns the number is soft and nothing about why.
  if not exists (select 1 from pg_constraint
                  where conname = 'org_contracts_approx_is_explained') then
    alter table org_contracts add constraint org_contracts_approx_is_explained
      check (not amount_is_approximate or length(btrim(coalesce(amount_note,''))) > 0);
  end if;
end $$;


-- ── 2. campaign ─────────────────────────────────────────────

do $$
begin
  alter table program_activities drop constraint if exists program_activities_format_check;
  alter table program_activities add constraint program_activities_format_check
    check (format is null or format in
      ('talk','one_on_one','couple','group','webinar','wellness_day','flyer',
       'campaign',   -- self-directed, no delivery moment. NEW in M4b.
       'other'));
end $$;


-- ── 3. vendor ───────────────────────────────────────────────

do $$
begin
  alter table program_activities drop constraint if exists program_activities_practitioner_kind_check;
  alter table program_activities add constraint program_activities_practitioner_kind_check
    check (practitioner_kind is null or practitioner_kind in
      ('advisor','counsellor',
       'vendor'));  -- delivered by an external provider. NEW in M4b.
end $$;

comment on column program_activities.practitioner_kind is
  'Who delivered it. ''vendor'' means an external provider, NOT Key Wellness '
  'staff — recording vendor work as advisor work inflates every capacity and '
  'utilisation figure that counts practitioner time, in the direction that '
  'flatters us.';


-- ── 4. Post-conditions ──────────────────────────────────────

do $$
declare n int;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='org_contracts'
                    and column_name='amount_is_approximate') then
    raise exception 'M4b: amount_is_approximate is missing';
  end if;

  -- Existing rows must keep the meaning they had. A contract that was exact
  -- before this migration is still exact after it.
  select count(*) into n from org_contracts where amount_is_approximate;
  if n <> 0 then
    raise exception 'M4b: % existing contract(s) were marked approximate by '
                    'this migration. It must change no existing row.', n;
  end if;

  if (select pg_get_constraintdef(oid) from pg_constraint
       where conname='program_activities_format_check') !~ 'campaign' then
    raise exception 'M4b: format still refuses campaign';
  end if;

  if (select pg_get_constraintdef(oid) from pg_constraint
       where conname='program_activities_practitioner_kind_check') !~ 'vendor' then
    raise exception 'M4b: practitioner_kind still refuses vendor';
  end if;

  -- Widening must not have dropped anything. A `drop constraint` followed by
  -- `add constraint` is how a value silently disappears.
  if (select pg_get_constraintdef(oid) from pg_constraint
       where conname='program_activities_format_check')
     !~ 'talk.*one_on_one.*couple.*group.*webinar.*wellness_day.*flyer' then
    raise exception 'M4b: widening the format check dropped an existing value';
  end if;

  if (select pg_get_constraintdef(oid) from pg_constraint
       where conname='program_activities_practitioner_kind_check')
     !~ 'advisor.*counsellor' then
    raise exception 'M4b: widening practitioner_kind dropped an existing value';
  end if;

  raise notice 'M4b applied. A retainer can now be recorded as approximate, and '
               'must say why. campaign and vendor are admitted.';
end $$;
