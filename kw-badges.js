/* kw-badges.js — Key Wellness shared badge engine (single source of truth) */
(function (global) {
  'use strict';

  const SUPABASE_URL = 'https://tarmpqxsabbehgjaonfz.supabase.co';
  const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRhcm1wcXhzYWJiZWhnamFvbmZ6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE1MjA2MjQsImV4cCI6MjA5NzA5NjYyNH0.Em-NvJVY_geHk6UOTxnpINgUw669V8W_9YvAi_koX9U';

  // ── Simple one-off badges (each rendered as a single card) ──
  const SIMPLE_DEFS = [
    { id: 'first_login',        icon: '🌟', name: 'First Step',         desc: 'Completed onboarding',                  pts: 50  },
    { id: 'first_assessment',   icon: '📋', name: 'Self-Aware',         desc: 'Completed first assessment',            pts: 100 },
    { id: 'high_scorer',        icon: '💯', name: 'Financial Star',     desc: 'Overall score of 75+',                  pts: 200 },
    { id: 'ef_started',         icon: '🆘', name: 'Safety Net Started', desc: 'Opened Emergency Fund Planner',         pts: 75  },
    { id: 'ef_halfway',         icon: '🛟', name: 'Halfway Safe',       desc: 'Emergency fund 50% funded',             pts: 150 },
    { id: 'ef_complete',        icon: '🏰', name: 'Fortress Built',     desc: 'Emergency fund fully funded',           pts: 300 },
    { id: 'check_in_1',         icon: '✅', name: 'On Track',           desc: 'Completed first fortnightly check-in',  pts: 75  },
    { id: 'check_in_3',         icon: '🔥', name: 'Consistent',         desc: '3 fortnightly check-ins',               pts: 150 },
    { id: 'booked_session',     icon: '📅', name: 'Getting Help',       desc: 'Booked a coaching session',             pts: 100 },
    { id: 'watched_video',      icon: '🎬', name: 'Knowledge Seeker',   desc: 'Watched a learning video',              pts: 25  },
  ];

  // ── Incremental score badges: ONE filling badge per area, three tiers ──
  // Each area fills up as the matching assessment dimension score rises.
  // Tier 1 at 40+, Tier 2 at 60+, Tier 3 (full) at 80+. Points are awarded
  // per tier as it is reached; award() dedupes so a tier is never paid twice.
  const TIER_THRESHOLDS = [40, 60, 80];
  const TIER_PTS        = [50, 100, 150];
  const TIER_LABELS     = ['Getting Started', 'On Track', 'Mastered'];
  const TIER_GROUPS = [
    { group: 'budget_master',      icon: '📊', name: 'Budget Master',      area: 'Budgeting',  dim: 'spending'   },
    { group: 'savings_champ',      icon: '🏦', name: 'Savings Champion',   area: 'Savings',    dim: 'savings'    },
    { group: 'debt_destroyer',     icon: '⚔️',  name: 'Debt Destroyer',    area: 'Debt',       dim: 'debt'       },
    { group: 'retirement_planner', icon: '🎯', name: 'Retirement Planner', area: 'Retirement', dim: 'retirement' },
    { group: 'insurance_hero',     icon: '🛡️',  name: 'Insurance Hero',    area: 'Insurance',  dim: 'insurance'  },
  ];

  // Award-defs that actually carry the tier points (one per group + tier).
  const TIER_DEFS = [];
  TIER_GROUPS.forEach(g => {
    TIER_THRESHOLDS.forEach((thr, i) => {
      TIER_DEFS.push({
        id: `${g.group}_t${i + 1}`, group: g.group, tier: i + 1, icon: g.icon,
        name: `${g.name} · Tier ${i + 1}`, desc: `Score ${thr}+ in ${g.area}`, pts: TIER_PTS[i],
      });
    });
  });

  // Legacy one-off score badges (pre-tier). Kept ONLY so historical earned
  // data and points migrate cleanly into the new tier ids; never shown as cards.
  const LEGACY_SCORE_IDS = TIER_GROUPS.map(g => g.group);
  const LEGACY_SCORE_DEFS = LEGACY_SCORE_IDS.map(id => ({ id, legacy: true, pts: 150 }));

  // BADGE_DEFS = everything that can be *awarded* (simple + tier ids).
  const BADGE_DEFS = [...SIMPLE_DEFS, ...TIER_DEFS];
  const DEF_MAP = Object.fromEntries([...BADGE_DEFS, ...LEGACY_SCORE_DEFS].map(d => [d.id, d]));
  const pointsFor = ids => ids.reduce((s, id) => s + (DEF_MAP[id]?.pts || 0), 0);

  // Highest tier (0–3) reached for an area. A legacy id counts as full (tier 3).
  function tierFor(earned, group) {
    if (!earned || !earned.length) return 0;
    if (earned.includes(group)) return 3;
    for (let i = 3; i >= 1; i--) { if (earned.includes(`${group}_t${i}`)) return i; }
    return 0;
  }

  // Expand any legacy score id into its three tier ids. Returns {earned, changed}.
  function migrateEarned(earned) {
    const set = new Set(earned || []);
    let changed = false;
    TIER_GROUPS.forEach(g => {
      if (set.has(g.group)) {
        set.delete(g.group); changed = true;
        for (let i = 1; i <= 3; i++) set.add(`${g.group}_t${i}`);
      }
    });
    return { earned: [...set], changed };
  }

  let _client = null;

  function ensureSupabase() {
    return new Promise((resolve, reject) => {
      if (global.supabase) return resolve();
      const s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2';
      s.onload = () => resolve();
      s.onerror = () => reject(new Error('Failed to load Supabase library'));
      document.head.appendChild(s);
    });
  }

  async function getClient() {
    if (_client) return _client;
    // Reuse shared client from index.html or tool pages if available
    if (global._kwSb)   { _client = global._kwSb;   return _client; }
    if (global._toolSb) { _client = global._toolSb; return _client; }
    await ensureSupabase();
    _client = global.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
    return _client;
  }

  function toast(msg) {
    try {
      const t = document.createElement('div');
      t.style.cssText = 'position:fixed;bottom:80px;left:50%;transform:translateX(-50%);' +
        'background:#1A2744;color:#fff;padding:11px 22px;border-radius:99px;font-size:13px;' +
        'font-weight:600;z-index:99999;box-shadow:0 4px 20px rgba(0,0,0,.3);white-space:nowrap';
      t.textContent = msg;
      document.body.appendChild(t);
      setTimeout(() => t.remove(), 3500);
    } catch (_) {}
  }

  async function award(badgeIds) {
    const incoming = (Array.isArray(badgeIds) ? badgeIds : [badgeIds]).filter(id => DEF_MAP[id]);
    if (!incoming.length) return [];

    const sb = await getClient();
    const { data: { user } } = await sb.auth.getUser();
    if (!user) { console.warn('[KWBadges] No logged-in user; cannot award badges.'); return []; }

    const { data: row, error: readErr } = await sb
      .from('badges').select('*').eq('user_id', user.id).maybeSingle();
    if (readErr) { console.error('[KWBadges] read error', readErr); return []; }

    const existing = (row && row.earned_badge_ids) || [];
    const fresh = incoming.filter(id => !existing.includes(id));
    if (!fresh.length) return [];

    const merged = [...existing, ...fresh];
    const points = pointsFor(merged);

    const { error: writeErr } = await sb.from('badges').upsert({
      user_id: user.id, earned_badge_ids: merged, points, updated_at: new Date().toISOString(),
    }, { onConflict: 'user_id' });
    if (writeErr) { console.error('[KWBadges] write error', writeErr); return []; }

    fresh.forEach(id => { const d = DEF_MAP[id]; toast(`🏆 Badge earned: ${d.name} (+${d.pts} pts)`); });
    const el = document.getElementById('sb-pts');
    if (el) el.textContent = points;
    return fresh;
  }

  // Persist a full earned array + recomputed points (used by the legacy→tier migration).
  async function setEarned(earned) {
    const sb = await getClient();
    const { data: { user } } = await sb.auth.getUser();
    if (!user) return;
    const points = pointsFor(earned);
    const { error } = await sb.from('badges').upsert({
      user_id: user.id, earned_badge_ids: earned, points, updated_at: new Date().toISOString(),
    }, { onConflict: 'user_id' });
    if (error) console.error('[KWBadges] setEarned error', error);
  }

  global.KWBadges = {
    BADGE_DEFS, DEF_MAP, pointsFor, award,
    SIMPLE_DEFS, TIER_GROUPS, TIER_DEFS, TIER_THRESHOLDS, TIER_PTS, TIER_LABELS,
    tierFor, migrateEarned, setEarned,
  };

  // Strip emoji and non-Latin symbols before writing text into jsPDF.
  // jsPDF's built-in fonts only cover Latin-1; multi-byte characters
  // render as "&"-separated bytes (garbled). Apply ONLY on the PDF path —
  // on-screen HTML renders emoji fine and should not be touched.
  function pdfSafe(text) {
    if (text == null) return '';
    return String(text)
      .replace(/[\u{1F000}-\u{1FFFF}]/gu, '')   // supplementary emoji planes
      .replace(/[\u{2600}-\u{27BF}]/gu,   '')   // misc symbols & dingbats (✓ ✗ ⚠ etc.)
      .replace(/[\u{2190}-\u{21FF}]/gu,   '')   // arrows
      .replace(/[\u{2B00}-\u{2BFF}]/gu,   '')   // misc symbols & arrows
      .replace(/[︀-️]/g,        '')   // variation selectors
      .replace(/\s{2,}/g, ' ')
      .trim();
  }
  global.pdfSafe = pdfSafe;

  // Suppress browser autofill/autocomplete on financial inputs portal-wide.
  // Runs after the DOM is ready on every page that includes this module.
  // Auth fields (email, password) are intentionally skipped so password managers keep working.
  function suppressFinancialAutofill() {
    const sel = 'input[type="number"], input[type="text"], input[inputmode="decimal"], input[inputmode="numeric"]';
    document.querySelectorAll(sel).forEach(function (el) {
      const t  = (el.type  || '').toLowerCase();
      const id = (el.id    || '').toLowerCase();
      const nm = (el.name  || '').toLowerCase();
      if (t === 'password' || t === 'email') return;
      if (id.includes('email') || id.includes('password') ||
          id.includes('login')  || id.includes('signin')  || id.includes('signup')) return;
      if (nm.includes('email') || nm.includes('password')) return;

      el.setAttribute('autocomplete',   'off');
      el.setAttribute('autocorrect',    'off');
      el.setAttribute('autocapitalize', 'off');
      el.setAttribute('spellcheck',     'false');
      el.setAttribute('data-form-type', 'other');
      // Randomise name so the browser cannot match it to a remembered field.
      // Safe because all tool inputs are read by id (getElementById / pf(id)), not by name.
      if (el.id) {
        el.setAttribute('name', 'kw_' + Math.random().toString(36).slice(2, 8));
      }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', suppressFinancialAutofill);
  } else {
    suppressFinancialAutofill();
  }
})(window);
