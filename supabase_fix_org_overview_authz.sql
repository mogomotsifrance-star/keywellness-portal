-- ============================================================
-- FIX: org_overview() authorization NULL-logic hole
-- Caught by browser_rls_test.js check 6.
--
-- Before: for a non-employer, employer_org() is NULL, so
--   `is_admin() OR (employer_org() = target_org)` evaluates to NULL,
--   `NOT NULL` is NULL, and `IF NULL THEN raise` is skipped — letting
--   any logged-in user read any org's aggregates.
-- After: coalesce the comparison to false so non-managers are rejected.
--
-- Only the authz line changed; the body is identical to the migration.
-- ============================================================

create or replace function org_overview(target_org uuid)
returns json
language plpgsql security definer set search_path = public as $$
declare
  n      int;
  result json;
begin
  -- Auth: admin, or the HR manager of THIS org only.
  -- coalesce(...,false) closes the NULL-logic hole for non-employers.
  if not (is_admin() or coalesce(employer_org() = target_org, false)) then
    raise exception 'not authorised';
  end if;

  select count(*) into n
  from profiles
  where org_id = target_org;

  if n < 5 then
    return json_build_object(
      'suppressed',    true,
      'n_employees',   n,
      'message',       'Too few participants to display aggregates while protecting individual privacy.'
    );
  end if;

  select json_build_object(
    'n_employees',         n,
    'participation_pct',   round(100.0 * count(a.user_id)::numeric / nullif(n, 0), 1),
    'avg_score',           round(avg(a.score)::numeric, 1),
    'avg_by_dimension',    (
      select json_object_agg(dim_key, round(avg_val::numeric, 1))
      from (
        select dim.key as dim_key, avg(dim.value::text::numeric) as avg_val
        from profiles p2
        cross join lateral (
          select * from assessments a3
          where a3.user_id = p2.id
          order by a3.created_at desc
          limit 1
        ) latest
        cross join lateral jsonb_each(latest.cat_scores) as dim(key, value)
        where p2.org_id = target_org
        group by dim.key
      ) dims
    )
  ) into result
  from profiles p
  left join lateral (
    select *
    from assessments a2
    where a2.user_id = p.id
    order by a2.created_at desc
    limit 1
  ) a on true
  where p.org_id = target_org;

  return result;
end;
$$;
