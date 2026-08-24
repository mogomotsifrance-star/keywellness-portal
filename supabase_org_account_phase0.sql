-- ============================================================
-- Key Wellness — Organisation Account View, PHASE 0
-- Run in the Supabase SQL Editor. Safe to re-run.
--
-- Prerequisites: supabase_advisor_portal.sql, supabase_advisor_rpcs.sql,
-- supabase_advisor_team_lead.sql, supabase_org_units.sql.
--
-- Rollback: migrations/rollback-org-account-phase0.sql
--
-- Spec: claude/org-account-view-spec.md (rev 3)
-- ============================================================
--
-- WHAT THIS DOES
--
--   1. Makes every advisor client attributable to an organisation, and
--      to a company/site within it. Nothing in the account view can be
--      aggregated per organisation until this holds.
--   2. Establishes ONE definition of "over-indebted" — DTI above 45% —
--      readable from the database by every surface, so the advisor
--      portal and the HR dashboard stop disagreeing about the same
--      person.
--
-- It deliberately does NOT build any panel. This is the floor the rest
-- of the work stands on.
--
-- ------------------------------------------------------------
-- DESIGN NOTES
--
-- * org_id becomes required-or-declared, not required. An advisor must
--   be able to work with someone who is not under a company programme,
--   so `no_org` is an explicit choice rather than a NULL that could
--   equally mean "forgot". The check constraint enforces exactly that:
--   you may leave org_id empty, but only by saying so.
--
-- * A mismatch between what the advisor entered and what the member's
--   profile says is FLAGGED, never silently overwritten. Either party
--   may be the one who is wrong, and a human has to look. Overwriting
--   would destroy the evidence needed to tell which.
--
-- * Organisation inheritance hangs off `profiles`, not off auth.users.
--   link_advisor_clients_on_signup() fires on signup, when the profile
--   row may not exist yet and certainly has no org_id — a member gets
--   their org when they enter an invite code, which is later. A trigger
--   on profiles catches both moments, and every subsequent org change.
--
-- * org_unit_id follows the two-level company → site rule that
--   org_units is built on: a client may be attached to a site, never to
--   a company that has sites. The validation only fires when the unit
--   actually changes, so a company that later gains sites cannot
--   retroactively block edits to unrelated fields on old rows.
--
-- * The DTI bands land in threshold_config as data, with kw_dti_band()
--   as the single function that reads them. org_financial_indicators()
--   is left alone: its hard-coded bands are already 20/35/45, so
--   rewriting a large working function here would be risk without
--   benefit. Section 9 verifies the two agree. The advisor portal's
--   diagDebt() is the one that must change, and that is an advisor.html
--   change shipping in the same release — see the deployment note.
-- ------------------------------------------------------------


-- ── 1. Attribution columns ───────────────────────────────────

alter table advisor_clients
  add column if not exists org_unit_id  uuid references org_units(id),
  add column if not exists no_org       boolean not null default false,
  add column if not exists org_mismatch boolean not null default false;

create index if not exists advisor_clients_org_idx
  on advisor_clients (org_id) where org_id is not null;

create index if not exists advisor_clients_org_unit_idx
  on advisor_clients (org_unit_id) where org_unit_id is not null;

create index if not exists advisor_clients_needs_attention_idx
  on advisor_clients (org_mismatch) where org_mismatch;

comment on column advisor_clients.org_unit_id is
  'Company/site within the organisation. Must be a leaf unit, matching the member picker rule.';
comment on column advisor_clients.no_org is
  'Explicitly a private client, not under a company programme. The only legitimate reason org_id is empty.';
comment on column advisor_clients.org_mismatch is
  'The advisor-entered organisation differs from the linked member profile. Needs a human, not an overwrite.';


-- ── 2. Backfill ──────────────────────────────────────────────
-- Inherit from the linked member's profile wherever we can.

update advisor_clients ac
   set org_id      = p.org_id,
       org_unit_id = coalesce(ac.org_unit_id, p.org_unit_id),
       updated_at  = now()
  from profiles p
 where p.id = ac.member_user_id
   and ac.org_id is null
   and p.org_id is not null;

-- Flag, do not fix, anything that disagrees.
update advisor_clients ac
   set org_mismatch = true,
       updated_at   = now()
  from profiles p
 where p.id = ac.member_user_id
   and ac.org_id is not null
   and p.org_id is not null
   and ac.org_id <> p.org_id
   and ac.org_mismatch is distinct from true;

-- Whatever is still unattributed becomes an explicit private client.
-- Admin → Advisors → Attribution surfaces these for review; see §7.
update advisor_clients
   set no_org     = true,
       updated_at = now()
 where org_id is null
   and no_org is not true;


