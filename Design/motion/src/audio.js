// The film's sound, synthesized from the same clock as the picture: the music (112.5 BPM, D major) and every UI
// sound on its cue. Rendered offline (48 kHz, stereo) and written as a 32-bit float WAV; render.mjs masters it.
import { CUE, at, BEAT, BAR, DURATION } from './time.js';

const SR = 48000;
const mtof = (m) => 440 * Math.pow(2, (m - 69) / 12);

// a seeded PRNG: the same render every time
function prng(seed) {
  let s = seed >>> 0;
  return () => { s = (s + 0x6D2B79F5) >>> 0; let t = s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}

export async function renderAudio({ stems = 'all' } = {}) {
  const ctx = new OfflineAudioContext(2, Math.ceil(SR * DURATION), SR);
  const rnd = prng(7);

  // ── buses ────────────────────────────────────────────────────────────────────────────────────────────────
  const master = ctx.createGain();
  const glue = ctx.createDynamicsCompressor();
  glue.threshold.value = -20; glue.knee.value = 12; glue.ratio.value = 2.2; glue.attack.value = 0.012; glue.release.value = 0.28;
  const makeup = ctx.createGain(); makeup.gain.value = 1.0;
  const limiter = ctx.createDynamicsCompressor();
  limiter.threshold.value = -3; limiter.knee.value = 0; limiter.ratio.value = 20; limiter.attack.value = 0.002; limiter.release.value = 0.09;
  const rumble = ctx.createBiquadFilter(); rumble.type = 'highpass'; rumble.frequency.value = 30; rumble.Q.value = 0.6;   // nothing under 30 Hz
  master.connect(rumble).connect(glue).connect(makeup).connect(limiter).connect(ctx.destination);

  // stems: music (ducked by the kick and under the UI's moments) and the drums; the sounds of the picture
  const musicOut = ctx.createGain(), sfxOut = ctx.createGain();
  musicOut.gain.value = stems === 'sfx' ? 0 : 0.4;    // the bed sits well under the picture's sounds
  sfxOut.gain.value = stems === 'music' ? 0 : 1;
  musicOut.connect(master); sfxOut.connect(master);
  const music = ctx.createGain();
  const duck = ctx.createGain();
  music.connect(duck).connect(musicOut);
  const drums = ctx.createGain(); drums.connect(musicOut);
  const sfx = ctx.createGain();
  sfx.connect(sfxOut);

  // reverb: a warm, decaying stereo noise tail
  const reverb = ctx.createConvolver();
  {
    const len = Math.floor(SR * 2.6), ir = ctx.createBuffer(2, len, SR);
    for (let ch = 0; ch < 2; ch++) {
      const d = ir.getChannelData(ch);
      let lp = 0;
      for (let i = 0; i < len; i++) {
        const x = rnd() * 2 - 1;
        lp += (x - lp) * (0.18 + 0.5 * Math.exp(-i / (SR * 0.25)));   // darker as it decays
        d[i] = lp * Math.pow(1 - i / len, 2.4) * Math.exp(-i / (SR * 0.9));
      }
    }
    reverb.buffer = ir;
  }
  const verbIn = ctx.createGain(), verbOut = ctx.createGain(); verbOut.gain.value = 0.5;
  verbIn.connect(reverb).connect(verbOut).connect(musicOut);
  const reverb2 = ctx.createConvolver(); reverb2.buffer = reverb.buffer;
  const sfxVerbIn = ctx.createGain(), sfxVerbOut = ctx.createGain(); sfxVerbOut.gain.value = 0.5;
  sfxVerbIn.connect(reverb2).connect(sfxVerbOut).connect(sfxOut);

  // ping-pong delay, dotted eighth
  const dl = ctx.createDelay(2), dr = ctx.createDelay(2), fbL = ctx.createGain(), fbR = ctx.createGain();
  dl.delayTime.value = BEAT * 0.75; dr.delayTime.value = BEAT * 0.75;
  fbL.gain.value = 0.38; fbR.gain.value = 0.38;
  const dTone = ctx.createBiquadFilter(); dTone.type = 'lowpass'; dTone.frequency.value = 3800;
  const merger = ctx.createChannelMerger(2);
  const delayIn = ctx.createGain();
  delayIn.connect(dTone).connect(dl);
  dl.connect(fbL).connect(dr); dr.connect(fbR).connect(dl);
  dl.connect(merger, 0, 0); dr.connect(merger, 0, 1);
  const delayOut = ctx.createGain(); delayOut.gain.value = 0.42;
  merger.connect(delayOut).connect(music);

  // noise
  const noise = ctx.createBuffer(2, SR * 2, SR);
  for (let ch = 0; ch < 2; ch++) { const d = noise.getChannelData(ch); for (let i = 0; i < d.length; i++) d[i] = rnd() * 2 - 1; }
  const noiseSrc = (t0, t1) => { const n = ctx.createBufferSource(); n.buffer = noise; n.loop = true; n.start(t0, rnd() * 1.5); n.stop(t1); return n; };

  // ── instruments ──────────────────────────────────────────────────────────────────────────────────────────
  const gainEnv = (t0, a, peak, d, sustain, t1, r) => {
    const g = ctx.createGain();
    g.gain.setValueAtTime(0, t0);
    g.gain.linearRampToValueAtTime(peak, t0 + a);
    g.gain.setTargetAtTime(peak * sustain, t0 + a, d / 3);
    if (t1 != null) { g.gain.setValueAtTime(peak * sustain, t1); g.gain.setTargetAtTime(0, t1, r / 4); }
    return g;
  };
  const pan = (v) => { const p = ctx.createStereoPanner(); p.pan.value = v; return p; };
  const send = (node, { verb = 0, delay = 0 } = {}, toSfx = false) => {
    if (verb) { const g = ctx.createGain(); g.gain.value = verb; node.connect(g).connect(toSfx ? sfxVerbIn : verbIn); }
    if (delay) { const g = ctx.createGain(); g.gain.value = delay; node.connect(g).connect(delayIn); }
  };

  /** A warm pad: two detuned saws and a triangle per note, through a slowly opening low-pass. */
  function pad(t0, t1, notes, vol, cutoff = [900, 2400]) {
    notes.forEach((m, i) => {
      const f = mtof(m);
      const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.Q.value = 0.4;
      lp.frequency.setValueAtTime(cutoff[0], t0); lp.frequency.linearRampToValueAtTime(cutoff[1], t1);
      const hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 170; hp.Q.value = 0.5;   // room for the bass
      const env = gainEnv(t0, 0.7, vol / notes.length, 1, 0.9, t1, 1.4);
      const p = pan((i / (notes.length - 1 || 1)) * 0.7 - 0.35);
      lp.connect(hp).connect(env).connect(p);
      p.connect(music);
      send(p, { verb: 0.55 });
      for (const [type, det, g] of [['sawtooth', -7, 0.32], ['sawtooth', 7, 0.32], ['triangle', 0, 0.6]]) {
        const o = ctx.createOscillator(); o.type = type; o.frequency.value = f; o.detune.value = det;
        const og = ctx.createGain(); og.gain.value = g;
        o.connect(og).connect(lp); o.start(t0); o.stop(t1 + 2);
      }
    });
  }

  /** A soft pluck (the arpeggio): sine + triangle, a fast decay, a closing filter. */
  function pluck(t, m, vol, { len = 0.32, bright = 3200, panv = 0, delay = 0.35, verb = 0.18, dest = music } = {}) {
    const f = mtof(m);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.Q.value = 1.2;
    lp.frequency.setValueAtTime(bright, t); lp.frequency.exponentialRampToValueAtTime(Math.max(400, f * 1.5), t + len);
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, t); env.gain.linearRampToValueAtTime(vol, t + 0.004); env.gain.setTargetAtTime(0, t + 0.004, len / 4);
    const p = pan(panv);
    lp.connect(env).connect(p); p.connect(dest);
    send(p, { verb, delay });
    for (const [type, mul, g] of [['triangle', 1, 0.7], ['sine', 2, 0.25], ['sine', 1, 0.5]]) {
      const o = ctx.createOscillator(); o.type = type; o.frequency.value = f * mul;
      const og = ctx.createGain(); og.gain.value = g; o.connect(og).connect(lp); o.start(t); o.stop(t + len * 3);
    }
  }

  /** A bell (FM): the chimes, the hook, the lantern. */
  function bell(t, m, vol, { len = 1.6, ratio = 3.5, index = 2.2, panv = 0, verb = 0.35, delay = 0, dest = sfx } = {}) {
    const f = mtof(m);
    const car = ctx.createOscillator(); car.type = 'sine'; car.frequency.value = f;
    const mod = ctx.createOscillator(); mod.type = 'sine'; mod.frequency.value = f * ratio;
    const mg = ctx.createGain();
    mg.gain.setValueAtTime(f * index, t); mg.gain.exponentialRampToValueAtTime(f * 0.05, t + len * 0.6);
    mod.connect(mg).connect(car.frequency);
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, t); env.gain.linearRampToValueAtTime(vol, t + 0.003); env.gain.exponentialRampToValueAtTime(vol * 0.001, t + len);
    const air = ctx.createOscillator(); air.type = 'sine'; air.frequency.value = f * 2.76;
    const ag = ctx.createGain(); ag.gain.setValueAtTime(vol * 0.18, t); ag.gain.exponentialRampToValueAtTime(vol * 0.0005, t + len * 0.35);
    const p = pan(panv);
    car.connect(env).connect(p); air.connect(ag).connect(p); p.connect(dest);
    send(p, { verb, delay }, dest === sfx);
    for (const o of [car, mod, air]) { o.start(t); o.stop(t + len + 0.1); }
  }

  function bass(t, dur, m, vol) {
    const f = mtof(m);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 420; lp.Q.value = 0.7;
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, t); env.gain.linearRampToValueAtTime(vol, t + 0.008);
    env.gain.setTargetAtTime(vol * 0.75, t + 0.01, 0.08); env.gain.setValueAtTime(vol * 0.75, t + dur - 0.03); env.gain.linearRampToValueAtTime(0, t + dur);
    const shaper = ctx.createWaveShaper();
    const curve = new Float32Array(1024); for (let i = 0; i < 1024; i++) { const x = i / 511.5 - 1; curve[i] = Math.tanh(x * 1.6); }
    shaper.curve = curve;
    const pre = ctx.createGain(); pre.gain.value = 0.45;
    lp.connect(pre).connect(shaper).connect(env).connect(music);
    for (const [type, mul, g] of [['sine', 1, 0.9], ['triangle', 1, 0.35], ['sine', 2, 0.12]]) {
      const o = ctx.createOscillator(); o.type = type; o.frequency.value = f * mul;
      const og = ctx.createGain(); og.gain.value = g; o.connect(og).connect(lp); o.start(t); o.stop(t + dur + 0.05);
    }
  }

  const kicks = [];
  function kick(t, vol = 0.9) {
    vol *= 0.55;
    kicks.push(t);
    const o = ctx.createOscillator(); o.type = 'sine';
    o.frequency.setValueAtTime(165, t); o.frequency.exponentialRampToValueAtTime(56, t + 0.08); o.frequency.exponentialRampToValueAtTime(47, t + 0.3);
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, t); env.gain.linearRampToValueAtTime(vol, t + 0.002); env.gain.setTargetAtTime(0, t + 0.05, 0.072);
    o.connect(env).connect(drums);
    o.start(t); o.stop(t + 0.7);
    const n = noiseSrc(t, t + 0.02), hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 2500;
    const ng = ctx.createGain(); ng.gain.setValueAtTime(vol * 0.12, t); ng.gain.exponentialRampToValueAtTime(0.0001, t + 0.015);
    n.connect(hp).connect(ng).connect(drums);
  }
  function clap(t, vol = 0.32) {
    const bp = ctx.createBiquadFilter(); bp.type = 'bandpass'; bp.frequency.value = 1350; bp.Q.value = 0.9;
    const env = ctx.createGain(); env.gain.setValueAtTime(0, t);
    for (const [dt, v] of [[0, 1], [0.011, 0.8], [0.022, 0.9]]) { env.gain.setValueAtTime(vol * v, t + dt); env.gain.setTargetAtTime(vol * 0.15, t + dt + 0.001, 0.003); }
    env.gain.setValueAtTime(vol * 0.5, t + 0.03); env.gain.setTargetAtTime(0, t + 0.03, 0.045);
    const n = noiseSrc(t, t + 0.4);
    const p = pan(0.05);
    n.connect(bp).connect(env).connect(p); p.connect(music);
    send(p, { verb: 0.4 });
  }
  function hat(t, vol = 0.07, open = false, panv = 0.25) {
    const hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 7200;
    const bp = ctx.createBiquadFilter(); bp.type = 'peaking'; bp.frequency.value = 10000; bp.gain.value = 4;
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, t); env.gain.linearRampToValueAtTime(vol, t + 0.002); env.gain.setTargetAtTime(0, t + 0.004, open ? 0.09 : 0.012);
    const n = noiseSrc(t, t + (open ? 0.6 : 0.12));
    const p = pan(panv);
    n.connect(hp).connect(bp).connect(env).connect(p); p.connect(music);
  }
  function riser(t0, t1, vol = 0.16) {
    const n = noiseSrc(t0, t1 + 0.05);
    const bp = ctx.createBiquadFilter(); bp.type = 'bandpass'; bp.Q.value = 2.2;
    bp.frequency.setValueAtTime(300, t0); bp.frequency.exponentialRampToValueAtTime(7500, t1);
    const g = ctx.createGain(); g.gain.setValueAtTime(0.0001, t0); g.gain.exponentialRampToValueAtTime(vol, t1 - 0.02); g.gain.linearRampToValueAtTime(0, t1 + 0.02);
    n.connect(bp).connect(g).connect(sfx);
    send(g, { verb: 0.3 }, true);
    const o = ctx.createOscillator(); o.type = 'sawtooth';
    o.frequency.setValueAtTime(mtof(57), t0); o.frequency.exponentialRampToValueAtTime(mtof(69), t1);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.setValueAtTime(400, t0); lp.frequency.exponentialRampToValueAtTime(3000, t1);
    const og = ctx.createGain(); og.gain.setValueAtTime(0.0001, t0); og.gain.exponentialRampToValueAtTime(vol * 0.35, t1 - 0.02); og.gain.linearRampToValueAtTime(0, t1 + 0.01);
    o.connect(lp).connect(og).connect(sfx); o.start(t0); o.stop(t1 + 0.05);
  }
  function impact(t, vol = 0.85) {
    const o = ctx.createOscillator(); o.type = 'sine';
    o.frequency.setValueAtTime(70, t); o.frequency.exponentialRampToValueAtTime(32, t + 1.4);
    const env = ctx.createGain(); env.gain.setValueAtTime(0, t); env.gain.linearRampToValueAtTime(vol, t + 0.005); env.gain.setTargetAtTime(0, t + 0.02, 0.38);
    o.connect(env).connect(sfx); o.start(t); o.stop(t + 2.2);
    const n = noiseSrc(t, t + 1.2), lp = ctx.createBiquadFilter(); lp.type = 'lowpass';
    lp.frequency.setValueAtTime(5000, t); lp.frequency.exponentialRampToValueAtTime(200, t + 0.8);
    const ng = ctx.createGain(); ng.gain.setValueAtTime(vol * 0.32, t); ng.gain.setTargetAtTime(0, t + 0.01, 0.14);
    n.connect(lp).connect(ng).connect(sfx);
    send(ng, { verb: 0.9 }, true);
  }
  function whoosh(t, dur, { up = true, vol = 0.14, from = -0.6, to = 0.6 } = {}) {
    vol *= 1.3;
    const n = noiseSrc(t, t + dur + 0.05);
    const bp = ctx.createBiquadFilter(); bp.type = 'bandpass'; bp.Q.value = 1.1;
    const [f0, f1] = up ? [350, 5200] : [4800, 300];
    bp.frequency.setValueAtTime(f0, t); bp.frequency.exponentialRampToValueAtTime(f1, t + dur);
    const g = ctx.createGain(); g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(vol, t + dur * 0.55); g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    const p = ctx.createStereoPanner(); p.pan.setValueAtTime(from, t); p.pan.linearRampToValueAtTime(to, t + dur);
    n.connect(bp).connect(g).connect(p); p.connect(sfx);
    send(p, { verb: 0.25 }, true);
  }

  // ── UI sounds ────────────────────────────────────────────────────────────────────────────────────────────
  function click(t, vol = 0.32, tone = 2400) {
    vol *= 4;
    const n = noiseSrc(t, t + 0.03), bp = ctx.createBiquadFilter(); bp.type = 'bandpass'; bp.frequency.value = tone; bp.Q.value = 1.5;
    const g = ctx.createGain(); g.gain.setValueAtTime(vol, t); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.012);
    n.connect(bp).connect(g).connect(sfx);
    const o = ctx.createOscillator(); o.type = 'sine'; o.frequency.setValueAtTime(tone * 0.6, t); o.frequency.exponentialRampToValueAtTime(tone * 0.3, t + 0.02);
    const og = ctx.createGain(); og.gain.setValueAtTime(vol * 0.35, t); og.gain.exponentialRampToValueAtTime(0.0001, t + 0.025);
    o.connect(og).connect(sfx); o.start(t); o.stop(t + 0.04);
  }
  function keyThock(t, vol = 0.45) {
    vol *= 1.4;
    click(t, vol * 0.7, 2600);
    const o = ctx.createOscillator(); o.type = 'sine'; o.frequency.setValueAtTime(220, t); o.frequency.exponentialRampToValueAtTime(120, t + 0.05);
    const g = ctx.createGain(); g.gain.setValueAtTime(vol * 0.8, t); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.09);
    o.connect(g).connect(sfx); o.start(t); o.stop(t + 0.12);
    click(t + 0.075, vol * 0.25, 1800);   // the key coming back up
  }
  function haptic(t, vol = 0.6) {
    vol *= 1.3;
    for (const [f, v] of [[62, 1], [124, 0.25]]) {
      const o = ctx.createOscillator(); o.type = 'sine'; o.frequency.value = f;
      const g = ctx.createGain(); g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(vol * v, t + 0.006); g.gain.setTargetAtTime(0, t + 0.03, 0.025);
      o.connect(g).connect(sfx); o.start(t); o.stop(t + 0.25);
    }
  }
  function bloop(t, up = true, vol = 0.32) {
    vol *= 1.25;
    const o = ctx.createOscillator(); o.type = 'sine';
    const [f0, f1] = up ? [210, 520] : [480, 190];
    o.frequency.setValueAtTime(f0, t); o.frequency.exponentialRampToValueAtTime(f1, t + 0.11);
    const o2 = ctx.createOscillator(); o2.type = 'triangle'; o2.frequency.setValueAtTime(f0 * 1.5, t); o2.frequency.exponentialRampToValueAtTime(f1 * 1.5, t + 0.11);
    const g = ctx.createGain(); g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(vol, t + 0.015); g.gain.setTargetAtTime(0, t + 0.06, 0.04);
    const g2 = ctx.createGain(); g2.gain.value = 0.18;
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 2200;
    o.connect(g); o2.connect(g2).connect(g); g.connect(lp).connect(sfx);
    send(lp, { verb: 0.2 }, true);
    o.start(t); o.stop(t + 0.35); o2.start(t); o2.stop(t + 0.35);
  }
  function blip(t, m, vol = 0.18, panv = 0) { bell(t, m, vol * 1.9, { len: 0.45, ratio: 2, index: 0.8, panv, verb: 0.22 }); }
  // the UI's chimes are glassy and in tune (a harmonic FM ratio); only the lantern rings like a real bell
  const glass = { ratio: 2, index: 1.15 };
  const needsChime = (t) => { bell(t, 81, 0.3, { len: 1.3, verb: 0.4, ...glass }); bell(t + 0.11, 86, 0.27, { len: 1.5, verb: 0.4, ...glass }); };
  const notifChime = (t) => { bell(t, 86, 0.24, { len: 1.1, verb: 0.35, panv: -0.1, ...glass }); bell(t + 0.07, 90, 0.22, { len: 1.1, verb: 0.35, ...glass }); bell(t + 0.14, 93, 0.22, { len: 1.4, verb: 0.4, panv: 0.1, ...glass }); };
  const success = (t) => { blip(t, 88, 0.17); blip(t + 0.08, 93, 0.17); };
  const turnChime = (t) => { [86, 90, 93, 98].forEach((m, i) => bell(t + i * 0.065, m, 0.19, { len: 1.4, verb: 0.45, panv: (i - 1.5) * 0.15, ...glass })); };

  // ── the score ────────────────────────────────────────────────────────────────────────────────────────────
  const CH = {
    D: { pad: [50, 57, 61, 64, 66], bass: 38, arp: [74, 78, 81, 85, 88] },
    Bm: { pad: [47, 54, 57, 61, 62], bass: 35, arp: [71, 74, 78, 81, 85] },
    G: { pad: [43, 50, 54, 57, 59], bass: 31, arp: [67, 71, 74, 78, 81] },
    A: { pad: [45, 52, 59, 61, 66], bass: 33, arp: [69, 73, 76, 81, 83] },
  };
  const bars = ['D', 'G', 'D', 'Bm', 'G', 'A', 'D', 'Bm', 'G', 'A', 'D', 'Bm', 'G', 'A', 'D', 'Bm', 'G', 'A', 'Bm', 'G', 'D', 'G', 'D', 'D'];
  const section = (b) => (b <= 2 ? 'intro' : b <= 8 ? 'mac' : b <= 10 ? 'away' : b <= 18 ? 'phone' : b <= 20 ? 'every' : 'end');
  const ARP = [0, 2, 1, 3, 2, 4, 3, 1, 0, 2, 1, 3, 4, 3, 2, 1];

  bars.forEach((name, i) => {
    const b = i + 1, t0 = at(b), ch = CH[name], sec = section(b);
    // pads everywhere, opening up through the film
    const padVol = { intro: 0.13, mac: 0.1, away: 0.13, phone: 0.09, every: 0.1, end: 0.15 }[sec];
    const cut = { intro: [500, 1400], mac: [900, 1800], away: [1500, 700], phone: [1400, 2600], every: [1800, 3000], end: [1200, 3400] }[sec];
    pad(t0, t0 + BAR, ch.pad, padVol, cut);
    // bass
    if (sec === 'mac' || sec === 'phone' || sec === 'every') {
      const pattern = sec === 'mac' ? [[1, 1.5], [2.5, 0.5], [3, 1], [4, 0.5], [4.5, 0.5]] : [[1, 0.5], [1.5, 0.5], [2, 0.5], [2.5, 0.5], [3, 0.5], [3.5, 0.5], [4, 0.5], [4.5, 0.5]];
      for (const [beat, len] of pattern) bass(at(b, beat), len * BEAT * 0.92, ch.bass + (beat === 4.5 && sec === 'phone' ? 12 : 0), sec === 'mac' ? 0.16 : 0.135);
    }
    if (sec === 'away' && b === 10) bass(at(b, 1), BAR, ch.bass, 0.1);
    if (sec === 'end' && b === 21) bass(at(b, 1), BAR * 1.5, 38, 0.11);
    // the arpeggio: sixteenths, sparse in the intro and the end
    if (sec !== 'away' || b === 10) {
      const step = sec === 'intro' || sec === 'end' ? 2 : 1;
      const vol = { intro: 0.05, mac: 0.06, away: 0.04, phone: 0.065, every: 0.06, end: 0.045 }[sec];
      for (let s16 = 0; s16 < 16; s16 += step) {
        if (sec === 'intro' && b === 1 && s16 < 8) continue;
        pluck(at(b, 1 + s16 / 4), ch.arp[ARP[s16] % ch.arp.length], vol * (s16 % 4 === 0 ? 1.15 : 0.85), { panv: s16 % 2 ? 0.3 : -0.3, delay: sec === 'end' ? 0.5 : 0.32 });
      }
    }
    // drums
    if (sec === 'mac' || sec === 'phone') {
      const four = sec === 'phone';
      for (const beat of four ? [1, 2, 3, 4] : [1, 2.75, 3]) kick(at(b, beat), beat === 1 ? 0.9 : 0.78);
      clap(at(b, 2)); clap(at(b, 4));
      if (four) for (let e = 0; e < 16; e++) hat(at(b, 1 + e * 0.25), e % 2 ? 0.035 : (e % 4 === 2 ? 0.07 : 0.05), false, e % 2 ? 0.28 : -0.12);
      else for (const beat of [1.5, 2.5, 3.5, 4.5]) hat(at(b, beat), 0.06, false, 0.2);
      if (b % 2 === 0) hat(at(b, 4.5), 0.06, true, 0.3);
    }
    if (sec === 'intro' && b === 2) for (let s16 = 0; s16 < 16; s16++) hat(at(b, 1 + s16 / 4), 0.018 + s16 * 0.0022, false, 0.35);
    if (sec === 'away' && b === 10) for (let s16 = 0; s16 < 16; s16++) hat(at(b, 1 + s16 / 4), 0.012 + s16 * 0.003, false, -0.3);
    if (sec === 'every') {
      for (const beat of [1, 2, 3, 4]) { kick(at(b, beat), 0.9); }
      clap(at(b, 2), 0.28); clap(at(b, 4), 0.28);
      for (const beat of [1.5, 2.5, 3.5, 4.5]) hat(at(b, beat), 0.065, false, 0.2);
      // a stab on each device's beat
      if (b === 19) for (const beat of [1, 2, 3]) ch.pad.slice(1).forEach((m) => pluck(at(b, beat), m + 12, 0.07, { len: 0.5, bright: 5000, verb: 0.35, delay: 0.15 }));
    }
  });
  // fills into the drops
  for (const [b, beat] of [[8, 4], [18, 4]]) for (let k = 0; k < 4; k++) clap(at(b, beat + k / 4), 0.12 + k * 0.05);
  // the hook on the iPhone: a bell melody, the delay answering it
  const HOOK = [
    [11, 1, 81, 1], [11, 2.5, 78, 0.5], [11, 3, 76, 1], [11, 4, 74, 1],
    [12, 1, 78, 1], [12, 2.5, 74, 0.5], [12, 3, 73, 1], [12, 4, 71, 1],
    [13, 1, 74, 0.5], [13, 1.5, 76, 0.5], [13, 2, 78, 1], [13, 3, 81, 2],
    [14, 1, 76, 1.5], [14, 2.5, 73, 0.5], [14, 3, 76, 1], [14, 4, 81, 1],
    [15, 1, 81, 1], [15, 2.5, 78, 0.5], [15, 3, 76, 1], [15, 4, 74, 1],
    [16, 1, 78, 1], [16, 2.5, 81, 0.5], [16, 3, 83, 1], [16, 4, 81, 1],
    [17, 1, 78, 0.5], [17, 1.5, 76, 0.5], [17, 2, 74, 1], [17, 3, 76, 2],
    [18, 1, 73, 1.5], [18, 2.5, 76, 0.5], [18, 3, 81, 2],
  ];
  for (const [b, beat, m] of HOOK) bell(at(b, beat), m, 0.075, { len: 1.1, ratio: 2, index: 1.1, verb: 0.3, delay: 0.25, dest: music, panv: 0.08 });

  // the sections' joins
  riser(at(2, 1), at(3, 1), 0.13);
  impact(at(3, 1), 0.5);
  whoosh(at(9, 1) - 0.05, 1.3, { up: false, vol: 0.12, from: 0.5, to: -0.5 });
  riser(at(10, 1), at(11, 1), 0.15);
  impact(at(11, 1), 0.55);
  riser(at(20, 3), at(21, 1), 0.12);
  impact(at(21, 1), 0.55);
  // the pad's long last chord and the final bell
  bell(at(24, 1), 74, 0.12, { len: 4, ratio: 3.5, index: 1.4, verb: 0.7 });

  // ── the picture's sounds, on their cues ──────────────────────────────────────────────────────────────────
  const T = CUE;
  blip(T.ringIn + 0.02, 86, 0.15, 0.3);
  [0, 1, 2].forEach((i) => blip(T.rings + i * BEAT / 2, [81, 85, 88][i], 0.11, 0.35));
  whoosh(T.tabForms, 0.55, { up: false, vol: 0.07, from: 0.4, to: 0.4 });
  whoosh(T.pullBack - 0.25, 0.75, { up: true, vol: 0.16, from: 0.6, to: -0.2 });
  needsChime(T.needs);
  haptic(T.needs + 0.12, 0.25);
  click(T.inboxClick, 0.3);
  whoosh(T.inboxClick + 0.01, 0.38, { up: true, vol: 0.06, from: 0.5, to: 0.1 });
  keyThock(T.press1);
  success(T.sent);
  whoosh(T.panelClose, 0.3, { up: false, vol: 0.05, from: 0.1, to: 0.5 });
  [[T.toolNew, 86], [T.toolTalk, 90], [T.toolPoint, 93]].forEach(([t, m]) => { blip(t, m, 0.1, 0.4); click(t - 0.005, 0.06, 3200); });
  whoosh(T.tabFolds, 0.25, { up: false, vol: 0.04, from: 0.5, to: 0.5 });
  whoosh(T.phoneUp, 0.95, { up: true, vol: 0.13, from: 0.3, to: 0.1 });
  click(T.islandPress, 0.12, 1500); haptic(T.islandPress + 0.3, 0.35);
  bloop(T.islandOpen, true, 0.3);
  bloop(T.islandClose, false, 0.22);
  haptic(T.ask, 0.55); bloop(T.ask + 0.02, true, 0.18);
  notifChime(T.ask + 0.12);
  click(T.bannerPress, 0.1, 1500); haptic(T.menuOpen, 0.4);
  whoosh(T.menuOpen, 0.3, { up: true, vol: 0.05, from: 0, to: 0.1 });
  click(T.choose, 0.22, 1900);
  success(T.answered + 0.04);
  whoosh(T.answered + 0.05, 0.35, { up: true, vol: 0.06, from: 0, to: 0 });
  click(T.lockCard - 0.2, 0.16, 900);
  needsChime(T.lockCard + 0.1);
  click(T.allowTap, 0.22, 1900); haptic(T.allowTap + 0.01, 0.3);
  blip(T.working, 81, 0.08, 0);
  turnChime(T.yourTurn);
  whoosh(T.phoneOut + 0.3, 0.8, { up: false, vol: 0.1, from: 0.2, to: -0.4 });
  [T.every1, T.every2, T.every3].forEach((t, i) => whoosh(t - 0.18, 0.4, { up: true, vol: 0.08, from: 0.8, to: 0.3 + i * 0.1 }));
  click(T.secure + 0.15, 0.14, 1200); bell(T.secure + 0.15, 62, 0.22, { len: 2.4, ratio: 1.5, index: 0.6, verb: 0.5 }); bell(T.secure + 0.15, 74, 0.08, { len: 2, ratio: 2, index: 0.5, verb: 0.5 });
  bell(T.endIn + 0.02, 86, 0.18, { len: 3.2, ratio: 3.5, index: 1.8, verb: 0.75 });      // the lantern
  whoosh(T.endIn, 0.6, { up: false, vol: 0.06, from: 0.4, to: 0.6 });                    // the splash of the hop
  bell(T.wordmark, 81, 0.06, { len: 2, ratio: 2, index: 0.6, verb: 0.6 });

  // the music ducks under each kick (a gentle pump) and under the UI's big moments
  duck.gain.setValueAtTime(1, 0);
  for (const k of kicks) { duck.gain.setValueAtTime(1, k); duck.gain.linearRampToValueAtTime(0.62, k + 0.008); duck.gain.setTargetAtTime(1, k + 0.02, 0.07); }
  for (const t of [T.needs, T.inboxClick, T.press1, T.sent, T.islandOpen, T.ask, T.menuOpen, T.choose, T.lockCard, T.allowTap, T.yourTurn, T.endIn]) {
    music.gain.setValueAtTime(1, t - 0.03); music.gain.linearRampToValueAtTime(0.6, t + 0.01); music.gain.setTargetAtTime(1, t + 0.3, 0.22);
  }

  // in and out
  master.gain.setValueAtTime(0, 0); master.gain.linearRampToValueAtTime(1, 0.03);
  master.gain.setValueAtTime(1, at(24, 3)); master.gain.linearRampToValueAtTime(0, DURATION - 0.05);

  const buffer = await ctx.startRendering();
  return wav(buffer);
}

/** 32-bit float WAV. */
function wav(buffer) {
  const ch = buffer.numberOfChannels, len = buffer.length, bytes = len * ch * 4;
  const out = new ArrayBuffer(44 + bytes), v = new DataView(out);
  const w = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
  w(0, 'RIFF'); v.setUint32(4, 36 + bytes, true); w(8, 'WAVE'); w(12, 'fmt ');
  v.setUint32(16, 16, true); v.setUint16(20, 3, true); v.setUint16(22, ch, true); v.setUint32(24, buffer.sampleRate, true);
  v.setUint32(28, buffer.sampleRate * ch * 4, true); v.setUint16(32, ch * 4, true); v.setUint16(34, 32, true);
  w(36, 'data'); v.setUint32(40, bytes, true);
  const data = [...Array(ch)].map((_, c) => buffer.getChannelData(c));
  let o = 44;
  for (let i = 0; i < len; i++) for (let c = 0; c < ch; c++) { v.setFloat32(o, data[c][i], true); o += 4; }
  return out;
}
