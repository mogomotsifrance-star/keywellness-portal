/* Key Wellness — shared session, role probe and interface routing.
   ═══════════════════════════════════════════════════════════════════════

   Loaded by index.html and ops.html, AFTER the Supabase CDN script — it
   reads window.supabase.createClient at first use.

   WHY THIS FILE EXISTS. Before it, the same four things were written four
   times over: the project URL and anon key (index:985, admin:398,
   advisor:645, employer:266), the CDN-failure guard (present in index and
   advisor, MISSING in admin and employer, which render blank if jsdelivr
   fails), the role probe (three divergent shapes — index sets
   window._isAdmin/_advisor/_employerOrgId, admin and employer use
   window._kwRoles, advisor.html has none), and the interface list (four
   different expressions, one of them carrying the comment "matching
   kwGoToInterface() in index.html / admin.html", which is a hand-copy
   admitting it is one). ops.html would have been the fifth of each.

   THE SEAM IS DECISION VS PRESENTATION. Everything here is testable without
   a DOM. Anything that touches `document` — the chooser, the role switcher —
   stays on the page that owns those elements. resolveRoute() in particular
   is the whole routing rule as a pure function, so tests/smoke-routing.js
   can assert every role combination without loading a page.

   ADOPTED BY index.html AND ops.html ONLY. admin.html and employer.html keep
   their own switchers (still pointing at admin.html) and their missing CDN
   guard until Prompt 11 rebuilds them. Recorded in CLAUDE_CONTEXT.md §2.   */

