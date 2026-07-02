# Rollback notes

One entry per migration file, in application order. Run the rollback SQL in the
Supabase SQL Editor. Safe to run only if you want to fully remove that batch's
database objects — nothing here is destructive to pre-existing tables.

## supabase_points_ledger.sql (Batch 1 — points ledger)

Nothing pre-existing referenced these objects, so dropping is safe and complete:

```sql
drop view if exists public.my_points;
drop function if exists public.award_points(text, text);
drop table if exists public.points_events;
drop table if exists public.points_catalog;
```

Note: `points_catalog` includes the `legacy_migration` row (0 pts) and
`points_events` includes the one-time legacy carry-over rows (`ref_id =
'v1-carryover'`). Dropping the tables removes those too — the source data
(`badges.points`) is untouched, so the backfill can be re-run if the ledger is
ever recreated.

## supabase_leaderboard_optin.sql (Batch 3 — opt-in & alias)

```sql
alter table public.profiles
  drop column if exists leaderboard_opt_in,
  drop column if exists display_alias;
```

Note: this permanently discards any member's leaderboard opt-in choice and
chosen display name. No other table references these columns.
