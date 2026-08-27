# 00 — Live schema snapshot

**Taken 25 Aug 2026 against the live Supabase project `tarmpqxsabbehgjaonfz`
(`mogomotsifrance-star's Project`, eu-west-1).** Read-only: nine catalogue SELECTs
from `information_schema` / `pg_catalog`, run through the Supabase MCP connection.
Nothing was created, altered, dropped, granted or revoked. The queries are in
[`tests/live-schema-snapshot.sql`](../../tests/live-schema-snapshot.sql) and can be
re-run in the SQL editor to refresh this file.

**This replaces the graded "applied?" inference in `00-codebase-map.md` §4.**
§10 below is the repo-file-to-live verdict.

> **Engine: PostgreSQL 17.6.1.** The migration discipline in `CLAUDE_CONTEXT.md` §3.2
> and the build preamble both say "tested locally against PostgreSQL 16". Production
> is 17. See §11, F1.

---

## 1. Shape at a glance

| | |
|---|---|
| Public tables | **38** (the data model said 37) |
| RLS | **on for all 38**, none forced |
| Functions in `public` | **111** |
| RLS policies | **77** |
| Triggers (non-internal) | **8** |
| Extensions | 5 — **no `pg_cron`, no `pg_net`** |

---

## 2. Tables, row counts, RLS

All rows below have `rls=on`.

```
admins                     4      org_reports                4
advisor_clients            4      org_units                 11
advisor_notes              3      organizations              3
advisors                   5      pathways                   3
ai_chat_usage             11      points_catalog            16
assessments               31      points_events            177
badges                    30      profiles                  38
bookings                  22      program_activities         1
certificates               3      quiz_attempts              3
checkins                  14      quiz_questions            24
content_items             48      quizzes                    3
content_progress          48      reward_fulfilments         3
emergency_fund            10      reward_thresholds          3
employers                  2      stress_logs               13
hr_unit_scope              0      threshold_config          11
notifications              2      tool_data                138
org_headcount_reports      0      tool_usage_events         56
                                  unit_departments         161
                                  video_watch_credits       17
                                  video_watch_progress      43
                                  webinar_views             16
```

### The three organisations, in detail

```
BOPEU     active  members= 2  bookings= 0  reports=0  units= 0  webinars=0  activities=0
Sedimosa  active  members= 8  bookings= 7  reports=0  units=11  webinars=9  activities=0
Test Co   active  members=22  bookings=13  reports=4  units= 0  webinars=0  activities=1
```

Also: **6 profiles have no `org_id`**, and 2 of the 22 bookings belong to them
(7 + 13 = 20 are attributable to an organisation).

`org_reports` = **3 draft + 1 published**, all four Test Co. `content_items` =
10 webinars (9 Sedimosa, 1 global) + 38 lessons.

---

## 3. Columns

### `bookings` — 24 columns (the M1 target)

```
id                        uuid        NOT NULL  default gen_random_uuid()
user_id                   uuid        null
user_name                 text        null
user_email                text        null
requested_date            text        null          ← text, not date
session_type              text        null          ← M1 reads this
status                    text        null      default 'pending'
created_at                timestamptz null      default now()
service                   text        null
updated_at                timestamptz null
requested_time            text        null          ← text, not time
client_seen_confirmation  boolean     NOT NULL  default false
attended                  boolean     null
attendance_confirmed_by   uuid        null
attendance_confirmed_at   timestamptz null
session_mode              text        null          ← M1 writes this
client_type               text        null      default 'member'
advisor_id                uuid        null
advisor_client_id         uuid        null
booked_by                 text        NOT NULL  default 'member'
member_response           text        null
member_response_at        timestamptz null
member_response_note      text        null
advisor_seen_response     boolean     NOT NULL  default false
```

There is **no `org_id`** on `bookings` — organisation attribution runs through
`profiles.org_id` via `user_id`. There is no `activity_id`, no `notes`, and no
date/time column that is not text.

Live data in the two columns M1 touches:

```
session_type  distinct:  'In-Person'  /  'Individual'  /  'Virtual'
session_mode  distinct:   NULL        /  'physical'
```

### `program_activities` — 10 columns

```
id uuid NOT NULL default gen_random_uuid() · org_id uuid NOT NULL ·
activity_type text NOT NULL · title text NOT NULL · activity_date date NOT NULL ·
attendee_count int NOT NULL · delivery_mode text null · notes text null ·
created_by uuid NOT NULL · created_at timestamptz NOT NULL default now()
```

### `org_reports` — 14 columns