-- ── 3. The constraint ────────────────────────────────────────

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'advisor_clients_org_required'
  ) then
    alter table advisor_clients
      add constraint advisor_clients_org_required
      check (org_id is not null or no_org) not valid;
  end if;
end $$;

alter table advisor_clients validate constraint advisor_clients_org_required;

-- A unit only means something alongside an organisation.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'advisor_clients_unit_needs_org'
  ) then
    alter table advisor_clients
      add constraint advisor_clients_unit_needs_org
      check (org_unit_id is null or org_id is not null) not valid;
  end if;
end $$;

alter table advisor_clients validate constraint advisor_clients_unit_needs_org;


-- ── 4. The unit must be a real, open site of that organisation ──

create or replace function kw_validate_client_unit()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_org      uuid;
  v_active   boolean;
  v_children int;
begin
  -- Only police the unit when it is actually being set or changed. A
  -- company that later gains sites must not block unrelated edits to
  -- rows that were valid when they were written.
  if tg_op = 'UPDATE' and new.org_unit_id is not distinct from old.org_unit_id then
    return new;
  end if;

  if new.org_unit_id is null then
    return new;
  end if;

  select org_id, is_active into v_org, v_active
    from org_units where id = new.org_unit_id;

  if v_org is null then
    raise exception 'org_unit % does not exist', new.org_unit_id;
  end if;

  -- Two distinct mistakes, two distinct messages. "No organisation" and
  -- "the wrong organisation's site" are corrected differently.
  if new.org_id is null then
    raise exception 'org_unit % cannot be set without an organisation', new.org_unit_id;
  end if;

  if v_org <> new.org_id then
    raise exception 'org_unit % does not belong to organisation %',
      new.org_unit_id, new.org_id;
  end if;

  if not v_active then
    raise exception 'org_unit % is closed — pick an open site', new.org_unit_id;
  end if;

  select count(*) into v_children
    from org_units where parent_unit_id = new.org_unit_id and is_active;

  if v_children > 0 then
    raise exception
      'org_unit % is a company with sites — attach the client to a site, not the company',
      new.org_unit_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_client_unit on advisor_clients;
create trigger trg_validate_client_unit
  before insert or update of org_unit_id, org_id on advisor_clients
  for each row execute function kw_validate_client_unit();


-- ── 5. Keeping attribution in step ───────────────────────────

-- 5a. On insert: inherit from the member if we know them, flag if we disagree.
create or replace function link_advisor_client_on_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_uid  uuid;
  v_org  uuid;
  v_unit uuid;
begin
  if new.member_user_id is null and new.email is not null then
    select id into v_uid from auth.users
     where lower(email) = lower(new.email)
     limit 1;
    if v_uid is not null then
      new.member_user_id := v_uid;
      new.linked_at      := now();
    end if;
  end if;

  if new.member_user_id is not null then
    select org_id, org_unit_id into v_org, v_unit
      from profiles where id = new.member_user_id;

    if new.org_id is null and v_org is not null then
      new.org_id := v_org;
      if new.org_unit_id is null then
        new.org_unit_id := v_unit;
      end if;
    elsif new.org_id is not null and v_org is not null and new.org_id <> v_org then
      new.org_mismatch := true;
    end if;
  end if;

  if new.org_id is not null then
    new.no_org := false;
  end if;

  return new;
end;
$$;

-- 5b. On the member gaining or changing an organisation.
--     Fires when a profile row is created, and whenever org_id or
--     org_unit_id changes — which is when an invite code is entered,
--     and again if an admin moves someone between companies.
create or replace function kw_sync_advisor_client_org()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.org_id is null then
    return new;
  end if;

  update advisor_clients ac
     set org_id       = case when ac.org_id is null then new.org_id      else ac.org_id      end,
         org_unit_id  = case when ac.org_id is null then new.org_unit_id else ac.org_unit_id end,
         no_org       = case when ac.org_id is null then false           else ac.no_org      end,
         org_mismatch = (ac.org_id is not null and ac.org_id <> new.org_id),
         updated_at   = now()
   where ac.member_user_id = new.id;

  return new;
end;
$$;

drop trigger if exists trg_sync_advisor_client_org on profiles;
create trigger trg_sync_advisor_client_org
  after insert or update of org_id, org_unit_id on profiles
  for each row execute function kw_sync_advisor_client_org();


-- ── 6. One definition per indicator ──────────────────────────
-- threshold_config already exists (supabase_reward_thresholds.sql) and
-- is world-readable under RLS, which is what lets advisor.html read the
-- same numbers the RPCs use.

