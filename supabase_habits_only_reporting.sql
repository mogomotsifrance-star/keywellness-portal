-- ============================================================
-- Key Wellness — B1: a habits check is not a wellness score
--
-- Rollback: migrations/rollback-habits-only-reporting.sql
--
-- ══ WHAT THIS FIXES ════════════════════════════════════════
--
-- P0-3 replaced the 16-figure assessment with an 11-question habits check.
-- P0-4 then stopped SHOWING a score out of 100 until the four sources it
-- rests on exist, because the dimensions behind it are estimates until the
-- member has given us their budget, their emergency fund and their debts.
--
-- That gate stopped at the screen. The score was still computed, still
-- written to profiles.live_score on every dashboard render, and still read
-- by five reporting functions — so a number too provisional to show its
-- owner was averaged into their employer's report, banded in their
-- department's breakdown, and counted against every dimension floor in the
-- indicator panel. HR read it as a measurement. Nobody could check it,
-- least of all the member, who was never shown it.
--
-- Two halves, and both are needed:
--
--   SQL (this file)      — reporting excludes a member whose latest
--                          assessment is habits-only and who has no gated
--                          live score, and counts them as engaged instead.
--   index.html           — persistLiveWellness() applies the same gate at
--                          the source, writing NULL rather than a number,
--                          and records picture_sources (0-6) on every pass.
--
-- ══ THE PREDICATE ══════════════════════════════════════════
--
-- One rule, spelled the same way in all five functions so it can be found
-- by grep and cannot drift:
--
--     coalesce((<answers>->>'_habits_only')::boolean, false)
--       and <profile>.live_score is null
--
-- Nulling live_score alone is NOT sufficient anywhere. Every one of these
-- functions falls back to the assessment's own score or cat_scores when the
-- live value is absent — and for a habits-only row that fallback is exactly
-- the figure that must not be reported.
--
-- ══ WHAT IS KEPT ═══════════════════════════════════════════
--
--   goals and income. These two dimensions are habit questions end to end;
--   they mean the same thing on a habits-only row as on a full one, so
--   excluding them would throw away an answer we actually have. Every other
--   dimension needs figures and is dropped.
--
--   Engagement. completed_assessment, assessed and the activation funnel
--   still count this member. They have done something; what they have not
--   done is give us enough to score. `engaged_not_scored` is the new figure
--   that keeps those two apart — without it, excluding someone from the
--   average makes them look like they never showed up.
--
-- ══ WHAT DOES NOT CHANGE ═══════════════════════════════════
--
--   A PRE-P0-3 ASSESSMENT KEEPS ITS SCORE, INDEFINITELY. Those members gave
--   their figures inside the assessment, so the score was honestly earned.
--   Rows without _habits_only are untouched here and grandfathered in
--   index.html. 28 live profiles depend on this.
--
--   The suppression floors. Base-5 and the <3 cell floor are unchanged, and
--   the new `completeness` block carries the <3 floor like everything else
--   HR sees.
--
--   The M3 service-line split. _org_report_period_data and _dept_metrics
--   were rewritten IN PLACE by M3 Part 2 and their disk files are history
--   (see CLAUDE.md). Every block below reads the LIVE body, substitutes, and
--   asserts — sections 7 and 8 additionally count kw_line_is_confidential
--   before and after and refuse to apply if it moved.
--
-- ══ HOW TO RE-RUN ══════════════════════════════════════════
--
-- Idempotent. Each function block either finds _habits_only already in the
-- live body and returns, or asserts every substitution applied. A silent
-- no-op is not possible: a search string that stops matching raises.
--
-- Applied live 15 Sep 2026.
-- ============================================================


-- ══ 1. Prep: the rollback's source of truth, and the new column ═══════════
--
-- Transcribing 24k chars of live body into a rollback script by hand is
-- exactly how the M3 split gets lost again, so the rollback restores from
-- bodies captured here instead.
create table if not exists kw_fn_backup (
  id            bigserial primary key,
  taken_at      timestamptz not null default now(),
  tag           text not null,
  proname       text not null,
  identity_args text not null,
  definition    text not null
);

-- SECURITY DEFINER bodies are internal. Postgres grants nothing on a new table
-- to PUBLIC, but be explicit — the same reflex the function rule demands.
revoke all on table kw_fn_backup from public, anon, authenticated;
alter table kw_fn_backup enable row level security;

