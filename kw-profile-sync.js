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
      notice.style.cssText = 'background:#fffbf0;border-left:4px solid #c8973a;border-radius:0 8px 8px 0;padding:10px 16px;font-size:13px;color:#1a2744;margin-bottom:16px';
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
  function confirm(changes) {
    return new Promise(resolve => {
      if (!changes || !changes.length) return resolve(false);
      const ov = document.createElement('div');
      ov.id = 'kw-profile-modal';
      ov.style.cssText = 'position:fixed;inset:0;background:rgba(26,39,68,.6);z-index:9999;display:flex;align-items:center;justify-content:center;padding:20px;box-sizing:border-box';
      ov.innerHTML = `
        <div style="background:#fff;border-radius:12px;padding:28px 24px;max-width:400px;width:100%;box-shadow:0 8px 40px rgba(26,39,68,.3)">
          <div style="font-size:18px;font-weight:700;color:#1a2744;margin-bottom:8px">Update your profile?</div>
          <p style="font-size:13px;line-height:1.65;color:#6b7280;margin-bottom:20px">
            This will update your saved financial profile and recalculate your hub scores. Continue?
          </p>
          <div style="display:flex;gap:10px;flex-wrap:wrap">
            <button id="kwp-yes" style="flex:1;padding:11px 8px;background:#c8973a;color:#fff;border:none;border-radius:8px;font-weight:700;cursor:pointer;font-size:13px">Update profile</button>
            <button id="kwp-no"  style="flex:1;padding:11px 8px;background:#f5f0e8;color:#1a2744;border:none;border-radius:8px;font-weight:600;cursor:pointer;font-size:13px">Keep for this tool only</button>
          </div>
        </div>`;
      document.body.appendChild(ov);
      const cleanup = (val) => { document.body.removeChild(ov); resolve(val); };
      ov.querySelector('#kwp-yes').addEventListener('click', () => cleanup(true));
      ov.querySelector('#kwp-no').addEventListener('click',  () => cleanup(false));
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
