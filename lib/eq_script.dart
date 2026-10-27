// JavaScript injected into the YouTube Music page.
//
// Two paths, chosen per player element:
//  * "hook": the element has a normal src (mp3/mp4 file) -> route it through the
//    EQ with createMediaElementSource (works in WebKit).
//  * "mse":  the element has a blob: src (Media Source Extensions, what YT Music
//    streams use). WebKit gives createMediaElementSource only silence for these,
//    so we capture the AAC segments the page appends to its SourceBuffer, decode
//    them ourselves, and play them through the EQ while the original element is
//    muted. If anything goes wrong the original element is un-muted again.
//
// Everything runs through one 10-band EQ + gain boost + limiter chain.
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
    armed: false, ctx: null, hooked: new WeakSet(), n: 0, err: '',
    mode: '', el: null, giveUp: false, dl: 0, dmode: '', mime: ''
  };

  // ======================================================================
  // 1. MP4 / AAC helpers
  // ======================================================================
  function rd32(b, o) { return ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0; }
  function tag(b, o) { return String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]); }
  function concat(a, b) { var r = new Uint8Array(a.length + b.length); r.set(a, 0); r.set(b, a.length); return r; }
  function find(b, name) {
    var c0 = name.charCodeAt(0), c1 = name.charCodeAt(1), c2 = name.charCodeAt(2), c3 = name.charCodeAt(3);
    for (var i = 0; i + 4 <= b.length; i++)
      if (b[i] === c0 && b[i + 1] === c1 && b[i + 2] === c2 && b[i + 3] === c3) return i;
    return -1;
  }
  // Calls fn(type, bodyStart, boxEnd, boxStart) for each box in [s, e). fn may return false to stop.
  function walk(b, s, e, fn) {
    var o = s;
    while (o + 8 <= e) {
      var sz = rd32(b, o), hs = 8, t = tag(b, o + 4);
      if (sz === 1) { sz = rd32(b, o + 8) * 4294967296 + rd32(b, o + 12); hs = 16; }
      else if (sz === 0) sz = e - o;
      if (sz < hs || o + sz > e) break;
      if (fn(t, o + hs, o + sz, o) === false) return;
      o += sz;
    }
  }
  var SR = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];
  function parseASC(a) {
    var bit = 0;
    function rb(n) { var v = 0; for (var i = 0; i < n; i++) { v = (v * 2) + ((a[bit >> 3] >> (7 - (bit & 7))) & 1); bit++; } return v; }
    var aot = rb(5), sf = rb(4), rate;
    if (sf === 15) { rate = rb(24); sf = SR.indexOf(rate); } else rate = SR[sf];
    var ch = rb(4);
    if (aot === 5 || aot === 29) { rb(4); aot = rb(5); }   // HE-AAC: use the core (LC) layer
    if (!rate || sf < 0 || aot < 1 || aot > 4 || ch < 1 || ch > 7) return null;
    return { aot: aot, sf: sf, rate: rate, ch: ch };
  }
  function descr(b, p) {
    var t = b[p++], len = 0, k = 0, x;
    do { x = b[p++]; len = (len * 128) + (x & 0x7f); k++; } while ((x & 0x80) && k < 4);
    return { t: t, len: len, p: p };
  }
  function parseInit(b) {          // -> { ts, asc } (asc null if not AAC-LC-ish)
    var r = { ts: 0, asc: null };
    var i = find(b, 'mdhd');
    if (i >= 0) r.ts = b[i + 4] === 1 ? rd32(b, i + 24) : rd32(b, i + 16);
    var e = find(b, 'esds');
    if (e >= 0) {
      try {
        var p = e + 8, d = descr(b, p);
        if (d.t === 3) {
          p = d.p + 2; var fl = b[p++];
          if (fl & 0x80) p += 2;
          if (fl & 0x40) p += 1 + b[p];
          if (fl & 0x20) p += 2;
          d = descr(b, p);
          if (d.t === 4) {
            p = d.p + 13; d = descr(b, p);
            if (d.t === 5) r.asc = parseASC(b.subarray(d.p, d.p + d.len));
          }
        }
      } catch (er) {}
    }
    return r;
  }
  // seg = one moof + its mdat, starting at the moof. -> { dts, frames[] } or null
  function parseSeg(seg) {
    var out = null;
    walk(seg, 0, seg.length, function (t, s, e, o) {
      if (t !== 'moof') return;
      var cur = -1;
      walk(seg, s, e, function (t2, s2, e2) {
        if (t2 !== 'traf') return;
        var defSize = 0, dts = 0, truns = [];
        walk(seg, s2, e2, function (t3, s3, e3) {
          var fl = rd32(seg, s3) & 0xffffff, p = s3 + 4;
          if (t3 === 'tfhd') {
            p += 4;
            if (fl & 1) p += 8;
            if (fl & 2) p += 4;
            if (fl & 8) p += 4;
            if (fl & 0x10) defSize = rd32(seg, p);
          } else if (t3 === 'tfdt') {
            dts = seg[s3] === 1 ? rd32(seg, s3 + 4) * 4294967296 + rd32(seg, s3 + 8) : rd32(seg, s3 + 4);
          } else if (t3 === 'trun') truns.push([s3, fl]);
        });
        var frames = [];
        cur = e + 8;                                  // default: start of mdat payload
        truns.forEach(function (tr) {
          var s3 = tr[0], fl = tr[1], p = s3 + 4, n = rd32(seg, p); p += 4;
          if (fl & 1) { cur = o + (rd32(seg, p) | 0); p += 4; }
          if (fl & 4) p += 4;
          for (var k = 0; k < n; k++) {
            if (fl & 0x100) p += 4;
            var size = defSize;
            if (fl & 0x200) { size = rd32(seg, p); p += 4; }
            if (fl & 0x400) p += 4;
            if (fl & 0x800) p += 4;
            frames.push(seg.subarray(cur, cur + size)); cur += size;
          }
        });
        if (!out) out = { dts: dts, frames: frames };
        else { out.frames = out.frames.concat(frames); }
      });
    });
    return out;
  }
  function buildAdts(a, frames) {
    var total = 0, i;
    for (i = 0; i < frames.length; i++) total += frames[i].length + 7;
    var out = new Uint8Array(total), o = 0;
    for (i = 0; i < frames.length; i++) {
      var f = frames[i], L = f.length + 7;
      out[o] = 0xFF; out[o + 1] = 0xF1;
      out[o + 2] = ((a.aot - 1) << 6) | (a.sf << 2) | (a.ch >> 2);
      out[o + 3] = ((a.ch & 3) << 6) | (L >> 11);
      out[o + 4] = (L >> 3) & 0xFF;
      out[o + 5] = ((L & 7) << 5) | 0x1F;
      out[o + 6] = 0xFC;
      out.set(f, o + 7); o += L;
    }
    return out;
  }
  S._t = { parseInit: parseInit, parseSeg: parseSeg, buildAdts: buildAdts, walk: walk, rd32: rd32 };

  // ======================================================================
  // 2. Capture what the page appends to its audio SourceBuffer
  // ======================================================================
  var M = S.sbs = [];                 // newest last, max 3
  var sbInfo = new WeakMap();
  var msMime = new WeakMap();
  function copyBytes(d) {
    if (d instanceof ArrayBuffer) return new Uint8Array(d.slice(0));
    return new Uint8Array(d.buffer.slice(d.byteOffset, d.byteOffset + d.byteLength));
  }
  function onInit(info) {
    var b = info.initParts.length === 1 ? info.initParts[0] : info.initParts.reduce(concat);
    var r = parseInit(b);
    info.init = b; info.ts = r.ts; info.asc = r.asc;
    if (!info.asc || !info.ts) info.bad = 'no AAC config';
  }
  function onSeg(info, seg) {
    if (!info.asc || !info.ts) return;
    var r = parseSeg(seg);
    if (!r || !r.frames.length) return;
    var start = r.dts / info.ts + info.tso;
    var rec = { key: Math.round(start * 1000), start: start, frames: r.frames, seg: seg,
                dur: r.frames.length * 1024 / info.asc.rate, buf: null, fail: 0, pending: false, off: 0 };
    rec.end = rec.start + rec.dur;
    info.segs[rec.key] = rec;
  }
  function feed(info, chunk) {
    var b = info.carry ? concat(info.carry, chunk) : chunk, o = 0;
    while (o + 8 <= b.length) {
      var sz = rd32(b, o), t = tag(b, o + 4);
      if (sz === 1) { if (o + 16 > b.length) break; sz = rd32(b, o + 8) * 4294967296 + rd32(b, o + 12); }
      if (sz < 8 || o + sz > b.length) break;      // incomplete: wait for the rest
      if (t === 'ftyp') { info.initParts = [b.slice(o, o + sz)]; }
      else if (t === 'moov') { info.initParts.push(b.slice(o, o + sz)); onInit(info); }
      else if (t === 'moof') { info.moof = b.slice(o, o + sz); }
      else if (t === 'mdat' && info.moof) { onSeg(info, concat(info.moof, b.subarray(o, o + sz))); info.moof = null; }
      o += sz;
    }
    info.carry = o < b.length ? b.slice(o) : null;
  }
  function patchMS(proto) {
    if (!proto || !Object.prototype.hasOwnProperty.call(proto, 'addSourceBuffer') || proto.__ytp) return;
    proto.__ytp = true;
    var orig = proto.addSourceBuffer;
    proto.addSourceBuffer = function (mime) {
      var sb = orig.apply(this, arguments);
      try {
        var m = String(mime);
        if (/^audio\//i.test(m)) {
          var info = { mime: m, ms: this, initParts: [], carry: null, moof: null, segs: {}, tso: 0,
                       kind: /mp4|m4a|aac/i.test(m) ? 'mp4' : 'other', t0: Date.now() };
          sbInfo.set(sb, info); M.push(info); if (M.length > 3) M.shift();
          if (info.kind !== 'mp4') info.bad = 'unsupported container ' + m;
        }
      } catch (e) { S.err = 'cap:' + e; }
      return sb;
    };
  }
  try {
    patchMS(window.MediaSource && MediaSource.prototype);
    patchMS(window.ManagedMediaSource && ManagedMediaSource.prototype);
    var SBP = window.SourceBuffer && SourceBuffer.prototype;
    if (SBP && !SBP.__ytp) {
      SBP.__ytp = true;
      var oa = SBP.appendBuffer, orem = SBP.remove;
      SBP.appendBuffer = function (d) {
        try {
          var info = sbInfo.get(this);
          if (info && !info.bad) { info.tso = this.timestampOffset || 0; feed(info, copyBytes(d)); }
        } catch (e) { S.err = 'cap:' + e; }
        return oa.apply(this, arguments);
      };
      SBP.remove = function (a, z) {
        try {
          var info = sbInfo.get(this);
          if (info) for (var k in info.segs) { var r = info.segs[k]; if (r.end > a && r.start < z) delete info.segs[k]; }
        } catch (e) {}
        return orem.apply(this, arguments);
      };
    }
  } catch (e) { S.err = 'patch:' + e; }

  // ======================================================================
  // 3. Audio graph: 10-band EQ + boost + limiter
  // ======================================================================
  function media() {
    var l = document.querySelectorAll('video,audio');
    if (l.length) return Array.prototype.slice.call(l);
    var out = [];
    (function walkDom(root) {
      var all = root.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        if (el.tagName === 'VIDEO' || el.tagName === 'AUDIO') out.push(el);
        if (el.shadowRoot) walkDom(el.shadowRoot);
      }
    })(document);
    return out;
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
    var lim = c.createDynamicsCompressor();
    lim.threshold.value = -3; lim.knee.value = 0; lim.ratio.value = 20;
    lim.attack.value = 0.003; lim.release.value = 0.15;
    S.amp.connect(lim); lim.connect(c.destination);
    S.an = c.createAnalyser(); S.an.fftSize = 256; lim.connect(S.an);
    apply();
  }

  // ======================================================================
  // 4. MSE player: decode captured segments, schedule them against the element clock
  // ======================================================================
  var live = false, muted0 = false, anchor = null, sched = {}, srcs = [];
  var busy = false, under = 0, okN = 0, failN = 0, lastInfo = null, noInfoT = 0, lastTick = 0;
  var listened = new WeakSet();

  function curInfo() {
    for (var i = M.length - 1; i >= 0; i--) {
      var st; try { st = M[i].ms.readyState; } catch (e) { st = 'closed'; }
      if (st !== 'closed') return M[i];
    }
    return null;
  }
  function sortedSegs(info) {
    var a = []; for (var k in info.segs) a.push(info.segs[k]);
    a.sort(function (x, y) { return x.start - y.start; });
    return a;
  }
  function stopAll() {
    var c = S.ctx, t = c ? c.currentTime : 0;
    srcs.forEach(function (x) {
      try { x.g.gain.cancelScheduledValues(t); x.g.gain.setTargetAtTime(0, t, 0.008); x.s.stop(t + 0.04); } catch (e) {}
    });
    srcs = []; sched = {}; anchor = null;
  }
  function release() {
    stopAll();
    if (live) { live = false; try { if (S.el) S.el.muted = muted0; } catch (e) {} }
  }
  function fallback(why) {
    release(); S.status = 'fallback'; S.err = why; S.giveUp = true;
  }
  function decodeSeg(info, rec) {
    var c = S.ctx, rate = info.asc.rate;
    var segs = sortedSegs(info), prev = null;
    for (var i = 0; i < segs.length; i++) if (segs[i] !== rec && Math.abs(segs[i].end - rec.start) < 0.01) { prev = segs[i]; break; }
    var pre = prev ? Math.min(2, prev.frames.length) : 0;
    var frames = pre ? prev.frames.slice(-pre).concat(rec.frames) : rec.frames;
    var data = buildAdts(info.asc, frames);
    return c.decodeAudioData(data.buffer).then(function (buf) {
      var exp = frames.length * 1024 / rate, diff = buf.duration - exp;
      S.dl = Math.round(diff * 1000); S.dmode = 'adts';
      rec.buf = buf; rec.off = Math.max(0, pre * 1024 / rate + diff);
    }, function (e1) {
      // Fallback: let the browser decode init + fragment as a fragmented MP4.
      return c.decodeAudioData(concat(info.init, rec.seg).buffer).then(function (buf) {
        S.dmode = 'fmp4'; rec.buf = buf; rec.off = 0;
      }, function (e2) { throw new Error('decode ' + (e1 && e1.message || e1) + ' / ' + (e2 && e2.message || e2)); });
    });
  }
  function ensureDecoded(info, t) {
    if (busy) return;
    var segs = sortedSegs(info);
    for (var i = 0; i < segs.length; i++) {
      var r = segs[i];
      if (r.end < t - 5) { if (r.buf) { r.buf = null; } continue; }
      if (r.start > t + 14) break;
      if (r.end <= t - 0.1 || r.buf || r.fail || r.pending) continue;
      busy = true; r.pending = true;
      decodeSeg(info, r).then(function () { okN++; failN = 0; }, function (e) {
        r.fail = 1; failN++; S.err = String(e && e.message || e);
        if (!okN && failN >= 3) fallback('decode failed: ' + S.err);
      }).then(function () { r.pending = false; busy = false; });
      return;
    }
  }
  function schedule(rec, rate, now) {
    var c = S.ctx;
    var when = anchor.c + (rec.start - anchor.m) / rate;
    var off = rec.off, dur = rec.dur, minT = now + 0.02;
    if (when < minT) { var skip = (minT - when) * rate; off += skip; dur -= skip; when = minT; }
    sched[rec.key] = 1;
    if (dur <= 0.005) return false;
    var s = c.createBufferSource(), g = c.createGain();
    s.buffer = rec.buf; s.playbackRate.value = rate;
    s.connect(g); g.connect(S.input);
    var entry = { s: s, g: g };
    s.onended = function () {
      try { s.disconnect(); g.disconnect(); } catch (e) {}
      var i = srcs.indexOf(entry); if (i >= 0) srcs.splice(i, 1);
    };
    s.start(when, off, dur);
    srcs.push(entry);
    return true;
  }
  function attach(el) {
    if (listened.has(el)) return; listened.add(el);
    ['seeking', 'pause', 'waiting', 'emptied', 'ratechange'].forEach(function (ev) {
      el.addEventListener(ev, function () { if (S.mode === 'mse') stopAll(); }, true);
    });
    el.addEventListener('volumechange', function () { if (live && !el.muted) { try { el.muted = true; } catch (e) {} } }, true);
    el.addEventListener('loadstart', function () { S.giveUp = false; failN = 0; }, true);
  }
  function tickMse() {
    var c = S.ctx, el = S.el;
    if (!S.armed || !c || !el) return;
    var info = curInfo();
    if (info !== lastInfo) { stopAll(); lastInfo = info; }
    if (!info) {
      release();
      if (!noInfoT) noInfoT = Date.now();
      S.status = Date.now() - noInfoT > 4000 ? 'late' : 'waiting'; return;
    }
    noInfoT = 0; S.mime = info.mime;
    if (info.bad) { fallback(info.bad); return; }
    if (S.giveUp) { release(); return; }
    if (!S.on) { release(); S.status = 'bypass'; return; }
    if (c.state !== 'running') { c.resume().catch(function (e) { S.err = String(e); }); S.status = 'blocked'; return; }
    var t = el.currentTime, rate = el.playbackRate || 1;
    ensureDecoded(info, t);
    var playing = !el.paused && !el.seeking && !el.ended && el.readyState >= 3;
    if (!playing) { stopAll(); if (!live) S.status = 'preparing'; return; }
    var now = c.currentTime;
    if (anchor) {
      var exp = anchor.m + (now - anchor.c) * rate;
      if (Math.abs(exp - t) > 0.3 || anchor.rate !== rate) stopAll();
    }
    if (!anchor) anchor = { c: now, m: t, rate: rate };
    var segs = sortedSegs(info), covered = false, started = false;
    for (var i = 0; i < segs.length; i++) {
      var r = segs[i];
      if (r.end <= t - 0.05) continue;
      if (r.start > t + 4 * rate) break;
      if (r.buf && r.start - 0.03 <= t && t < r.end + 0.03) covered = true;
      if (!r.buf || sched[r.key]) continue;
      if (schedule(r, rate, now)) started = true;
    }
    if (started && !live) { live = true; muted0 = el.muted; try { el.muted = true; } catch (e) {} }
    if (live) {
      under = covered ? 0 : under + 0.1;
      if (under > 2.5) { release(); S.giveUp = true; S.status = 'fallback'; S.err = 'gap at ' + t.toFixed(1) + 's'; return; }
      S.status = 'active';
    } else S.status = 'preparing';
  }

  // ======================================================================
  // 5. Hook path for plain (non-MSE) sources + element discovery
  // ======================================================================
  var quiet = 0;
  function scan() {
    if (!S.armed) { S.status = 'idle'; return; }
    if (S.ctx && S.ctx.state !== 'running') S.ctx.resume().catch(function (e) { S.err = String(e); });
    var els = media();
    if (!els.length) { if (S.status !== 'active') S.status = 'waiting'; return; }
    var hookedAny = false;
    for (var i = 0; i < els.length; i++) {
      var el = els[i], src = String(el.currentSrc || el.src || '');
      if (!S.ctx) { build(); if (!S.ctx) return; }
      if (src.indexOf('blob:') === 0) {
        S.mode = 'mse'; S.el = el; attach(el);
        continue;
      }
      if (!src && !el.srcObject) continue;
      if (S.hooked.has(el)) { hookedAny = true; continue; }
      if (S.ctx.state !== 'running') { S.ctx.resume().catch(function (e) { S.err = String(e); }); S.status = 'blocked'; return; }
      try { S.ctx.createMediaElementSource(el).connect(S.input); S.hooked.add(el); S.n++; S.status = 'active'; S.mode = 'hook'; hookedAny = true; }
      catch (e) { S.status = 'error'; S.err = String(e && e.message || e); }
    }
    if (S.mode === 'hook' && hookedAny && S.an) {          // watchdog (hook path only)
      var v = els[0];
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
    var v = S.el || media()[0], info = curInfo(), nseg = 0, ndec = 0;
    if (info) for (var k in info.segs) { nseg++; if (info.segs[k].buf) ndec++; }
    return JSON.stringify({
      status: S.status, armed: S.armed, ctx: S.ctx ? S.ctx.state : 'none', hooked: S.n,
      media: !!v, paused: v ? v.paused : null, rs: v ? v.readyState : null,
      src: v ? String(v.currentSrc || v.src || (v.srcObject ? 'srcObject' : 'none')).slice(0, 24) : '',
      mode: S.mode, live: live, segs: nseg, dec: ndec, dl: S.dl, dmode: S.dmode,
      mime: String(S.mime || '').slice(0, 40), err: S.err
    });
  };
  ['touchend', 'click', 'play', 'playing'].forEach(function (ev) { document.addEventListener(ev, scan, true); });
  setInterval(scan, 1000);
  setInterval(function () { try { if (S.mode === 'mse') tickMse(); } catch (e) { S.err = 'tick:' + e; } }, 100);
})();
''';