insert into threshold_config (key, value, updated_at) values

  ('indicator.dti', jsonb_build_object(
     'label',        'Debt-to-income',
     'unit',         'percent',
     'expression',   'monthly debt service ÷ gross monthly income × 100',
     'flag_band',    'over_indebted',
     'flag_label',   'Over-indebted',
     -- 'max' is an EXCLUSIVE upper bound: a band matches when dti < max.
     -- Exactly 45.0 therefore flags as over-indebted, which is what
     -- org_financial_indicators() has always done. The labels are written
     -- to say so rather than the looser ">45%", which reads as excluding
     -- 45 and would contradict every figure already published.
     'bands', jsonb_build_array(
       jsonb_build_object('key','healthy',      'label','Healthy (under 20%)',   'max', 20),
       jsonb_build_object('key','manageable',   'label','Manageable (20–34.9%)', 'max', 35),
       jsonb_build_object('key','strained',     'label','Strained (35–44.9%)',   'max', 45),
       jsonb_build_object('key','over_indebted','label','Over-indebted (45%+)',  'max', null)
     )
   ), now()),

  -- The six headline indicators of Panel 3 share one dimension floor.
  ('indicator.dimension_flag_below', to_jsonb(40), now()),

  -- Anything at or above this rate is high-cost credit.
  ('indicator.high_cost_credit_rate', to_jsonb(20), now()),

  -- Below this base a figure is marked low-base internally and
  -- suppressed entirely in client-safe output.
  ('indicator.low_base', to_jsonb(5), now()),

  -- Emergency cover, in months of essential expenses.
  ('indicator.emergency_months_floor', to_jsonb(1), now()),

  -- Savings rate below this counts as not building wealth.
  ('indicator.savings_rate_floor_pct', to_jsonb(10), now()),

  -- The face of Panel 3, in fixed display order. Positions are stable
  -- on purpose: a panel that reorders itself by prevalence destroys
  -- period-on-period comparison.
  ('panel3.headline', jsonb_build_object(
     'row_1_label', 'Pressure now',
     'row_1', jsonb_build_array('over_indebted','no_emergency_buffer','living_beyond_means'),
     'row_2_label', 'Future exposure',
     'row_2', jsonb_build_array('retirement_shortfall','cover_gap','not_building_wealth'),
     'callout', 'informal_and_high_cost_credit'
   ), now())

on conflict (key) do update
  set value = excluded.value, updated_at = now();


