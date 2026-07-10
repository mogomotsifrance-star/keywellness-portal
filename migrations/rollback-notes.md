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

## supabase_leaderboard.sql (Batch 4 — leaderboard & rewards RPCs)

```sql
drop function if exists public.org_rewards(uuid, text);
drop function if exists public.org_leaderboard_self_rank(text);
drop function if exists public.org_leaderboard(text);
```

Note: nothing pre-existing referenced these; safe to drop in any order once
the leaderboard page (Batch 5) and HR Rewards tab (Batch 7) are no longer
calling them.

## supabase_financial_indicators.sql (Batch 6 — org_financial_indicators())

```sql
drop function if exists public.org_financial_indicators(uuid);
```

Note: nothing pre-existing referenced this; safe to drop once the HR
dashboard's Debt Health / Retirement Readiness panels (Batch 7) are removed.

## supabase_rewards_categories.sql (Rewards-reshape Batch 1 — category column + my_points extension)

Prior `my_points` definition (restore this first if rolling back — it's the
exact view from `supabase_points_ledger.sql` §5, before the three per-category
columns were appended):

```sql
create or replace view public.my_points
with (security_invoker = true) as
  select user_id,
         coalesce(sum(points), 0) as total_points,
         coalesce(sum(points) filter (where season = to_char(now(), 'YYYY"-Q"Q')), 0) as season_points
  from public.points_events
  group by user_id;

grant select on public.my_points to authenticated;
```

Then drop the category column:

```sql
alter table public.points_catalog drop column if exists category;
```

Note: dropping `category` before restoring the view would break the new
view definition's join — restore the view FIRST, then drop the column, if
rolling back this batch in isolation.

## supabase_reward_thresholds.sql (Rewards-reshape Batch 2 — threshold config)

```sql
drop table if exists public.reward_thresholds;
```

Note: nothing pre-existing referenced this; safe to drop once org_rewards()/
record_reward_fulfilment() (Batch 4/5) no longer read it.

## Member leaderboard removal (Rewards-reshape Batch 3 — product decision)

The member-facing leaderboard is removed (`VIEWS['leaderboard']` deleted from
`index.html`, replaced by the private Rewards Progress card). `org_leaderboard()`
and `org_leaderboard_self_rank()` are dropped from the database. Recreate
scripts below are the verbatim current definitions from `supabase_leaderboard.sql`
— run these FIRST if the leaderboard ever needs to come back, then re-add the
frontend view.

Recreate `org_leaderboard(p_season text default null)`:

```sql
create or replace function public.org_leaderboard(p_season text default null)
returns table (
  alias         text,
  season_points bigint,
  badge_count   int,
  rank          bigint,
  is_self       boolean
)
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_org    uuid;
  v_season text;
  v_public_badges text[] := array[
    'first_login','first_assessment','booked_session','ef_t1',
    'checkin_streak_t1','checkin_streak_t2','checkin_streak_t3',
    'learning_t1','learning_t2','learning_t3',
    'budget_year_t1','budget_year_t2','budget_year_t3','budget_year_t4',
    'budget_year_t5','budget_year_t6','budget_year_t7','budget_year_t8',
    'budget_year_t9','budget_year_t10','budget_year_t11','budget_year_t12'
  ];
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select org_id into v_org from profiles where id = v_uid;
  if v_org is null then
    return;
  end if;

  v_season := coalesce(p_season, to_char(now(), 'YYYY"-Q"Q'));

  return query
  with org_points as (
    select pe.user_id, coalesce(sum(pe.points), 0) as season_points
    from points_events pe
    join profiles p on p.id = pe.user_id
    where p.org_id = v_org and pe.season = v_season
    group by pe.user_id
  ),
  badge_counts as (
    select b.user_id, count(*) as badge_count
    from badges b
    cross join lateral unnest(b.earned_badge_ids) as bid(id)
    where bid.id = any(v_public_badges)
    group by b.user_id
  ),
  ranked as (
    select
      p.id as user_id,
      coalesce(op.season_points, 0) as season_points,
      coalesce(nullif(trim(p.display_alias), ''), 'Member') as alias,
      coalesce(bc.badge_count, 0) as badge_count,
      rank() over (order by coalesce(op.season_points, 0) desc) as rnk
    from profiles p
    left join org_points   op on op.user_id = p.id
    left join badge_counts bc on bc.user_id = p.id
    where p.org_id = v_org and p.leaderboard_opt_in = true
  )
  select r.alias, r.season_points, r.badge_count, r.rnk as rank, (r.user_id = v_uid) as is_self
  from ranked r
  where r.rnk <= 50 or r.user_id = v_uid
  order by r.rnk asc;
end;
$$;

grant execute on function public.org_leaderboard(text) to authenticated;
```

