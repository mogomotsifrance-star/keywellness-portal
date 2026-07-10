-- Inspect the legacy policies flagged by check 15.
-- We need to see their USING / WITH CHECK clauses to know if they leak.
select
  tablename,
  policyname,
  cmd                       as command,
  roles,
  qual                      as using_clause,
  with_check                as with_check_clause
from pg_policies
where schemaname = 'public'
  and tablename in ('assessments','checkins','badges','emergency_fund','profiles')
order by tablename, policyname;
