-- ============================================================
-- DOCUMENTATION ONLY. DO NOT RUN.
-- member_debts — the live definition, recorded 4 Oct 2026
--
-- This table exists on the live project (tarmpqxsabbehgjaonfz) with 25 rows,
-- but no migration for it was ever committed to any branch of this repo. It
-- was read back from the catalogue on 4 Oct 2026 (pg_get_constraintdef,
-- pg_indexes, pg_get_triggerdef, pg_policies, pg_get_functiondef) so the next
-- person knows it is there and what writes through it.
--
-- Nothing in this repo writes member_debts. It is described in
-- docs/first-session-audit-2026-09-08.md (Changes section) as one of two new
-- tables, with member_assets, but the build that created it did not land.
--
-- Why it matters: kw_recalc_member_rollups() writes profiles.monthly_debt,
-- total_debt_balance and total_liabilities from it, and monthly_debt is the
-- numerator of every HR and admin debt-service figure. A member with rows
-- here has those three profile columns owned by this table.
--
-- Re-creating it from this file on a database that already has it would
-- fail on the first statement. It is wrapped in a block comment for that
-- reason: it is a record, not a migration.
-- ============================================================

/*
create table public.member_debts (
  id                   uuid        not null default gen_random_uuid(),
  user_id              uuid        not null,
  name                 text        not null,
  kind                 text        not null default 'other',
  balance              numeric,
  monthly_payment      numeric,
  interest_rate        numeric,
  is_housing           boolean     not null default false,
  deducted_from_salary boolean     not null default false,
  opened_source        text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint member_debts_pkey primary key (id),
  constraint member_debts_user_id_fkey foreign key (user_id)
    references auth.users(id) on delete cascade,
  constraint member_debts_kind_ck check (kind = any (array[
    'mortgage','car','personal_loan','credit_card','store_credit',
    'student_loan','motshelo_loan','family_loan','salary_advance','other']))
);

create index member_debts_user_idx on public.member_debts using btree (user_id);

alter table public.member_debts enable row level security;

create policy member_debts_admin_read on public.member_debts
  as permissive for select to public using (is_admin());
create policy member_debts_own on public.member_debts
  as permissive for all to public
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Table grants as read back (Supabase defaults; RLS is what restricts):
--   postgres, anon, authenticated, service_role = arwdDxtm

create trigger member_debts_rollup after insert or delete or update
  on public.member_debts for each row execute function kw_register_touch();
create trigger member_debts_stamp before update
  on public.member_debts for each row execute function kw_register_stamp();

-- kw_register_touch()  SECURITY DEFINER, execute revoked from anon/authenticated.
--   Sets updated_at, flips profiles.has_no_debts to false on the first insert,
--   then calls kw_recalc_member_rollups(user_id).
-- kw_register_stamp()  plain trigger: new.updated_at := now().
-- kw_recalc_member_rollups(uuid)  SECURITY DEFINER, execute revoked from
--   anon/authenticated. Sets, for that user:
--     monthly_debt = sum(monthly_payment)
--                  + greatest(0, payslip_loan_deductions - sum(deducted rows))
--                  + greatest(0, budget_debt_min - sum(non-deducted rows))
--     total_debt_balance, total_liabilities = sum(balance)   (when rows exist)
--     total_assets = sum(member_assets.value)                (when rows exist)

-- Account deletion: the FK is ON DELETE CASCADE, so member_debts rows go with
-- the auth user and do not block admin_user_delete().
*/