```
id uuid NOT NULL default gen_random_uuid() · org_id uuid NOT NULL ·
period_start date NOT NULL · period_end date NOT NULL · period_label text NOT NULL ·
status text NOT NULL default 'draft' · narrative jsonb NOT NULL default '{}' ·
data_snapshot jsonb null · created_by uuid NOT NULL ·
created_at timestamptz NOT NULL default now() · updated_at timestamptz NOT NULL default now() ·
published_by uuid null · published_at timestamptz null · unit_id uuid null
```

### `content_items` — 15 columns

```
id uuid NOT NULL default gen_random_uuid() · title text NOT NULL ·
pathway_id smallint null · section_label text null · sort_order smallint null ·
video_path text null · poster_path text null · duration_seconds int null ·
created_at timestamptz NOT NULL default now() · kind text NOT NULL default 'lesson' ·
org_id uuid null · description text null · published bool NOT NULL default true ·
webinar_date date null · thumbnail_url text null
```

### Remaining tables

```
admins                 email

advisors               id · user_id · email · full_name · phone · title · is_active ·
                       created_by · created_at · updated_at · is_team_lead

advisor_clients        id · advisor_id · member_user_id · first_name · last_name · email ·
                       phone · org_id · assessment jsonb · source · status · linked_at ·
                       created_by · created_at · updated_at · org_unit_id · no_org · org_mismatch

advisor_notes          id · client_id · advisor_id · booking_id · body · created_at ·
                       updated_at · origin

ai_chat_usage          id · user_id · used_at · input_tokens · output_tokens · cache_read_tokens

assessments            id · user_id · score · cat_scores jsonb · answers jsonb · created_at

badges                 user_id · earned_badge_ids jsonb · points · updated_at · earned jsonb

certificates           id · user_id · pathway_id · certificate_name · completed_on · created_at

checkins               id · user_id · vals jsonb · score · notes · created_at

content_progress       id · user_id · content_id · completed_at

emergency_fund         user_id · monthly · current_savings · contribution · target_months · updated_at

employers              id · user_id · org_id · email · created_at

hr_unit_scope          id · hr_user_id · hr_email · org_id · unit_id · created_at

notifications          id · user_id · type · title · body · created_at · read_at

org_headcount_reports  id · org_id · headcount · reported_by · created_at

org_units              id · org_id · parent_unit_id · name · is_active · sort_order · created_at

organizations          id · name · invite_code · is_active · created_at · program_name ·
                       program_logo_path

pathways               id · title · description · sort_order · status · certificate_level · created_at

points_catalog         event_type · points · active · category

points_events          id · user_id · event_type · ref_id · points · season · created_at

profiles               id · age_group · income_range · employment · goals jsonb · last_score ·
                       last_cat_scores jsonb · joined_at · updated_at · phone · avatar_b64 ·
                       welcome_seen · consent_accepted · consent_date · monthly_income ·
                       monthly_expenses · age · onboarded · first_name · last_name ·
                       badges_earned jsonb · badges_points · gross_income · net_income ·
                       other_income · total_assets · total_liabilities · monthly_debt ·
                       total_savings · monthly_savings · fin_updated_at · essential_expenses ·
                       total_debt_balance · net_is_manual · org_id · leaderboard_opt_in ·
                       display_alias · live_score · live_cat_scores · live_score_at ·
                       org_unit_id · gender · department_id · will_status ·
                       advisor_data_consent · advisor_data_consent_at        (45 columns)

quiz_attempts          id · user_id · quiz_id · score · passed · answers jsonb · created_at
quiz_questions         id · quiz_id · sort_order · section_label · question · options jsonb ·
                       correct_index · created_at
quizzes                id · pathway_id · pass_mark · question_count · created_at

reward_fulfilments     id · org_id · user_id · season · category · note · fulfilled_by · created_at
reward_thresholds      category · first_season_points · returning_points · updated_at

stress_logs            id · user_id · level · tags text[] · notes · created_at
threshold_config       key · value jsonb · updated_at
tool_data              user_id · tool · data jsonb · updated_at
tool_usage_events      id · user_id · tool_key · event_type · created_at
unit_departments       id · unit_id · name · is_active · sort_order · created_at
video_watch_credits    user_id · video_id · quarter · created_at
video_watch_progress   id · user_id · video_id · max_position_seconds · duration_seconds ·
                       completed_at · updated_at
webinar_views          id · webinar_id · user_id · viewed_at
```

---

## 4. Constraints that matter for the build

