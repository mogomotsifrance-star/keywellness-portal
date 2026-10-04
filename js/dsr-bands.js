/* ================================================================
   Key Wellness — debt service ratio (DSR) bands
   The ONE browser copy of the DSR thresholds. Decided 4 Oct 2026.

   DSR = total monthly debt repayments ÷ gross monthly income × 100.
   Member side: gross salary (plus other income the member gave the DTI
   tool); where gross is not recorded, take-home pay, labelled as such (it
   reads higher than the true figure). Advisor side: the client's own gross
   income, i.e. gross salary plus their own business, rental and dividend
   income, never spouse income (decided 4 Oct 2026).

     healthy        below 40%
     manageable     40% up to below 50%
     strained       50% up to below 60%
     over_indebted  60% and above   (shown as "Overindebted")

   `max` is an EXCLUSIVE upper bound: exactly 40 is manageable, exactly 50
   is strained, exactly 60 is overindebted. kw_dti_band() in SQL reads the
   same numbers from threshold_config 'indicator.dsr', and the Edge
   Functions mirror them in supabase/functions/_shared/kw-finance.ts.
   Change all three together, or the member, the advisor and HR disagree.

   40 is the Key Wellness wellbeing BENCHMARK, the figure to advise
   towards. 60 is the over-indebtedness LINE used for risk flags. They are
   named separately on purpose: under the bands before this change the
   lending norm happened to equal the top of "manageable", and code read it
   from there. It no longer does.

   No other page may hold 40, 50 or 60 as a DSR threshold. Read them here.
   ================================================================ */
