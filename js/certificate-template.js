/* Key Wellness — ProLearn certificate template (Learning Pathways).
   Self-contained module: builds the certificate SVG, renders it to a
   downloadable PNG (SVG → canvas, 2x resolution), and provides a
   window.print() fallback. No pdf-lib, no server-side rendering.

   Palette is ProLearn's own navy/orange/gold — deliberately NOT the
   green/yellow LMS palette (css/kw-pathways.css) — this is the one
   place in the app that keeps the older brand identity, per the
   certificate being a third-party (ProLearn) issued credential.

   KNOWN GAP (flagged in BUILD-NOTES.md): the actual
   prolearn-certificate-preview.html reference file and the
   prolearn-logo.png / prolearn-signature.png assets were not available
   when this was built. Layout follows the brief's written description;
   exact colours/positions and both image assets need a follow-up pass
   once the real files are supplied — <image> tags below reference the
   expected paths (assets/img/prolearn-logo.png,
   assets/img/prolearn-signature.png) so dropping the real files in
   place is the only change needed later. */
(function (global) {
  'use strict';

  const NAVY = '#14213D';
  const NAVY_DEEP = '#0B1526';
  const GOLD = '#C9A227';
  const GOLD_LIGHT = '#E8CE6C';
  const ORANGE = '#D97706';
  const CREAM = '#FBF8F0';
  const INK = '#1C271C';
  const MUTED = '#6B6455';

  const FONT_SCRIPT = "'Pinyon Script', cursive";
  const FONT_SERIF = "'DM Mono', monospace"; // small-caps/mono labels — matches the rest of the app's mono usage

  function esc(s) {
    return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  // Certificate SVG, viewBox 1000x700 (landscape). {name, date, level} are the
  // only tokens — level is the pathway's certificate_level (e.g. "Foundations").
  function svgMarkup({ name, date, level }) {
    const safeName = esc(name || 'Member');
    const safeLevel = esc((level || 'Foundations').toUpperCase());
    const safeDate = esc(date || '');

    return `<svg viewBox="0 0 1000 700" xmlns="http://www.w3.org/2000/svg" font-family="'DM Mono',monospace">
  <rect width="1000" height="700" fill="${CREAM}"/>
  <rect x="18" y="18" width="964" height="664" fill="none" stroke="${GOLD}" stroke-width="2"/>
  <rect x="26" y="26" width="948" height="648" fill="none" stroke="${GOLD}" stroke-width="1" stroke-opacity=".6"/>

  <!-- Navy wave header -->
  <path d="M0,0 L1000,0 L1000,150 C820,190 620,110 500,150 C380,190 180,110 0,150 Z" fill="${NAVY}"/>
  <path d="M0,0 L1000,0 L1000,150 C820,190 620,110 500,150 C380,190 180,110 0,150 Z" fill="none" stroke="${GOLD}" stroke-width="2" stroke-opacity=".5"/>

  <!-- ProLearn logo — expected asset, see module header comment -->
  <image href="assets/img/prolearn-logo.png" x="440" y="24" width="120" height="70" preserveAspectRatio="xMidYMid meet"/>

  <text x="500" y="200" text-anchor="middle" font-size="34" font-weight="700" letter-spacing="6" fill="${GOLD}">CERTIFICATE</text>
  <text x="500" y="228" text-anchor="middle" font-size="15" letter-spacing="8" fill="${NAVY}">OF COMPLETION</text>

  <!-- Ribbon + medallion, left -->
  <g transform="translate(110,470)">
    <path d="M0,0 L-26,70 L0,54 L26,70 Z" fill="${ORANGE}"/>
    <path d="M0,0 L26,70 L0,54 L-26,70 Z" fill="${NAVY}" fill-opacity=".85"/>
    <circle cx="0" cy="-8" r="46" fill="${GOLD_LIGHT}" stroke="${GOLD}" stroke-width="4"/>
    <circle cx="0" cy="-8" r="34" fill="none" stroke="${NAVY}" stroke-width="2" stroke-dasharray="3 4"/>
    <text x="0" y="-2" text-anchor="middle" font-size="26" fill="${NAVY}">&#10022;</text>
  </g>

  <text x="500" y="290" text-anchor="middle" font-size="12" letter-spacing="4" fill="${MUTED}">THIS CERTIFICATE IS PROUDLY PRESENTED TO</text>

  <text x="500" y="370" text-anchor="middle" font-family="${FONT_SCRIPT}" font-size="58" fill="${NAVY}">${safeName}</text>
  <line x1="260" y1="392" x2="740" y2="392" stroke="${GOLD}" stroke-width="1.5"/>

  <text x="500" y="428" text-anchor="middle" font-size="12" letter-spacing="3" fill="${INK}">FOR COMPLETING</text>
  <text x="500" y="452" text-anchor="middle" font-size="14" font-weight="700" letter-spacing="2" fill="${NAVY}">FINANCIAL WELLNESS &#8212; ${safeLevel} LEVEL</text>

  <!-- Date, bottom-left -->
  <line x1="120" y1="600" x2="330" y2="600" stroke="${NAVY}" stroke-width="1"/>
  <text x="225" y="622" text-anchor="middle" font-size="13" fill="${NAVY}">${safeDate}</text>
  <text x="225" y="640" text-anchor="middle" font-size="10" letter-spacing="3" fill="${MUTED}">DATE</text>

  <!-- Signature, bottom-right -->
  <image href="assets/img/prolearn-signature.png" x="700" y="548" width="180" height="50" preserveAspectRatio="xMidYMax meet"/>
  <line x1="670" y1="600" x2="880" y2="600" stroke="${NAVY}" stroke-width="1"/>
  <text x="775" y="620" text-anchor="middle" font-size="11.5" font-weight="700" letter-spacing="1" fill="${NAVY}">MOGOMOTSI P. FRANCE</text>
  <text x="775" y="636" text-anchor="middle" font-size="10" letter-spacing="2" fill="${MUTED}">MANAGING DIRECTOR</text>

  <text x="500" y="672" text-anchor="middle" font-size="9.5" letter-spacing="2" fill="${MUTED}">PROLEARN &#183; AWARDING BODY &#183; BOTSWANA</text>
</svg>`;
  }

  // Fetch a Google Fonts family and inline every referenced font file as a
  // base64 data URI @font-face block. SVG→canvas rasterization (drawImage on
  // an <img> built from a serialized SVG blob) does NOT resolve external
  // @font-face/@import rules — the font bytes must live inside the SVG itself.
  async function inlineGoogleFont(family, weights) {
    const cssUrl = `https://fonts.googleapis.com/css2?family=${encodeURIComponent(family)}${weights ? ':wght@' + weights : ''}&display=swap`;
    const css = await (await fetch(cssUrl)).text();
    const urls = Array.from(css.matchAll(/url\((https:\/\/fonts\.gstatic\.com\/[^)]+)\)/g)).map(m => m[1]);
    const faces = await Promise.all(urls.map(async (url) => {
      const buf = await (await fetch(url)).arrayBuffer();
      let binary = '';
      const bytes = new Uint8Array(buf);
      for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
      const b64 = btoa(binary);
      return url.endsWith('.woff2') ? `data:font/woff2;base64,${b64}` : `data:font/woff;base64,${b64}`;
    }));
    const faceRules = css.replace(/url\(https:\/\/fonts\.gstatic\.com\/[^)]+\)/g, () => `url(${faces.shift()})`);
    return faceRules;
  }

  let _fontCssCache = null;
  async function getInlinedFontCss() {
    if (_fontCssCache) return _fontCssCache;
    try {
      const [script, mono] = await Promise.all([
        inlineGoogleFont('Pinyon+Script'),
        inlineGoogleFont('DM+Mono', '400;500;700'),
      ]);
      _fontCssCache = script + '\n' + mono;
    } catch (e) {
      console.warn('[Certificate] font inlining failed, PNG export may fall back to system fonts:', e);
      _fontCssCache = '';
    }
    return _fontCssCache;
  }

  // Render the certificate to a PNG and trigger a download. scale=2 → 2000x1400px.
  async function downloadPNG({ name, date, level }, filenamePrefix) {
    const fontCss = await getInlinedFontCss();
    const raw = svgMarkup({ name, date, level });
    const withStyle = raw.replace(/^(<svg[^>]*>)/, `$1<style>${fontCss}</style>`);

    if (document.fonts && document.fonts.ready) {
      try { await document.fonts.load(`58px 'Pinyon Script'`); } catch (_) {}
      await document.fonts.ready;
    }

    const scale = 2, w = 1000 * scale, h = 700 * scale;
    const blob = new Blob([withStyle], { type: 'image/svg+xml;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    try {
      const img = await new Promise((resolve, reject) => {
        const im = new Image();
        im.onload = () => resolve(im);
        im.onerror = reject;
        im.src = url;
      });
      const canvas = document.createElement('canvas');
      canvas.width = w; canvas.height = h;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(img, 0, 0, w, h);
      const pngUrl = canvas.toDataURL('image/png');
      const a = document.createElement('a');
      a.href = pngUrl;
      a.download = `${(filenamePrefix || 'key-wellness-certificate')}.png`;
      document.body.appendChild(a);
      a.click();
      a.remove();
    } finally {
      URL.revokeObjectURL(url);
    }
  }

  // Print fallback — opens the certificate in a dedicated print view.
  function printCertificate({ name, date, level }) {
    const w = window.open('', '_blank', 'width=1000,height=700');
    if (!w) return false;
    w.document.write(`<!DOCTYPE html><html><head><title>Certificate</title>
      <style>@page{size:landscape}body{margin:0;display:flex;align-items:center;justify-content:center}svg{width:100%;height:auto}</style>
      </head><body>${svgMarkup({ name, date, level })}</body></html>`);
    w.document.close();
    w.onload = () => { w.focus(); w.print(); };
    return true;
  }

  global.KWCertificate = { svgMarkup, downloadPNG, printCertificate };
})(window);
