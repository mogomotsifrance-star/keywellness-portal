-- Proves the can_manage_advisor() NULL hole and the fix. Run by tests/run-can-manage-fix.sh.
\set ON_ERROR_STOP on
\set QUIET on
create or replace function t_as(p_uid text, p_email text) returns void language sql as $$
  select set_config('test.uid', p_uid, false), set_config('test.email', p_email, false) $$;
create or replace function t_check(p_name text, p_ok boolean) returns void language plpgsql as $$
begin if p_ok then raise notice 'PASS  %', p_name; else raise exception 'FAIL  %', p_name; end if; end $$;
grant execute on function t_as(text,text), t_check(text,boolean) to authenticated;
set role authenticated;
select t_as('a0000000-0000-4000-8000-000000000004', 'member@example.test');
\if :fixed
select t_check('fixed: a member gets FALSE from can_manage_advisor()', can_manage_advisor('b0000000-0000-4000-8000-000000000001') is false);
do $$ begin
  begin
    perform advance_recommendation_create('c0000000-0000-4000-8000-000000000001', '{}'::jsonb, '{"tier":"RED"}'::jsonb, null, '{}'::jsonb, '[]'::jsonb, null, null, null, 'model');
    raise exception 'FAIL  fixed: a member could still generate an Advance Recommendation';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  fixed: a member is refused by advance_recommendation_create (%)', sqlerrm;
  end;
end $$;
\else
select t_check('before the fix: a member gets NULL (not false) from can_manage_advisor()', can_manage_advisor('b0000000-0000-4000-8000-000000000001') is null);
select t_check('before the fix: the hole is real — a member CAN generate an Advance Recommendation for their own record',
  (advance_recommendation_create('c0000000-0000-4000-8000-000000000001', '{}'::jsonb, '{"tier":"RED"}'::jsonb, null, '{}'::jsonb, '[]'::jsonb, null, null, null, 'model'))->>'status' = 'draft');
reset role;
delete from advance_recommendations;
\endif
reset role;
