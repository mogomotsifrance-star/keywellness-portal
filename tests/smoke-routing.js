/* Key Wellness — headless checks for role routing.

   smoke6.js was referenced in the handover notes but never committed, so this
   is built fresh. It is also the FIRST automated guard on index.html at all —
   the largest and least-protected file in the repo.

   Two layers:
     1. KW.resolveRoute() as a pure function, over every role combination.
        No DOM, no navigation, no timing.
     2. index.html actually routing — navigation is intercepted and recorded
        rather than followed, so a wrong redirect is a recorded fact instead
        of a page that fails to load for some other reason.

   Usage:  node tests/smoke-routing.js
*/
const { chromium } = require('playwright');
const path = require('path');
const url = require('url');

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('PASS  ' + name); }
  else    { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}

const INDEX = url.pathToFileURL(path.resolve(__dirname, '..', 'index.html')).href;

/* The stub every page in this repo needs. See the note in smoke-account.js:
   index.html loads supabase-js from jsdelivr, and if the CDN is reachable the
   real library OVERWRITES this stub, the page builds a real client against
   production, and every assertion afterwards is meaningless. */
function installStub(page, roles, storedInterface) {
  return page.addInitScript(({ roles, storedInterface }) => {
    if (storedInterface) {
      try { sessionStorage.setItem('kw_interface', storedInterface); } catch (_) {}
    } else {
      try { sessionStorage.removeItem('kw_interface'); } catch (_) {}
    }
    window.__roles = roles;

    const q = (table) => {
      const chain = {
        eq: () => chain, or: () => chain, order: () => chain, limit: () => chain,
        maybeSingle: async () => {
          if (table === 'profiles')  return { data: roles.member ? { id: 'u1' } : null, error: null };
          if (table === 'admins')    return { data: roles.admin ? { email: 'x@y.z' } : null, error: null };
          if (table === 'employers') return { data: roles.employer ? { org_id: 'org-1' } : null, error: null };
          return { data: null, error: null };
        },
        single: async () => ({ data: null, error: null }),
        then: (res) => res({ data: [], error: null })
      };
      return chain;
    };
    const fake = {
      from: (t) => ({ select: () => q(t), insert: () => q(t), update: () => q(t), delete: () => q(t) }),
      rpc: async (fn) => {
        if (fn === 'advisor_me') return { data: roles.advisor ? { id: 'adv-1' } : null, error: null };
        return { data: [], error: null };
      },
      auth: {
        getSession: async () => ({ data: { session: roles.signedIn === false ? null
          : { user: { id: 'u1', email: 'someone@keywellness.co.bw' } } } }),
        getUser: async () => ({ data: { user: { id: 'u1', email: 'someone@keywellness.co.bw' } } }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
        signOut: async () => ({ error: null })
      }
    };
    window.supabase = { createClient: () => fake };
  }, { roles, storedInterface });
}

(async () => {
  const browser = await chromium.launch();

  /* ── 1. The rule, as a pure function ───────────────────────
     Loaded with no session so index.html shows its auth screen and never
     routes; KW is available because kw-session.js is in <head>. */
  {
    const page = await browser.newPage();
    await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
    await installStub(page, { signedIn: false, member: true });
    await page.goto(INDEX);
    await page.waitForFunction(() => !!window.KW);

    const verdicts = await page.evaluate(() => {
      const R = (o) => Object.assign({ member: true, admin: false, advisor: false,
                                       employer: false, employerOrgId: null }, o);
      const out = {};
      out.memberOnly   = window.KW.resolveRoute(R({}), null);
      out.advisorOnly  = window.KW.resolveRoute(R({ advisor: true }), null);
      out.adminOnly    = window.KW.resolveRoute(R({ admin: true }), null);
      out.hrOnly       = window.KW.resolveRoute(R({ employer: true, employerOrgId: 'o' }), null);
      out.france       = window.KW.resolveRoute(R({ admin: true, advisor: true }), null);
      out.storedAdmin  = window.KW.resolveRoute(R({ admin: true }), 'admin');
      out.storedOps    = window.KW.resolveRoute(R({ admin: true }), 'ops');
      out.storedMember = window.KW.resolveRoute(R({ admin: true, advisor: true }), 'member');
      out.storedStale  = window.KW.resolveRoute(R({ admin: true, advisor: true }), 'employer');
      out.adminOpts    = window.KW.interfaces(R({ admin: true })).map(i => i.id);
      return out;
    });

    check('1  a plain member stays put',
      verdicts.memberOnly.action === 'stay', JSON.stringify(verdicts.memberOnly));
    check('2  an advisor with no other hat goes straight to advisor.html',
      verdicts.advisorOnly.action === 'go' && /advisor\.html$/.test(verdicts.advisorOnly.href),
      JSON.stringify(verdicts.advisorOnly));
    check('3  an admin lands on ops.html, not admin.html',
      verdicts.adminOnly.action === 'go' && /ops\.html$/.test(verdicts.adminOnly.href),
      JSON.stringify(verdicts.adminOnly));
    check('4  an HR user goes to employer.html',
      verdicts.hrOnly.action === 'go' && /employer\.html$/.test(verdicts.hrOnly.href),
      JSON.stringify(verdicts.hrOnly));
    check('5  someone holding two staff hats is offered the chooser, not redirected',
      verdicts.france.action === 'choose' && verdicts.france.options.length === 3,
      JSON.stringify(verdicts.france.action));
    /* The migration shim. Every live session today holds 'admin'. */
    check('6  a stored "admin" from before ops existed maps forward to ops.html',
      verdicts.storedAdmin.action === 'go' && /ops\.html$/.test(verdicts.storedAdmin.href),
      JSON.stringify(verdicts.storedAdmin));
    check('7  a stored "ops" is honoured',
      verdicts.storedOps.action === 'go' && /ops\.html$/.test(verdicts.storedOps.href));
    check('8  someone who asked to be on the member portal stays there',
      verdicts.storedMember.action === 'stay');
    check('9  a stored choice for a role they no longer hold falls back to the chooser',
      verdicts.storedStale.action === 'choose', JSON.stringify(verdicts.storedStale.action));
    check('10 the admin interface list offers ops and never admin',
      verdicts.adminOpts.includes('ops') && !verdicts.adminOpts.includes('admin'),
      JSON.stringify(verdicts.adminOpts));

    /* Every combination resolves to something valid — no undefined verdicts. */
    const matrix = await page.evaluate(() => {
      const bad = [];
      for (let m = 0; m < 2; m++) for (let a = 0; a < 2; a++)
      for (let d = 0; d < 2; d++) for (let e = 0; e < 2; e++) {
        const roles = { member: !!m, admin: !!a, advisor: !!d,
                        employer: !!e, employerOrgId: e ? 'o' : null };
        for (const stored of [null, 'member', 'ops', 'advisor', 'employer', 'admin']) {
          const v = window.KW.resolveRoute(roles, stored);
          if (!v || !['stay','go','choose'].includes(v.action)) bad.push([roles, stored, v]);
          if (v.action === 'go' && !v.href) bad.push([roles, stored, v]);
        }
      }
      return bad;
    });
    check('11 all 16 role combinations x 6 stored values resolve to a valid verdict',
      matrix.length === 0, JSON.stringify(matrix.slice(0, 2)));

    await page.close();
  }

  /* ── 2. index.html's wrapper acting on the verdict ─────────
     NOT the whole login flow. kwRouteByRole() is called from three places in
     index.html, each after loadAllData() and the session-trust gate — driving
     that end to end would mean stubbing most of a 500 KB page, and it would
     be testing the login flow rather than the routing change.

     What changed is the wrapper: verdict -> location.replace, or the chooser.
     So the roles are placed and kwRouteByRole() is called directly, with
     navigation intercepted and recorded instead of followed. */
  async function routeWith(roles, stored) {
    const page = await browser.newPage();
    const nav = [];
    await page.route('**cdn.jsdelivr.net/npm/@supabase/**', r => r.abort());
    await page.route('**/*.html', route => {
      const req = route.request();
      if (req.isNavigationRequest() && req.url() !== INDEX) { nav.push(req.url()); return route.abort(); }
      return route.continue();
    });
    await installStub(page, { signedIn: false, member: true }, stored);
    await page.goto(INDEX);
    await page.waitForFunction(() => !!window.KW && typeof window.kwRouteByRole === 'function');

    const returned = await page.evaluate((roles) => {
      window._isAdmin       = !!roles.admin;
      window._advisor       = roles.advisor ? { id: 'adv-1' } : null;
      window._employerOrgId = roles.employer ? 'org-1' : null;
      window.KW.roles = null;               // force the legacy-globals bridge
      return window.kwRouteByRole();
    }, roles);

    await page.waitForTimeout(400);
    const chooser = await page.evaluate(() => {
      const el = document.getElementById('interface-chooser');
      return !!el && el.style.display === 'flex';
    });
    await page.close();
    return { nav, chooser, returned };
  }

  const adminGo = await routeWith({ admin: true }, null);
  check('12 kwRouteByRole sends an admin to ops.html',
    adminGo.nav.some(u => /ops\.html/.test(u)), JSON.stringify(adminGo.nav));
  check('13 and never to admin.html',
    !adminGo.nav.some(u => /admin\.html/.test(u)), JSON.stringify(adminGo.nav));
  check('14 and reports that the caller should stop',
    adminGo.returned === true, String(adminGo.returned));

  const staleGo = await routeWith({ admin: true }, 'admin');
  check('15 a live session holding the old "admin" choice lands on ops.html',
    staleGo.nav.some(u => /ops\.html/.test(u)) && !staleGo.nav.some(u => /admin\.html/.test(u)),
    JSON.stringify(staleGo.nav));

  const advisorGo = await routeWith({ advisor: true }, null);
  check('16 an advisor goes to advisor.html',
    advisorGo.nav.some(u => /advisor\.html/.test(u)), JSON.stringify(advisorGo.nav));

  const hrGo = await routeWith({ employer: true }, null);
  check('17 an HR user goes to employer.html',
    hrGo.nav.some(u => /employer\.html/.test(u)), JSON.stringify(hrGo.nav));

  const memberGo = await routeWith({}, null);
  check('18 a plain member is not redirected and the caller continues',
    memberGo.nav.length === 0 && memberGo.returned === false,
    'nav=' + JSON.stringify(memberGo.nav) + ' returned=' + memberGo.returned);

  const franceGo = await routeWith({ admin: true, advisor: true }, null);
  check('19 two staff hats: the chooser opens and nothing is redirected',
    franceGo.nav.length === 0 && franceGo.chooser && franceGo.returned === true,
    'nav=' + JSON.stringify(franceGo.nav) + ' chooser=' + franceGo.chooser);

  await browser.close();
  console.log('\n  ' + pass + ' passed, ' + fail + ' failed.\n');
  process.exit(fail ? 1 : 0);
})();
