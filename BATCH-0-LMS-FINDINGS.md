# Batch 0 — LMS Discovery Findings (Video Pathways, Quizzes, Prolearn Certificates)

Read-only batch. No schema, RPC, or frontend changes made. Investigated via:
`supabase link` + REST introspection against the live project (anon key, GET/POST-less
probes only — `supabase db dump`/`query` both require Docker, unavailable in this
environment, so table existence was confirmed via PostgREST's `PGRST205` "relation not
in schema cache" error, which is unambiguous and does not depend on RLS), plus reading
`index.html`, `kw-badges.js`, and every `supabase_*.sql` file in the repo.

This file is separate from the existing (untracked) `BATCH-0-FINDINGS.md`, which is the
output of a *different, unrelated* workstream (email domain bugs, signup 500s, booking
calendar) — that file was not touched or overwritten.

---

## GO/NO-GO verdict: **hold — one gate condition is literally triggered, but it's fixable, not fatal**

Per this batch's own rule: *"Stop and report if … (b) `content_items`/`content_progress`
don't exist or have conflicting columns."* They don't exist at all (confirmed below) —
so, by the letter of the rule, this is a stop. In practice this is a **premise
correction, not a blocker**: Batch 2's plan assumed it could `ALTER TABLE content_items
ADD COLUMN pathway_id …`; instead it needs to `CREATE TABLE content_items (...)` from
scratch. No data is at risk (there's nothing to migrate out of a table that isn't
there) and nothing else in the plan depends on prior `content_items` rows. Recommend:
**proceed to Batch 1/2 with the DDL corrected from ALTER to CREATE**, once the two real
open decisions below are settled.

---

## 1. Learn page inventory — current architecture is materially different from the brief's assumption

- **No `content_items`/`content_progress` tables anywhere.** The Learn page is two
  hardcoded JS arrays baked directly into `index.html`:
  - `CONTENT` ([index.html:2787](index.html:2787)) — 14 articles, plain objects
    (`cat/icon/title/desc`), rendered client-side, no DB backing at all (article "read"
    state is Supabase-backed via `tool_data`, see below, but article *content* is
    static JS).
  - `VIDEOS` ([index.html:2685](index.html:2685)) — **8 existing video modules**
    (`welcome, budget, credit, emfund, retire, investing, stress, insurance`), each a
    YouTube (`yt`) or Vimeo (`vimeo`) **embed ID**, not a Supabase Storage file. Only
    `welcome` and `budget` currently have a real embed attached; the other 6 render a
    "Coming Soon" placeholder.
- **Sequential unlock and Supabase-backed progress already exist for videos** — this
  part of the brief's assumption is *correct*, just implemented differently than
  expected:
  - Progress lives in a generic key-value table `tool_data(user_id, tool, data jsonb)`
    under `tool='video_progress'`, data shape `{completed:[videoId,...]}` — loaded by
    `loadVideoProgress()` / written by `saveVideoProgress()`
    ([index.html:2697-2713](index.html:2697)).
  - Unlock logic: `i === 0 || _done.includes(VIDEOS[i-1].id)`
    ([index.html:2856](index.html:2856)) — index-order sequential, same rule the brief
    wants for the new pathways.
  - Completion trigger: **already `ended` event**, not an honour click —
    `Vimeo.Player.on('ended', ...)` / `YT.PlayerState.ENDED`
    ([index.html:2754-2781](index.html:2754)) call `window.markVideoComplete(vidId, pts)`.
- **`kw_watched` localStorage + honour-system button is dead code, not live.**
  `window.markVideoWatched` ([index.html:4436](index.html:4436)) reads/writes
  `localStorage['kw_watched']` and calls `KWBadges.recordPoints('video_watched', ...)`
  directly — but **it is never called from anywhere in the repo** (grepped, zero call
  sites). It appears to be a superseded first draft, left in place. Locked Decision #2
  says to retire it "in the same batch" as the `content_items`/RPC work — since it's
  already inert, this is a pure deletion with zero behavior change, safe to do any time.
- Points for videos already flow through the real ledger (`markVideoComplete` →
  `KWBadges.recordPoints('video_watched', vidId)` → `award_points()` RPC), **not** a
  client-side tally. This is the correct target pattern for the new `complete_video()`
  RPC to extend, not replace.

**Scope implication for Batch 4**: "rebuild the Learn → Videos section" per the brief
means the new pathway UI **replaces** this existing 8-module `VIDEOS` array/embed system
outright (its content is subsumed into Pathway 1 + the standalone welcome video, now
Supabase-Storage-hosted instead of YouTube/Vimeo-embedded). Flagging this explicitly
since it means real content currently live for users (the `welcome` and `budget`
Vimeo embeds) gets replaced, not augmented — confirm this is the intended scope before
Batch 4 deletes `VIDEOS`/`_attachVideoPlayers`/the Vimeo+YouTube iframe API loaders.

---

## 2. `content_items` / `content_progress` — confirmed absent (schema-cache probe)

REST introspection with the anon key (`GET /rest/v1/<table>?select=*&limit=1`) distinguishes
"table doesn't exist" (`PGRST205`) from "table exists, RLS blocks you" (empty `200 []`
or a permission error) unambiguously. Results:

| Table | Result |
|---|---|
| `content_items` | **404 `PGRST205`** — not in schema cache |
| `content_progress` | **404 `PGRST205`** — not in schema cache |
| `pathways` | 404 — confirms no naming collision |
| `quizzes` | 404 — confirms no naming collision |
| `quiz_questions` | 404 — confirms no naming collision |
| `quiz_attempts` | 404 — confirms no naming collision |
| `certificates` | 404 — confirms no naming collision |
| `profiles`, `badges`, `points_events` | 200 `[]` — exist, anon-readable-or-RLS-empty as expected |

No naming collisions anywhere (condition c is clear). Condition (b) is the only gate
hit, and per the section above it's a DDL-shape correction, not a redesign.

---

## 3. `award_points()` RPC — signature confirmed, plus two things the brief didn't anticipate

**Signature** (`supabase_points_ledger.sql`, live and in use today):
```sql
award_points(p_event_type text, p_ref_id text) returns json
-- → {"awarded": bool, "points": int, "total": bigint}
```
No `category` parameter — category is a fixed attribute of the event *type*, stored as
a column on `points_catalog` (added later by `supabase_rewards_categories.sql`):
`category in ('utilisation','learning','progress','private')`.

**Finding A — the "Learning" wiring already exists and is pre-provisioned for this exact
feature.** `points_catalog` already has:

| event_type | points | category |
|---|---|---|
| `article_read` | 15 | learning |
| `video_watched` | **25** | learning |
| `quiz_passed` | **50** | learning |

`video_watched` at 25 matches Locked Decision #7 (+25/video) exactly — reuse as-is, no
catalog change needed for `complete_video()`.

**`quiz_passed` conflicts with Locked Decision #7's "+75 on first quiz pass"** — the
catalog already has it at 50. Nothing in the live codebase currently *emits*
`quiz_passed` (grepped: zero `recordPoints('quiz_passed', ...)` call sites), so it looks
like this row was seeded in anticipation of this exact build and nobody has used it yet
— changing it from 50→75 is safe (no historical events to reconcile). **Needs a decision
either way** since it's a real, already-live value, not a guess: keep 50 (match what's
already provisioned) or bump to 75 (match this brief).

**Finding B — `quiz_passed` is already consumed by the HR report.**
`org_report_data(_v2).sql`'s Learning section already counts distinct users per
`event_type = 'quiz_passed'` / `'video_watched'` / `'article_read'` (suppressed
small-cohort counts, no per-member rows — this **is** the Batch 0 point 7 baseline, and
it stays structurally unchanged; it just starts returning non-zero numbers once this
ships, which is expected and correct, not a leak).

**Finding C — admin exclusion is client-side only, today.** `KWBadges.recordPoints()`
checks `if (global._isAdmin) return null` **before** calling the RPC
([kw-badges.js:359](kw-badges.js:359)) — `award_points()` itself has no server-side admin
check. An `admins` table does exist (`admins(email)`, looked up by email —
[index.html:872](index.html:872)) and is queryable inside a `SECURITY DEFINER` function,
so `complete_video()`/`submit_quiz()` **can** implement Locked Decision #7's "admin
accounts never generate points events" as a real server-side guarantee (join
`auth.users`→`admins` on email inside the RPC) rather than trusting the client flag —
recommend doing this properly for the new RPCs even though the existing one doesn't.

**Finding D — this is a real, confirmed load-bearing risk for Batch 5 point 3.**
`reward_thresholds` (`supabase_reward_thresholds.sql`) already has:
```
('learning', first_season_points=500, returning_points=150)
```
with an existing code comment: *"returning value MUST be reviewed each season against
new content published."* Pathway 1 alone injects up to `15×25 + 50(or 75) = 425–450`
points — 3× the returning-member Learning threshold. This isn't speculative, it's
already sitting in the live schema waiting to be blown past. Confirms Batch 5 point 3
verbatim; escalate before shipping Batch 4, not after.

---

## 4. Profile name fields for certificate pre-fill

`profiles` has `first_name` / `last_name` (both used live, e.g.
[index.html:4406-4408](index.html:4406)). **No `display_name` column** — confirmed via a
direct REST probe (`column profiles.display_name does not exist`, error `42703`). Use
the same concatenation the app already does elsewhere: `last_name ? \`${first_name}
${last_name}\` : first_name`.

---

## 5. Storage buckets

`GET /storage/v1/bucket` (anon key) returns **`[]` — zero buckets exist in this project,
not just `videos`.** Consistent with the brief's expectation ("not yet uploaded"), but
slightly broader: there is currently no storage infrastructure at all, so Batch 1 is
creating the very first bucket for this project, not adding one alongside existing
ones. No blocker — just note there's no precedent bucket-policy pattern to copy from
inside this project.

---

## 6. Prolearn certificate assets

- `prolearn-logo.png`, `prolearn-signature.png`: **not present anywhere in the repo**
  (only `assets/img/kw-icon.png` and `assets/img/kw-logo-horizontal.png` exist).
- `prolearn-certificate-preview.html` (referenced by the brief as "the recreation
  delivered alongside this prompt"): **not present in the repo and was not attached to
  this conversation.** The brief itself anticipates the asset case ("if absent, flag in
  BUILD-NOTES and proceed with the SVG template referencing the expected paths") but
  doesn't have a fallback for the *template file* being missing too — Batch 4 cannot
  faithfully "match" a preview it doesn't have. Needs Tshenolo to supply either the
  actual template file/screenshot or a description precise enough to recreate (wave
  header layout, medallion/ribbon placement, exact fonts) before Batch 4 builds the
  certificate SVG.

---

## 7. HR baseline (org_overview / org_report_data)

- `org_overview()` (`supabase_org_overview_fix.sql` + related): grepped for
  `learning|video|quiz` — **zero matches**. No per-member or aggregate learning data
  surfaces there today.
- `org_report_data()` / `_v2()`: aggregate Learning section already exists (see Finding
  B above) — this **is** the pre-existing baseline, already correctly shaped (suppressed
  distinct-user counts, no per-member rows). Nothing to change structurally; it will
  just start reporting real numbers once `video_watched`/`quiz_passed` events flow from
  the new RPCs. Re-confirm output shape unchanged after Batch 3 lands (quick sanity
  query, not a code change).
- Note: `supabase_org_report_data_v2.sql` has an **unrelated uncommitted fix in
  progress** (`git diff` shows a column-ambiguity bug fix in `demographics_cross`,
  nothing to do with learning/video/quiz) — not touched, flagging only so it isn't
  confused with LMS-related changes if this file gets modified again in Batch 3.

---

## Two decisions needed before Batch 1 proceeds

1. **`quiz_passed` points: keep the already-provisioned 50, or change to the brief's
   75?** Either is safe (nothing has emitted this event yet), but it's a real existing
   value, not a placeholder — pick one deliberately.
2. **Confirm full replacement of the existing 8-module `VIDEOS` array** (including the
   two live Vimeo embeds, `welcome` and `budget`) **by the new pathway system**, per
   Batch 4's "retire the hardcoded video array remnants." If instead the old modules
   should stay reachable somewhere (e.g. as an archive), that changes Batch 4's scope.

Everything else above is either already resolved by the brief's own contingency
language (Prolearn assets, empty storage) or a straightforward DDL correction (create
vs. alter `content_items`/`content_progress`) that doesn't need a decision to proceed.

---

## Decisions (confirmed by Tshenolo, 2026-07-10)

1. **`quiz_passed` stays at 50 points** (the already-provisioned catalog value). No
   `points_catalog` change needed — `submit_quiz()` calls `award_points('quiz_passed',
   quiz_id)` and gets 50 as-is.
2. **Full replacement confirmed.** The existing `VIDEOS` array (8 modules, 2 live —
   `welcome`, `budget`), its Vimeo/YouTube embed/player code, and the `tool_data
   ='video_progress'` row are retired outright in Batch 4. No archive/legacy view.

**GO** — proceeding to Batch 1 (storage bucket) with `content_items`/`content_progress`
created fresh (not altered) in Batch 2.