create or replace function kw_threshold(p_key text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select value from threshold_config where key = p_key;
$$;

comment on function kw_threshold(text) is
  'Single read point for indicator definitions. Do not hard-code a threshold anywhere that could call this.';


create or replace function kw_dti_band(p_dti numeric)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_bands jsonb;
  v_band  jsonb;
begin
  if p_dti is null then
    return null;
  end if;

  v_bands := coalesce(kw_threshold('indicator.dti') -> 'bands', '[]'::jsonb);

  for v_band in select * from jsonb_array_elements(v_bands) loop
    if v_band ->> 'max' is null or p_dti < (v_band ->> 'max')::numeric then
      return v_band ->> 'key';
    end if;
  end loop;

  return null;
end;
$$;

comment on function kw_dti_band(numeric) is
  'Canonical DTI banding. "over_indebted" (>45%) is what "flagged for debt" means.';


create or replace function kw_is_over_indebted(p_dti numeric)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select kw_dti_band(p_dti)
       = coalesce(kw_threshold('indicator.dti') ->> 'flag_band', 'over_indebted');
$$;


grant execute on function kw_threshold(text)        to authenticated;
grant execute on function kw_dti_band(numeric)      to authenticated;
grant execute on function kw_is_over_indebted(numeric) to authenticated;


-- ── 7. Keeping attribution fixed ─────────────────────────────
-- A queue, so this does not quietly rot back to where it started.

create or replace function admin_attribution_queue()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_out jsonb;
begin
  if not is_admin() then
    raise exception 'not authorised';
  end if;

  select jsonb_build_object(
    'no_org_count',   (select count(*) from advisor_clients where no_org and status = 'active'),
    'mismatch_count', (select count(*) from advisor_clients where org_mismatch and status = 'active'),
    'no_org', coalesce((
      select jsonb_agg(jsonb_build_object(
        'client_id',    ac.id,
        'name',         trim(coalesce(ac.first_name,'') || ' ' || coalesce(ac.last_name,'')),
        'email',        ac.email,
        'advisor_name', adv.full_name,
        'is_member',    ac.member_user_id is not null,
        'created_at',   ac.created_at
      ) order by ac.created_at desc)
      from advisor_clients ac
      join advisors adv on adv.id = ac.advisor_id
      where ac.no_org and ac.status = 'active'
    ), '[]'::jsonb),
    'mismatched', coalesce((
      select jsonb_agg(jsonb_build_object(
        'client_id',      ac.id,
        'name',           trim(coalesce(ac.first_name,'') || ' ' || coalesce(ac.last_name,'')),
        'advisor_name',   adv.full_name,
        'advisor_org',    o1.name,
        'profile_org',    o2.name,
        'updated_at',     ac.updated_at
      ) order by ac.updated_at desc)
      from advisor_clients ac
      join advisors adv        on adv.id = ac.advisor_id
      left join organizations o1 on o1.id = ac.org_id
      left join profiles      p  on p.id  = ac.member_user_id
      left join organizations o2 on o2.id = p.org_id
      where ac.org_mismatch and ac.status = 'active'
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

grant execute on function admin_attribution_queue() to authenticated;


-- ── 8. Surface the new fields to the advisor portal ──────────

create or replace function kw_unit_label(p_unit_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
           when u.parent_unit_id is null then u.name
           else coalesce(par.name, '') || ' — ' || u.name
         end
    from org_units u
    left join org_units par on par.id = u.parent_unit_id
   where u.id = p_unit_id;
$$;

grant execute on function kw_unit_label(uuid) to authenticated;


-- Unchanged from supabase_advisor_team_lead.sql except for the four
-- attribution fields added to the projection.
create or replace function advisor_clients_list(
  p_include_archived boolean default false,
  p_advisor_id       uuid    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_advisor uuid    := current_advisor_id();
  v_lead    boolean := is_team_lead();
  v_scope   uuid;
  v_all     boolean := false;
  v_out     jsonb;
begin
  if v_advisor is null and not is_admin() then
    raise exception 'not authorised';
  end if;

  if p_advisor_id is null then
    if v_lead or is_admin() then
      v_all := true;
    else
      v_scope := v_advisor;
    end if;
  else
    if not can_manage_advisor(p_advisor_id) then
      raise exception 'not authorised for that advisor';
    end if;
    v_scope := p_advisor_id;
  end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.last_name, t.first_name), '[]'::jsonb)
    into v_out
  from (
    select
      ac.id,
      ac.first_name,
      ac.last_name,
      ac.email,
      ac.phone,
      ac.status,
      ac.source,
      ac.assessment,
      ac.created_at,
      ac.updated_at,
      ac.member_user_id,
      ac.member_user_id is not null                as is_member,
      ac.linked_at,
      o.name                                       as org_name,
      ac.org_id,
      ac.org_unit_id,                                          -- new
      kw_unit_label(ac.org_unit_id)                as unit_label,   -- new
      ac.no_org,                                                -- new
      ac.org_mismatch,                                          -- new
      ac.advisor_id,
      adv.full_name                                as advisor_name,
      ac.advisor_id = v_advisor                    as is_mine,
      coalesce(p.advisor_data_consent, false)      as has_consent,
      (select count(*) from bookings b
        where (ac.member_user_id is not null and b.user_id = ac.member_user_id)
           or b.advisor_client_id = ac.id)         as sessions_total,
      (select count(*) from bookings b
        where ((ac.member_user_id is not null and b.user_id = ac.member_user_id)
            or b.advisor_client_id = ac.id)
          and b.attended is true)                  as sessions_attended,
      (select max(b.requested_date::text) from bookings b
        where ((ac.member_user_id is not null and b.user_id = ac.member_user_id)
            or b.advisor_client_id = ac.id))       as last_session_date,
      (select count(*) from bookings b
        where b.advisor_client_id = ac.id
          and b.booked_by = 'advisor'
          and b.member_response = 'declined')      as declined_count,
      case when coalesce(p.advisor_data_consent, false)
           then p.last_score end                   as wellness_score,
      case when coalesce(p.advisor_data_consent, false)
           then p.last_cat_scores end              as wellness_cat_scores
    from advisor_clients ac
    join advisors adv       on adv.id = ac.advisor_id
    left join profiles      p on p.id = ac.member_user_id
    left join organizations o on o.id = coalesce(ac.org_id, p.org_id)
    where (v_all or ac.advisor_id = v_scope)
      and (p_include_archived or ac.status = 'active')
  ) t;

  return v_out;
end;
$$;

grant execute on function advisor_clients_list(boolean, uuid) to authenticated;


-- ── 9. Verification ──────────────────────────────────────────
-- Run these after the migration. Every one should hold.

-- 9a. Nothing unattributed by omission.
--   select count(*) as should_be_zero
--     from advisor_clients where org_id is null and not no_org;

-- 9b. Attribution spread.
--   select coalesce(o.name, '(private client)') as org,
--          count(*) filter (where ac.status = 'active') as active_clients,
--          count(*) filter (where ac.org_mismatch)      as mismatched
--     from advisor_clients ac
--     left join organizations o on o.id = ac.org_id
--    group by 1 order by 2 desc;

-- 9c. The queue an admin should clear.
--   select admin_attribution_queue();

-- 9d. Banding is live and reads from config.
--   select d as dti, kw_dti_band(d) as band, kw_is_over_indebted(d) as flagged
--     from (values (12.0),(28.0),(41.0),(46.0),(81.3)) v(d);
--   -- expect: healthy, manageable, strained, over_indebted, over_indebted
--   --         f,       f,          f,        t,             t

-- 9e. The live consultation records, banded by the agreed definition.
--   select ac.id,
--          round(100 * (select sum(coalesce((l->>'monthlyInstalment')::numeric,0))
--                         from jsonb_array_elements(ac.assessment->'liabilities') l)
--                    / nullif(coalesce((ac.assessment->'income'->>'monthlySalary')::numeric,0)
--                           + coalesce((ac.assessment->'income'->>'spouseIncome')::numeric,0)
--                           + coalesce((ac.assessment->'income'->>'rentals')::numeric,0)
--                           + coalesce((ac.assessment->'income'->>'dividends')::numeric,0)
--                           + coalesce((ac.assessment->'income'->>'businessIncome')::numeric,0), 0), 1) as dti
--     from advisor_clients ac where ac.assessment is not null;
--   -- then band each with kw_dti_band(); expect 2 of 4 over_indebted

-- 9f. The unit rule bites.
--   -- picking a company that has sites should raise:
--   --   'org_unit ... is a company with sites'

-- 9g. org_financial_indicators() still agrees with the config.
--   select (kw_threshold('indicator.dti') -> 'bands') as canonical_bands;
--   -- compare against the hard-coded 20/35/45 in org_financial_indicators().
--   -- They match today. If you ever change one, change both.


-- ── 10. Deployment note — this is not finished in SQL ────────
--
-- advisor.html's diagDebt() still bands DTI at 35/50/65. Until it is
-- changed to read kw_threshold('indicator.dti'), a client at 50% DTI
-- reads "Acceptable" in gold on the advisor screen and "Over-indebted"
-- everywhere else. Ship the advisor.html change in the SAME release as
-- this migration.
--
-- Tell the advisors before it lands. Clients they know as amber will
-- turn red on the day of the deploy — that is the correct reading, but
-- being surprised by it in front of a client is not.
--
-- Check any client report already issued that quoted a DTI band, since
-- the next report will read differently for the same person.
--
-- Before touching advisor.html, run the fork check from the build
-- record and read every line it prints:
--     diff <(git show origin/dev:advisor.html) advisor.html | grep '^<'
--
-- ── 11. Housekeeping found while writing this ────────────────
--
-- `bookings` RLS is defined only in the Supabase dashboard — it is in no
-- repo file, so a rebuild from source would not reproduce it. Captured
-- here as documentation. Nothing below runs; it is a record.
--
--   bookings_admin           ALL     jwt email IN (select email from admins)
--   bookings_admin_all       ALL     is_admin()
--   bookings_advisor_insert  INSERT  advisor_id = current_advisor_id()
--                                      and booked_by = 'advisor'
--   bookings_advisor_select  SELECT  advisor_id = current_advisor_id()
--                                      or is_team_lead()
--                                      or exists (advisor_clients ac
--                                           where ac.advisor_id = current_advisor_id()
--                                             and (ac.member_user_id = bookings.user_id
--                                               or ac.id = bookings.advisor_client_id))
--   bookings_advisor_update  UPDATE  advisor_id = current_advisor_id()
--   bookings_lead_update     UPDATE  is_team_lead()
--   bookings_member_respond  UPDATE  user_id = auth.uid()
--   bookings_own             ALL     user_id = auth.uid()
--   bookings_self            ALL     auth.uid() = user_id
--
-- Two pairs are redundant: bookings_admin duplicates bookings_admin_all
-- with a raw email subquery instead of is_admin(), and bookings_own and
-- bookings_self are the same policy written twice. Permissive policies
-- OR together so neither is a security problem, but each extra policy is
-- evaluated on every row of every query. Worth dropping bookings_admin
-- and bookings_self in their own change, with their own rollback — NOT
-- folded into this migration, because dropping RLS policies deserves to
-- be reviewed on its own.
-- ============================================================
