# Batch 0 — Webinar Thumbnails + Admin Editing: Read-Only Discovery

Zero writes. GO/NO-GO gate for the "Vimeo Thumbnails + Admin Webinar Editing"
addendum. Evidence gathered against the current `dev` tree + live oEmbed endpoint.

**Verdict: GO**, with one schema-model correction and one live-test that needs
Tshenolo (see "Blocking inputs" at the bottom). Path recommendation:
**oEmbed-primary is viable *client-side*** (CORS confirmed), but the embed-only
behaviour is unverified, so the manual fallback (path b) must be built regardless
— exactly as the prompt already mandates.

---

## 0.1 — "Webinars table" does NOT exist. It's `content_items` with `kind='webinar'`.

The addendum repeatedly says "the webinars table". There is no such table. Per the
locked 2026-07-14 MD decision (memory: webinars-vimeo-hosting), webinars are rows in
the existing **`content_items`** LMS table, distinguished by `kind='webinar'`, with
the Vimeo reference stored in **`video_path`** (`'<id>'` or `'<id>/<privacy-hash>'`).

Consequence: the migration adds `thumbnail_url` to **`content_items`**, not to a
`webinars` table. This is an adaptation, not a blocker — every "webinars table"
instruction maps cleanly onto `content_items where kind='webinar'`.

Relevant columns already on `content_items` (kind='webinar' rows):
`id, title, description, org_id, video_path, duration_seconds, published,
webinar_date, pathway_id, section_label, sort_order, created_at`.

## 0.2 — Schema state: `webinar_date` EXISTS; `thumbnail_url` does NOT.

- `webinar_date date` was added by `supabase_sedimosa_phase2_batch1.sql:91`
  (`add column if not exists webinar_date date`) — this is the combined prompt's
  "Batch 7" work. It is **committed** (commits `3c218a7`, `c2a0168`) and the live
  frontend already depends on it (admin.html:462, index.html:3698). So the edit
  modal does NOT need to add `webinar_date` — it already exists.
- **No `thumbnail_url` column anywhere.** Grep across all `*.sql` + both HTML files:
  zero hits. This is the one column Batch 1 must add.
- Batch 7 is **fully applied/committed, NOT mid-flight** → no collision risk. The
  prompt's "STOP if Batch 7 is partially applied" condition does not trigger.

Migration lineage to mirror for the new column (additive, `if not exists`):
`alter table public.content_items add column if not exists thumbnail_url text;`
Rollback: `alter table public.content_items drop column if exists thumbnail_url;`

## 0.3 — oEmbed live test (public videos): WORKS, width-controllable.

`GET https://vimeo.com/api/oembed.json?url=https://vimeo.com/<id>&width=640` returns:
- `thumbnail_url` — a `i.vimeocdn.com/video/...-d_640` image, **640×360 (16:9)**.
- `thumbnail_width` / `thumbnail_height` — echo the served size.
- `thumbnail_url_with_play_button` — same image with a Vimeo play overlay baked in.
- Requested size is controlled by the **`width` query param** (echoed back as
  `_640`). We should request `width=640` (or larger) rather than accept the small
  default. Only use URLs the API actually returns — never fabricate CDN patterns.

Tested live against 2 current public videos (347119375, 259411563) — both returned
correct 16:9 thumbnails. A deleted ID returns `404 Not Found` (plain text, not JSON)
— the fetch code must treat non-200 / non-JSON as "no thumbnail", not crash.

## 0.4 — CORS: oEmbed is browser-fetchable. Client-side path (a) is viable.

`access-control-allow-origin: *` on the oEmbed response (tested with
`Origin: https://mogomotsifrance-star.github.io`). This is the key finding that
un-blocks the design: the admin form can fetch oEmbed **directly from the browser**
in admin.html — no Edge Function, no server round-trip needed for path (a). Backfill
(2.2) can likewise run from an admin browser console/one-off, or be recorded as
individual UPDATEs.

## 0.5 — Embed-only privacy behaviour: UNVERIFIED (cannot test from here).

The decisive question — does oEmbed return a thumbnail for THIS account's
*embed-only / hidden-from-Vimeo* videos — could **not** be tested, because:
- I have no DB credentials in this environment (memory: supabase-apply-workflow), so
  I cannot read a real stored `video_path` to test against.
- Public-video oEmbed working tells us nothing about embed-only behaviour; the
  addendum itself flags oEmbed as "INCONSISTENT for embed-only videos".
- The `id/hash` URL form returns 200 for public videos even with a wrong hash (Vimeo
  ignores the hash when the video is public) — so that test is not informative about
  the private case either.

→ This is why the manual thumbnail input (path b) is not optional. Build both.

## 0.6 — Admin surface (where editing/upload lives).