insert into kw_fn_backup (tag, proname, identity_args, definition)
select 'phase-b-habits-only', p.proname,
       pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('org_overview','org_financial_indicators','_org_indicator_counts',
                     '_org_report_period_data','_dept_metrics')
   and not exists (select 1 from kw_fn_backup b
                    where b.tag = 'phase-b-habits-only' and b.proname = p.proname
                      and b.identity_args = pg_get_function_identity_arguments(p.oid));

-- B1: how much of the six-source picture the member has given us. Additive,
-- nullable, no default — an absent value means "not computed yet", which is
-- different from 0 ("computed, and they have given us nothing").
alter table profiles add column if not exists picture_sources smallint;
comment on column profiles.picture_sources is
  'B1: count (0-6) of the dashboard picture sources this member has completed. Null = never computed.';


-- ══ 2. org_overview — the HR dashboard's headline ═════════════════════════
--
-- Nine substitutions: the average, the summary lateral, the band
-- distribution, the dimension lateral, the dimension filter, the distress
-- cut, the quarterly trend, the new completeness block, and its declare.
do $$
declare
  v_src text;
  v_new text;
begin
  select replace(definition, E'\r', '') into v_src from kw_fn_backup
   where tag='phase-b-habits-only' and proname='org_overview';
  if v_src is null then raise exception 'no backup body for org_overview'; end if;
  v_new := v_src;

  v_new := replace(v_new,
'      ''participation_pct'', round(100.0 * v_assessed_n::numeric / nullif(n, 0), 1),
      ''avg_score'',         round(avg(
        case when p.live_score is not null and p.live_score_at is not null
                  and p.live_score_at >= a.created_at
             then p.live_score else a.score end
      )::numeric, 1)
    ) into v_summary',
