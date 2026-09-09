// kw-profile-sync.js — Shared financial profile read/write helper
// Requires: window._toolSb, window._toolUser (set by each tool's auth init IIFE)

const KWProfile = (function () {
  let _p = null;

  async function load() {
    if (!window._toolSb || !window._toolUser) return null;
    try {
      const { data } = await window._toolSb
        .from('profiles')
        .select('gross_income,net_income,other_income,monthly_income,monthly_expenses,total_assets,total_liabilities,monthly_debt,total_savings,monthly_savings,fin_updated_at')
        .eq('id', window._toolUser.id)
        .maybeSingle();
      _p = data || null;
    } catch (e) {
      console.warn('KWProfile.load error:', e);
      _p = null;
    }
    return _p;
  }

  function get(col) { return _p ? (_p[col] ?? null) : null; }

  function _applyVal(el, val) {
    if (el.type === 'number' || el.inputMode === 'numeric') {
      el.value = val;
    } else {
      // MUST use comma-thousands / dot-decimal (en-BW) — the tools' fmtInput strips non [0-9.]; en-ZA's
      // space-thousands + comma-decimal would be mis-parsed into a ×100 value.
      el.value = Number(val).toLocaleString('en-BW', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    }
    el.dataset.kwProfileCol = el.dataset.kwProfileCol || '';
    el.dataset.kwProfileVal = String(val);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // mappings: [{inputId, col}]  — col is the profiles column name
  function prefill(mappings, noticeParentSelector) {
    if (!_p) return [];
    const filled = [];

    mappings.forEach(({ inputId, col }) => {
      const val = _p[col];
      if (val == null || val === 0) return;
      const el = document.getElementById(inputId);
      if (!el) return;
      el.dataset.kwProfileCol = col;
      _applyVal(el, val);
      filled.push({ inputId, col, val });
    });

    if (filled.length > 0 && !document.getElementById('kw-profile-notice')) {
      const notice = document.createElement('div');
      notice.id = 'kw-profile-notice';
      notice.style.cssText = 'background:var(--kw-yellow-tint);border-left:4px solid var(--kw-yellow-ink);border-radius:0 8px 8px 0;padding:10px 16px;font-size:13px;color:var(--kw-ink);margin-bottom:16px';
      notice.innerHTML = '<strong>Pre-filled from your profile.</strong> Adjust below if needed — when you save we\'ll ask whether to update your shared profile.';
      const parent = noticeParentSelector
        ? document.querySelector(noticeParentSelector)
        : (document.querySelector('.container') || document.querySelector('main') || document.body);
      if (parent) parent.insertBefore(notice, parent.firstChild);
    }
    return filled;
  }

  // Returns [{col, newVal}] for any prefilled field whose value changed
  function detectChanges(mappings) {
    if (!_p) return [];
    return mappings
      .map(({ inputId, col }) => {
        const el = document.getElementById(inputId);
        if (!el || el.dataset.kwProfileCol !== col) return null;
        const orig = parseFloat(el.dataset.kwProfileVal || '0');
        const curr = parseFloat((el.value || '0').toString().replace(/,/g, ''));
        if (isNaN(curr) || Math.abs(curr - orig) < 0.01) return null;
        return { col, newVal: curr };
      })
      .filter(Boolean);
  }

  // Show the "update profile?" modal. Returns a Promise<boolean>.
  //
  // opts (all optional): { title, body, yesLabel, noLabel, defaultYes }
  // defaultYes focuses the Yes button and makes Enter accept it — for the budget,
  // where saying yes is the expected answer because the budget IS the source of
  // truth for these figures (P0-5). Escape always answers no; a dialog that a
  // member cannot decline is not a question.
  function confirm(changes, opts) {
    const o = opts || {};
    return new Promise(resolve => {
      if (!changes || !changes.length) return resolve(false);
      const esc = (t) => String(t).replace(/[&<>"]/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;' }[c]));
      const ov = document.createElement('div');
      ov.id = 'kw-profile-modal';
      ov.style.cssText = 'position:fixed;inset:0;background:rgba(35,38,31,.6);z-index:9999;display:flex;align-items:center;justify-content:center;padding:20px;box-sizing:border-box';
      ov.innerHTML = `
        <div style="background:#fff;border-radius:12px;padding:28px 24px;max-width:420px;width:100%;box-shadow:0 8px 40px rgba(35,38,31,.3)">
          <div style="font-size:18px;font-weight:700;color:var(--kw-ink);margin-bottom:8px">${esc(o.title || 'Update your profile?')}</div>
          <p style="font-size:13px;line-height:1.65;color:var(--kw-grey);margin-bottom:20px">
            ${esc(o.body || 'This will update your saved financial profile and recalculate your hub scores. Continue?')}
          </p>
          <div style="display:flex;gap:10px;flex-wrap:wrap">
            <button id="kwp-yes" style="flex:1;padding:11px 8px;background:var(--kw-green);color:#fff;border:none;border-radius:8px;font-weight:700;cursor:pointer;font-size:13px">${esc(o.yesLabel || 'Update profile')}</button>
            <button id="kwp-no"  style="flex:1;padding:11px 8px;background:var(--kw-surface);color:var(--kw-ink);border:none;border-radius:8px;font-weight:600;cursor:pointer;font-size:13px">${esc(o.noLabel || 'Keep for this tool only')}</button>
          </div>
        </div>`;
      document.body.appendChild(ov);
      const onKey = (e) => { if (e.key === 'Escape') cleanup(false); };
      const cleanup = (val) => {
        document.removeEventListener('keydown', onKey);
        if (ov.parentNode) document.body.removeChild(ov);
        resolve(val);
      };
      document.addEventListener('keydown', onKey);
      ov.querySelector('#kwp-yes').addEventListener('click', () => cleanup(true));
      ov.querySelector('#kwp-no').addEventListener('click',  () => cleanup(false));
      if (o.defaultYes !== false) setTimeout(() => ov.querySelector('#kwp-yes').focus(), 0);
    });
  }

  async function writeBack(changes) {
    if (!window._toolSb || !window._toolUser || !changes || !changes.length) return;
    const payload = { fin_updated_at: new Date().toISOString() };
    changes.forEach(({ col, newVal }) => { payload[col] = newVal; });
    const { error } = await window._toolSb.from('profiles').update(payload).eq('id', window._toolUser.id);
    if (error) { console.error('KWProfile.writeBack failed:', error); return; }
    if (typeof showToast === 'function') showToast('Profile updated.');
    // Keep local copy in sync
    if (_p) changes.forEach(({ col, newVal }) => { _p[col] = newVal; });
  }

  // Convenience: detect changes, ask, and write if confirmed
  async function maybeWriteBack(mappings) {
    const changes = detectChanges(mappings);
    if (!changes.length) return;
    const ok = await confirm(changes);
    if (ok) await writeBack(changes);
  }

  return { load, get, prefill, detectChanges, confirm, writeBack, maybeWriteBack };
})();

// ─────────────────────────────────────────────────────────────────────────────
// KWSource — where a prefilled figure actually came from (P0-5, audit F7).
//
// DTI and Retirement both told the member "Income pulled from your Budget
// Planner" when the figure had in fact come from the assessment. A source line
// that names the wrong tool is worse than none: the member goes to the budget to
// correct it and finds nothing there to correct.
//
// The honest test is two-part — profiles.fin_updated_at proves SOMETHING wrote
// the shared figures, and a saved budget proves the budget existed to be that
// something. Neither alone is enough, so when in doubt this says "your profile",
// which is true whatever wrote it.
// ─────────────────────────────────────────────────────────────────────────────
const KWSource = (function () {
  let _budget = null;   // null = not yet checked

  async function budgetSaved() {
    if (_budget !== null) return _budget;
    _budget = false;
    if (!window._toolSb || !window._toolUser) return _budget;
    try {
      const { data } = await window._toolSb.from('tool_data').select('data')
        .eq('user_id', window._toolUser.id).eq('tool', 'budget_planner').maybeSingle();
      const d = data && data.data;
      _budget = !!(d && d.currentKey && d.budgets && d.budgets[d.currentKey]);
    } catch (e) { console.warn('KWSource.budgetSaved failed:', e); }
    return _budget;
  }

  function label(profile, fromBudget) {
    return (profile && profile.fin_updated_at && fromBudget) ? 'from your budget' : 'from your profile';
  }
  function line(profile, fromBudget) { return 'Pre-filled ' + label(profile, fromBudget); }

  // Resolve and write the line in one call, for the common case.
  async function apply(elId, profile, suffix) {
    const el = document.getElementById(elId);
    if (!el) return;
    el.textContent = line(profile, await budgetSaved()) + (suffix || '');
    el.style.display = '';
  }

  return { budgetSaved, label, line, apply };
})();
