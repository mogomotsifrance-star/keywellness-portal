/* kw-badges.js — Key Wellness shared badge engine (single source of truth) */
(function (global) {
  'use strict';

  const SUPABASE_URL = 'https://tarmpqxsabbehgjaonfz.supabase.co';
  const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRhcm1wcXhzYWJiZWhnamFvbmZ6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE1MjA2MjQsImV4cCI6MjA5NzA5NjYyNH0.Em-NvJVY_geHk6UOTxnpINgUw669V8W_9YvAi_koX9U';

  // ── Simple one-off badges (each rendered as a single card) ──
  // Behaviour areas that grow over time (EF, check-ins, learning, savings,
  // retirement, investing, budgeting) are NOT here — they live in
  // PROGRESS_DEFS below as single "filling" badges. The ids removed from this
  // list (ef_started/halfway/complete, check_in_1/3, watched_video) are kept in
  // LEGACY_PROGRESS_MAP so historical earners migrate into the right fill tier.
  const SIMPLE_DEFS = [
    { id: 'first_login',        icon: '🌟', name: 'First Step',         desc: 'Completed onboarding',                  pts: 50  },
    { id: 'first_assessment',   icon: '📋', name: 'Self-Aware',         desc: 'Completed first assessment',            pts: 100 },
    { id: 'high_scorer',        icon: '💯', name: 'Financial Star',     desc: 'Overall score of 75+',                  pts: 200 },
    { id: 'booked_session',     icon: '📅', name: 'Getting Help',       desc: 'Booked a coaching session',             pts: 100 },
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

  // ════════════════════════════════════════════════════════════════════
  //  PART 0 — PROGRESS-CAPABLE BADGE MODEL ("filling" badges)
  //  A single badge fills across tiers as a live behaviour metric rises.
  //  Each def declares:
  //    id        — group id; tier award ids are `${id}_t1`, `${id}_t2`, …
  //    kind      — 'state'       : fill reflects CURRENT value, may go DOWN
  //                                (points already earned are never stripped).
  //                'achievement' : fill never visually drops below the highest
  //                                tier reached; points are sticky.
  //    unit      — 'pct'  : metric is 0–100, glass fills to the value.
  //                'count': metric is 0..max, glass fills value/max.
  //    max       — (count only) value that fills the glass to 100%.
  //    tiers     — [{ threshold, label, pts }] ordered low→high. A tier is
  //                "reached" when metric >= threshold; its pts are awarded once.
  //  Current progress is computed by the host from live Supabase data and fed
  //  to award()/render — see computeBadgeMetrics() in index.html. A snapshot of
  //  {tier,pct,lastUpdated} per badge is also cached to tool_data='badge_progress'
  //  so the fill is consistent across devices before raw data reloads.
  // ════════════════════════════════════════════════════════════════════
  const PROGRESS_DEFS = [
    // PART 1 — Emergency Fund (current-state; fills AND empties)
    { id:'ef', icon:'🛟', name:'Safety Net', kind:'state', unit:'pct',
      blurb:'Emergency fund vs 6 months of essential expenses',
      tiers:[
        { threshold:1,   label:'Set up',       pts:75  },
        { threshold:50,  label:'Halfway',      pts:150 },
        { threshold:100, label:'Fully funded', pts:300 },
      ] },
    // PART 2 — Retirement Readiness (current-state; toward 70%-of-gross goal)
    { id:'retire_ready', icon:'🎯', name:'Retirement Ready', kind:'state', unit:'pct',
      blurb:'Projected pension vs 70% of your gross salary',
      tiers:[
        { threshold:25,  label:'On the board', pts:75  },
        { threshold:50,  label:'Halfway',      pts:125 },
        { threshold:75,  label:'Nearly there', pts:175 },
        { threshold:100, label:'Retirement ready', pts:250 },
      ] },
    // PART 3a — Savings-rate milestones (achievement; % of NET pay saved)
    { id:'savings_rate', icon:'🏦', name:'Savings Rate', kind:'achievement', unit:'pct',
      blurb:'Share of your net pay that you save',
      tiers:[
        { threshold:5,   label:'5% saved',  pts:75  },
        { threshold:10,  label:'10% saved', pts:125 },
        { threshold:20,  label:'20% saved', pts:250 },
      ] },
    // PART 3b — Sustained saving (achievement; 3 consecutive months >= 20%)
    { id:'savings_streak', icon:'🔁', name:'Steady Saver', kind:'achievement', unit:'count', max:3,
      blurb:'Consecutive budgeting months saving 20% or more',
      tiers:[
        { threshold:1, label:'1 month at 20%',  pts:75  },
        { threshold:2, label:'2 months at 20%', pts:100 },
        { threshold:3, label:'3 months at 20%', pts:225 },
      ] },
    // PART 4 — Investing + positive net worth, per quarter (achievement)
    { id:'investor', icon:'📈', name:'Quarterly Investor', kind:'achievement', unit:'count', max:4,
      blurb:'Quarters with the investing tool used and positive net worth',
      tiers:[
        { threshold:1, label:'1 quarter', pts:100 },
        { threshold:2, label:'2 quarters', pts:100 },
        { threshold:3, label:'3 quarters', pts:100 },
        { threshold:4, label:'Full year', pts:150 },
      ] },
    // PART 5 — Fortnightly check-ins, time-based (achievement)
    { id:'checkin_streak', icon:'✅', name:'Check-in Streak', kind:'achievement', unit:'count', max:3,
      blurb:'Fortnightly check-ins about two weeks apart',
      tiers:[
        { threshold:1, label:'First check-in', pts:75  },
        { threshold:2, label:'Two check-ins',  pts:75  },
        { threshold:3, label:'Three check-ins', pts:150 },
      ] },
    // PART 6 — Learning engagement (drives the "confidence" indicator)
    { id:'learning', icon:'📚', name:'Confident Learner', kind:'achievement', unit:'pct',
      blurb:'Learn content engaged — articles read + videos completed',
      tiers:[
        { threshold:25,  label:'Curious',   pts:50  },
        { threshold:50,  label:'Engaged',   pts:100 },
        { threshold:100, label:'Confident', pts:200 },
      ] },
    // PART 7 — Budget consistency, one tier per budgeting month (achievement)
    { id:'budget_year', icon:'🗓️', name:'Budget Discipline', kind:'achievement', unit:'count', max:12,
      blurb:'Months with a maintained budget (up to a full year)',
      tiers: Array.from({ length:12 }, (_, i) => ({
        threshold:i + 1, label:`${i + 1} month${i ? 's' : ''}`, pts:50,
      })) },
  ];

  // Legacy one-off ids → the progress group + the tier index they represent.
  // On migration the user is credited tiers 1..index of that group.
  const LEGACY_PROGRESS_MAP = {
    ef_started:  { group:'ef', tier:1 },
    ef_halfway:  { group:'ef', tier:2 },
    ef_complete: { group:'ef', tier:3 },
    check_in_1:  { group:'checkin_streak', tier:1 },
    check_in_3:  { group:'checkin_streak', tier:3 },
    watched_video:{ group:'learning', tier:1 },
  };

  const PROGRESS_MAP = Object.fromEntries(PROGRESS_DEFS.map(d => [d.id, d]));

  // Expand each progress def into per-tier award defs (these carry the points).
  const PROGRESS_TIER_DEFS = [];
  PROGRESS_DEFS.forEach(d => {
    d.tiers.forEach((t, i) => {
      PROGRESS_TIER_DEFS.push({
        id:`${d.id}_t${i + 1}`, group:d.id, tier:i + 1,
        icon:d.icon, name:`${d.name} · ${t.label}`, desc:t.label, pts:t.pts,
      });
    });
  });

  // tier award ids for a progress def, e.g. ['ef_t1','ef_t2','ef_t3']
  function progressTierIds(def) {
    return def.tiers.map((_, i) => `${def.id}_t${i + 1}`);
  }
  // How many tiers a live metric value has reached (count of thresholds met).
  function tiersReached(def, value) {
    const v = Number(value) || 0;
    return def.tiers.filter(t => v >= t.threshold).length;
  }
  // How many tiers already have their points credited (persisted in `earned`).
  function tiersEarned(def, earned) {
    const set = new Set(earned || []);
    return progressTierIds(def).filter(id => set.has(id)).length;
  }
  // Glass fill 0–100 for a metric value. Achievement badges never visually drop
  // below the highest tier already earned; state badges show the live value.
  function progressFill(def, value, earned) {
    const v = Number(value) || 0;
    let pct = def.unit === 'count'
      ? (def.max ? (v / def.max) * 100 : 0)
      : v;
    pct = Math.max(0, Math.min(100, pct));
    if (def.kind === 'achievement') {
      const n = Math.max(tiersReached(def, value), tiersEarned(def, earned));
      if (n > 0) {
        const reached = def.tiers[n - 1].threshold;
        const floor = def.unit === 'count'
          ? (def.max ? (reached / def.max) * 100 : 0)
          : reached;
        pct = Math.max(pct, floor);
      }
    }
    return Math.round(pct);
  }

  // BADGE_DEFS = everything that can be *awarded* (simple + assessment tiers + progress tiers).
  const BADGE_DEFS = [...SIMPLE_DEFS, ...TIER_DEFS, ...PROGRESS_TIER_DEFS];
  const DEF_MAP = Object.fromEntries([...BADGE_DEFS, ...LEGACY_SCORE_DEFS].map(d => [d.id, d]));
  const pointsFor = ids => ids.reduce((s, id) => s + (DEF_MAP[id]?.pts || 0), 0);

  // Award all tiers of a progress badge that the live metric has reached.
  // Sticky + deduped by award(); never strips a tier even if `value` later drops.
  async function awardProgress(groupId, value) {
    const def = PROGRESS_MAP[groupId];
    if (!def) return [];
    const n = tiersReached(def, value);
    if (n <= 0) return [];
    return award(progressTierIds(def).slice(0, n));
  }

  // Highest tier (0–3) reached for an area. A legacy id counts as full (tier 3).
  function tierFor(earned, group) {
    if (!earned || !earned.length) return 0;
    if (earned.includes(group)) return 3;
    for (let i = 3; i >= 1; i--) { if (earned.includes(`${group}_t${i}`)) return i; }
    return 0;
  }

  // Migrate legacy earned ids into the new tier id scheme. Handles BOTH the
  // assessment-dimension groups (one-off score id → 3 tier ids) and the
  // behaviour progress badges (ef_*/check_in_*/watched_video → fill tiers).
  // Idempotent; returns {earned, changed}.
  function migrateEarned(earned) {
    const set = new Set(earned || []);
    let changed = false;
    // Assessment dimensions: legacy "budget_master" → budget_master_t1..t3
    TIER_GROUPS.forEach(g => {
      if (set.has(g.group)) {
        set.delete(g.group); changed = true;
        for (let i = 1; i <= 3; i++) set.add(`${g.group}_t${i}`);
      }
    });
    // Behaviour progress: ef_started/halfway/complete, check_in_1/3, watched_video
    Object.entries(LEGACY_PROGRESS_MAP).forEach(([legacyId, m]) => {
      if (set.has(legacyId)) {
        set.delete(legacyId); changed = true;
        for (let i = 1; i <= m.tier; i++) set.add(`${m.group}_t${i}`);
      }
    });
    return { earned: [...set], changed };
  }

  // Persist a per-badge fill snapshot { badgeId: {tier, pct, lastUpdated} } to
  // tool_data='badge_progress' so fills are consistent across devices before the
  // raw tool data reloads. Earned tier ids (in the badges table) remain the
  // authoritative record of which points were credited; this is display cache.
  async function saveProgress(progressMap) {
    try {
      const sb = await getClient();
      const { data: { user } } = await sb.auth.getUser();
      if (!user) return;
      await sb.from('tool_data').upsert({
        user_id: user.id, tool: 'badge_progress',
        data: progressMap || {}, updated_at: new Date().toISOString(),
      }, { onConflict: 'user_id,tool' });
    } catch (e) { console.warn('[KWBadges] saveProgress skipped:', e); }
  }
  async function loadProgress() {
    try {
      const sb = await getClient();
      const { data: { user } } = await sb.auth.getUser();
      if (!user) return {};
      const { data } = await sb.from('tool_data').select('data')
        .eq('user_id', user.id).eq('tool', 'badge_progress').maybeSingle();
      return (data && data.data) || {};
    } catch (e) { return {}; }
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
    // Progress-capable (filling) badge model — Part 0
    PROGRESS_DEFS, PROGRESS_MAP, PROGRESS_TIER_DEFS,
    progressTierIds, tiersReached, tiersEarned, progressFill, awardProgress,
    saveProgress, loadProgress,
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
