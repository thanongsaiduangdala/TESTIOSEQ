// JavaScript injected into the YouTube Music page. It routes the page's own
// <video>/<audio> element through a 10-band EQ + gain boost + limiter
// using the Web Audio API, so playback never stops.
const String eqScript = r'''
(function () {
  if (window.__ytEQ) return;
  var F = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
  var S = window.__ytEQ = {
    status: 'waiting', gains: F.map(function () { return 0; }),
    boost: 1, on: true, ctx: null, hooked: new WeakSet()
  };
  function apply() {
    var c = S.ctx; if (!c) return; var t = c.currentTime;
    S.filters.forEach(function (f, i) { f.gain.setTargetAtTime(S.on ? S.gains[i] : 0, t, 0.02); });
    S.amp.gain.setTargetAtTime(S.on ? S.boost : 1, t, 0.02);
  }
  function build() {
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) { S.status = 'unsupported'; return; }
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
    var lim = c.createDynamicsCompressor();   // acts as a limiter so boost clips less
    lim.threshold.value = -3; lim.knee.value = 0; lim.ratio.value = 20;
    lim.attack.value = 0.003; lim.release.value = 0.15;
    S.amp.connect(lim); lim.connect(c.destination);
    S.an = c.createAnalyser(); S.an.fftSize = 256; lim.connect(S.an);
    apply();
  }
  var quiet = 0;
  function scan() {
    if (S.ctx && S.ctx.state !== 'running') S.ctx.resume();
    var els = document.querySelectorAll('video,audio');
    for (var i = 0; i < els.length; i++) {
      var el = els[i]; if (S.hooked.has(el)) continue;
      if (!S.ctx) { build(); if (!S.ctx) return; }
      // Only hook once the context is running, otherwise the element goes mute.
      if (S.ctx.state !== 'running') { S.ctx.resume(); S.status = 'blocked'; return; }
      try { S.ctx.createMediaElementSource(el).connect(S.input); S.hooked.add(el); S.status = 'active'; }
      catch (e) { S.status = 'error: ' + e.message; }
    }
    // Watchdog: playing but no signal => stream can't be processed.
    var v = document.querySelector('video');
    if (S.status === 'active' || S.status === 'silent') {
      if (!v || v.paused || v.muted || v.volume === 0) { quiet = 0; return; }
      var d = new Uint8Array(S.an.fftSize); S.an.getByteTimeDomainData(d);
      var loud = false; for (var k = 0; k < d.length; k++) if (Math.abs(d[k] - 128) > 1) { loud = true; break; }
      quiet = loud ? 0 : quiet + 1;
      S.status = quiet >= 5 ? 'silent' : 'active';
    }
  }
  S.set = function (o) {
    if (o.gains) S.gains = o.gains;
    if (o.boost) S.boost = o.boost;
    if (typeof o.on === 'boolean') S.on = o.on;
    apply();
  };
  ['touchend', 'click', 'play', 'playing'].forEach(function (ev) { document.addEventListener(ev, scan, true); });
  setInterval(scan, 1000);
})();
''';
