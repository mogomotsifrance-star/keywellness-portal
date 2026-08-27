-- Key Wellness — M4 baseline, captured BEFORE the migration.
-- Separate file because the runner needs it as its own psql invocation and a
-- heredoc inside the harness fights with the quoting in the SQL.

set session "test.email" = 'admin@keywellness.co.bw';

drop table if exists m4_baseline;
create table m4_baseline (
  org_id       uuid,
  org_name     text,
  label        text,
  period_start date,
  period_end   date,
  payload      jsonb
);

-- The REAL org_report_data(), on the same three windows M1's regression uses.
insert into m4_baseline (org_id, org_name, label, period_start, period_end, payload)
select o.id, o.name, p.label, p.s, p.e, org_report_data(o.id, p.s, p.e)
  from organizations o
 cross join (values ('Q1 2026',      date '2026-01-01', date '2026-03-31'),
                    ('Q3 2026',      date '2026-07-01', date '2026-09-30'),
                    ('Apr-Jun 2026', date '2026-04-01', date '2026-06-30'))
              as p(label, s, e);

drop table if exists m4_counts;
create table m4_counts (k text primary key, n bigint);
insert into m4_counts values
  ('program_activities', (select count(*) from program_activities)),
  ('bookings',           (select count(*) from bookings)),
  ('points_events',      (select count(*) from points_events)),
  ('actions',            (select count(*) from actions));
