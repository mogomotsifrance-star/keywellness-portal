/* Key Wellness — shared motion module.
   No dependencies. Nothing here auto-runs; pages call KW.* explicitly. */
(function(){
  'use strict';

  function prefersReducedMotion(){
    return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  }

  function easeOutCubic(t){
    return 1 - Math.pow(1 - t, 3);
  }

  var KW = window.KW || {};

  /* Staggered entrance for a set of elements. */
  KW.reveal = function(selector, opts){
    opts = opts || {};
    var els = typeof selector === 'string' ? document.querySelectorAll(selector) : selector;
    if (!els || !els.length) return;

    var stagger = opts.stagger != null ? opts.stagger : 60; /* ms, matches --kw-stagger */
    var reduced = prefersReducedMotion();

    els.forEach(function(el, i){
      el.classList.add('reveal');
      if (reduced){
        el.classList.add('in');
        return;
      }
      /* force reflow so the transition fires even if 'reveal' was just added */
      void el.offsetWidth;
      setTimeout(function(){
        el.classList.add('in');
      }, i * stagger);
    });
  };

  /* Animate a number counting up inside el. */
  KW.countUp = function(el, target, opts){
    opts = opts || {};
    var duration = opts.duration != null ? opts.duration : 1100; /* ms, matches --kw-countup */
    var format = opts.format || function(v){ return Math.round(v).toString(); };
    var start = opts.from != null ? opts.from : 0;

    if (prefersReducedMotion()){
      el.textContent = format(target);
      return;
    }

    var startTime = null;
    function step(ts){
      if (startTime === null) startTime = ts;
      var progress = Math.min((ts - startTime) / duration, 1);
      var eased = easeOutCubic(progress);
      var value = start + (target - start) * eased;
      el.textContent = format(value);
      if (progress < 1){
        requestAnimationFrame(step);
      } else {
        el.textContent = format(target);
      }
    }
    requestAnimationFrame(step);
  };

  /* Sweep an SVG circle's stroke-dashoffset to represent a percentage (0-100). */
  KW.ring = function(el, pct, opts){
    opts = opts || {};
    var duration = opts.duration != null ? opts.duration : 1100;
    var r = parseFloat(el.getAttribute('r'));
    var circumference = 2 * Math.PI * r;
    var targetOffset = circumference * (1 - Math.max(0, Math.min(100, pct)) / 100);

    el.style.strokeDasharray = circumference;

    if (prefersReducedMotion()){
      el.style.strokeDashoffset = targetOffset;
      return;
    }

    var startOffset = circumference;
    el.style.strokeDashoffset = startOffset;

    var startTime = null;
    function step(ts){
      if (startTime === null) startTime = ts;
      var progress = Math.min((ts - startTime) / duration, 1);
      var eased = easeOutCubic(progress);
      el.style.strokeDashoffset = startOffset + (targetOffset - startOffset) * eased;
      if (progress < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  };

  /* Resolve a .kw-skeleton element to either content or a visible error state. */
  KW.skeletonResolve = function(el, opts){
    opts = opts || {};
    el.classList.remove('kw-skeleton');
    el.removeAttribute('aria-busy');

    if (opts.error){
      el.innerHTML = opts.error;
      return;
    }
    if (opts.content != null){
      if (typeof opts.content === 'string'){
        el.innerHTML = opts.content;
      } else if (opts.content instanceof Node){
        el.innerHTML = '';
        el.appendChild(opts.content);
      }
    }
    if (!prefersReducedMotion()){
      el.classList.add('reveal');
      void el.offsetWidth;
      requestAnimationFrame(function(){ el.classList.add('in'); });
    }
  };

  window.KW = KW;
})();