`admin.html` → `renderWebinars()` (admin.html:458). Sidebar "Org Webinars" view.
- Load: `sb.from('content_items').select('id,title,description,org_id,video_path,
  duration_seconds,published,webinar_date,created_at').eq('kind','webinar')`
  ordered by `webinar_date desc, created_at desc`. **This explicit column list must
  gain `thumbnail_url`** (Batch 3) — unlike the member side (see 0.8).
- Create: `createWebinar()` (admin.html:532) → `sb.from('content_items').insert({...
  kind:'webinar', published:false, webinar_date, ...})`. Requires title + Vimeo ref
  + date. `parseVimeoRef()` (admin.html:517) normalises to `id` / `id/hash`.
- Publish toggle: `toggleWebinarPublished()` (admin.html:576).
- Inline date edit already exists: `updateWebinarDate()` (admin.html:588) — the
  pattern to extend into a full edit modal (title/desc/category/URL/date/thumbnail).
- **There is currently NO full-metadata edit** (only inline date + publish toggle),
  and **no delete** — consistent with the addendum's "editing only, no deletion".
- Note: `content_items` has no `category` column. The addendum's edit-modal
  "category" maps to the existing `section_label` (nullable, currently null for
  webinars) or should be dropped from the modal. Flag for decision.

## 0.7 — Admin write authorization (RLS). No pre-existing member hole.

`content_items` has exactly two policies (supabase_webinars_thresholds_schema.sql):
- `content_items_readable` — SELECT; lessons to all, webinars only when
  `published AND (org_id is null OR org_id = my org)`.
- `content_items_admin_all` — `FOR ALL TO authenticated USING (is_admin()) WITH
  CHECK (is_admin())`. **This is the admin-only UPDATE path** Batch 1.3 asks to
  confirm — it exists, via the `is_admin()` helper. Members have **no** INSERT/
  UPDATE/DELETE policy on `content_items` → Batch 1's "member cannot UPDATE" holds
  by construction. No papering-over needed.

## 0.8 — Member rendering (where the poster slots in).

- Load: `sb.from('content_items').select('*')` (index.html:3734) → `select('*')`
  means **`thumbnail_url` flows in automatically; no member-side query change**.
- `renderWebinarsSection()` (index.html:3952) builds two surfaces:
  - **Spotlight** ("★ LATEST WEBINAR", newest by `webinar_date`) — `.lp-ws-art`
    containing `kwPoster(s, 640)` (index.html:3993).
  - **Grid cards** ("Previous Webinars") — `.lp-lc-art` containing `kwPoster(w,320)`
    (index.html:3971).
- **Spotlight already exists** (Batch 7). This addendum integrates with it.
- Current poster = `kwPoster()` (js/kw-lms-posters.js) — a generated SVG. Webinar
  titles don't match the lesson thumb-art keys, so webinars currently fall to the
  "glass" placeholder (welcome-door illo). **That generated SVG is the exact
  null/broken-thumbnail fallback** Batch 4 needs: render `<img src=thumbnail_url>`
  when present, `onerror` → swap to the `kwPoster()` SVG. Both are 16:9 (320×180 /
  640×360) so there's no layout shift.
- Playback is untouched: `lpOpenWebinar()` (index.html:4180) swaps the poster for the
  Vimeo embed on click. We only add the poster image; we do not touch embed logic.

## 0.9 — Inventory: UNAVAILABLE from here.

Row count and the list of stored `video_path` values (for the 2.2 backfill) require a
DB query I can't run (no credentials). Needs Tshenolo (query below).

---

## Blocking inputs needed from Tshenolo before Batch 1+

1. **One real stored webinar reference** (or run the query) so oEmbed can be tested
   against the *actual* embed-only privacy setting — this decides whether path (a)
   yields anything for real webinars or whether it's manual-only in practice:
   `select id, title, video_path from content_items where kind='webinar';`
2. **Vimeo privacy status**: have the webinar videos actually been switched to
   "Embed only / Hide from Vimeo" yet, and is the embed-domain whitelist set for BOTH
   the GitHub Pages prod domain and the Cloudflare Pages dev domain? (Manual dashboard
   fact; affects whether oEmbed and even *playback* work on dev.)
3. **"Category" in the edit modal**: `content_items` has no category column. Use the
   existing nullable `section_label`, or drop "category" from the modal? (Locked
   decision #4 lists category as a field, but the schema doesn't have one.)

## Production-live / manual-apply constraints (standing)

- dev + prod share ONE Supabase project — the Batch 1 `add column` is production-live
  the instant it's applied. Applied BY HAND in the SQL Editor (no CLI/psql here).
- Rollback written before forward SQL, per project rule.
- Frontend → `dev` only.
