// js/kw-lms-posters.js — AURORA/GLASS edition v2
// kwPoster(item, width) → SVG string
// item: content_items row { sort_order, title, section_label, duration_seconds }

(function (global) {
  'use strict';

  var DK = '#10240F';   // deep-ink outlines / text
  var G1 = '#E8C018';   // main gold
  var G2 = '#F4DC7A';   // soft gold

  // Light pastel gradient pairs [top-left → bottom-right]
  var SEC_GRAD = {
    'Mindset & Psychology':  ['#F0F9EA', '#C6E0AC'],
    'Diagnosis & Direction': ['#E8F7F7', '#AEDADC'],
    'Practical Foundations': ['#FAF4E0', '#E8D28A'],
    'Protection & Debt':     ['#E8EEF8', '#AABCD4'],
    'Wealth Thinking':       ['#F8EDE8', '#D8A898'],
  };
  var NAV_GRAD = ['#ECECF8', '#ACACD4'];

  // ── Illustrations — 100 × 100 coordinate space ───────────────────────
  // Style: DK (#10240F) stroke outlines · G1 (#E8C018) gold accents · clean line art
  var ILLOS = {

    // 0 — Welcome: open door with golden light spilling through
    0: // door frame
       '<rect x="22" y="14" width="48" height="70" rx="4" fill="none" stroke="' + DK + '" stroke-width="4"/>' +
       // open door leaf (pivots right) — shows golden light inside
       '<path d="M44,14 Q60,22 62,49 Q60,76 44,84 Z" fill="' + G1 + '" fill-opacity=".4"/>' +
       '<path d="M44,14 Q60,22 62,49 Q60,76 44,84" fill="none" stroke="' + DK + '" stroke-width="3.5"/>' +
       '<line x1="44" y1="14" x2="44" y2="84" stroke="' + DK + '" stroke-width="2.5"/>' +
       // door knob
       '<circle cx="58" cy="51" r="4.5" fill="' + G1 + '" stroke="' + DK + '" stroke-width="1.5"/>' +
       // floor light triangle
       '<path d="M44,84 L18,98 L74,98 Z" fill="' + G1 + '" fill-opacity=".35"/>' +
       '<line x1="8" y1="98" x2="92" y2="98" stroke="' + DK + '" stroke-width="2" opacity=".2"/>',

    // 1 — Introduction to Financial Literacy: compass
    1: '<circle cx="50" cy="52" r="34" fill="none" stroke="' + DK + '" stroke-width="4"/>' +
       '<circle cx="50" cy="52" r="26" fill="none" stroke="' + DK + '" stroke-width="1.5" opacity=".3"/>' +
       // cardinal tick marks
       '<line x1="50" y1="18" x2="50" y2="26" stroke="' + DK + '" stroke-width="3"/>' +
       '<line x1="50" y1="78" x2="50" y2="86" stroke="' + DK + '" stroke-width="3"/>' +
       '<line x1="16" y1="52" x2="24" y2="52" stroke="' + DK + '" stroke-width="3"/>' +
       '<line x1="76" y1="52" x2="84" y2="52" stroke="' + DK + '" stroke-width="3"/>' +
       // north needle (gold)
       '<path d="M50,52 L44,28 L56,28 Z" fill="' + G1 + '"/>' +
       // south needle (dark)
       '<path d="M50,52 L44,76 L56,76 Z" fill="' + DK + '" opacity=".6"/>' +
       // pivot
       '<circle cx="50" cy="52" r="5" fill="' + DK + '"/>' +
       '<circle cx="50" cy="52" r="2.5" fill="' + G1 + '"/>',

    // 2 — Understanding Your Relationship with Money: magnifying glass on Pula coin
    2: // coin
       '<circle cx="42" cy="42" r="22" fill="' + G1 + '" fill-opacity=".28"/>' +
       '<circle cx="42" cy="42" r="16" fill="none" stroke="' + G1 + '" stroke-width="2.5"/>' +
       '<text x="42" y="50" text-anchor="middle" font-size="18" font-weight="bold" fill="' + DK + '" font-family="serif">P</text>' +
       // magnifying glass ring (over coin)
       '<circle cx="42" cy="42" r="28" fill="none" stroke="' + DK + '" stroke-width="5"/>' +
       // handle
       '<line x1="63" y1="63" x2="86" y2="86" stroke="' + DK + '" stroke-width="7" stroke-linecap="round"/>' +
       // lens glint
       '<path d="M27,27 Q32,22 39,22" stroke="white" stroke-width="2.5" fill="none" stroke-linecap="round" opacity=".65"/>',

    // 3 — Emotional Spending: heart with price tag
    3: // heart outline (bold)
       '<path d="M50,34 C50,22 34,18 26,28 C18,38 28,50 50,70 C72,50 82,38 74,28 C66,18 50,22 50,34 Z"' +
       ' fill="' + G1 + '" fill-opacity=".18" stroke="' + DK + '" stroke-width="4" stroke-linejoin="round"/>' +
       // price tag string
       '<line x1="50" y1="70" x2="50" y2="82" stroke="' + DK + '" stroke-width="2" opacity=".6"/>' +
       // price tag rectangle
       '<rect x="36" y="82" width="28" height="16" rx="4" fill="' + G2 + '" fill-opacity=".5" stroke="' + DK + '" stroke-width="2.5"/>' +
       // tag hole
       '<circle cx="50" cy="82" r="2.5" fill="' + DK + '"/>' +
       // P on tag
       '<text x="50" y="95" text-anchor="middle" font-size="10" font-weight="bold" fill="' + DK + '" font-family="sans-serif">P</text>',

    // 4 — Lifestyle Inflation: rising bar chart with coin at top
    4: // bars (left to right, increasing height)
       '<rect x="10" y="68" width="20" height="20" rx="3" fill="' + G1 + '" fill-opacity=".25"/>' +
       '<rect x="10" y="48" width="20" height="40" rx="3" fill="none" stroke="' + DK + '" stroke-width="3"/>' +
       '<rect x="36" y="44" width="20" height="44" rx="3" fill="' + G1 + '" fill-opacity=".2"/>' +
       '<rect x="36" y="28" width="20" height="60" rx="3" fill="none" stroke="' + DK + '" stroke-width="3"/>' +
       '<rect x="62" y="16" width="20" height="72" rx="3" fill="' + G1 + '" fill-opacity=".35"/>' +
       '<rect x="62" y="16" width="20" height="72" rx="3" fill="none" stroke="' + DK + '" stroke-width="3"/>' +
       // trend line
       '<path d="M20,56 L46,36 L72,22" stroke="' + G1 + '" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>' +
       // coin at top of tallest bar
       '<circle cx="72" cy="12" r="9" fill="' + G1 + '" stroke="' + DK + '" stroke-width="2"/>' +
       '<text x="72" y="16.5" text-anchor="middle" font-size="9" font-weight="bold" fill="' + DK + '" font-family="sans-serif">P</text>' +
       // baseline
       '<line x1="8" y1="90" x2="92" y2="90" stroke="' + DK + '" stroke-width="2.5" opacity=".3"/>',

    // 5 — Qualifying vs Affording: tilted balance scale
    5: '<line x1="50" y1="12" x2="50" y2="72" stroke="' + DK + '" stroke-width="4" stroke-linecap="round"/>' +
       '<path d="M32,72 L50,72 L68,72 L72,84 L28,84 Z" fill="none" stroke="' + DK + '" stroke-width="3"/>' +
       // beam (slightly tilted — left pan lower/heavier)
       '<line x1="6" y1="30" x2="94" y2="22" stroke="' + DK + '" stroke-width="4.5" stroke-linecap="round"/>' +
       // left pan strings
       '<line x1="6" y1="30" x2="18" y2="36" stroke="' + DK + '" stroke-width="2" opacity=".55"/>' +
       '<line x1="36" y1="28" x2="26" y2="34" stroke="' + DK + '" stroke-width="2" opacity=".55"/>' +
       // left pan (heavier/lower — "qualify: ✓")
       '<path d="M4,36 Q10,54 20,54 Q30,54 36,36 Z" fill="' + G1 + '" fill-opacity=".25" stroke="' + DK + '" stroke-width="3"/>' +
       '<path d="M12,46 L18,52 L28,40" stroke="' + DK + '" stroke-width="2.5" fill="none" stroke-linecap="round"/>' +
       // right pan strings
       '<line x1="94" y1="22" x2="84" y2="30" stroke="' + DK + '" stroke-width="2" opacity=".55"/>' +
       '<line x1="64" y1="26" x2="74" y2="20" stroke="' + DK + '" stroke-width="2" opacity=".55"/>' +
       // right pan ("afford: P")
       '<path d="M64,20 Q70,38 80,38 Q90,38 96,20 Z" fill="' + DK + '" fill-opacity=".08" stroke="' + DK + '" stroke-width="3"/>' +
       '<text x="80" y="34" text-anchor="middle" font-size="13" fill="' + G1 + '" font-weight="bold" font-family="sans-serif">P</text>',

    // 6 — The Three Money Problems: three overlapping circles
    6: '<circle cx="30" cy="40" r="24" fill="' + G1 + '" fill-opacity=".18" stroke="' + DK + '" stroke-width="3.5"/>' +
       '<circle cx="70" cy="40" r="24" fill="' + G1 + '" fill-opacity=".14" stroke="' + DK + '" stroke-width="3.5"/>' +
       '<circle cx="50" cy="70" r="24" fill="' + G1 + '" fill-opacity=".12" stroke="' + DK + '" stroke-width="3.5"/>' +
       '<text x="26" y="46" text-anchor="middle" font-size="20" font-weight="bold" fill="' + DK + '" font-family="sans-serif">1</text>' +
       '<text x="74" y="46" text-anchor="middle" font-size="20" font-weight="bold" fill="' + DK + '" font-family="sans-serif">2</text>' +
       '<text x="50" y="76" text-anchor="middle" font-size="20" font-weight="bold" fill="' + DK + '" font-family="sans-serif">3</text>',

    // 7 — Setting SMART Financial Goals: bullseye with arrow
    7: '<circle cx="50" cy="54" r="36" fill="none" stroke="' + DK + '" stroke-width="3.5"/>' +
       '<circle cx="50" cy="54" r="24" fill="none" stroke="' + DK + '" stroke-width="3.5"/>' +
       '<circle cx="50" cy="54" r="12" fill="' + G1 + '" fill-opacity=".35" stroke="' + DK + '" stroke-width="3.5"/>' +
       '<circle cx="50" cy="54" r="5" fill="' + DK + '"/>' +
       // arrow from top-left into bullseye
       '<line x1="10" y1="14" x2="50" y2="53" stroke="' + G1 + '" stroke-width="4" stroke-linecap="round"/>' +
       '<path d="M4,10 L17,8 L19,21 Z" fill="' + G1 + '"/>',

    // 8 — Understanding Your Payslip: document with Pula header and data rows
    8: '<rect x="18" y="6" width="64" height="88" rx="6" fill="' + DK + '" fill-opacity=".04" stroke="' + DK + '" stroke-width="3.5"/>' +
       // header band
       '<rect x="22" y="10" width="56" height="20" rx="3" fill="' + G1 + '" fill-opacity=".3"/>' +
       '<text x="50" y="27" text-anchor="middle" font-size="16" font-weight="bold" fill="' + DK + '" font-family="serif">P</text>' +
       // data rows
       '<rect x="26" y="36" width="32" height="4" rx="2" fill="' + DK + '" opacity=".2"/>' +
       '<rect x="62" y="36" width="14" height="4" rx="2" fill="' + DK + '" opacity=".2"/>' +
       '<rect x="26" y="46" width="28" height="4" rx="2" fill="' + DK + '" opacity=".16"/>' +
       '<rect x="62" y="46" width="14" height="4" rx="2" fill="' + DK + '" opacity=".16"/>' +
       '<rect x="26" y="56" width="36" height="4" rx="2" fill="' + DK + '" opacity=".13"/>' +
       '<rect x="66" y="56" width="10" height="4" rx="2" fill="' + DK + '" opacity=".13"/>' +
       // divider
       '<line x1="22" y1="66" x2="74" y2="66" stroke="' + DK + '" stroke-width="1.5" opacity=".25"/>' +
       // totals
       '<rect x="26" y="72" width="24" height="7" rx="3" fill="' + G1 + '" fill-opacity=".65"/>' +
       '<rect x="56" y="72" width="18" height="7" rx="3" fill="' + G1 + '" fill-opacity=".5"/>',

    // 9 — Creating a Personal Budget: horizontal bar chart
    9: '<rect x="10" y="14" width="78" height="10" rx="5" fill="' + G1 + '" fill-opacity=".3" stroke="' + DK + '" stroke-width="2.5"/>' +
       '<rect x="10" y="32" width="60" height="10" rx="5" fill="' + G1 + '" fill-opacity=".22" stroke="' + DK + '" stroke-width="2.5"/>' +
       '<rect x="10" y="50" width="44" height="10" rx="5" fill="' + G1 + '" fill-opacity=".16" stroke="' + DK + '" stroke-width="2.5"/>' +
       '<rect x="10" y="68" width="28" height="10" rx="5" fill="' + G1 + '" fill-opacity=".12" stroke="' + DK + '" stroke-width="2.5"/>' +
       '<line x1="8" y1="84" x2="92" y2="84" stroke="' + DK + '" stroke-width="2.5" opacity=".28"/>',

    // 10 — Managing Cash Flow: in/out circular arrows with Pula center
    10: '<path d="M26,30 A30,30 0 1,1 74,30" fill="none" stroke="' + DK + '" stroke-width="5.5" stroke-linecap="round"/>' +
        '<path d="M28,26 L18,36 L36,40 Z" fill="' + DK + '"/>' +
        '<path d="M74,70 A30,30 0 1,1 26,70" fill="none" stroke="' + G1 + '" stroke-width="5.5" stroke-linecap="round"/>' +
        '<path d="M72,74 L82,64 L64,60 Z" fill="' + G1 + '"/>' +
        '<circle cx="50" cy="50" r="13" fill="' + G1 + '" fill-opacity=".35"/>' +
        '<text x="50" y="55" text-anchor="middle" font-size="14" font-weight="bold" fill="' + DK + '" font-family="sans-serif">P</text>',

    // 11 — Needs vs Wants: split circle with symbols
    11: '<circle cx="50" cy="50" r="36" fill="none" stroke="' + DK + '" stroke-width="3.5"/>' +
        '<path d="M50,14 A36,36 0 0,0 50,86 Z" fill="' + DK + '" fill-opacity=".08"/>' +
        '<path d="M50,14 A36,36 0 0,1 50,86 Z" fill="' + G1 + '" fill-opacity=".18"/>' +
        '<line x1="50" y1="14" x2="50" y2="86" stroke="' + DK + '" stroke-width="2.5"/>' +
        // left side (need): simple house
        '<path d="M20,56 L20,66 L40,66 L40,56" fill="none" stroke="' + DK + '" stroke-width="2.5"/>' +
        '<path d="M18,56 L30,44 L42,56" fill="none" stroke="' + DK + '" stroke-width="2.5"/>' +
        // right side (want): 5-point star outline
        '<path d="M68,42 L70.5,49 L78,49 L72,53.5 L74,61 L68,56.5 L62,61 L64,53.5 L58,49 L65.5,49 Z"' +
        ' fill="' + G1 + '" fill-opacity=".5" stroke="' + DK + '" stroke-width="1.5"/>',

    // 12 — Building Better Money Habits: circular arrow loop + checkmark
    12: '<path d="M50,12 A38,38 0 1,1 12,50" fill="none" stroke="' + DK + '" stroke-width="6.5" stroke-linecap="round"/>' +
        '<path d="M14,44 L6,56 L24,58 Z" fill="' + DK + '"/>' +
        '<circle cx="50" cy="50" r="19" fill="' + G1 + '" fill-opacity=".28"/>' +
        '<circle cx="50" cy="50" r="19" fill="none" stroke="' + DK + '" stroke-width="2.5"/>' +
        '<path d="M39,50 L47,59 L63,40" stroke="' + DK + '" stroke-width="4.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',

    // 13 — Emergency Funds: shield with Pula
    13: '<path d="M50,8 L84,22 L84,56 Q84,80 50,94 Q16,80 16,56 L16,22 Z"' +
        ' fill="' + G1 + '" fill-opacity=".2" stroke="' + DK + '" stroke-width="4"/>' +
        '<path d="M50,20 L76,32 L76,56 Q76,74 50,84 Q24,74 24,56 L24,32 Z"' +
        ' fill="none" stroke="' + DK + '" stroke-width="2" opacity=".3"/>' +
        '<text x="50" y="65" text-anchor="middle" font-size="28" font-weight="bold" fill="' + DK + '" font-family="serif">P</text>',

    // 14 — Understanding Debt: interlocking chain links (outline)
    14: '<rect x="8" y="26" width="30" height="18" rx="9" fill="' + G1 + '" fill-opacity=".18" stroke="' + DK + '" stroke-width="5"/>' +
        '<rect x="34" y="34" width="30" height="18" rx="9" fill="' + DK + '" fill-opacity=".06" stroke="' + DK + '" stroke-width="5"/>' +
        '<rect x="60" y="26" width="30" height="18" rx="9" fill="' + G1 + '" fill-opacity=".18" stroke="' + DK + '" stroke-width="5"/>' +
        '<rect x="20" y="50" width="30" height="18" rx="9" fill="' + DK + '" fill-opacity=".06" stroke="' + DK + '" stroke-width="5"/>' +
        '<rect x="48" y="50" width="30" height="18" rx="9" fill="' + G1 + '" fill-opacity=".18" stroke="' + DK + '" stroke-width="5"/>',

    // 15 — Assets vs Liabilities: two-column bar comparison
    15: // assets column (taller, gold tint)
        '<rect x="14" y="22" width="32" height="64" rx="4" fill="' + G1 + '" fill-opacity=".28" stroke="' + DK + '" stroke-width="3.5"/>' +
        // liabilities column (shorter, plain)
        '<rect x="54" y="54" width="32" height="32" rx="4" fill="' + DK + '" fill-opacity=".07" stroke="' + DK + '" stroke-width="3.5"/>' +
        // baseline
        '<line x1="10" y1="88" x2="90" y2="88" stroke="' + DK + '" stroke-width="2.5" opacity=".3"/>' +
        // labels
        '<text x="30" y="40" text-anchor="middle" font-size="16" fill="' + DK + '" font-weight="bold" font-family="sans-serif">+</text>' +
        '<text x="70" y="74" text-anchor="middle" font-size="16" fill="' + DK + '" font-weight="bold" font-family="sans-serif">−</text>',
  };

  // ── Helpers ───────────────────────────────────────────────
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

  // ── kwPoster ─────────────────────────────────────────────
  function kwPoster(item, width) {
    width = width || 320;
    var h    = Math.round(width * 9 / 16);

    // Bespoke dark-navy thumbnail art (title-matched) takes precedence over the
    // pastel/glass fallback below. See js/kw-lms-thumbs.js. Matched by normalised
    // title, so it tolerates '&' vs 'and' and punctuation drift vs content_items.
    var thumbArt = (item && item.title && typeof global.kwThumbArt === 'function')
      ? global.kwThumbArt(item.title) : null;
    if (thumbArt) return darkThumbPoster(item, width, h, thumbArt);

    var n    = item.sort_order;            // null for welcome
    var dur  = fmtDur(item.duration_seconds);
    var grad = SEC_GRAD[item.section_label] || NAV_GRAD;
    var c1   = grad[0], c2 = grad[1];
    var key  = n == null ? 'w' : n;
    var gid  = 'kwpg-' + key + '-' + width;
    var sid  = 'kwsh-' + gid;   // tile shadow filter
    var tcid = 'kwtc-' + gid;   // tile clipPath

    // Illustration: 100×100 illo → scale 0.82 (82×82) centered at (160, 72)
    // translate(160-41, 72-41) = translate(119, 31)
    var illo = ILLOS[n == null ? 0 : n] || '';
    var tx = 119, ty = 31, sc = 0.82;

    // Glass tile: x=12,y=10 w=296 h=124  → right:308 bottom:134
    var tileX = 12, tileY = 10, tileW = 296, tileH = 124;

    // Bottom strip: y ≈ 142–178
    // Lesson label bottom-left
    var label = n ? ('LESSON ' + String(n).padStart(2, '0')) : 'WELCOME';
    // Play+duration pill — right-aligned to x=308
    var durStr = dur ? _esc(dur) : '';
    // pill: fixed 9px monospace → ~5.6px/char + 28px overhead (icon + padding)
    var pillW = dur ? Math.round(durStr.length * 5.6 + 30) : 0;
    var pillX = dur ? (308 - pillW) : 0;
    // play triangle inside pill
    var triX  = pillX + 9;

    return '<svg viewBox="0 0 320 180" width="' + width + '" height="' + h + '" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="' + _esc(item.title) + '">\n' +
'<defs>\n' +
'<linearGradient id="' + gid + '" x1="0" y1="0" x2="1" y2="1">' +
'<stop offset="0%" stop-color="' + c1 + '"/><stop offset="100%" stop-color="' + c2 + '"/>' +
'</linearGradient>\n' +
'<filter id="' + sid + '" x="-8%" y="-8%" width="116%" height="116%">' +
'<feDropShadow dx="0" dy="2" stdDeviation="6" flood-color="' + DK + '" flood-opacity=".10"/>' +
'</filter>\n' +
'<clipPath id="' + tcid + '">' +
'<rect x="' + tileX + '" y="' + tileY + '" width="' + tileW + '" height="' + tileH + '" rx="14"/>' +
'</clipPath>\n' +
'</defs>\n' +

// ── background gradient ──
'<rect width="320" height="180" fill="url(#' + gid + ')"/>\n' +

// ── subtle depth dots (gold accents) ──
'<circle cx="300" cy="18" r="5" fill="' + G1 + '" opacity=".55"/>\n' +
'<circle cx="286" cy="28" r="3" fill="' + G1 + '" opacity=".3"/>\n' +
'<circle cx="18" cy="162" r="4" fill="' + DK + '" opacity=".1"/>\n' +

// ── frosted-glass tile ──
'<rect x="' + tileX + '" y="' + tileY + '" width="' + tileW + '" height="' + tileH + '" rx="14"' +
  ' fill="white" fill-opacity=".82"' +
  ' stroke="' + DK + '" stroke-opacity=".06" stroke-width="1"' +
  ' filter="url(#' + sid + ')"/>\n' +

// ── bespoke illustration (clipped to tile) ──
(illo
  ? '<g transform="translate(' + tx + ',' + ty + ') scale(' + sc + ')" clip-path="url(#' + tcid + ')">' + illo + '</g>\n'
  : '') +

// ── lesson label chip (bottom-left) ──
'<rect x="14" y="150" width="' + (label.length * 6.2 + 12) + '" height="18" rx="9"' +
  ' fill="' + DK + '" fill-opacity=".72"/>\n' +
'<text x="20" y="163" font-family="\'DM Mono\',monospace" font-size="9" fill="white" letter-spacing="1.6">' + label + '</text>\n' +

// ── play + duration pill (bottom-right) ──
(dur
  ? '<rect x="' + pillX + '" y="150" width="' + pillW + '" height="18" rx="9"' +
      ' fill="' + DK + '" fill-opacity=".72"/>\n' +
    '<polygon points="' + triX + ',155.5 ' + triX + ',165.5 ' + (triX + 6.5) + ',160.5" fill="white"/>\n' +
    '<text x="' + (triX + 11) + '" y="163" font-family="\'DM Mono\',monospace" font-size="9" fill="white" letter-spacing=".4">' + durStr + '</text>\n'
  : // no duration: show bare play badge
    '<rect x="294" y="150" width="18" height="18" rx="9" fill="' + DK + '" fill-opacity=".72"/>\n' +
    '<polygon points="299,155.5 299,165.5 309,160.5" fill="white"/>\n') +

'</svg>';
  }

  // ── darkThumbPoster ──────────────────────────────────────
  // Renders a bespoke navy thumbnail. entry = { vb, art }: the art is embedded
  // in a nested <svg> at its native viewBox and cover-scaled to the 320×180
  // poster. Full-bleed designs authored at 320×180 (e.g. the welcome art) are
  // used as-is; smaller lesson illustrations (200×120) get the portal's lesson
  // chip + play/duration pill on a bottom scrim so the chrome stays legible.
  function darkThumbPoster(item, width, h, entry) {
    var NAVY   = '#0d1a3a';
    var vb     = (entry && entry.vb) || '0 0 200 120';
    var art    = (entry && entry.art) || '';
    var full   = vb === '0 0 320 180';   // authored at full poster size
    var n      = item.sort_order;
    var dur    = fmtDur(item.duration_seconds);
    var durStr = dur ? _esc(dur) : '';
    var uid    = 'kwdk-' + (n == null ? 'x' : n) + '-' + width;

    var head = '<svg viewBox="0 0 320 180" width="' + width + '" height="' + h + '" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="' + _esc(item.title) + '">\n' +
      '<rect width="320" height="180" fill="' + NAVY + '"/>\n' +
      '<svg x="0" y="0" width="320" height="180" viewBox="' + vb + '" preserveAspectRatio="xMidYMid slice">' + art + '</svg>\n';

    // Full-bleed art is a finished piece — no scrim/chip. Add a duration pill
    // only when we actually know the length.
    if (full) {
      if (!dur) return head + '</svg>';
      var pw = Math.round(durStr.length * 5.6 + 30), px = 308 - pw, tx = px + 9;
      return head +
        '<rect x="' + px + '" y="150" width="' + pw + '" height="18" rx="9" fill="#000" fill-opacity=".5"/>\n' +
        '<polygon points="' + tx + ',155.5 ' + tx + ',165.5 ' + (tx + 6.5) + ',160.5" fill="' + G1 + '"/>\n' +
        '<text x="' + (tx + 11) + '" y="163" font-family="\'DM Mono\',monospace" font-size="9" fill="#fff" letter-spacing=".4">' + durStr + '</text>\n' +
        '</svg>';
    }

    var label = n ? ('LESSON ' + String(n).padStart(2, '0'))
                  : (item.section_label ? _esc(item.section_label).toUpperCase() : 'WELCOME');
    var chipW = Math.round(label.length * 6.2 + 12);
    var pillW = dur ? Math.round(durStr.length * 5.6 + 30) : 0;
    var pillX = dur ? (308 - pillW) : 0;
    var triX  = pillX + 9;

    return head +
'<defs><linearGradient id="' + uid + '" x1="0" y1="0" x2="0" y2="1">' +
'<stop offset="0" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".55"/>' +
'</linearGradient></defs>\n' +
'<rect x="0" y="132" width="320" height="48" fill="url(#' + uid + ')"/>\n' +
'<rect x="14" y="150" width="' + chipW + '" height="18" rx="9" fill="#000" fill-opacity=".5"/>\n' +
'<text x="20" y="163" font-family="\'DM Mono\',monospace" font-size="9" fill="#fff" letter-spacing="1.6">' + label + '</text>\n' +
(dur
  ? '<rect x="' + pillX + '" y="150" width="' + pillW + '" height="18" rx="9" fill="#000" fill-opacity=".5"/>\n' +
    '<polygon points="' + triX + ',155.5 ' + triX + ',165.5 ' + (triX + 6.5) + ',160.5" fill="' + G1 + '"/>\n' +
    '<text x="' + (triX + 11) + '" y="163" font-family="\'DM Mono\',monospace" font-size="9" fill="#fff" letter-spacing=".4">' + durStr + '</text>\n'
  : '<circle cx="303" cy="159" r="10" fill="' + G1 + '"/>\n' +
    '<polygon points="300,154 300,164 309,159" fill="' + NAVY + '"/>\n') +
'</svg>';
  }

  global.kwPoster = kwPoster;
  global.ILLOS    = ILLOS;

})(typeof window !== 'undefined' ? window : this);
