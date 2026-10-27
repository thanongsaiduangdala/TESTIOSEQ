// JavaScript injected into the YouTube Music page. It routes the page's own
// <video>/<audio> element through a 10-band EQ + gain boost + limiter
// using the Web Audio API. Nothing touches the audio until the user "arms" it.
const String eqScript = r'''
(function () {
  if (window.__ytEQ) return;
  // Keep the page "visible" so YouTube doesn't pause when the UI changes.
  try {
    Object.defineProperty(document, 'hidden', { get: function () { return false; }, configurable: true });
    Object.defineProperty(document, 'visibilityState', { get: function () { return 'visible'; }, configurable: true });
    ['visibilitychange', 'webkitvisibilitychange'].forEach(function (ev) {
      document.addEventListener(ev, function (e) { e.stopImmediatePropagation(); }, true);
    });
  } catch (e) {}

  var F = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
  var S = window.__ytEQ = {
    status: 'idle', gains: F.map(function () { return 0; }), boost: 1, on: true,
    armed: false, ctx: null, hooked: new WeakSet(), n: 0, err: ''
  };

  function deepFind() {            // also looks inside open shadow roots
    var out = [];
    (function walk(root) {
      var all = root.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        if (el.tagName === 'VIDEO' || el.tagName === 'AUDIO') out.push(el);
        if (el.shadowRoot) walk(el.shadowRoot);
      }
    })(document);
    return out;
  }
  function media() {
    var l = document.querySelectorAll('video,audio');
    return l.length ? Array.prototype.slice.call(l) : deepFind();
  }
  function apply() {
    var c = S.ctx; if (!c || !S.filters) return; var t = c.currentTime;
    S.filters.forEach(function (f, i) { f.gain.setTargetAtTime(S.on ? S.gains[i] : 0, t, 0.02); });
    S.amp.gain.setTargetAtTime(S.on ? S.boost : 1, t, 0.02);
  }
  function build() {
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) { S.status = 'unsupported'; S.err = 'no AudioContext'; return; }
    var c = S.ctx = new AC();
    S.input = c.createGain();
    var prev = S.input;
    S.filters = F.map(function (f, i) {
      var b = c.createBiquadFilter();
      b.type = i === 0 ? 'lowshelf' : i === F.length - 1 ? 'highshelf' : 'peaking';
      b.frequency.value = f; b.Q.value = 1.1;
      prev.connect(b); prev = b; return b;
    });
    S.amp = c.createGain(); prev.connect(S.amp);
    var lim = c.createDynamicsCompressor();   // limiter: reduces clipping when boosting
    lim.threshold.value = -3; lim.knee.value = 0; lim.ratio.value = 20;
    lim.attack.value = 0.003; lim.release.value = 0.15;
    S.amp.connect(lim); lim.connect(c.destination);
    S.an = c.createAnalyser(); S.an.fftSize = 256; lim.connect(S.an);
    apply();
  }
  var quiet = 0;
  function scan() {
    if (!S.armed) { S.status = 'idle'; return; }
    if (S.ctx && S.ctx.state !== 'running') S.ctx.resume().catch(function (e) { S.err = String(e); });
    var els = media();
    if (!els.length) { if (S.status !== 'active') S.status = 'waiting'; return; }
    for (var i = 0; i < els.length; i++) {
      var el = els[i]; if (S.hooked.has(el)) continue;
      if (!S.ctx) { build(); if (!S.ctx) return; }
      // Only hook once the context is running, otherwise the element goes mute.
      if (S.ctx.state !== 'running') { S.ctx.resume().catch(function (e) { S.err = String(e); }); S.status = 'blocked'; return; }
      try { S.ctx.createMediaElementSource(el).connect(S.input); S.hooked.add(el); S.n++; S.status = 'active'; }
      catch (e) { S.status = 'error'; S.err = String(e && e.message || e); }
    }
    // Watchdog: playing but no signal => this stream can't be processed.
    var v = els[0];
    if ((S.status === 'active' || S.status === 'silent') && S.an) {
      if (!v || v.paused || v.muted || v.volume === 0) { quiet = 0; return; }
      var d = new Uint8Array(S.an.fftSize); S.an.getByteTimeDomainData(d);
      var loud = false; for (var k = 0; k < d.length; k++) if (Math.abs(d[k] - 128) > 1) { loud = true; break; }
      quiet = loud ? 0 : quiet + 1;
      S.status = quiet >= 6 ? 'silent' : 'active';
    }
  }
  S.set = function (o) {
    if (o.gains) S.gains = o.gains;
    if (o.boost) S.boost = o.boost;
    if (typeof o.on === 'boolean') S.on = o.on;
    if (o.arm && !S.armed) { S.armed = true; scan(); setTimeout(scan, 300); }
    apply();
  };
  S.diag = function () {
    var v = media()[0];
    return JSON.stringify({
      status: S.status, armed: S.armed, ctx: S.ctx ? S.ctx.state : 'none', hooked: S.n,
      media: !!v, paused: v ? v.paused : null, rs: v ? v.readyState : null,
      src: v ? String(v.currentSrc || v.src || (v.srcObject ? 'srcObject' : 'none')).slice(0, 24) : '',
      err: S.err
    });
  };
  ['touchend', 'click', 'play', 'playing'].forEach(function (ev) { document.addEventListener(ev, scan, true); });
  setInterval(scan, 1000);
})();
''';
