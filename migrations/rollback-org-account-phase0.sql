-- ============================================================
-- ROLLBACK — Organisation Account View, Phase 0
-- Reverses supabase_org_account_phase0.sql. Safe to re-run.
--
-- Order matters: constraints and triggers referencing a column must go
-- before the column does, and functions after the triggers that use
-- them. This is the failure the advisor-portal rollback hit the first
-- time round, so it is written deliberately here.
--
-- NOTE ON DATA LOSS. Dropping org_unit_id discards the company/site
-- attribution captured since the migration ran, and dropping
-- org_mismatch discards the record of which clients disagreed with
-- their member profile. org_id itself is NOT dropped — it predates this
-- migration — but the backfill in §2 cannot be distinguished from
-- values entered later, so it is not reversed. If that matters, snapshot
-- first:
--
--   create table advisor_clients_phase0_backup as
--     select id, org_id, org_unit_id, no_org, org_mismatch
--       from advisor_clients;
-- ============================================================


-- ── 1. Triggers ──────────────────────────────────────────────

drop trigger if exists trg_validate_client_unit    on advisor_clients;
drop trigger if exists trg_sync_advisor_client_org on profiles;


-- ── 2. Constraints ───────────────────────────────────────────

alter table advisor_clients drop constraint if exists advisor_clients_org_required;
alter table advisor_clients drop constraint if exists advisor_clients_unit_needs_org;


-- ── 3. Restore the original insert trigger function ──────────
-- As it stood before Phase 0: links by email and inherits org_id only.

create or replace function link_advisor_client_on_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_uid uuid;
begin
  if new.member_user_id is null and new.email is not null then
    select id into v_uid from auth.users
     where lower(email) = lower(new.email)
     limit 1;
    if v_uid is not null then
      new.member_user_id := v_uid;
      new.linked_at := now();
    end if;
  end if;

  -- Keep org_id in step with the member's org whenever we know it.
  if new.member_user_id is not null and new.org_id is null then
    select org_id into new.org_id from profiles where id = new.member_user_id;
  end if;

  return new;
end;
$$;


-- ── 4. Restore advisor_clients_list() without the new fields ──

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
      ac.id, ac.first_name, ac.last_name, ac.email, ac.phone,
      ac.status, ac.source, ac.assessment, ac.created_at, ac.updated_at,
      ac.member_user_id,
      ac.member_user_id is not null                as is_member,
      ac.linked_at,
      o.name                                       as org_name,
      ac.org_id,
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


-- ── 5. Functions introduced by Phase 0 ───────────────────────

drop function if exists admin_attribution_queue();
drop function if exists kw_validate_client_unit();
drop function if exists kw_sync_advisor_client_org();
drop function if exists kw_is_over_indebted(numeric);
drop function if exists kw_dti_band(numeric);
drop function if exists kw_unit_label(uuid);
drop function if exists kw_threshold(text);


-- ── 6. Indexes ───────────────────────────────────────────────

drop index if exists advisor_clients_org_idx;
drop index if exists advisor_clients_org_unit_idx;
drop index if exists advisor_clients_needs_attention_idx;


-- ── 7. Columns ───────────────────────────────────────────────
-- Last, so nothing above still references them.

alter table advisor_clients
  drop column if exists org_unit_id,
  drop column if exists no_org,
  drop column if exists org_mismatch;


-- ── 8. Threshold config rows ─────────────────────────────────
-- Only the keys Phase 0 added. The reward thresholds that shared this
-- table before are left alone.

delete from threshold_config
 where key in (
   'indicator.dti',
   'indicator.dimension_flag_below',
   'indicator.high_cost_credit_rate',
   'indicator.low_base',
   'indicator.emergency_months_floor',
   'indicator.savings_rate_floor_pct',
   'panel3.headline'
 );


-- ── 9. Verify the rollback is clean ──────────────────────────
--
--   select count(*) as should_be_zero from information_schema.columns
--    where table_name = 'advisor_clients'
--      and column_name in ('org_unit_id','no_org','org_mismatch');
--
--   select count(*) as should_be_zero from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('kw_threshold','kw_dti_band','kw_is_over_indebted',
--                        'kw_unit_label','kw_validate_client_unit',
--                        'kw_sync_advisor_client_org','admin_attribution_queue');
--
--   select count(*) as should_be_zero from pg_constraint
--    where conname in ('advisor_clients_org_required','advisor_clients_unit_needs_org');
--
--   select count(*) as should_be_zero from threshold_config where key like 'indicator.%';
--
--   select advisor_clients_list();   -- still works, without the new fields
-- ============================================================
