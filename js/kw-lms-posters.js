// js/kw-lms-posters.js — AURORA/GLASS lesson poster illustrations
// kwPoster(item, width) → inline SVG string
// item: content_items DB row { sort_order, title, section_label, duration_seconds }

(function (global) {
  'use strict';

  var G1 = '#E8C018', G2 = '#F4DC7A', W = 'white', DK = '#10240F';

  var SEC_GRAD = {
    'Mindset & Psychology':  ['#0F3D24', '#1A5E38'],
    'Diagnosis & Direction': ['#083543', '#125668'],
    'Practical Foundations': ['#3E2508', '#664010'],
    'Protection & Debt':     ['#131E30', '#1E304A'],
    'Wealth Thinking':       ['#3D1610', '#62261A'],
  };
  var NAV_GRAD = ['#0F1B30', '#1A2D4E'];

  // ── Illustrations (drawn in 100 × 100 coordinate space) ───────────────
  // Palette: G1 (#E8C018) main gold · G2 (#F4DC7A) soft gold ·
  //          W (white) line work  ·  DK (#10240F) deep-ink detail
  var ILLOS = {

    // 0 — Welcome to Key Wellness: ornate key
    0: '<circle cx="40" cy="50" r="21" fill="none" stroke="' + W + '" stroke-width="5.5" opacity=".9"/>' +
       '<circle cx="40" cy="50" r="14" fill="' + G1 + '"/>' +
       '<circle cx="40" cy="50" r="6" fill="' + DK + '"/>' +
       '<rect x="57" y="47" width="33" height="7" rx="3.5" fill="' + G1 + '"/>' +
       '<rect x="75" y="54" width="8" height="11" rx="3.5" fill="' + G2 + '"/>' +
       '<rect x="83" y="54" width="7" height="8" rx="3" fill="' + G2 + '"/>',

    // 1 — Introduction to Financial Literacy: open book + light rays
    1: '<path d="M48,22 L16,30 14,78 48,72 Z" fill="' + G1 + '"/>' +
       '<path d="M52,22 L84,30 86,78 52,72 Z" fill="' + G2 + '"/>' +
       '<rect x="47" y="22" width="6" height="50" rx="2" fill="' + W + '" opacity=".85"/>' +
       '<line x1="22" y1="44" x2="44" y2="40" stroke="' + W + '" stroke-width="2" opacity=".55"/>' +
       '<line x1="22" y1="54" x2="44" y2="50" stroke="' + W + '" stroke-width="2" opacity=".55"/>' +
       '<line x1="22" y1="64" x2="44" y2="60" stroke="' + W + '" stroke-width="2" opacity=".55"/>' +
       '<line x1="50" y1="18" x2="50" y2="4" stroke="' + W + '" stroke-width="2.5" stroke-linecap="round" opacity=".9"/>' +
       '<line x1="50" y1="18" x2="60" y2="7" stroke="' + W + '" stroke-width="2" stroke-linecap="round" opacity=".7"/>' +
       '<line x1="50" y1="18" x2="40" y2="7" stroke="' + W + '" stroke-width="2" stroke-linecap="round" opacity=".7"/>' +
       '<line x1="50" y1="18" x2="67" y2="12" stroke="' + W + '" stroke-width="1.5" stroke-linecap="round" opacity=".5"/>' +
       '<line x1="50" y1="18" x2="33" y2="12" stroke="' + W + '" stroke-width="1.5" stroke-linecap="round" opacity=".5"/>',

    // 2 — Understanding Your Relationship with Money: heart + Pula coin
    2: '<circle cx="64" cy="58" r="26" fill="' + G1 + '"/>' +
       '<circle cx="64" cy="58" r="20" fill="' + G2 + '"/>' +
       '<text x="64" y="66" text-anchor="middle" font-size="21" font-weight="bold" fill="' + DK + '" font-family="serif">P</text>' +
       '<path d="M34,46 C34,32 14,32 14,46 C14,56 34,72 34,72 C34,72 54,56 54,46 C54,32 34,32 34,46 Z" fill="' + W + '" opacity=".85"/>' +
       '<path d="M34,48 C34,37 19,37 19,48 C19,56 34,68 34,68 C34,68 49,56 49,48 C49,37 34,37 34,48 Z" fill="' + G1 + '"/>',

    // 3 — Emotional Spending: shopping bag + impulse spark
    3: '<path d="M30,30 C30,14 70,14 70,30" fill="none" stroke="' + W + '" stroke-width="5" stroke-linecap="round"/>' +
       '<path d="M14,30 L18,84 L82,84 L86,30 Z" fill="' + G1 + '"/>' +
       '<rect x="14" y="25" width="72" height="8" rx="2" fill="' + G2 + '"/>' +
       '<path d="M28,56 Q36,46 44,56 Q52,66 60,56 Q68,46 76,56" stroke="' + W + '" stroke-width="3" fill="none" stroke-linecap="round" opacity=".9"/>' +
       '<path d="M78,15 L80,8 L82,15 L89,13 L84,17.5 L86.5,25 L80,20.5 L73.5,25 L76,17.5 L71,13 Z" fill="' + G2 + '" opacity=".92"/>',

    // 4 — Lifestyle Inflation: expanding rings + upward arrow
    4: '<circle cx="50" cy="60" r="40" fill="none" stroke="' + G1 + '" stroke-width="1.5" opacity=".22"/>' +
       '<circle cx="50" cy="60" r="29" fill="none" stroke="' + G1 + '" stroke-width="2" opacity=".38"/>' +
       '<circle cx="50" cy="60" r="19" fill="none" stroke="' + G1 + '" stroke-width="2.5" opacity=".58"/>' +
       '<circle cx="50" cy="60" r="10" fill="' + G1 + '" opacity=".75"/>' +
       '<line x1="50" y1="78" x2="50" y2="10" stroke="' + W + '" stroke-width="5" stroke-linecap="round"/>' +
       '<path d="M36,28 L50,8 L64,28 Z" fill="' + W + '"/>' +
       '<text x="50" y="65" text-anchor="middle" font-size="10" font-weight="bold" fill="' + DK + '" font-family="sans-serif">P</text>',

    // 5 — Qualifying vs Affording: balance scale
    5: '<line x1="50" y1="12" x2="50" y2="72" stroke="' + W + '" stroke-width="4" stroke-linecap="round"/>' +
       '<path d="M32,72 L50,72 L68,72 L72,84 L28,84 Z" fill="' + W + '" opacity=".7"/>' +
       '<line x1="6" y1="28" x2="94" y2="22" stroke="' + G1 + '" stroke-width="5" stroke-linecap="round"/>' +
       '<path d="M0,34 Q8,52 18,52 Q28,52 36,34 Z" fill="' + G1 + '"/>' +
       '<path d="M64,28 Q72,44 82,44 Q92,44 100,28 Z" fill="' + G2 + '"/>' +
       '<line x1="6" y1="28" x2="18" y2="34" stroke="' + W + '" stroke-width="1.5" opacity=".55"/>' +
       '<line x1="36" y1="34" x2="24" y2="28" stroke="' + W + '" stroke-width="1.5" opacity=".55"/>' +
       '<line x1="64" y1="28" x2="72" y2="34" stroke="' + W + '" stroke-width="1.5" opacity=".55"/>' +
       '<line x1="100" y1="28" x2="88" y2="34" stroke="' + W + '" stroke-width="1.5" opacity=".55"/>' +
       '<text x="18" y="49" text-anchor="middle" font-size="18" fill="' + DK + '" font-family="sans-serif">✓</text>' +
       '<text x="82" y="41" text-anchor="middle" font-size="14" fill="' + DK + '" font-weight="bold" font-family="sans-serif">P</text>',

    // 6 — The Three Money Problems: three overlapping coin-circles
    6: '<circle cx="30" cy="40" r="23" fill="' + G1 + '" opacity=".95"/>' +
       '<circle cx="70" cy="40" r="23" fill="' + G1 + '" opacity=".85"/>' +
       '<circle cx="50" cy="68" r="23" fill="' + G1 + '" opacity=".75"/>' +
       '<circle cx="30" cy="40" r="16" fill="' + G2 + '" opacity=".45"/>' +
       '<circle cx="70" cy="40" r="16" fill="' + G2 + '" opacity=".4"/>' +
       '<circle cx="50" cy="68" r="16" fill="' + G2 + '" opacity=".38"/>' +
       '<text x="27" y="46" text-anchor="middle" font-size="18" font-weight="bold" fill="' + DK + '" font-family="sans-serif">1</text>' +
       '<text x="73" y="46" text-anchor="middle" font-size="18" font-weight="bold" fill="' + DK + '" font-family="sans-serif">2</text>' +
       '<text x="50" y="74" text-anchor="middle" font-size="18" font-weight="bold" fill="' + DK + '" font-family="sans-serif">3</text>',

    // 7 — Setting SMART Goals: bullseye target + arrow
    7: '<circle cx="50" cy="52" r="36" fill="none" stroke="' + G1 + '" stroke-width="3.5"/>' +
       '<circle cx="50" cy="52" r="24" fill="none" stroke="' + G1 + '" stroke-width="3.5"/>' +
       '<circle cx="50" cy="52" r="12" fill="' + G1 + '"/>' +
       '<circle cx="50" cy="52" r="5" fill="' + DK + '"/>' +
       '<line x1="10" y1="12" x2="51" y2="51" stroke="' + W + '" stroke-width="4" stroke-linecap="round"/>' +
       '<path d="M4,8 L16,6 L18,18 Z" fill="' + W + '"/>' +
       '<circle cx="51" cy="51" r="3.5" fill="' + G2 + '"/>',

    // 8 — Understanding Your Payslip: document with rows + Pula header
    8: '<rect x="18" y="6" width="64" height="86" rx="6" fill="' + G1 + '"/>' +
       '<rect x="22" y="10" width="56" height="20" rx="3" fill="' + G2 + '" opacity=".55"/>' +
       '<text x="50" y="27" text-anchor="middle" font-size="17" font-weight="bold" fill="' + DK + '" font-family="serif">P</text>' +
       '<rect x="26" y="36" width="32" height="4" rx="2" fill="' + W + '" opacity=".7"/>' +
       '<rect x="62" y="36" width="14" height="4" rx="2" fill="' + W + '" opacity=".7"/>' +
       '<rect x="26" y="46" width="28" height="4" rx="2" fill="' + W + '" opacity=".6"/>' +
       '<rect x="62" y="46" width="14" height="4" rx="2" fill="' + W + '" opacity=".6"/>' +
       '<rect x="26" y="56" width="36" height="4" rx="2" fill="' + W + '" opacity=".5"/>' +
       '<rect x="66" y="56" width="10" height="4" rx="2" fill="' + W + '" opacity=".5"/>' +
       '<line x1="22" y1="66" x2="74" y2="66" stroke="' + W + '" stroke-width="1.5" opacity=".4"/>' +
       '<rect x="26" y="72" width="24" height="6" rx="3" fill="' + G2 + '" opacity=".8"/>' +
       '<rect x="56" y="72" width="18" height="6" rx="3" fill="' + G2 + '" opacity=".8"/>',

    // 9 — Creating a Personal Budget: horizontal budget bars
    9: '<rect x="10" y="14" width="80" height="10" rx="5" fill="' + G1 + '"/>' +
       '<rect x="10" y="32" width="64" height="10" rx="5" fill="' + G2 + '"/>' +
       '<rect x="10" y="50" width="44" height="10" rx="5" fill="' + G1 + '" opacity=".7"/>' +
       '<rect x="10" y="68" width="28" height="10" rx="5" fill="' + G2 + '" opacity=".7"/>' +
       '<line x1="8" y1="84" x2="92" y2="84" stroke="' + W + '" stroke-width="2.5" opacity=".4"/>' +
       '<text x="95" y="23" font-size="8" fill="' + W + '" opacity=".75" font-family="monospace">50%</text>' +
       '<text x="79" y="41" font-size="8" fill="' + W + '" opacity=".75" font-family="monospace">30%</text>' +
       '<text x="59" y="59" font-size="8" fill="' + W + '" opacity=".75" font-family="monospace">15%</text>' +
       '<text x="43" y="77" font-size="8" fill="' + W + '" opacity=".75" font-family="monospace">5%</text>',

    // 10 — Managing Cash Flow: in/out circular arrows
    10: '<path d="M26,30 A30,30 0 1,1 74,30" fill="none" stroke="' + G1 + '" stroke-width="7" stroke-linecap="round"/>' +
        '<path d="M28,26 L18,36 L36,40 Z" fill="' + G1 + '"/>' +
        '<path d="M74,70 A30,30 0 1,1 26,70" fill="none" stroke="' + G2 + '" stroke-width="7" stroke-linecap="round"/>' +
        '<path d="M72,74 L82,64 L64,60 Z" fill="' + G2 + '"/>' +
        '<text x="50" y="56" text-anchor="middle" font-size="14" font-weight="bold" fill="' + W + '" opacity=".9" font-family="sans-serif">P</text>',

    // 11 — Needs vs Wants: split circle
    11: '<path d="M50,14 A36,36 0 0,0 50,86 Z" fill="' + G1 + '"/>' +
        '<path d="M50,14 A36,36 0 0,1 50,86 Z" fill="' + G2 + '" opacity=".8"/>' +
        '<circle cx="50" cy="50" r="36" fill="none" stroke="' + W + '" stroke-width="2.5" opacity=".6"/>' +
        '<line x1="50" y1="14" x2="50" y2="86" stroke="' + W + '" stroke-width="2.5" opacity=".75"/>' +
        '<circle cx="34" cy="40" r="5" fill="' + DK + '" opacity=".4"/>' +
        '<circle cx="34" cy="60" r="3.5" fill="' + DK + '" opacity=".35"/>' +
        '<circle cx="66" cy="40" r="4" fill="' + DK + '" opacity=".3"/>' +
        '<path d="M62,56 L70,52 L74,62 L64,64 Z" fill="' + DK + '" opacity=".28"/>',

    // 12 — Building Better Money Habits: habit loop + checkmark
    12: '<path d="M50,12 A38,38 0 1,1 12,50" fill="none" stroke="' + G1 + '" stroke-width="8" stroke-linecap="round"/>' +
        '<path d="M14,44 L6,56 L24,58 Z" fill="' + G1 + '"/>' +
        '<circle cx="50" cy="50" r="18" fill="' + G2 + '" opacity=".85"/>' +
        '<path d="M39,50 L47,59 L63,40" stroke="' + DK + '" stroke-width="4.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',

    // 13 — Emergency Funds: shield with Pula
    13: '<path d="M50,8 L84,22 L84,56 Q84,80 50,94 Q16,80 16,56 L16,22 Z" fill="' + G1 + '"/>' +
        '<path d="M50,18 L76,30 L76,56 Q76,74 50,86 Q24,74 24,56 L24,30 Z" fill="' + G2 + '" opacity=".55"/>' +
        '<text x="50" y="65" text-anchor="middle" font-size="30" font-weight="bold" fill="' + DK + '" font-family="serif">P</text>',

    // 14 — Understanding Debt: interlocking chain links
    14: '<rect x="8" y="26" width="30" height="18" rx="9" fill="none" stroke="' + G1 + '" stroke-width="5.5"/>' +
        '<rect x="34" y="34" width="30" height="18" rx="9" fill="none" stroke="' + G2 + '" stroke-width="5.5"/>' +
        '<rect x="60" y="26" width="30" height="18" rx="9" fill="none" stroke="' + G1 + '" stroke-width="5.5"/>' +
        '<rect x="20" y="50" width="30" height="18" rx="9" fill="none" stroke="' + G2 + '" stroke-width="5.5"/>' +
        '<rect x="48" y="50" width="30" height="18" rx="9" fill="none" stroke="' + G1 + '" stroke-width="5.5"/>',

    // 15 — Assets vs Liabilities: two-column bar chart
    15: '<rect x="12" y="44" width="32" height="42" rx="4" fill="' + G1 + '"/>' +
        '<rect x="12" y="20" width="32" height="22" rx="4" fill="' + G1 + '" opacity=".5"/>' +
        '<rect x="56" y="60" width="32" height="26" rx="4" fill="' + G2 + '" opacity=".85"/>' +
        '<line x1="8" y1="88" x2="92" y2="88" stroke="' + W + '" stroke-width="2.5" opacity=".5"/>' +
        '<text x="28" y="36" text-anchor="middle" font-size="16" fill="' + W + '" font-weight="bold" font-family="sans-serif">+</text>' +
        '<text x="72" y="78" text-anchor="middle" font-size="16" fill="' + DK + '" font-weight="bold" font-family="sans-serif">−</text>',
  };

  // ── Helpers ────────────────────────────────────────────────
  function fmtDur(secs) {
    if (!secs || secs < 0) return null;
    if (secs < 90) return secs + 's';
    return Math.round(secs / 60) + ' min';
  }

  function _esc(s) {
    return String(s || '')
      .replace(/&/g, '&amp;')
      .replace(/"/g, '&quot;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  }

  // ── kwPoster ───────────────────────────────────────────────
  // item: content_items row { sort_order, title, section_label, duration_seconds }
  // width: render width in px (height = width × 9/16)
  function kwPoster(item, width) {
    width = width || 320;
    var h    = Math.round(width * 9 / 16);
    var n    = item.sort_order;   // null for welcome video
    var dur  = fmtDur(item.duration_seconds);
    var grad = SEC_GRAD[item.section_label] || NAV_GRAD;
    var c1   = grad[0], c2 = grad[1];
    var key  = n == null ? 'w' : n;
    var gid  = 'kwpg-' + key + '-' + width;
    var fid  = 'kwgr-' + gid;   // grain filter
    var sid  = 'kwsh-' + gid;   // tile shadow
    var tcid = 'kwtc-' + gid;   // tile clip

    // Illustration: illo drawn in 100×100 space, placed in glass tile
    // Tile: x=88,y=16,w=144,h=106 → centre (160,69)
    // Scale 0.80 → 80×80, translate so centre lands at (160,69)
    var illo  = ILLOS[n == null ? 0 : n] || '';
    var tx    = 120, ty = 29, sc = 0.80;

    // Duration pill: right-edge at x=287, width estimated from text length
    var durStr = dur ? _esc(dur) : '';
    var durW   = dur ? Math.round(durStr.length * 5.6 + 14) : 0;
    var durX   = dur ? (287 - durW) : 0;
    var durTx  = dur ? (durX + durW / 2) : 0;

    return '<svg viewBox="0 0 320 180" width="' + width + '" height="' + h + '" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="' + _esc(item.title) + '">\n' +
'<defs>\n' +
'<linearGradient id="' + gid + '" x1="0" y1="0" x2="1" y2="1">' +
'<stop offset="0%" stop-color="' + c1 + '"/><stop offset="100%" stop-color="' + c2 + '"/>' +
'</linearGradient>\n' +
'<filter id="' + fid + '" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB">' +
'<feTurbulence type="fractalNoise" baseFrequency=".70 .62" numOctaves="4" stitchTiles="stitch" result="noise"/>' +
'<feColorMatrix in="noise" type="saturate" values="0" result="gn"/>' +
'<feBlend in="SourceGraphic" in2="gn" mode="overlay" result="blend"/>' +
'<feComposite in="blend" in2="SourceGraphic" operator="in"/>' +
'</filter>\n' +
'<filter id="' + sid + '" x="-15%" y="-15%" width="130%" height="130%">' +
'<feDropShadow dx="0" dy="3" stdDeviation="8" flood-color="#000" flood-opacity=".35"/>' +
'</filter>\n' +
'<clipPath id="' + tcid + '"><rect x="88" y="16" width="144" height="106" rx="10"/></clipPath>\n' +
'</defs>\n' +
// ── scene background ──
'<rect width="320" height="180" fill="url(#' + gid + ')"/>\n' +
// ── gold depth rings ──
'<circle cx="290" cy="-18" r="74" fill="none" stroke="' + G1 + '" stroke-width="1" opacity=".12"/>\n' +
'<circle cx="290" cy="-18" r="55" fill="none" stroke="' + G1 + '" stroke-width="1.5" opacity=".09"/>\n' +
'<circle cx="22" cy="196" r="62" fill="none" stroke="' + G1 + '" stroke-width="1" opacity=".1"/>\n' +
// ── film grain overlay ──
'<rect width="320" height="180" fill="white" opacity=".04" filter="url(#' + fid + ')"/>\n' +
// ── frosted-glass tile ──
'<rect x="88" y="16" width="144" height="106" rx="10" fill="white" fill-opacity=".11" stroke="white" stroke-opacity=".22" stroke-width="1" filter="url(#' + sid + ')"/>\n' +
'<rect x="89" y="17" width="142" height="3" rx="1.5" fill="white" fill-opacity=".13"/>\n' +
// ── bespoke illustration ──
(illo ? '<g transform="translate(' + tx + ',' + ty + ') scale(' + sc + ')" clip-path="url(#' + tcid + ')">' + illo + '</g>\n' : '') +
// ── duration pill ──
(dur ? '<rect x="' + durX + '" y="151" width="' + durW + '" height="18" rx="9" fill="black" fill-opacity=".38"/>\n' +
       '<text x="' + durTx + '" y="164.5" text-anchor="middle" font-family="\'DM Mono\',monospace" font-size="9.5" fill="white" fill-opacity=".9" letter-spacing=".5">' + durStr + '</text>\n' : '') +
// ── persistent gold play badge ──
'<circle cx="303" cy="161" r="12" fill="' + G1 + '"/>\n' +
'<circle cx="303" cy="161" r="9.5" fill="' + G2 + '" fill-opacity=".4"/>\n' +
'<polygon points="300,155.5 300,166.5 311,161" fill="' + DK + '" opacity=".88"/>\n' +
'</svg>';
  }

  global.kwPoster    = kwPoster;
  global.ILLOS       = ILLOS;

})(typeof window !== 'undefined' ? window : this);