```
bookings_session_mode_check     CHECK (session_mode = ANY ('{physical,virtual}'))
bookings_booked_by_chk          CHECK (booked_by = ANY ('{member,advisor,admin}'))
bookings_client_type_check      CHECK (client_type = ANY ('{member,dependent}'))
bookings_member_response_chk    CHECK (member_response IS NULL OR member_response = ANY
                                       ('{accepted,declined,reschedule_requested}'))
bookings_pkey / _user_id_fkey / _advisor_id_fkey / _advisor_client_id_fkey /
                _attendance_confirmed_by_fkey

  → there is NO check on bookings.session_type. It is free text, as the data model says.

program_activities_activity_type_check
        CHECK (activity_type = ANY ('{group_intervention,education_talk,webinar,clinic,other}'))
program_activities_delivery_mode_check
        CHECK (delivery_mode = ANY ('{physical,virtual,hybrid}'))
program_activities_attendee_count_check   CHECK (attendee_count >= 0)

org_reports_status_check        CHECK (status = ANY ('{draft,published}'))
content_items_kind_check        CHECK (kind = ANY ('{lesson,webinar}'))

advisor_clients_org_required      CHECK (org_id IS NOT NULL OR no_org)
advisor_clients_unit_needs_org    CHECK (org_unit_id IS NULL OR org_id IS NOT NULL)
advisor_clients_source_check      CHECK (source = ANY ('{advisor_added,admin_assigned,booking_claim}'))
advisor_clients_status_check      CHECK (status = ANY ('{active,archived}'))

points_events_user_id_event_type_ref_id_key   UNIQUE (user_id, event_type, ref_id)
organizations_invite_code_key                 UNIQUE (invite_code)
org_units_org_id_name_key                     UNIQUE (org_id, name)
unit_departments_unit_id_name_key             UNIQUE (unit_id, name)
admins_pkey                                   PRIMARY KEY (email)
```

`admins` is keyed on **email**, not `user_id` — relevant to the M3 admin-split
mechanism (an `admins.lines` column keys off email too).

---

## 5. Functions — the ones the build touches

### Reporting: only **two** `org_report_data` overloads exist

```
org_report_data(p_org_id uuid, p_start date, p_end date)                    -> jsonb  SECDEF
org_report_data(p_org_id uuid, p_start date, p_end date, p_unit_id uuid)    -> jsonb  SECDEF
_org_report_period_data(p_org_id uuid, p_start date, p_end date)            -> jsonb  SECDEF
_org_report_period_data(p_org_id uuid, p_start date, p_end date, p_unit_ids uuid[]) -> jsonb SECDEF
org_report_company_breakdown(p_org_id uuid, p_start date, p_end date)       -> jsonb  SECDEF
org_report_department_breakdown(p_org_id uuid, p_start date, p_end date, p_unit_id uuid) -> jsonb SECDEF
advisor_session_breakdown(p_org_id uuid, p_start date, p_end date)          -> jsonb  SECDEF
session_source_trend(p_org_id uuid, p_start date, p_end date)               -> jsonb  SECDEF
```

The repo's five `org_report_data*.sql` files are a version history; only the latest
DDL is live. **M2 has eight signatures to overload, not six** — `_org_report_period_data`
carries two.

### Role and gate helpers

```
is_admin() · is_advisor() · is_team_lead() · current_advisor_id() · current_member_org() ·
employer_org() · can_manage_advisor(uuid) · hr_scoped_unit_ids() · hr_unit_in_scope(uuid,uuid)
```

All `SECURITY DEFINER`. `is_counsellor()`, `current_counsellor_id()` and
`is_clinical_lead()` do **not** exist — M3 adds them.

### ACL hygiene — the REVOKE rule holds where it was applied

Correctly locked to `{postgres, service_role}` only:

```
_dept_metrics · _org_indicator_counts · _org_indicator_catalogue ·
_org_report_period_data (both) · admin_org_has_dependents · admin_unit_has_dependents ·
learning_qualified · utilisation_qualified
```

The Phase 1a fix is confirmed in effect: `_org_indicator_counts` shows
`{postgres=X/postgres,service_role=X/postgres}` and nothing more.

Two grant conventions coexist. The newer admin RPCs use
`{postgres, authenticated, service_role}` — no `anon`. The older `advisor_*`, `org_*`
and `is_*` functions carry `=X/postgres` (i.e. **PUBLIC**, which includes `anon`).
Those are gated internally, so it is not an exposure — but see §9.

---

## 6. RLS policies — 77, and what M3 must reckon with