'      ''participation_pct'', round(100.0 * v_assessed_n::numeric / nullif(n, 0), 1),
      -- B1: a habits-only assessment carries no figures, so neither its own
      -- score nor a live score derived from it describes this member''s money.
      -- Nulling live_score alone is NOT enough: the else branch would fall back
      -- to a.score, which for a habits-only row is exactly the number that must
      -- not be reported. Excluded from the average, counted separately.
      ''avg_score'',         round(avg(
        case when coalesce((a.answers->>''_habits_only'')::boolean, false)
                  and p.live_score is null then null
             when p.live_score is not null and p.live_score_at is not null
                  and p.live_score_at >= a.created_at
             then p.live_score else a.score end
      )::numeric, 1),
      ''engaged_not_scored'', count(*) filter (
        where a.created_at is not null
          and coalesce((a.answers->>''_habits_only'')::boolean, false)
          and p.live_score is null)
    ) into v_summary');
  if v_new = v_src then raise exception 'sub 1 (summary) did not apply'; end if;

  v_src := v_new;
  v_new := replace(v_new,
'      select user_id, score, created_at
      from assessments
      where user_id = p.id
      order by created_at desc
      limit 1',
'      select user_id, score, created_at, answers
      from assessments
      where user_id = p.id
      order by created_at desc
      limit 1');
  if v_new = v_src then raise exception 'sub 2 (summary lateral) did not apply'; end if;

  v_src := v_new;
  v_new := replace(v_new,
'      from profiles p
      join assessments a on a.user_id = p.id
      where p.org_id = target_org
        and (v_scope is null or p.org_unit_id = any(v_scope))
      order by p.id, a.created_at desc',
'      from profiles p
      join assessments a on a.user_id = p.id
      where p.org_id = target_org
        and (v_scope is null or p.org_unit_id = any(v_scope))
        -- B1: not scored, so not placed in a band either.
        and not (coalesce((a.answers->>''_habits_only'')::boolean, false) and p.live_score is null)
      order by p.id, a.created_at desc');
  if v_new = v_src then raise exception 'sub 3 (distribution) did not apply'; end if;

  v_src := v_new;
  v_new := replace(v_new,
'        select cat_scores, created_at
        from assessments
        where user_id = p.id
        order by created_at desc
        limit 1
      ) latest',
'        select cat_scores, created_at, answers
        from assessments
        where user_id = p.id
        order by created_at desc
        limit 1
      ) latest');
  if v_new = v_src then raise exception 'sub 4 (dim lateral) did not apply'; end if;

  v_src := v_new;
  v_new := replace(v_new,
'        and dim.key <> ''_insCount''
      group by dim.key',
'        and dim.key <> ''_insCount''
        -- B1: a habits-only member''s dimensions are behaviour halves scored as
        -- if the figures were there. Kept ONLY for the two that are habit
        -- questions end to end (goals, income); excluded elsewhere.
        and (not (coalesce((latest.answers->>''_habits_only'')::boolean, false) and p.live_score is null)
             or dim.key in (''goals'', ''income''))
      group by dim.key');
  if v_new = v_src then raise exception 'sub 5 (dim filter) did not apply'; end if;

  v_src := v_new;
  v_new := replace(v_new,
'      and eff.cats ? ''emergency''
    order by p.id, a.created_at desc',
'      and eff.cats ? ''emergency''
      -- B1: emergency is not one of the two habit-only dimensions.
      and not (coalesce((a.answers->>''_habits_only'')::boolean, false) and p.live_score is null)
    order by p.id, a.created_at desc');
  if v_new = v_src then raise exception 'sub 6 (distress) did not apply'; end if;

  v_src := v_new;
  v_new := replace(v_new,
'    )
    group by date_trunc(''quarter'', a.created_at)',
'    )
      -- B1: a habits-only score is not comparable with the figure-derived
      -- scores beside it in the same quarter, so it does not move the trend.
      and not coalesce((a.answers->>''_habits_only'')::boolean, false)
    group by date_trunc(''quarter'', a.created_at)');
  if v_new = v_src then raise exception 'sub 7 (trend) did not apply'; end if;

  v_src := v_new;
  v_new := replace(v_new,
'  return json_build_object(
    ''suppressed'',   false,
    ''summary'',      v_summary,',
'  -- B1: how far along the six-source picture the cohort is. Same <3 cell floor
  -- as everything else HR sees.
  select json_build_object(
    ''suppressed'', (count(*) < 3),
    ''none'',   case when count(*) < 3 then null else count(*) filter (where coalesce(picture_sources,0) = 0) end,
    ''some'',   case when count(*) < 3 then null else count(*) filter (where coalesce(picture_sources,0) between 1 and 2) end,
    ''most'',   case when count(*) < 3 then null else count(*) filter (where coalesce(picture_sources,0) >= 3) end,
    ''n'',      count(*),
    ''label'',  ''How many of the six figures each member has given: none, 1-2, or 3 or more''
  ) into v_completeness
  from profiles
  where org_id = target_org
    and (v_scope is null or org_unit_id = any(v_scope));

  return json_build_object(
    ''suppressed'',   false,
    ''summary'',      v_summary,
    ''completeness'', v_completeness,');
  if v_new = v_src then raise exception 'sub 8 (completeness) did not apply'; end if;

  v_src := v_new;
  v_new := replace(v_new, '  v_trend        json;', '  v_trend        json;' || E'\n' || '  v_completeness json;');
  if v_new = v_src then raise exception 'sub 9 (declare) did not apply'; end if;

  execute v_new;
end $$;


-- ══ 3. Backfill ══════════════════════════════════════════════════════════
--
-- Idempotent; safe to re-run. Two jobs, and the second is the one that matters.
--
-- 1. picture_sources for everybody, so `completeness` has something to report
--    before any member next opens the dashboard.
--
-- 2. Null live_score where it was written WITHOUT the gate. Until now the front
--    end persisted a live score on every dashboard render regardless of how
--    much the member had given us, so a habits-only member carries a score
--    derived from behaviour answers alone. Going forward the guard stops that
--    at the source; this clears what it already wrote. A habits-only member who
--    HAS met the gate keeps their score — it is computed from real figures, and
--    the dashboard shows it to them, so reporting should see it too.
--
-- NOTE: this seeds picture_sources from what Supabase can see, which is not
-- quite what the dashboard resolver sees. "I have no debts" lives in
-- localStorage (kw_no_debts) until P0-5 gives it a column, so a debt-free
-- member is seeded one short and corrects itself the next time they open the
-- dashboard. The seed is best-effort; the front end is authoritative.
with src as (
  select p.id,
    (exists (select 1 from assessments a where a.user_id = p.id))::int as s_habits,
    (exists (select 1 from tool_data t where t.user_id = p.id and t.tool = 'budget_planner'
               and t.data ? 'currentKey'
               and t.data->'budgets' ? (t.data->>'currentKey')))::int as s_budget,
    (exists (select 1 from emergency_fund e where e.user_id = p.id
               and e.target_months is not null
               and (coalesce(e.current_savings,0) > 0 or coalesce(e.contribution,0) > 0 or coalesce(e.monthly,0) > 0)))::int as s_emergency,
    (exists (select 1 from tool_data t where t.user_id = p.id and t.tool = 'dti_calculator'
               and jsonb_array_length(coalesce(t.data->'debts','[]'::jsonb)) > 0))::int as s_debts,
    (exists (select 1 from tool_data t where t.user_id = p.id and t.tool = 'net_worth_tracker'
               and (jsonb_array_length(coalesce(t.data->'assets','[]'::jsonb)) > 0
                 or jsonb_array_length(coalesce(t.data->'liabilities','[]'::jsonb)) > 0)))::int as s_networth,
    (exists (select 1 from tool_data t where t.user_id = p.id and t.tool = 'retirement'
               and t.data ? 'snapshot'))::int as s_retirement,
    (select coalesce((a.answers->>'_habits_only')::boolean, false)
       from assessments a where a.user_id = p.id
      order by a.created_at desc limit 1) as habits_only
  from profiles p
)
update profiles p
   set picture_sources = s.s_habits + s.s_budget + s.s_emergency + s.s_debts + s.s_networth + s.s_retirement,
       -- The dashboard's own gate: habits + budget + emergency + debts.
       live_score = case
         when coalesce(s.habits_only, false)
              and not (s.s_habits = 1 and s.s_budget = 1 and s.s_emergency = 1 and s.s_debts = 1)
         then null else p.live_score end,
       live_cat_scores = case
         when coalesce(s.habits_only, false)
              and not (s.s_habits = 1 and s.s_budget = 1 and s.s_emergency = 1 and s.s_debts = 1)
         then null else p.live_cat_scores end
  from src s
 where s.id = p.id
   and (p.picture_sources is distinct from (s.s_habits + s.s_budget + s.s_emergency + s.s_debts + s.s_networth + s.s_retirement)
     or (coalesce(s.habits_only, false)
         and not (s.s_habits = 1 and s.s_budget = 1 and s.s_emergency = 1 and s.s_debts = 1)
         and (p.live_score is not null or p.live_cat_scores is not null)));


-- ══ 4. _org_indicator_counts — the indicator panel's bases ════════════════
--
-- Every dimension floor gains a `scored` gate except goals_unclear and
-- single_income_reliance, which rest on habit questions.
do $$
declare v_src text; v_new text;
begin
  select replace(definition, E'\r', '') into v_src from kw_fn_backup
   where tag='phase-b-habits-only' and proname='_org_indicator_counts';
  if v_src is null then raise exception 'no backup body'; end if;
  v_new := v_src;

  -- latest needs the answers to tell a habits-only row from a full one
  v_new := replace(v_new,
'    select distinct on (a.user_id) a.user_id, a.cat_scores, a.created_at
    from assessments a',
'    select distinct on (a.user_id) a.user_id, a.cat_scores, a.created_at, a.answers
    from assessments a');
  if v_new = v_src then raise exception 'sub 1 (latest) did not apply'; end if;

  -- eff carries the verdict, computed once
  v_src := v_new;
  v_new := replace(v_new,
'           then p.live_cat_scores else l.cat_scores end as cats
    from latest l
    join profiles p on p.id = l.user_id
  ),',
'           then p.live_cat_scores else l.cat_scores end as cats,
      -- B1: scored = we have figures behind these dimensions. A habits-only
      -- row with no gated live score is behaviour answers alone.
      not (coalesce((l.answers->>''_habits_only'')::boolean, false) and p.live_score is null) as scored
    from latest l
    join profiles p on p.id = l.user_id
  ),');
  if v_new = v_src then raise exception 'sub 2 (eff) did not apply'; end if;

  -- Dimension floors: gated on `scored`, EXCEPT goals and income, which are
  -- habit questions end to end and mean the same on either kind of row.
  v_src := v_new;
  v_new := replace(v_new,
'      count(*) filter (where cats ? ''emergency'')  as base_emergency,
      count(*) filter (where cats ? ''emergency''  and (cats->>''emergency'')::numeric  < v_floor) as no_emergency_buffer,
      count(*) filter (where cats ? ''spending'')   as base_spending,
      count(*) filter (where cats ? ''spending''   and (cats->>''spending'')::numeric   < v_floor) as living_beyond_means,
      count(*) filter (where cats ? ''retirement'') as base_retirement,
      count(*) filter (where cats ? ''retirement'' and (cats->>''retirement'')::numeric < v_floor) as retirement_shortfall,
      count(*) filter (where cats ? ''insurance'')  as base_insurance,
      count(*) filter (where cats ? ''insurance''  and (cats->>''insurance'')::numeric  < v_floor) as cover_gap,
      count(*) filter (where cats ? ''savings'')    as base_savings,
      count(*) filter (where cats ? ''savings''    and (cats->>''savings'')::numeric    < v_floor) as not_building_wealth,
      count(*) filter (where cats ? ''debt'')       as base_debt_dim,
      count(*) filter (where cats ? ''debt''       and (cats->>''debt'')::numeric       < v_floor) as debt_strain,',
'      count(*) filter (where scored)               as scored_n,
      count(*) filter (where not scored)           as engaged_not_scored,
      count(*) filter (where scored and cats ? ''emergency'')  as base_emergency,
      count(*) filter (where scored and cats ? ''emergency''  and (cats->>''emergency'')::numeric  < v_floor) as no_emergency_buffer,
      count(*) filter (where scored and cats ? ''spending'')   as base_spending,
      count(*) filter (where scored and cats ? ''spending''   and (cats->>''spending'')::numeric   < v_floor) as living_beyond_means,
      count(*) filter (where scored and cats ? ''retirement'') as base_retirement,
      count(*) filter (where scored and cats ? ''retirement'' and (cats->>''retirement'')::numeric < v_floor) as retirement_shortfall,
      count(*) filter (where scored and cats ? ''insurance'')  as base_insurance,
      count(*) filter (where scored and cats ? ''insurance''  and (cats->>''insurance'')::numeric  < v_floor) as cover_gap,
      count(*) filter (where scored and cats ? ''savings'')    as base_savings,
      count(*) filter (where scored and cats ? ''savings''    and (cats->>''savings'')::numeric    < v_floor) as not_building_wealth,
      count(*) filter (where scored and cats ? ''debt'')       as base_debt_dim,
      count(*) filter (where scored and cats ? ''debt''       and (cats->>''debt'')::numeric       < v_floor) as debt_strain,');
  if v_new = v_src then raise exception 'sub 3 (dims gating) did not apply'; end if;

  -- engaged_not_scored surfaces beside assessed
  v_src := v_new;
  v_new := replace(v_new,
'    ''assessed'',   (select assessed from dims),',
'    ''assessed'',   (select assessed from dims),
    -- B1: assessed, but with nothing behind the figures. Counted, never scored.
    ''engaged_not_scored'', (select engaged_not_scored from dims),');
  if v_new = v_src then raise exception 'sub 4 (output) did not apply'; end if;

  execute v_new;
end $$;


-- ══ 5. admin_org_indicators — forward engaged_not_scored to the panel ═════
--
-- Sections 5-8 read the LIVE body and back it up under a second tag,
-- 'phase-b-habits-only-caller'. The rollback restores from both tags.
do $$
declare
  v_def text;
  v_new text;
  v_old text;
  v_rep text;
  v_hits int;
begin
  insert into kw_fn_backup (taken_at, tag, proname, identity_args, definition)
  select now(), 'phase-b-habits-only-caller', p.proname,
         pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_org_indicators'
     and not exists (select 1 from kw_fn_backup b
                      where b.tag = 'phase-b-habits-only-caller'
                        and b.proname = 'admin_org_indicators');

  select replace(pg_get_functiondef(p.oid), E'\r', '') into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_org_indicators';

  if v_def is null then raise exception 'admin_org_indicators not found'; end if;

  if position('engaged_not_scored' in v_def) > 0 then
    raise notice 'admin_org_indicators already carries engaged_not_scored — nothing to do';
    return;
  end if;

  v_old := '      ''assessed'',           (v_now->>''assessed'')::int,';
  v_rep := '      ''assessed'',           (v_now->>''assessed'')::int,' || E'\n' ||
           '      -- B1: assessed, but with no figures behind the dimensions — a habits' || E'\n' ||
           '      -- check alone. Counted here so the cohort still adds up, and excluded' || E'\n' ||
           '      -- from every dimension base by _org_indicator_counts().' || E'\n' ||
           '      ''engaged_not_scored'',  coalesce((v_now->>''engaged_not_scored'')::int, 0),';

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'sub (cohort.assessed) matched % times, expected 1', v_hits;
  end if;

  v_new := replace(v_def, v_old, v_rep);
  if v_new = v_def then raise exception 'sub (cohort.assessed) did not apply'; end if;

  execute v_new;

  select replace(pg_get_functiondef(p.oid), E'\r', '') into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_org_indicators';
  if position('is_admin() or is_team_lead()' in v_def) = 0 then
    raise exception 'authz check lost';
  end if;
  if position('engaged_not_scored' in v_def) = 0 then
    raise exception 'engaged_not_scored not present after apply';
  end if;
end $$;


-- ══ 6. org_financial_indicators — the retirement median and its bands ═════
--
-- The DTI and stress blocks read self-reported figures and are untouched.
-- Only retirement reads a dimension score. Its median also gains a
-- reported_count: the other two blocks ship one, and now that a member can be
-- excluded, a median with no base changes size silently.
do $mig$
declare
  v_def text;
  v_old text;
  v_rep text;
  v_n   int;

  function_name constant text := 'org_financial_indicators';
begin
  insert into kw_fn_backup (taken_at, tag, proname, identity_args, definition)
  select now(), 'phase-b-habits-only-caller', p.proname,
         pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = function_name
     and not exists (select 1 from kw_fn_backup b
                      where b.tag = 'phase-b-habits-only-caller'
                        and b.proname = function_name);

  select replace(pg_get_functiondef(p.oid), E'\r', '') into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = function_name;

  if v_def is null then raise exception '% not found', function_name; end if;

  if position('_habits_only' in v_def) > 0 then
    raise notice '% already gated — nothing to do', function_name;
    return;
  end if;

  -- ── 1. a reported_count for the retirement median ────────────────────────
  v_old := E'  v_ret_median     numeric;';
  v_rep := E'  v_ret_reported   int;\n  v_ret_median     numeric;';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception 'sub 1 (declare) matched %, expected 1', v_n; end if;
  v_def := replace(v_def, v_old, v_rep);

  v_old := E'  select percentile_cont(0.5) within group (order by ret_score)\n  into v_ret_median\n  from (';
  v_rep := E'  select count(*), percentile_cont(0.5) within group (order by ret_score)\n  into v_ret_reported, v_ret_median\n  from (';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception 'sub 2 (median select) matched %, expected 1', v_n; end if;
  v_def := replace(v_def, v_old, v_rep);

  v_old := E'    ''retirement'', json_build_object(\n      ''median'', round(v_ret_median, 1),';
  v_rep := E'    ''retirement'', json_build_object(\n      ''reported_count'', v_ret_reported,\n      ''median'', round(v_ret_median, 1),';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception 'sub 3 (output) matched %, expected 1', v_n; end if;
  v_def := replace(v_def, v_old, v_rep);

  -- ── 2. the latest-assessment lateral must carry answers ──────────────────
  v_old := 'select cat_scores, created_at from assessments';
  v_rep := 'select cat_scores, created_at, answers from assessments';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 2 then raise exception 'sub 4 (lateral) matched %, expected 2', v_n; end if;
  v_def := replace(v_def, v_old, v_rep);

  -- ── 3. the gate, on both the median and the band query ───────────────────
  v_old := E'      and (v_scope is null or p.org_unit_id = any(v_scope))\n      and eff.cats ? ''retirement''\n  ) x;';
  v_rep := E'      and (v_scope is null or p.org_unit_id = any(v_scope))\n      and eff.cats ? ''retirement''\n      and not (coalesce((a.answers->>''_habits_only'')::boolean, false)\n               and p.live_score is null)\n  ) x;';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception 'sub 5 (median gate) matched %, expected 1', v_n; end if;
  v_def := replace(v_def, v_old, v_rep);

  v_old := E'        and (v_scope is null or p.org_unit_id = any(v_scope))\n        and eff.cats ? ''retirement''\n    ) y';
  v_rep := E'        and (v_scope is null or p.org_unit_id = any(v_scope))\n        and eff.cats ? ''retirement''\n        and not (coalesce((a.answers->>''_habits_only'')::boolean, false)\n                 and p.live_score is null)\n    ) y';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception 'sub 6 (band gate) matched %, expected 1', v_n; end if;
  v_def := replace(v_def, v_old, v_rep);

  execute v_def;

  -- ── 4. assert what must have survived ────────────────────────────────────
  select replace(pg_get_functiondef(p.oid), E'\r', '') into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = function_name;

  if position('is_admin() or coalesce(employer_org() = target_org, false)' in v_def) = 0 then
    raise exception 'authz check lost';
  end if;
  if position('if v_assessed_count < 5 then' in v_def) = 0 then
    raise exception 'cohort floor of 5 lost';
  end if;
  v_n := (length(v_def) - length(replace(v_def, 'between 1 and 2', ''))) / length('between 1 and 2');
  if v_n <> 6 then raise exception 'cell floor appears % times, expected 6', v_n; end if;
  v_n := (length(v_def) - length(replace(v_def, '_habits_only', ''))) / length('_habits_only');
  if v_n <> 2 then raise exception 'gate appears % times, expected 2', v_n; end if;
end
$mig$;


-- ══ 7. _org_report_period_data — the report's dimension bands ═════════════
--
-- CAUTION: this body carries the M3 Part 2 service-line split and the disk
-- file supabase_org_report_data_v4.sql does NOT. The block reads the live
-- body, counts kw_line_is_confidential before and after, and refuses to
-- apply if the count moved.
do $mig$
declare
  v_def   text;
  v_old   text;
  v_rep   text;
  v_n     int;
  v_lines_before int;
begin
  insert into kw_fn_backup (taken_at, tag, proname, identity_args, definition)
  select now(), 'phase-b-habits-only-caller', p.proname,
         pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = '_org_report_period_data'
     and pg_get_function_identity_arguments(p.oid) like '%p_unit_ids%'
     and not exists (select 1 from kw_fn_backup b
                      where b.tag = 'phase-b-habits-only-caller'
                        and b.proname = '_org_report_period_data'
                        and b.identity_args like '%p_unit_ids%');

  select replace(pg_get_functiondef(p.oid), E'\r', '') into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = '_org_report_period_data'
     and pg_get_function_identity_arguments(p.oid) like '%p_unit_ids%';

  if v_def is null then raise exception '_org_report_period_data(5-arg) not found'; end if;

  if position('_habits_only' in v_def) > 0 then
    raise notice '_org_report_period_data already gated — nothing to do';
    return;
  end if;

  v_lines_before := (length(v_def) - length(replace(v_def, 'kw_line_is_confidential', '')))
                    / length('kw_line_is_confidential');
  if v_lines_before < 10 then
    raise exception 'service-line split looks wrong before patching: % occurrences', v_lines_before;
  end if;

  -- ── 1. the latest-in-period row must carry its answers ───────────────────
  v_old := $q$    select distinct on (a.user_id) a.user_id, a.cat_scores, a.created_at
    from assessments a$q$;
  v_rep := $q$    select distinct on (a.user_id) a.user_id, a.cat_scores, a.created_at, a.answers
    from assessments a$q$;
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception 'sub 1 (latest_in_period) matched %, expected 1', v_n; end if;
  v_def := replace(v_def, v_old, v_rep);

  -- ── 2. carry a scored flag alongside the effective cat_scores ────────────
  v_old := $q$           then p.live_cat_scores else lip.cat_scores end as cat_scores
    from latest_in_period lip$q$;
  v_rep := $q$           then p.live_cat_scores else lip.cat_scores end as cat_scores,
      -- B1: scored = there are figures behind these dimensions. A habits-only
      -- check whose live score never met the dashboard gate is behaviour
      -- answers alone, so its dimension scores are not measurements.
      not (coalesce((lip.answers->>'_habits_only')::boolean, false)
           and p.live_score is null) as scored
    from latest_in_period lip$q$;
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception 'sub 2 (effective) matched %, expected 1', v_n; end if;
  v_def := replace(v_def, v_old, v_rep);

  -- ── 3. keep only the two dimensions behaviour answers can speak to ───────
  v_old := $q$    where dim.key <> '_insCount'
  ),$q$;
  v_rep := $q$    where dim.key <> '_insCount'
      and (eff.scored or dim.key in ('goals', 'income'))
  ),$q$;
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception 'sub 3 (dims filter) matched %, expected 1', v_n; end if;
  v_def := replace(v_def, v_old, v_rep);

  execute v_def;

  -- ── 4. assert what must have survived ────────────────────────────────────
  select replace(pg_get_functiondef(p.oid), E'\r', '') into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = '_org_report_period_data'
     and pg_get_function_identity_arguments(p.oid) like '%p_unit_ids%';

  v_n := (length(v_def) - length(replace(v_def, 'kw_line_is_confidential', '')))
         / length('kw_line_is_confidential');
  if v_n <> v_lines_before then
    raise exception 'M3 service-line split changed: % occurrences, was %', v_n, v_lines_before;
  end if;
  if position('_kw_cell(p_client_safe' in v_def) = 0 then
    raise exception 'suppression helper lost';
  end if;
  v_n := (length(v_def) - length(replace(v_def, '_habits_only', ''))) / length('_habits_only');
  if v_n <> 1 then raise exception 'gate appears % times, expected 1', v_n; end if;
end
$mig$;


-- ══ 8. _dept_metrics — the department wellness bands ══════════════════════
--
-- Same M3 caution as section 7. The live branch still wins when it is
-- current: a gated live score is a real measurement. It is the FALLBACK that
-- was the problem.
do $mig$
declare
  v_def   text;
  v_old   text;
  v_rep   text;
  v_n     int;
  v_split_before int;
begin
  insert into kw_fn_backup (taken_at, tag, proname, identity_args, definition)
  select now(), 'phase-b-habits-only-caller', p.proname,
         pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = '_dept_metrics'
     and not exists (select 1 from kw_fn_backup b
                      where b.tag = 'phase-b-habits-only-caller'
                        and b.proname = '_dept_metrics');

  select replace(pg_get_functiondef(p.oid), E'\r', '') into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = '_dept_metrics';

  if v_def is null then raise exception '_dept_metrics not found'; end if;

  if position('_habits_only' in v_def) > 0 then
    raise notice '_dept_metrics already gated — nothing to do';
    return;
  end if;

  v_split_before := (length(v_def) - length(replace(v_def, 'kw_line_is_confidential', '')))
                    / length('kw_line_is_confidential');
  if v_split_before <> 2 then
    raise exception 'service-line split looks wrong before patching: % occurrences', v_split_before;
  end if;

  -- ── 1. the latest-assessment lateral must carry its answers ──────────────
  v_old := $q$      select a.score, a.created_at from assessments a$q$;
  v_rep := $q$      select a.score, a.created_at, a.answers from assessments a$q$;
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception 'sub 1 (la lateral) matched %, expected 1', v_n; end if;
  v_def := replace(v_def, v_old, v_rep);

  -- ── 2. a habits-only fallback is not a wellness score ────────────────────
  -- la.score on a habits-only row is derived from behaviour answers with no
  -- figures behind it, and it was landing in the department's wellness bands
  -- as if measured.
  v_old := $q$        then c.live_score
        else la.score
      end as eff_score$q$;
  v_rep := $q$        then c.live_score
        when coalesce((la.answers->>'_habits_only')::boolean, false)
             and c.live_score is null
        then null
        else la.score
      end as eff_score$q$;
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception 'sub 2 (eff_score) matched %, expected 1', v_n; end if;
  v_def := replace(v_def, v_old, v_rep);

  execute v_def;

  -- ── 3. assert what must have survived ────────────────────────────────────
  select replace(pg_get_functiondef(p.oid), E'\r', '') into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = '_dept_metrics';

  v_n := (length(v_def) - length(replace(v_def, 'kw_line_is_confidential', '')))
         / length('kw_line_is_confidential');
  if v_n <> v_split_before then
    raise exception 'M3 service-line split changed: % occurrences, was %', v_n, v_split_before;
  end if;
  if position('Fewer than 5 enrolled members' in v_def) = 0 then
    raise exception 'cohort floor of 5 lost';
  end if;
  if position('_kw_cell(p_client_safe' in v_def) = 0 then
    raise exception 'suppression helper lost';
  end if;
  -- The bands must still drop a null score rather than counting it as 0.
  if position('from eff where eff_score is not null' in v_def) = 0 then
    raise exception 'null-score exclusion lost — an unscored member would band as under_50';
  end if;
  v_n := (length(v_def) - length(replace(v_def, '_habits_only', ''))) / length('_habits_only');
  if v_n <> 1 then raise exception 'gate appears % times, expected 1', v_n; end if;
end
$mig$;
