-- ============================================================
-- Key Wellness — 2026 work-plan seed
--
-- Creates the client organisations, their contracts, their work plans and
-- every activity on those plans, as of the date this is run.
--
-- SAFE TO RUN TWICE. Every part guards on what already exists.
--
-- ══ PART 1 IS COMPLETE. PARTS 2–4 ARE NOT WRITTEN YET. ═════
--
-- Parts 2–4 need Lone's four work-plan documents (BOPEU, Hollard, LEA,
-- Morula Capital Partners). They have not been supplied, and the activities on
-- a client's work plan cannot be inferred from anything in this repository —
-- inventing them would put fabricated commitments in front of real clients.
-- Part 1 stands alone and is useful on its own: it creates the three missing
-- organisations and hands back their invite codes.
--
-- ══ TWO THINGS THAT WILL BITE YOU ══════════════════════════
--
-- (1) THIS FILE MUST RUN WITH A JWT CLAIM SET. admin_org_create() and
--     admin_org_suggest_code() are gated by is_admin(), which reads
--     auth.jwt() ->> 'email'. The Supabase SQL editor runs as postgres with NO
--     JWT, so is_admin() is false and both raise 'not authorised' — being
--     superuser does not help, because the check is on identity, not
--     privilege. Part 1 sets the claim with set_config(..., true), which is
--     TRANSACTION-LOCAL and is discarded at commit. It writes nothing and
--     grants nothing beyond the transaction.
--
--     Change the email below if you are not Lone. It must match a row in
--     `admins`.
--
-- (2) THE INVITE CODE IS RANDOM. admin_org_suggest_code() builds it as a
--     4-letter stem plus `floor(random() * 10000)`. It is therefore NOT
--     reproducible: this file cannot assert what the code will be, and a
--     second run must not generate a second one. Part 1 creates each
--     organisation only if it does not already exist, and PRINTS the codes at
--     the end. Save that output — it is what goes to each client's HR contact.
--
-- Depends on: supabase_admin_orgs_rpcs.sql (the RPCs), and M5 for
-- organizations.is_test.
-- ============================================================


-- ── Part 1 · The three missing organisations ────────────────
--
-- BOPEU already exists. Hollard, LEA and Morula Capital Partners are real
-- clients that appear in reports and prose but have never existed as rows.
--
-- Through admin_org_create(), never a raw insert: the RPC validates the name,
-- refuses a duplicate, validates or generates the invite code, and starts the
-- organisation active so members can join with the code straight away. A raw
-- insert skips all four.
--
-- Test Co needs no work here. organizations.is_test ships in M5 and
-- ops_timeline() excludes it INSIDE the function rather than in a policy, so
-- there is nothing for this seed to propose or set. The deploy note carries
-- the one-line update that flags it.

do $$
declare
  v_admin text := 'lone@keywellness.co.bw';   -- must be a row in `admins`
  v_name  text;
  v_res   jsonb;
  v_made  int := 0;
  v_had   int := 0;
begin
  -- Transaction-local. Discarded at commit; writes nothing.
  perform set_config('request.jwt.claims',
                     json_build_object('email', v_admin)::text, true);

  if not is_admin() then
    raise exception 'is_admin() is false for % — put that address in `admins`, '
                    'or change v_admin above. Nothing has been created.', v_admin;
  end if;

  foreach v_name in array array[
    'Hollard',
    'LEA',
    'Morula Capital Partners'
  ]
  loop
    if exists (select 1 from organizations where lower(name) = lower(v_name)) then
      v_had := v_had + 1;
      raise notice 'already there : %', v_name;
      continue;
    end if;

    -- Blank invite code = the RPC generates one.
    v_res  := admin_org_create(v_name, null, null, null);
    v_made := v_made + 1;
    raise notice 'created       : %  ->  %', v_name, v_res;
  end loop;

  raise notice '--';
  raise notice 'Part 1: % created, % already present.', v_made, v_had;
end $$;


-- The codes to hand out. Run this after the block above and SAVE THE OUTPUT:
-- the code is randomly generated and this is the only place it is written down.

select o.name,
       o.invite_code,
       case when o.is_active then 'active' else 'INACTIVE' end as status,
       to_char(o.created_at, 'DD Mon YYYY')                    as created
  from organizations o
 where o.name in ('BOPEU', 'Hollard', 'LEA', 'Morula Capital Partners')
 order by o.name;


-- ── Part 2 · Contracts ──────────────────────────────────────
-- NOT WRITTEN. Needs the documents: contract_kind (retainer or
-- per_engagement) per client, the period, and — for per-engagement clients —
-- the rate card rows. Amounts will be placeholders (0, with a comment) for
-- Lone to fill.


-- ── Part 3 · Work plans ─────────────────────────────────────
-- NOT WRITTEN. Needs the documents: each plan's own period, which is not
-- necessarily the calendar year and is not necessarily the same across the
-- four clients.


-- ── Part 4 · Activities ─────────────────────────────────────
-- NOT WRITTEN. Needs the documents: per activity, its service line, format,
-- planned month or planned date, and its state as of today.