(function (g) {
  'use strict';

  var CFG = {
    benchmark: 40,
    line: 60,
    flagBand: 'over_indebted',
    bands: [
      { key: 'healthy',       max: 40,   label: 'Healthy',      tone: 'good' },
      { key: 'manageable',    max: 50,   label: 'Manageable',   tone: 'mid'  },
      { key: 'strained',      max: 60,   label: 'Strained',     tone: 'warn' },
      { key: 'over_indebted', max: null, label: 'Overindebted', tone: 'bad'  }
    ]
  };

  // Colours by tone, each page's own CSS variable first so a page keeps its
  // palette; the hex is the design-system value if the variable is absent.
  var TONE_COLOR = {
    good: 'var(--green, #2d8a4e)',
    mid:  'var(--gold, #c8973a)',
    warn: 'var(--orange, #e67e22)',
    bad:  'var(--red, #c0392b)',
    none: 'var(--muted, #6b7280)'
  };

  function num(x) {
    if (x === null || x === undefined || x === '') return null;
    var n = Number(x);
    return isFinite(n) ? n : null;
  }

  // Band key for a percentage, or null when there is no figure.
  function band(pct) {
    var p = num(pct);
    if (p === null) return null;
    for (var i = 0; i < CFG.bands.length; i++) {
      var m = CFG.bands[i].max;
      if (m === null || m === undefined || p < m) return CFG.bands[i].key;
    }
    return null;
  }

  function def(key) {
    for (var i = 0; i < CFG.bands.length; i++) if (CFG.bands[i].key === key) return CFG.bands[i];
    return null;
  }

  // Lower bound of a band (the previous band's max), for range text.
  function lower(key) {
    var prev = 0;
    for (var i = 0; i < CFG.bands.length; i++) {
      if (CFG.bands[i].key === key) return prev;
      prev = CFG.bands[i].max;
    }
    return null;
  }

  function trimNum(n) { return String(Math.round(n * 100) / 100); }

  // "below 40%", "40 to 49.99%", "60% and above"
  function rangeText(key) {
    var d = def(key); if (!d) return '';
    var lo = lower(key);
    if (lo === 0 || lo === null) return 'below ' + trimNum(d.max) + '%';
    if (d.max === null || d.max === undefined) return trimNum(lo) + '% and above';
    return trimNum(lo) + ' to ' + trimNum(d.max - 0.01) + '%';
  }

  function label(key) { var d = def(key); return d ? d.label : ''; }
  function tone(key) { var d = def(key); return d ? d.tone : 'none'; }
  function color(key) { return TONE_COLOR[tone(key)] || TONE_COLOR.none; }
  function isOver(pct) { return band(pct) === CFG.flagBand; }

  // Full description of a figure: { pct, key, label, tone, color }.
  function describe(pct) {
    var key = band(pct);
    return { pct: num(pct), key: key, label: label(key), tone: tone(key), color: color(key) };
  }

  function fmtPct(pct, dp) {
    var p = num(pct);
    if (p === null) return '';
    return p.toFixed(dp === undefined ? 1 : dp) + '%';
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  // Take the live threshold_config 'indicator.dsr' value if a page fetched
  // it. Only numbers move; labels and tones stay as written here, because
  // the config labels carry ranges for HR output.
  function applyConfig(v) {
    if (!v || !v.bands || !v.bands.length) return;
    var ok = v.bands.every(function (b) { return def(b.key); });
    if (!ok) return;
    v.bands.forEach(function (b) { def(b.key).max = b.max === null ? null : num(b.max); });
    if (num(v.benchmark) !== null) CFG.benchmark = num(v.benchmark);
    if (num(v.over_indebted_line) !== null) CFG.line = num(v.over_indebted_line);
  }

  /* ── Copy ──────────────────────────────────────────────────────
     Member copy is member-facing: no em dashes, en dashes or double
     hyphens. The copy checklist greps this file for them. */

  var TAKE_HOME_NOTE = 'Based on take-home pay, so likely higher than your true figure.';

  // income: the words for the basis. Member pages are on gross salary, so the
  // default is "your salary". The advisor's client report (PFA) is on the
  // client's own gross income and passes "your own gross income".
  function whyTwoMember(income) {
    return 'At ' + CFG.line + '% or more, debt repayments take so much of ' + (income || 'your salary') + ' that you are ' +
      'considered overindebted. That is the line we use to flag serious risk. Our wellbeing target is ' +
      'lower, below ' + CFG.benchmark + '%. At that level your repayments still leave enough room for ' +
      'your needs, your savings and the unexpected. Between the two you are not in crisis, but every ' +
      'step down towards ' + CFG.benchmark + '% gives you more breathing room.';
  }

  // The one-line statement plus the expandable "Why two numbers?".
  // opts.basis: 'gross' | 'take_home'. opts.grossPrompt: html for the
  // "enter your gross salary" nudge, shown only on take-home.
  function memberExplainHtml(pct, opts) {
    opts = opts || {};
    var d = describe(pct);
    if (d.pct === null) return '';
    var takeHome = opts.basis === 'take_home';
    var line = 'Your debt repayments take up ' + fmtPct(d.pct) + ' of your ' +
      (takeHome ? 'take-home pay' : 'gross salary') + '. This is ' + d.label + '.';
    return '<div class="kw-dsr-explain">' +
      '<p class="kw-dsr-line">' + esc(line) + '</p>' +
      (takeHome ? '<p class="kw-dsr-basis">' + esc(TAKE_HOME_NOTE) +
        (opts.grossPrompt ? ' ' + opts.grossPrompt : '') + '</p>' : '') +
      '<details class="kw-dsr-why"><summary>Why two numbers?</summary><p>' + esc(whyTwoMember()) +
      '</p></details></div>';
  }

  function advisorText() {
    var parts = CFG.bands.map(function (b) { return b.label + ' ' + rangeText(b.key); });
    return 'DSR = total monthly debt repayments ÷ the client\'s own gross monthly income (gross salary plus their own business, rental and dividend income; spouse income is not included). Bands: ' + parts.join(' · ') + '. ' +
      CFG.line + '% is the over-indebtedness line used for risk flags. ' + CFG.benchmark +
      '% is the Key Wellness wellbeing benchmark and the target to advise towards. A member between ' +
      CFG.benchmark + '% and ' + CFG.line + '% is not overindebted but should have a plan to bring DSR below ' +
      CFG.benchmark + '%. On the member side, where gross salary is missing, DSR is calculated on take-home pay and is marked as such.';
  }

  function advisorExplainHtml() {
    return '<details class="kw-dsr-why"><summary>Why two numbers?</summary><p>' + esc(advisorText()) +
      '</p></details>';
  }

  g.KWDsr = {
    get benchmark() { return CFG.benchmark; },
    get line() { return CFG.line; },
    get bands() { return CFG.bands.slice(); },
    flagBand: CFG.flagBand,
    band: band, label: label, tone: tone, color: color, rangeText: rangeText,
    describe: describe, isOver: isOver, fmtPct: fmtPct, applyConfig: applyConfig,
    TAKE_HOME_NOTE: TAKE_HOME_NOTE,
    whyTwoMember: whyTwoMember, memberExplainHtml: memberExplainHtml,
    advisorText: advisorText, advisorExplainHtml: advisorExplainHtml
  };
})(typeof window !== 'undefined' ? window : globalThis);
