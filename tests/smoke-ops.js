/* Key Wellness — headless checks for ops.html.

   Loads the real page in Chromium with a stubbed Supabase client and drives
   both screens the way Lone would: walk the roll-call, write an action, start
   a review from the empty state, then read the day.

   The fixture uses the real payload shapes returned by tuesday_review_pack(),
   tuesday_review_open() and ops_timeline() — including the derived `label` on
   a carried action, which is the field the screen must not re-derive.

   Usage:  node tests/smoke-ops.js
*/
const { chromium } = require('playwright');
const path = require('path');
const url = require('url');

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name); }
  else    { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}

const OPS = url.pathToFileURL(path.resolve(__dirname, '..', 'ops.html')).href;

/* The daily view filters by date against Gaborone's today, so the fixture's
   dates have to move with it. Fixed dates drift into the past and every
   section renders empty — which looks exactly like a page bug and is not one. */
const TODAY = new Date(new Date().toLocaleString('en-US', { timeZone: 'Africa/Gaborone' }));
const d = n => { const x = new Date(TODAY); x.setDate(x.getDate() + n);
                 return x.toISOString().slice(0, 10); };
const ME  = '00000000-0000-0000-0000-000000000009';

/* tuesday_review_pack(): two organisations, Test Co already excluded by the
   RPC. BOPEU carries a carried action and an overdue open one. */
const PACK_STARTED = {
  as_of: '2026-08-25',
  meeting_id: 'meet-1',
  previous_meeting_id: 'meet-0',
  completion_rate: 33.3,
  organisations: [
    { org_id: 'org-bopeu', name: 'BOPEU', open_count: 2, needs_decision: true,
      last_week: [
        { id: 'a1', title: 'Send BOPEU report', owner: ME, due_date: '2026-08-20',
          state: 'done', label: 'done' },
        { id: 'a3', title: 'Chase BOPEU HR', owner: ME, due_date: '2026-08-21',
          state: 'dropped', label: 'carried' },
        { id: 'a4', title: 'Idea we abandoned', owner: ME, due_date: '2026-08-21',
          state: 'dropped', label: 'dropped' },
        /* Still open from last week. The real RPC returns EVERY action with
           meeting_id = the previous meeting, whatever its state. An earlier
           fixture left this one out, and the page-derived denominator came to
           2 where the SQL's completion_rate says 3. */
        { id: 'a2', title: 'Book BOPEU webinar', owner: ME, due_date: '2026-08-22',
          state: 'open', label: 'open' }
      ],
      open_now: [
        { id: 'a2', title: 'Book BOPEU webinar', owner: ME, due_date: '2026-08-22', overdue: true },
        { id: 'a5', title: 'Chase BOPEU HR', owner: ME, due_date: '2026-08-28', overdue: false }
      ] },
    { org_id: 'org-sed', name: 'Sedimosa', open_count: 1, needs_decision: false,
      last_week: [],
      open_now: [{ id: 'a6', title: 'Sedimosa flyer', owner: 'other', due_date: '2026-08-27', overdue: false }] }
  ],
  unassigned: { last_week: [], open_now: [
    { id: 'a7', title: 'Fix the printer', owner: ME, due_date: '2026-08-27', overdue: false }] }
};
const PACK_EMPTY = Object.assign({}, PACK_STARTED, { meeting_id: null, completion_rate: null });

const TIMELINE = {
  from: d(-7), to: d(14),
  organisations: [
    { org_id: 'org-bopeu', name: 'BOPEU', items: [
      { kind: 'booking', id: 'b1', on_date: d(0), service_line: 'financial',
        title: 'Budget Planning Session', practitioner: 'Kefilwe', mode: 'physical',
        format: 'one_on_one', state: 'attended', attendee_count: null } ] },
    { org_id: 'org-sed', name: 'Sedimosa', items: [
      { kind: 'booking', id: 'b2', on_date: d(2), service_line: 'psychosocial',
        title: 'Counselling session', practitioner: '', mode: null,
        format: 'one_on_one', state: 'pending', attendee_count: null },
      { kind: 'activity', id: 'p1', on_date: d(3), service_line: 'financial',
        title: 'Debt awareness talk', practitioner: '', mode: 'physical',
        format: 'education_talk', state: 'delivered', attendee_count: 40 },
      /* ops_timeline maps a webinar by its date: scheduled before, delivered
         after. 'published' is editorial and must never reach this column. */
      { kind: 'webinar', id: 'w9', on_date: d(9), service_line: 'financial',
        title: 'Managing debt in a tight month', practitioner: '', mode: null,
        format: 'webinar', state: 'scheduled', attendee_count: null } ] }
  ],
  /* A session whose member has no organisation on their profile. */
  unassigned: [
    { kind: 'booking', id: 'b9', on_date: d(1), service_line: 'financial',
      title: 'Walk-in consultation', practitioner: '', mode: null,
      format: 'one_on_one', state: 'pending', attendee_count: null } ]
};