window.KW = (function () {
  'use strict';

  var URL = 'https://tarmpqxsabbehgjaonfz.supabase.co';
  var KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRhcm1wcXhzYWJiZWhnamFvbmZ6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE1MjA2MjQsImV4cCI6MjA5NzA5NjYyNH0.Em-NvJVY_geHk6UOTxnpINgUw669V8W_9YvAi_koX9U';

  var INTERFACE_KEY = 'kw_interface';
  var _sb = null;

  /* The message admin.html and employer.html still lack. Without it the next
     line throws at parse time and the page renders blank with no
     explanation. */
  function guard() {
    if (window.supabase && window.supabase.createClient) return true;
    document.body.innerHTML =
      '<div style="max-width:420px;margin:80px auto;padding:32px;font-family:sans-serif;text-align:center;color:#1C1D1F">'
      + '<h2 style="margin-bottom:10px">Couldn\'t load Key Wellness</h2>'
      + '<p style="color:#4A4C52;margin-bottom:20px">We couldn\'t reach a required service. '
      + 'Please check your internet connection and try again.</p>'
      + '<button onclick="location.reload()" style="background:#397E2B;color:#fff;border:none;'
      + 'border-radius:2px;padding:11px 22px;font-weight:700;cursor:pointer">Retry</button></div>';
    throw new Error('Supabase JS SDK failed to load');
  }

  function sb() {
    if (!_sb) {
      guard();
      _sb = window.supabase.createClient(URL, KEY);
      window._kwSb = _sb;   // the existing convention: kw-badges.js and the
                            // tool pages already reuse this
    }
    return _sb;
  }

  /* Four independent lookups. Serialised they held the interface switcher back
     by four round trips on every page load.

     admins.email is compared lowercase to match how grants store it — an
     exact-case compare has locked admins out before and needed a data
     migration to unstick. The advisor answer comes from advisor_me() so the
     is_active flag and the email/user_id fallback live in one place.

     An employer may be matched on user_id OR email: a manager added by email
     before registering has no user_id yet, while one linked at grant time may
     have a user_id and a differently-cased email. Matching on email alone hid
     the HR Dashboard from the second group.                                  */
  async function detectRoles(client, user) {
    var email = (user && user.email ? user.email : '').toLowerCase();
    var safe = function (p) { return Promise.resolve(p).then(function (r) { return r; },
                                                             function () { return { data: null }; }); };
    var res = await Promise.all([
      safe(client.from('profiles').select('id').eq('id', user.id).maybeSingle()),
      safe(client.from('admins').select('email').eq('email', email).maybeSingle()),
      safe(client.rpc('advisor_me')),
      safe(client.from('employers').select('org_id')
                 .or('user_id.eq.' + user.id + ',email.eq.' + email).maybeSingle())
    ]);
    var roles = {
      member:        !!res[0].data,
      admin:         !!res[1].data,
      advisor:       !!res[2].data,
      advisorRecord: res[2].data || null,
      employer:      !!(res[3].data && res[3].data.org_id),
      employerOrgId: (res[3].data && res[3].data.org_id) || null
    };
    /* Mirrors is_staff() in SQL. M3 adds counsellor there and here together. */
    roles.staff = roles.admin || roles.advisor;
    window.KW.roles = roles;
    return roles;
  }

  /* Data only — no DOM, no icons rendered. ops.html ignores the icon field
     entirely; its design language forbids emoji. index.html's chooser uses
     it, and that page is the member language where it belongs. */
  function interfaces(roles) {
    var out = [{
      id: 'member', icon: '👤', title: 'My Portal',
      desc: 'Your own wellness dashboard, tools, assessment and bookings.',
      href: 'index.html'
    }];
    if (roles.advisor) out.push({
      id: 'advisor', icon: '🧭', title: 'Advisor Portal',
      desc: 'Your clients, consultation assessments and session diary.',
      href: 'advisor.html'
    });
    /* Was 'admin' -> admin.html. Admins now land on the ops workspace;
       admin.html is reachable from inside it until Prompt 11 retires it. */
    if (roles.admin) out.push({
      id: 'ops', icon: '⚙️', title: 'Ops Workspace',
      desc: 'The Tuesday review, your day, organisations and reports.',
      href: 'ops.html'
    });
    if (roles.employer) out.push({
      id: 'employer', icon: '🏢', title: 'HR Dashboard',
      desc: 'Your organisation’s aggregate wellness reporting.',
      href: 'employer.html'
    });
    return out;
  }

  /* A live session may hold 'admin' from before ops.html existed. Without
     this shim their next load lands on the page being retired. */
  function getInterface() {
    try {
      var v = sessionStorage.getItem(INTERFACE_KEY);
      return v === 'admin' ? 'ops' : v;
    } catch (_) { return null; }
  }
  function setInterface(id) {
    try { sessionStorage.setItem(INTERFACE_KEY, id); } catch (_) {}
  }
  function clearInterface() {
    try { sessionStorage.removeItem(INTERFACE_KEY); } catch (_) {}
  }

  /* The whole routing rule, as a pure function.
       {action:'stay'}                         nothing to choose, or they asked to be here
       {action:'go',     href, id}             one destination, or a remembered one
       {action:'choose', options}              more than one staff hat, no choice stored  */
  function resolveRoute(roles, stored) {
    var options = interfaces(roles);
    if (options.length === 1) return { action: 'stay', options: options };

    if (stored) {
      if (stored === 'member') return { action: 'stay', options: options };
      for (var i = 0; i < options.length; i++) {
        if (options[i].id === stored) {
          return { action: 'go', href: options[i].href, id: options[i].id, options: options };
        }
      }
      /* Stale choice for a role they no longer hold — fall through to the
         chooser rather than sending them somewhere they cannot get into. */
    }

    var staff = options.filter(function (o) { return o.id !== 'member'; });
    if (staff.length === 1) {
      return { action: 'go', href: staff[0].href, id: staff[0].id, remember: true, options: options };
    }
    return { action: 'choose', options: options };
  }

  return {
    url: URL, anonKey: KEY, interfaceKey: INTERFACE_KEY,
    roles: null,
    guard: guard, sb: sb,
    detectRoles: detectRoles,
    interfaces: interfaces,
    getInterface: getInterface, setInterface: setInterface, clearInterface: clearInterface,
    resolveRoute: resolveRoute
  };
})();