Recreate `org_leaderboard_self_rank(p_season text default null)`:

```sql
create or replace function public.org_leaderboard_self_rank(p_season text default null)
returns table (
  my_rank       bigint,
  total_members bigint,
  season_points bigint,
  opted_in      boolean
)
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_org    uuid;
  v_season text;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select org_id into v_org from profiles where id = v_uid;
  if v_org is null then
    return;
  end if;

  v_season := coalesce(p_season, to_char(now(), 'YYYY"-Q"Q'));

  return query
  with org_points as (
    select p.id as user_id,
           coalesce(sum(pe.points) filter (where pe.season = v_season), 0) as season_points
    from profiles p
    left join points_events pe on pe.user_id = p.id
    where p.org_id = v_org
    group by p.id
  ),
  ranked as (
    select user_id, season_points,
           rank() over (order by season_points desc) as rnk,
           count(*) over () as total
    from org_points
  )
  select r.rnk, r.total, r.season_points,
         (select leaderboard_opt_in from profiles where id = v_uid)
  from ranked r
  where r.user_id = v_uid;
end;
$$;

grant execute on function public.org_leaderboard_self_rank(text) to authenticated;
```

Drop statements (only run these once the recreate scripts above are safely saved —
they already are, in this file):

```sql
drop function if exists public.org_leaderboard(text);
drop function if exists public.org_leaderboard_self_rank(text);
```

Note: `org_rewards` is NOT dropped here — it is reshaped in place by
`supabase_rewards_reshape.sql` (Batch 4). Its prior definition is saved in
that batch's own rollback entry below.

## supabase_rewards_reshape.sql (Rewards-reshape Batch 4 — org_rewards() reshape + org_rewards_summary())

Prior `org_rewards()` definition (flat rank list, no categories) — restore
this to undo the reshape and go back to the old return shape:

```sql
create or replace function public.org_rewards(target_org uuid default null, p_season text default null)
returns table (
  first_name    text,
  last_name     text,
  season_points bigint,
  rank          bigint
)
language plpgsql security definer set search_path = public as $$
declare
  v_season text;
begin
  if target_org is null then
    target_org := employer_org();
  end if;

  if target_org is null then
    raise exception 'not authorised';
  end if;

  if not (is_admin() or coalesce(employer_org() = target_org, false)) then
    raise exception 'not authorised';
  end if;

  v_season := coalesce(p_season, to_char(now(), 'YYYY"-Q"Q'));

  return query
  with org_points as (
    select p.id as user_id, coalesce(sum(pe.points), 0) as season_points
    from profiles p
    left join points_events pe on pe.user_id = p.id and pe.season = v_season
    where p.org_id = target_org and p.leaderboard_opt_in = true
    group by p.id
  )
  select p.first_name, p.last_name, op.season_points,
         rank() over (order by op.season_points desc) as rank
  from org_points op
  join profiles p on p.id = op.user_id
  order by rank asc;
end;
$$;

grant execute on function public.org_rewards(uuid, text) to authenticated;
```