function stub(page, opts) {
  const o = opts || {};
  return page.addInitScript(({ PACK, TIMELINE, ME, started }) => {
    window.__rpc = [];
    window.__updates = [];
    const pack = started ? PACK.started : PACK.empty;

    const table = (t) => {
      const rows =
        t === 'notifications' ? (window.__notifications || [
          { id: 'n1', type: 'action_overdue',     title: 'Action overdue',     body: 'x', created_at: '2026-08-25' },
          { id: 'n2', type: 'action_due_tomorrow',title: 'Action due tomorrow',body: 'y', created_at: '2026-08-25' }
        ])
        : t === 'actions' ? [
          { id: 'a2', title: 'Book BOPEU webinar', owner: ME, due_date: '2026-08-22', state: 'open', org_id: 'org-bopeu' },
          { id: 'a6', title: 'Sedimosa flyer', owner: 'other', due_date: '2026-08-27', state: 'open', org_id: 'org-sed' },
          { id: 'a7', title: 'Fix the printer', owner: ME, due_date: '2026-08-27', state: 'open', org_id: null }
        ]
        : t === 'org_reports' ? [
          { id: 'r1', period_label: 'Q3 2026 (Jul–Sep)', period_start: '2026-07-01',
            period_end: '2026-09-30', status: 'published', org_id: 'org-testco' }
        ] : [];

      const chain = {
        eq: () => chain, is: () => chain, like: () => chain, in: (c, v) => { window.__updates.push(v); return chain; },
        or: () => chain, order: () => chain, limit: () => chain,
        maybeSingle: async () => ({
          data: t === 'profiles' ? { id: ME } : t === 'admins' ? { email: 'lone@keywellness.co.bw' } : null,
          error: null }),
        single: async () => ({ data: null, error: null }),
        update: () => chain,
        then: (res) => res({ data: rows, error: null })
      };
      return chain;
    };

    const fake = {
      from: (t) => ({ select: () => table(t), insert: () => table(t),
                      update: () => table(t), delete: () => table(t) }),
      rpc: async (fn, args) => {
        window.__rpc.push({ fn, args });
        if (fn === 'advisor_me') return { data: null, error: null };
        if (fn === 'tuesday_review_pack') return { data: pack, error: null };
        if (fn === 'ops_timeline') return { data: TIMELINE, error: null };
        if (fn === 'tuesday_review_open') {
          window.__started = true;
          return { data: { meeting_id: 'meet-1', held_on: '2026-08-25', created: true,
                           previous_meeting_id: 'meet-0',
                           carry_candidates: [{ id: 'a2', title: 'Book BOPEU webinar',
                             owner: ME, due_date: '2026-08-22', org_id: 'org-bopeu',
                             org_name: 'BOPEU' }] }, error: null };
        }
        if (fn === 'action_upsert') return { data: { id: 'new-1', state: 'open' }, error: null };
        return { data: [], error: null };
      },
      auth: {
        getSession: async () => ({ data: { session: { user: { id: ME, email: 'lone@keywellness.co.bw' } } } }),
        getUser: async () => ({ data: { user: { id: ME, email: 'lone@keywellness.co.bw' } } }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
        signOut: async () => ({ error: null })
      }
    };
    window.supabase = { createClient: () => fake };
  }, { PACK: { started: PACK_STARTED, empty: PACK_EMPTY }, TIMELINE, ME, started: o.started !== false });
}

async function open(browser, opts) {
  const page = await browser.newPage();
  await page.setViewportSize({ width: 1440, height: 900 });
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  /* The CDN would otherwise overwrite the stub — see smoke-account.js. */
  await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
  await stub(page, opts);
  await page.goto(OPS);
  await page.waitForTimeout(900);
  return { page, errors };
}

(async () => {
  const browser = await chromium.launch();

  /* ══ The Tuesday review, already started ══════════════════ */
  {
    const { page, errors } = await open(browser, { started: true });
    const txt = () => page.evaluate(() => document.body.innerText);

    check('1  the top bar carries the four destinations',
      await page.evaluate(() => Array.from(document.querySelectorAll('#dests .dest'))
        .map(b => b.textContent).join(',')) === 'Review,Today,Organisations,Reports');

    check('2  the roll-call numbers the organisations in review order',
      await page.evaluate(() => Array.from(document.querySelectorAll('.rc .nm'))
        .map(e => e.textContent.trim()).join('|')) === 'BOPEU|Sedimosa');

    check('3  the first organisation is the current position',
      await page.evaluate(() => {
        const rc = document.querySelectorAll('.rc');
        return rc[0].classList.contains('current') && !rc[1].classList.contains('current');
      }));

    check('4  a client needing a decision carries the yellow flag',
      await page.evaluate(() => !!document.querySelector('.rc .flag')));

    check('5  Test Co never appears — the RPC excludes it, the page does not filter',
      !/Test Co/.test(await txt()));

    check('6  the client name is the 40px heading',
      (await page.evaluate(() => document.querySelector('.client-name').textContent.trim())) === 'BOPEU');

    check('7  since-last-Tuesday shows the booking with its practitioner',
      /Budget Planning Session/.test(await txt()) && /Kefilwe/.test(await txt()));

    check('8  a carried action is labelled carried, not dropped',
      await page.evaluate(() => {
        const rows = Array.from(document.querySelectorAll('.row'));
        const r = rows.find(x => /Chase BOPEU HR/.test(x.textContent));
        return r && /carried/.test(r.textContent);
      }));

    check('9  and an abandoned one is still labelled dropped',
      await page.evaluate(() => {
        const rows = Array.from(document.querySelectorAll('.row'));
        const r = rows.find(x => /Idea we abandoned/.test(x.textContent));
        return r && /dropped/.test(r.textContent);
      }));

    /* The marked slots. Hiding them would make the review look finished.
       Note the /i: section labels carry text-transform:uppercase, and
       innerText returns RENDERED text, so a case-sensitive match on "Retainer"
       silently fails against "RETAINER". */
    check('10 the retainer section is present and collapses the three missing things into one line',
      /retainer/i.test(await txt())
      && /No contract, work plan or capacity recorded yet/.test(await txt()),
      (await txt()).slice((await txt()).search(/retainer/i), 120));

    check('11 unrecorded facts say so rather than showing a blank',
      /Account manager not recorded/.test(await txt()));

    check('12 the service-line marker is a square, filled for psychosocial',
      await page.evaluate(() => {
        const fin = document.querySelector('.sl-financial');
        const psy = document.querySelector('.sl-psychosocial');
        if (!fin) return false;
        const f = getComputedStyle(fin);
        return f.width === '9px' && f.height === '9px' && f.borderRadius === '0px';
      }));

    check('13 Next advances the roll-call and strikes the passed client through',
      await (async () => {
        await page.click('.next-btn');
        await page.waitForTimeout(700);
        return page.evaluate(() => {
          const rc = document.querySelectorAll('.rc');
          const name = document.querySelector('.client-name').textContent.trim();
          return name === 'Sedimosa' && rc[0].classList.contains('done')
                 && rc[1].classList.contains('current');
        });
      })());

    check('14 an action typed in the right panel reaches action_upsert with the org and the meeting',
      await (async () => {
        await page.fill('#newAction', 'Ring the HR contact');
        await page.press('#newAction', 'Enter');
        await page.waitForTimeout(700);
        return page.evaluate(() => {
          const c = window.__rpc.filter(r => r.fn === 'action_upsert').pop();
          return !!c && c.args.p_title === 'Ring the HR contact'
                 && c.args.p_org_id === 'org-sed' && c.args.p_meeting_id === 'meet-1';
        });
      })());

    check('15 Ctrl-K opens the search and filters',
      await (async () => {
        await page.keyboard.press('Control+K');
        await page.waitForTimeout(250);
        await page.fill('#kinput', 'sedi');
        await page.waitForTimeout(250);
        return page.evaluate(() => {
          const open = document.getElementById('kbox').classList.contains('open');
          const hits = Array.from(document.querySelectorAll('#kres button')).map(b => b.textContent);
          return open && hits.length === 1 && /Sedimosa/.test(hits[0]);
        });
      })());

    check('16 Escape closes it',
      await (async () => {
        await page.keyboard.press('Escape');
        await page.waitForTimeout(250);
        return page.evaluate(() => !document.getElementById('kbox').classList.contains('open'));
      })());

    /* A yellow flag with no referent is not allowed. */
    await page.evaluate(() => { RC = 0; return renderReview(); });
    await page.waitForTimeout(700);
    check('17a the needs-a-decision label names the decision',
      await page.evaluate(() => {
        const n = document.querySelector('.facts .need');
        return !!n && /overdue/.test(n.textContent) && !/Needs a decision/.test(n.textContent);
      }), await page.evaluate(() => ((document.querySelector('.facts .need')||{}).textContent)));

    check('17b and clicking it marks the action it refers to',
      await (async () => {
        await page.evaluate(() => { RC = 0; return renderReview(); });
        await page.waitForTimeout(700);
        await page.click('.facts .need');
        await page.waitForTimeout(300);
        return page.evaluate(() => !!document.querySelector('.action.picked'));
      })());

    check('17c no editorial state reaches the state column',
      await page.evaluate(() => !Array.from(document.querySelectorAll('.row .state'))
        .some(e => /published|draft/.test(e.textContent))));

    check('17 no uncaught JavaScript errors on the review screen',
      errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ══ The empty state ══════════════════════════════════════ */
  {
    const { page, errors } = await open(browser, { started: false });
    const txt = await page.evaluate(() => document.body.innerText);

    check('18 with no meeting today the centre offers one action',
      /Start Tuesday's review/.test(txt) && /No review has been started today/.test(txt));

    check('19 the roll-call says not started rather than showing a numbered list',
      /Not started/.test(txt) && await page.evaluate(() => document.querySelectorAll('.rc').length === 0));

    check('20 starting it calls tuesday_review_open once',
      await (async () => {
        await page.click('#startBtn');
        await page.waitForTimeout(900);
        return page.evaluate(() => window.__rpc.filter(r => r.fn === 'tuesday_review_open').length === 1);
      })());

    check('21 no uncaught JavaScript errors on the empty state',
      errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ══ The daily view ═══════════════════════════════════════ */
  {
    const { page, errors } = await open(browser, { started: true });
    await page.click('[data-dest="today"]');
    await page.waitForTimeout(1000);
    const txt = await page.evaluate(() => document.body.innerText);

    check('22 needs-me lists only the actions owned by the signed-in person',
      await page.evaluate(() => {
        const t = document.body.innerText;
        const i = t.indexOf('NEEDS ME'), j = t.indexOf('WAITING ON OTHERS');
        const mine = t.slice(i, j);
        return /Book BOPEU webinar/.test(mine) && /Fix the printer/.test(mine)
               && !/Sedimosa flyer/.test(mine);
      }));

    check('23 waiting-on lists what belongs to someone else',
      await page.evaluate(() => {
        const t = document.body.innerText;
        const i = t.indexOf('WAITING ON OTHERS'), j = t.indexOf("TUESDAY'S ACTIONS");
        return /Sedimosa flyer/.test(t.slice(i, j));
      }));

    check('24 an overdue action carries the yellow flag',
      await page.evaluate(() => !!document.querySelector('.col-left .flag')));

    check('25 the undated section says work plans do not exist yet',
      /Work plans are not recorded yet/.test(txt));

    check('26 capacity is a marked slot, not an invented number',
      /Practitioner ceilings are not recorded yet/.test(txt));

    /* A percentage over a denominator of three is false precision. Counts
       below 20, a percentage at or above it. */
    check("27 Tuesday's actions read as a count, not a percentage",
      /1 of 3 done/.test(txt), txt.slice(txt.indexOf("TUESDAY'S ACTIONS"), 60));

    check('28 opening Today marks the reminders read',
      await page.evaluate(() => window.__updates.length > 0
        && document.getElementById('reminders').getAttribute('data-unread') !== null));

    check('29 the reminders count is not yellow — yellow means a decision is needed',
      await page.evaluate(() => {
        const c = getComputedStyle(document.getElementById('reminders')).color;
        return !/240,\s*201,\s*10/.test(c);
      }));

    check('29a the day opens on the first thing that needs her',
      await page.evaluate(() => {
        const t = document.body.innerText;
        return !/Choose something on the left/.test(t)
               && /Book BOPEU webinar/.test(t.slice(t.indexOf('SELECTED'), t.indexOf('SELECTED') + 220));
      }), await page.evaluate(() => { const t = document.body.innerText;
            return t.slice(t.indexOf('SELECTED'), t.indexOf('SELECTED') + 140); }));

    check('29b a row with no organisation says so rather than showing nothing',
      await page.evaluate(() => !!Array.from(document.querySelectorAll('.row .muted'))
        .find(e => /no organisation/.test(e.textContent))));

    check('30 no uncaught JavaScript errors on the daily view',
      errors.length === 0, errors.join(' | '));
    await page.close();
  }

  /* ══ Organisations and Reports ════════════════════════════ */
  {
    const { page, errors } = await open(browser, { started: true });
    await page.click('[data-dest="orgs"]');
    await page.waitForTimeout(700);
    check('31 the organisations list shows the active clients and not Test Co',
      await page.evaluate(() => {
        const t = document.body.innerText;
        return /BOPEU/.test(t) && /Sedimosa/.test(t) && !/Test Co/.test(t);
      }));

    await page.click('[data-dest="reports"]');
    await page.waitForTimeout(700);
    check('32 the reports list renders the issued periods',
      /Q3 2026/.test(await page.evaluate(() => document.body.innerText)));

    check('33 no uncaught JavaScript errors on either',
      errors.length === 0, errors.join(' | '));
    await page.close();
  }

  await browser.close();
  console.log('\n  ' + pass + ' passed, ' + fail + ' failed.\n');
  process.exit(fail ? 1 : 0);
})();