### `bookings` carries **nine** policies

```
bookings_admin          ALL     USING (auth.jwt()->>'email') IN (SELECT admins.email FROM admins)
bookings_admin_all      ALL     USING is_admin()
bookings_own            ALL     USING (user_id = auth.uid())
bookings_self           ALL     USING (auth.uid() = user_id)
bookings_advisor_select SELECT  USING (advisor_id = current_advisor_id() OR is_team_lead()
                                       OR EXISTS (SELECT 1 FROM advisor_clients ac
                                                  WHERE ac.advisor_id = current_advisor_id()
                                                    AND (ac.member_user_id = bookings.user_id
                                                      OR ac.id = bookings.advisor_client_id)))
bookings_advisor_insert INSERT  CHECK (advisor_id = current_advisor_id() AND booked_by = 'advisor')
bookings_advisor_update UPDATE  USING (advisor_id = current_advisor_id())
bookings_lead_update    UPDATE  USING is_team_lead()
bookings_member_respond UPDATE  USING (user_id = auth.uid())
```

**All four "legacy" policies are live.** Their predicates are now captured above, which
is what M3 needed — the repo held them only as prose at
`supabase_org_account_phase0.sql:656-677`.

`bookings_advisor_select` matches `supabase_advisor_team_lead.sql:108-123` exactly, so
the team-lead rewrite is the live version.

Note `bookings_admin` compares `auth.jwt()->>'email'` to `admins.email` **without
`lower()`**, while `admins_read` and `is_admin()` both use `lower()`. A mixed-case
address satisfies one and not the other.

### HR has no row read on `bookings`

Confirmed — no HR policy on `bookings` at all. The aggregate-only rule holds as long as
psychosocial figures go only through the suppressed RPC path.

### Other policies of note

```
admins       admins_read          SELECT  lower(email) = lower(auth.jwt()->>'email')   (self only)
org_reports  org_reports_hr_read  SELECT  status='published' AND org_id = employer_org()
org_units    org_units_read       SELECT  is_active AND (org_id = current_member_org()
                                          OR org_id = employer_org() OR is_admin())
content_items content_items_readable SELECT kind='lesson' OR (kind='webinar' AND published
                                          AND (org_id IS NULL OR org_id = <caller's profile org>))
advisor_notes advisor_notes_admin_all ALL  is_admin()      ← the asymmetry M3 deliberately breaks
program_activities program_activities_admin_all ALL is_admin()   ← admin-only; no HR read
```

`stress_logs` carries four policies where two would do — `stress_logs_self` (ALL)
duplicates the three "Users can …" policies.

---

## 7. Triggers — 8

```
advisor_clients  trg_link_advisor_client      BEFORE INSERT OR UPDATE OF email, member_user_id
advisor_clients  trg_validate_client_unit     BEFORE INSERT OR UPDATE OF org_unit_id, org_id
bookings         trg_award_session_attended   AFTER UPDATE
notifications    trg_guard_notification_update BEFORE UPDATE
profiles         trg_lock_org_id              BEFORE UPDATE
profiles         trg_lock_org_unit_id         BEFORE UPDATE
profiles         trg_lock_profile_dims        BEFORE UPDATE
profiles         trg_sync_advisor_client_org  AFTER INSERT OR UPDATE OF org_id, org_unit_id
```

`trg_award_session_attended` fires on **every** `UPDATE` of `bookings`, which M1's
backfill will do 22 times. Its body:

```sql
if new.attended is true
   and (old.attended is distinct from true)
   and new.user_id is not null then
  insert into points_events (...) ... on conflict do nothing;
end if;
```

It is guarded on an `attended` transition, so a backfill that does not touch `attended`
awards nothing — and `points_events` has a `UNIQUE (user_id, event_type, ref_id)` as a
second line of defence. **Safe, but M1's test should assert `points_events` count is
unchanged**, because the guard is the only thing standing between a column backfill and
177 rows of points becoming more.

---

## 8. Extensions and configuration

```
pg_stat_statements 1.11 · pgcrypto 1.3 · plpgsql 1.0 · supabase_vault 0.3.1 · uuid-ossp 1.1
```

**`pg_cron` is not installed. Neither is `pg_net`.** See §11, F2.

`threshold_config`, all 11 rows:

```
budget_months_required            3
checkin_windows_required          6
sessions_attended_required        1
learning_library_fraction         0.3333
indicator.low_base                5          ← the base-5 floor M2 reuses
indicator.dimension_flag_below    40
indicator.emergency_months_floor  1
indicator.high_cost_credit_rate   20
indicator.savings_rate_floor_pct  10
indicator.dti                     {bands: healthy<20, manageable<35, strained<45, over_indebted}
panel3.headline                   {row_1, row_2, callout, labels}
```

No `capacity.*` keys yet — M7 adds them here rather than in a new table.

---

## 9. The ungated `SECURITY DEFINER` sweep

`CLAUDE.md`'s sweep returns **five rows, not zero**:

```
kw_dti_band(p_dti numeric)
kw_is_over_indebted(p_dti numeric)
kw_threshold(p_key text)
kw_unit_label(p_unit_id uuid)
verify_invite_code(p_code text)
```

Assessed one by one:

| Function | Reads | Verdict |
|---|---|---|
| `kw_dti_band` | nothing | **Fine.** `CLAUDE.md` names it as an acceptable pure helper |
| `kw_is_over_indebted` | nothing | **Fine.** Same |
| `kw_threshold` | `threshold_config` | **Fine.** Config, not personal data; already documented as acceptable |
| `kw_unit_label` | `org_units` | **Review.** Anon-callable; returns "Company — Site" for a unit id. Not personal data, but it is client structure, and it is not on the documented allow-list |
| `verify_invite_code` | `organizations` | **By design.** Signup happens before an account exists, so it must be anon-callable. It is a brute-force oracle for invite codes by construction; the only limit is the API gateway's |

No `_`-prefixed helper is exposed. The Phase 1a lock held, and no phase since has
reintroduced the problem.

---

## 10. Repo SQL files against live — replacing the "applied?" inference

**Confirmed applied** (an object it creates exists live with a matching shape):

```
multitenancy · fix_employers_pk · employer_email · org_units · org_units_hr_scope ·
sedimosa_phase2_batch1 · verify_invite_code · org_reports · program_activities ·
publish_org_report · org_report_data_v5_departments · suppress_count_bigint_fix ·
org_stress_summary · financial_indicators · live_wellness · utilisation_rpcs ·
points_ledger · points_integrity_fix · rewards_categories · reward_thresholds ·
rewards_reshape · reward_fulfilment · my_reward_fulfilments · org_headcount ·
org_rewards_v2 · org_rewards_stress_scoped · drop_leaderboard · lms_storage ·
lms_schema · lms_rpcs · lms_pathway1_update · lms_pathway2_* · lms_pathway3_* ·
learn_intro_video · webinars_thresholds_schema · webinar_learning_rpcs ·
webinar_thumbnails · advisor_portal · advisor_rpcs · advisor_team_lead · advisor_ux ·
fix_france_advisor · admin_orgs_rpcs · admin_units_rpcs · admin_depts_rpcs ·
admin_roles_rpcs · hr_france_sedimosa · org_account_phase0 · phase0a_picker ·
phase1_indicators · phase1a_lock_internal_helpers · ai_chat_usage ·
bookings_missing_columns · booking_notify_payload · rls_admins_self_read · seed_test_org
```

**Applied but superseded** — the file ran, a later file replaced its functions; only
the newest DDL is live:

```
org_report_data.sql (v1) · _v2 · _v3 · _v4        → superseded by v5_departments
employer_dashboard · org_overview_fix · org_overview_scoped · fix_org_overview_authz
                                                   → one org_overview(target_org) survives
leaderboard · leaderboard_optin                    → functions dropped by drop_leaderboard.sql
                                                     (profiles.leaderboard_opt_in and
                                                      display_alias columns remain)
advisor_portal's bookings_advisor_select           → replaced by advisor_team_lead's
```

**NOT applied:**

```
supabase_cleanup_policies.sql   — it drops legacy duplicate policies, and all four
                                  bookings duplicates are still live. C12 resolved:
                                  it never ran, or ran before they were recreated.
```

**Read-only, never "applied":**

```
verify · verify_org_units · inspect_policies · diagnose_magiclink ·
diagnose_magiclink_logs_explorer
```

---

## 11. Findings that change the build

### F1 — Production is PostgreSQL 17.6; the test discipline says 16

`tests/run-phase0.sh` and the build preamble both target PG16. Every migration from M1
on will be validated against a major version older than the one it lands on. The gap is
not academic for this work: PG17 changed `MERGE`, `COPY`, and several catalogue views,
and RLS plan behaviour differs in edge cases.

**Recommendation:** move the local harness to PostgreSQL 17 before M1. It is a one-line
change to the container/initdb step in `run-phase0.sh`, and it costs nothing now.
`CLAUDE_CONTEXT.md` §3.2 should be corrected at the same time.

