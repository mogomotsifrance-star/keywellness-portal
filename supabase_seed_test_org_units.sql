-- supabase_seed_test_org_units.sql
-- Give Test Co one unit and two departments, so the P0 first-session walk can
-- prove the department question is gone.
--
-- WHY THIS EXISTS. Audit task 7 walks a fresh account under TEST-1234, but Test
-- Co has zero org_units, so the company and department steps never fired for it
-- even before P0-1 deleted them. The removal Debswana specifically objected to
-- is therefore unverifiable under Test Co as it stands. The alternative — walk a
-- real client org — is worse: a test account would land in that client's member
-- list and their aggregates.
--
-- WHAT CHANGES
--   · one org_unit, "Test Co Head Office", top-level, under Test Co
--   · two unit_departments under it, "Finance" and "Operations"
--
-- WHAT DOES NOT
--   · Test Co's 22 existing members. They have org_unit_id null today and still
--     will. This adds a TOP-LEVEL unit, not a site under an existing company, so
--     the "stranding" rule (admin_unit_create rule 2 — giving a company its
--     first site leaves members recorded against the parent unplaceable) does
--     not apply. Nothing is reassigned and nothing is orphaned.
--   · every other organisation.
--
-- WHAT BREAKS IF IT IS WRONG. Test Co starts requiring a unit choice at signup
-- where it did not before. That is the point of the exercise, but it means the
-- walk now exercises kwRenderUnitPicker(). If the picker misbehaves, the walk
-- catches it — which is better than Debswana catching it.
--
-- HOW TO UNDO. Deactivate rather than delete, so nothing referencing the ids
-- dangles:
--   select admin_dept_set_active(id, false) from unit_departments
--    where unit_id = (select id from org_units where name = 'Test Co Head Office');
--   select admin_unit_set_active(
--     (select id from org_units where name = 'Test Co Head Office'), false);
-- (admin_unit_delete exists but refuses while dependents remain, which is the
-- behaviour you want here.)
--
-- SHAPE NOTE. "Test Co Head Office" is a top-level unit with no children, which
-- makes it a LEAF — members can be placed on it directly and it carries
-- departments. That is not a workaround: Sedimosa's MCM, DBGSS, DTCB, DPF,
-- Mmila and Sesiro are all live examples of the same shape. Only Debswana has
-- sites beneath it. Do not later add a site under Test Co Head Office without
-- reading admin_unit_create's rules 2 and 3 — it would strand any member placed
-- here and switch off its department reporting.
--
-- ROUTED THROUGH THE RPCs ON PURPOSE. CLAUDE.md: do not write to org_units or
-- unit_departments directly. Their admin-all RLS policies predate these RPCs and
-- bypass every guard the RPCs carry (two-level limit, name collision, stranding
-- count, department-reporting warning). The RPCs are is_admin()-gated on
-- IDENTITY, and superuser in the SQL editor does not satisfy that — so this file
-- sets request.jwt.claims the way live does. See CLAUDE_CONTEXT.md §"The
-- fixture's auth.jwt() is not Supabase's".
--
-- PREREQUISITE: supabase_fix_admin_unit_create_toplevel.sql
-- admin_unit_create() could not create a top-level company at all — it died on
-- 'record "v_parent" is not assigned yet' — so this seed cannot run without that
-- fix. Both were applied to live on 10 Sep 2026, fix first.
--
-- Idempotent: re-running reports what already exists and changes nothing.
-- Applied to live 10 Sep 2026; re-run confirmed it adds nothing a second time.

do $$
declare
  v_admin   text := 'tnmokgwetsi@gmail.com';   -- must be a row in admins
  v_org     uuid;
  v_unit    uuid;
  v_res     jsonb;
  v_missing text[];
begin
  -- Authenticate as an admin identity, exactly as a browser call would.
  perform set_config('request.jwt.claims',
                     json_build_object('email', v_admin)::text, true);

  if not exists (select 1 from admins where lower(email) = lower(v_admin)) then
    raise exception 'seed aborted: % is not in admins, so every admin_* RPC below would raise "not authorised"', v_admin;
  end if;

  select id into v_org from organizations where invite_code = 'TEST-1234';
  if v_org is null then
    raise exception 'seed aborted: no organisation with invite code TEST-1234';
  end if;

  -- ── The unit ────────────────────────────────────────────────────────────
  select id into v_unit
    from org_units
   where org_id = v_org and lower(name) = lower('Test Co Head Office');

  if v_unit is null then
    v_res := admin_unit_create(v_org, 'Test Co Head Office', null);
    v_unit := (v_res ->> 'id')::uuid;
    raise notice 'created unit: %', v_res ->> 'msg';
  else
    raise notice 'unit "Test Co Head Office" already exists (%), leaving it alone', v_unit;
  end if;

  -- ── The departments ─────────────────────────────────────────────────────
  -- admin_dept_add takes a name array and skips duplicates itself, but ask for
  -- only what is missing so a re-run says nothing rather than reporting skips.
  select array_agg(n) into v_missing
    from unnest(array['Finance','Operations']) as n
   where not exists (
     select 1 from unit_departments d
      where d.unit_id = v_unit and lower(d.name) = lower(n));

  if v_missing is null or cardinality(v_missing) = 0 then
    raise notice 'departments Finance and Operations already present, leaving them alone';
  else
    v_res := admin_dept_add(v_unit, v_missing);
    raise notice 'added departments: %', v_res ->> 'msg';
  end if;
end $$;

-- ── Verification. Expect exactly one unit and two active departments. ──────
select 'unit'  as row_kind, u.name, coalesce(p.name, '(top level — a leaf)') as parent,
       u.is_active::text as active
  from org_units u
  join organizations o on o.id = u.org_id
  left join org_units p on p.id = u.parent_unit_id
 where o.invite_code = 'TEST-1234'
union all
select 'dept', d.name, u.name, d.is_active::text
  from unit_departments d
  join org_units u on u.id = d.unit_id
  join organizations o on o.id = u.org_id
 where o.invite_code = 'TEST-1234'
union all
-- Existing members must be untouched: still 0 placed on any unit.
select 'members_on_a_unit', count(*)::text, '(expect 0 — nothing was reassigned)', ''
  from profiles p2
  join org_units u2 on u2.id = p2.org_unit_id
  join organizations o2 on o2.id = u2.org_id
 where o2.invite_code = 'TEST-1234'
 order by 1, 2;
