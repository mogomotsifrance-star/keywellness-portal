-- ============================================================
-- Rollback — M4b: the shapes real data needs
--
-- Idempotent. Leaves ZERO objects behind.
--
-- ══ THIS CAN DESTROY A QUALIFIER, NOT JUST A COLUMN ════════
--
-- Dropping amount_is_approximate does not make the numbers exact. It makes
-- them LOOK exact, which is the state M4b existed to end: a working figure
-- displayed bare, billed from, and never questioned.
--
-- The block below refuses to run while any contract is marked approximate.
-- Clear the flags deliberately if you mean it, having first written the
-- qualifier down somewhere a person will read:
--
--   select o.name, c.retainer_amount, c.amount_note
--     from org_contracts c join organizations o on o.id = c.org_id
--    where c.amount_is_approximate;
--
-- Narrowing the two check constraints will also FAIL, loudly and correctly, if
-- any row uses campaign or vendor. That is not a bug in this file: a rollback
-- that silently deleted those rows would be worse than one that stops.
-- ============================================================


-- ── 0. Refuse to silently make a soft number look firm ──────

do $$
declare n int;
begin
  if to_regclass('public.org_contracts') is null then
    raise notice 'M4b rollback: org_contracts is absent. Nothing to do.';
    return;
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='org_contracts'
                    and column_name='amount_is_approximate') then
    raise notice 'M4b rollback: amount_is_approximate is already gone.';
    return;
  end if;

  execute 'select count(*) from org_contracts where amount_is_approximate' into n;
  if n > 0 then
    raise exception 'M4b rollback: % contract(s) are marked APPROXIMATE. '
                    'Dropping the flag does not make them exact — it makes them '
                    'look exact. Record the qualifier elsewhere, clear the flags '
                    'deliberately, then re-run.', n;
  end if;
end $$;


-- ── 1. The columns ──────────────────────────────────────────

do $$
begin
  if to_regclass('public.org_contracts') is not null then
    execute 'alter table org_contracts drop constraint if exists org_contracts_approx_is_explained';
    execute 'alter table org_contracts drop column if exists amount_note';
    execute 'alter table org_contracts drop column if exists amount_is_approximate';
  end if;
end $$;


-- ── 2. Narrow the two checks back ───────────────────────────
-- These FAIL if a row uses the value being removed. Deliberately: the
-- alternative is deleting somebody's record of a real session.

do $$
declare n int;
begin
  if to_regclass('public.program_activities') is null then return; end if;

  select count(*) into n from program_activities where format = 'campaign';
  if n > 0 then
    raise exception 'M4b rollback: % activity/activities use format=campaign. '
                    'Re-classify them before narrowing the constraint.', n;
  end if;

  select count(*) into n from program_activities where practitioner_kind = 'vendor';
  if n > 0 then
    raise exception 'M4b rollback: % activity/activities are vendor-delivered. '
                    'Re-classifying them as advisor work would inflate every '
                    'capacity figure that counts practitioner time.', n;
  end if;

  alter table program_activities drop constraint if exists program_activities_format_check;
  alter table program_activities add constraint program_activities_format_check
    check (format is null or format in
      ('talk','one_on_one','couple','group','webinar','wellness_day','flyer','other'));

  alter table program_activities drop constraint if exists program_activities_practitioner_kind_check;
  alter table program_activities add constraint program_activities_practitioner_kind_check
    check (practitioner_kind is null or practitioner_kind in ('advisor','counsellor'));
end $$;


-- ── 3. Clean-slate verification ─────────────────────────────

do $$
begin
  if to_regclass('public.org_contracts') is not null
     and exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='org_contracts'
                    and column_name in ('amount_is_approximate','amount_note')) then
    raise exception 'M4b rollback incomplete: an amount column survives';
  end if;

  if to_regclass('public.program_activities') is not null
     and (select pg_get_constraintdef(oid) from pg_constraint
           where conname='program_activities_format_check') ~ 'campaign' then
    raise exception 'M4b rollback incomplete: format still admits campaign';
  end if;

  raise notice 'M4b rollback clean.';
end $$;
