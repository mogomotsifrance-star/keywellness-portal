/* kw-badges.js — Key Wellness shared badge engine (single source of truth) */
(function (global) {
  'use strict';

  const SUPABASE_URL = 'https://tarmpqxsabbehgjaonfz.supabase.co';
  const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRhcm1wcXhzYWJiZWhnamFvbmZ6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE1MjA2MjQsImV4cCI6MjA5NzA5NjYyNH0.Em-NvJVY_geHk6UOTxnpINgUw669V8W_9YvAi_koX9U';

  const BADGE_DEFS = [
    { id: 'first_login',        icon: '🌟', name: 'First Step',         desc: 'Completed onboarding',             pts: 50  },
    { id: 'first_assessment',   icon: '📋', name: 'Self-Aware',         desc: 'Completed first assessment',       pts: 100 },
    { id: 'budget_master',      icon: '📊', name: 'Budget Master',      desc: 'Score 80+ in Budgeting',           pts: 150 },
    { id: 'savings_champ',      icon: '🏦', name: 'Savings Champion',   desc: 'Score 80+ in Savings',             pts: 150 },
    { id: 'debt_destroyer',     icon: '⚔️',  name: 'Debt Destroyer',    desc: 'Score 80+ in Debt',                pts: 150 },
    { id: 'retirement_planner', icon: '🎯', name: 'Retirement Planner', desc: 'Score 80+ in Retirement',          pts: 150 },
    { id: 'insurance_hero',     icon: '🛡️',  name: 'Insurance Hero',    desc: 'Score 80+ in Insurance',           pts: 150 },
    { id: 'high_scorer',        icon: '💯', name: 'Financial Star',     desc: 'Overall score of 75+',             pts: 200 },
    { id: 'ef_started',         icon: '🆘', name: 'Safety Net Started', desc: 'Opened Emergency Fund Planner',    pts: 75  },
    { id: 'ef_halfway',         icon: '🛟', name: 'Halfway Safe',       desc: 'Emergency fund 50% funded',        pts: 150 },
    { id: 'ef_complete',        icon: '🏰', name: 'Fortress Built',     desc: 'Emergency fund fully funded',      pts: 300 },
    { id: 'check_in_1',         icon: '✅', name: 'On Track',           desc: 'Completed first monthly check-in', pts: 75  },
    { id: 'check_in_3',         icon: '🔥', name: 'Consistent',         desc: '3 monthly check-ins',              pts: 150 },
    { id: 'booked_session',     icon: '📅', name: 'Getting Help',       desc: 'Booked a coaching session',        pts: 100 },
    { id: 'watched_video',      icon: '🎬', name: 'Knowledge Seeker',   desc: 'Watched a learning video',         pts: 25  },
  ];

  const DEF_MAP = Object.fromEntries(BADGE_DEFS.map(d => [d.id, d]));
  const pointsFor = ids => ids.reduce((s, id) => s + (DEF_MAP[id]?.pts || 0), 0);

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

  global.KWBadges = { BADGE_DEFS, DEF_MAP, pointsFor, award };
})(window);