Then drop the new objects added by this batch:

```sql
drop function if exists public.org_rewards_summary(uuid, text);
drop table if exists public.org_headcount_reports;
drop table if exists public.reward_fulfilments;
```

Note: only drop `reward_fulfilments`/`org_headcount_reports` if Batches 5/7
have also been rolled back — `record_reward_fulfilment()`, `org_reward_history()`,
and `set_org_headcount()` all depend on these tables existing.

## supabase_reward_fulfilment.sql (Rewards-reshape Batch 5 — fulfilment RPCs)

Nothing pre-existing referenced these functions, so dropping is safe and
complete (the `reward_fulfilments` table itself is owned by Batch 4's
rollback entry above — don't drop it here if Batch 4 is still in place):

```sql
drop function if exists public.record_reward_fulfilment(uuid, text, text, text);
drop function if exists public.org_reward_history(text);
```

## supabase_org_headcount.sql (Rewards-reshape Batch 7 — employer headcount)

```sql
drop function if exists public.set_org_headcount(int, uuid);
```

Note: `org_headcount_reports` itself is owned by Batch 4's rollback entry
above (it was pre-created there) — don't drop it here if Batch 4 is still
in place; org_rewards_summary() still reads it for reported_headcount.

## supabase_lms_storage.sql (Learning Pathways Batch 1 — `Videos` storage bucket)

REVISED: the bucket is `Videos` (capital V), created by hand via the
dashboard before this file's second revision — not the lowercase `videos`
the first revision created (that stray empty bucket was cleaned up by the
revised file itself, see its own header comment). Rollback for the real
bucket — this DOES NOT remove the 15 Pathway-1 videos + welcome file
Tshenolo uploaded directly, only the RLS policy:

```sql
drop policy if exists "videos_public_read" on storage.objects;
```

To also remove the bucket and every uploaded file (destructive — only if
the pathway videos are being fully retired, not just the DB policy): **not
possible via raw SQL** — Supabase blocks direct `DELETE` on
`storage.objects`/`storage.buckets` with a `protect_delete()` trigger
(`42501`, "Use the Storage API instead" — confirmed live). Use the
dashboard's Storage → Buckets UI, or the Storage REST/JS API with a
service-role key, instead.

## supabase_lms_schema.sql (Learning Pathways Batch 2 — pathways/content_items/quizzes/certificates)

`content_items`/`content_progress` did not exist before this batch (confirmed
in Batch 0 discovery via REST schema-cache probe) — both are created fresh
here, not altered. Nothing pre-existing references any of these six new
tables or the `quiz_questions_public` view, so dropping is safe and complete:

```sql
drop view if exists public.quiz_questions_public;
drop table if exists public.certificates;
drop table if exists public.quiz_attempts;
drop table if exists public.quiz_questions;
drop table if exists public.quizzes;
drop table if exists public.content_progress;
drop table if exists public.content_items;
drop table if exists public.pathways;
```

Note: this permanently discards all member video-completion progress, quiz
attempts, and issued certificates recorded since this batch shipped — only
roll back before real members have used the feature, or after exporting
`quiz_attempts`/`certificates` if member records must be preserved.

## supabase_lms_rpcs.sql (Learning Pathways Batch 3 — complete_video/submit_quiz/issue_certificate RPCs)

Nothing pre-existing referenced these functions, so dropping is safe and
complete (the tables/view they read and write are owned by Batch 2's
rollback entry above — don't drop those here if Batch 3 is being rolled
back in isolation while Batch 2 stays in place):

```sql
drop function if exists public.issue_certificate(smallint, text);
drop function if exists public.submit_quiz(uuid, jsonb);
drop function if exists public.complete_video(uuid);
```

To also revert the Batch 2 tightening (revoking `anon` SELECT on
`quiz_questions_public`, applied in this same file):

```sql
grant select on public.quiz_questions_public to anon;
```

## supabase_lms_pathway1_update.sql (Learning Pathways — video reorg + new lesson + welcome video)

Tshenolo moved all 15 Pathway-1 files into a `Foundation/` subfolder, added
a new "Psychology of Spending" lesson (inserted as lesson 4, everything
from the old lesson 4 onward shifted down one), and uploaded a real
welcome video. This file UPDATEs existing `content_items` rows in place
(not delete+recreate) specifically so any `content_progress` already
recorded against these ids survives — rollback restores the PRE-reorg
values (original flat bucket-root paths, original 15-lesson order, no
Psychology of Spending row, welcome video back to the Batch 2 placeholder):

```sql
update public.content_items set sort_order = 1,  video_path = 'Module 1_Introduction to Financial Literacy_video.mp4'                    where pathway_id = 1 and title = 'Introduction to Financial Literacy';
update public.content_items set sort_order = 2,  video_path = 'Module 2_Understanding Your Relationship with Money_video.mp4'            where pathway_id = 1 and title = 'Understanding Your Relationship with Money';
update public.content_items set sort_order = 3,  video_path = 'Module 3_Emotional Spending_video.mp4'                                    where pathway_id = 1 and title = 'Emotional Spending';
update public.content_items set sort_order = 4,  video_path = 'Module 4_Lifestyle Inflation_video.mp4'                                   where pathway_id = 1 and title = 'Lifestyle Inflation';
update public.content_items set sort_order = 5,  video_path = 'Module 5_Qualifying vs Affording_video.mp4'                               where pathway_id = 1 and title = 'Qualifying vs Affording';
update public.content_items set sort_order = 6,  video_path = 'Module 6_The Three Money Problems_video.mp4'                              where pathway_id = 1 and title = 'The Three Money Problems';
update public.content_items set sort_order = 7,  video_path = 'Module 7_Setting SMART Financial Goals_video.mp4'                         where pathway_id = 1 and title = 'Setting SMART Financial Goals';
update public.content_items set sort_order = 8,  video_path = 'Module 8_Understanding Your Payslip_video.mp4'                            where pathway_id = 1 and title = 'Understanding Your Payslip';
update public.content_items set sort_order = 9,  video_path = 'Module 9_Creating a Personal Budget_video.mp4'                            where pathway_id = 1 and title = 'Creating a Personal Budget';
update public.content_items set sort_order = 10, video_path = 'Module 10_Managing Cash Flow_video.mp4'                                   where pathway_id = 1 and title = 'Managing Cash Flow';
update public.content_items set sort_order = 11, video_path = 'Module 11 -Needs vs Wants_video_4k.mp4'                                   where pathway_id = 1 and title = 'Needs vs Wants';
update public.content_items set sort_order = 12, video_path = 'Module 12 -Building Better Money Habits_video_4k.mp4'                     where pathway_id = 1 and title = 'Building Better Money Habits';
update public.content_items set sort_order = 13, video_path = 'Module 13 - Emergency Funds_video_4k.mp4'                                 where pathway_id = 1 and title = 'Emergency Funds';
update public.content_items set sort_order = 14, video_path = 'Module 14 - Understanding Debt_video_4k.mp4'                              where pathway_id = 1 and title = 'Understanding Debt';
update public.content_items set sort_order = 15, video_path = 'Module 15 - Assets vs Liabilities_video_4k (1).mp4'                       where pathway_id = 1 and title = 'Assets vs Liabilities';
delete from public.content_items where pathway_id = 1 and title = 'Psychology of Spending';
update public.content_items set video_path = 'welcome.mp4' where pathway_id is null and title = 'Welcome to Key Wellness';
```

Note: the DELETE above only removes the Psychology of Spending row itself
— if a real member has already completed it by the time of rollback,
their `content_progress` row for it is cascade-deleted too (unrecoverable
for that one lesson; every other lesson's progress is untouched since
this whole file only ever UPDATEs by matching on `id`-stable rows).