### F2 — `pg_cron` is not installed, so M5 and M4 have no scheduler

Prompt 2 asks for a recommendation between `pg_cron` and an Edge Function for the
action reminders, and Prompt 5 needs the same for the 1st-of-month invoice rows. The
answer is now constrained by fact rather than preference: **there is no `pg_cron` and no
`pg_net` in this project.** Options are (a) enable `pg_cron` from the Supabase dashboard
— available on this plan, one-time, and it must be recorded as a manual deploy step
since Claude does not apply anything; or (b) an Edge Function invoked by an external
scheduler. The double-fire question Prompt 2 raises is answered the same way either
way: make the writer idempotent on `(action_id, remind_at)`.

### F3 — The M1 test fixture cannot test M1

`tests/phase0-fixture.sql` defines `bookings` with **10** columns. Live has **24**. The
fixture is missing:

```
user_name · user_email · session_type · service · updated_at · requested_time ·
client_seen_confirmation · attendance_confirmed_by · attendance_confirmed_at ·
session_mode · client_type · member_response_at · member_response_note ·
advisor_seen_response
```

**`session_type` and `session_mode` — the two columns M1 exists to migrate — are both
absent.** Prompt 1's instruction to build the fixture from this snapshot rather than
from `phase0-fixture.sql` is not a precaution; without it M1's migration path is
untestable. The fixture is also missing every `bookings` CHECK constraint, including
`bookings_session_mode_check`, which is what makes the mode normalisation mandatory
rather than cosmetic.

### F4 — M1's `session_type` mapping, against the real values

```
'In-Person'   → session_mode 'physical'    (a mode)
'Virtual'     → session_mode 'virtual'     (a mode)
'Individual'  → no mode; it is a format    (leave session_mode null)
```

`session_mode` is currently `NULL` or `'physical'` only, so the backfill has real work
to do, and `bookings_session_mode_check` will reject anything not normalised to
`physical`/`virtual`. All 22 rows get `session_format = 'one_on_one'`.

### F5 — M2 has eight signatures, not six

`_org_report_period_data` carries two overloads and
`org_report_department_breakdown` takes four arguments, not three. Full list in §5.

### F6 — Permissive policies OR together, so M3 cannot exclude France by rewriting one policy

This is the finding that most changes Prompt 7. `bookings` has **four** ALL-command
policies that each grant broad access — `bookings_admin`, `bookings_admin_all`,
`bookings_own`, `bookings_self`. PostgreSQL ORs permissive policies together, so access
is the **union**. Rewriting `bookings_advisor_select` to split by service line achieves
nothing while `bookings_admin_all` (`USING is_admin()`) still grants France every row
through a different policy.

M3 must therefore **replace `bookings_admin` and `bookings_admin_all` outright** with a
line-aware admin policy, not merely add one. The plan's proposed mechanism
(`admins.lines`, `ops_admins`, or `is_ops_admin()`) has to be wired into whatever
replaces those two — and the migration has to drop them in the same transaction that
creates the replacement, or there is a window where the boundary is open.

`bookings_own` / `bookings_self` are harmless duplicates of each other (members reading
their own rows), but they are `ALL`, not `SELECT`, which is worth tightening while the
file is open.

### F7 — The base for a psychosocial pilot is thin

Sedimosa is the only organisation with units (11) and webinars (9), and has 7 bookings.
Test Co owns every report but is a test organisation to be hidden from ops lists. BOPEU
has 2 members and no activity at all. `program_activities` has **one** row, org-wide.

M1's regression test therefore proves less than it sounds: for two of three
organisations `org_report_data()` is counting almost nothing, and three of the four
Test Co reports are still `draft`, so their figures are not frozen snapshots. Worth
capturing the before-figures anyway, but the real regression signal will come from
Sedimosa.

### F8 — Two grant conventions, and one function worth a second look

Newer admin RPCs grant `{postgres, authenticated, service_role}`; older ones grant
PUBLIC (which includes `anon`). Both are gated internally so neither is an exposure
today, but the older convention means a future edit that drops an internal gate becomes
an anon-reachable read immediately. Worth normalising opportunistically.

`kw_unit_label(uuid)` (§9) is the one genuinely ungated function that touches a table.
Low severity — it needs a valid unit uuid and returns only names — but it is
anon-callable and not on the documented allow-list. Either add a gate or add it to the
allow-list in `CLAUDE.md` with the reasoning.
