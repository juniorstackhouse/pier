// Bars 19–24: every device on the beat, the end-to-end tunnel, then the site's own night harbour (Design/hero, driven
// frame by frame) with the name, the line and the address.
import { h, css, sym } from '../dom.js';
import { CUE, BEAT, BAR, DURATION } from '../time.js';
import { clamp, lerp, ease, prog, spring } from '../anim.js';
import { start as startHero } from '../../../hero/hero.js';
import { FORMAT } from '../format.js';
import { LANG, say } from '../lang.js';

const T = CUE;
const V = FORMAT.vertical;

function shot(src, kind) {
  return h('div', { class: `m-device ${kind}` }, h('img', { src }));
}

export function createOutroScene(montageLayer, endLayer) {
  // every device, on the beat
  // the site's screenshots, in the film's language
  const phone = shot(`/site/assets/shots/${LANG}/iphone-inbox.jpg`, 'phone');
  const mac = shot(`/site/assets/shots/${LANG}/mac-workspace.jpg`, 'mac');
  const ipad = shot(`/site/assets/shots/${LANG}/ipad-workspace.jpg`, 'ipad');
  const stage = h('div', { class: 'm-stage' }, mac, ipad, phone);
  // the tunnel: your box ⇄ your devices, the encryption end to end
  const dots = Array.from({ length: 9 }, () => h('i', { class: 't-dot' }));
  const tunnel = h('div', { class: 'm-tunnel' },
    h('div', { class: 't-node' }, h('div', { class: 't-icon' }, sym('server.rack', 46, '#E6E8EB')), h('span', {}, say('Your box', 'Sua box'))),
    h('div', { class: 't-line' }, ...dots, h('div', { class: 't-lock' }, sym('lock.fill', 18, '#4FC2BB'), h('span', {}, say('Mutual TLS', 'TLS mútuo')))),
    h('div', { class: 't-node' }, h('div', { class: 't-icon' }, sym('iphone', 40, '#E6E8EB'), sym('laptopcomputer', 44, '#E6E8EB')), h('span', {}, say('Your devices', 'Seus aparelhos'))));
  montageLayer.append(stage, tunnel);

  // the end: the night harbour, the name
  const heroStage = h('div', { class: 'end-stage', 'data-hero-stage': '', 'data-manual': '' });
  if (V) heroStage.style.setProperty('--band', '1180px');   // the site's phone layout: the words on top, the harbour under them
  endLayer.append(heroStage);
  const hero = startHero(heroStage, { manual: true, asks: false, portrait: V });
  const icon = h('img', { class: 'end-icon', src: '/site/assets/icon.png' });
  const word = h('div', { class: 'end-word' }, icon, h('span', {}, 'Pier'));
  const tag = h('div', { class: 'end-tag' }, say('Your coding agents,', 'Seus agentes de código,'), h('br'), h('em', {}, say('in your pocket.', 'no seu bolso.')));
  const details = h('div', { class: 'end-details' }, h('span', { class: 'dots' }, h('i'), h('i'), h('i')),
    say('Open source · iPhone, iPad & Mac · Claude Code & Codex', 'Código aberto · iPhone, iPad e Mac · Claude Code e Codex'));
  const url = h('div', { class: 'end-url' }, 'docktopier.com');
  const veil = h('div', { class: 'end-veil' });
  const copy = h('div', { class: 'end-copy' }, word, tag, details, url);
  endLayer.append(veil, copy);
  let hopped = false;

  return function update(t) {
    // ── montage
    const mOn = t >= T.every1 - 0.4 && t < T.endIn + 0.4;
    css(montageLayer, { display: mOn ? 'block' : 'none' });
    if (mOn) {
      const enter = (at, i) => spring(t - at, 0.62, 0.8);
      const out = ease.inCubic(prog(t, T.secure - 0.12, T.secure + 0.22));
      const place = V ? [
        { el: phone, at: T.every1, x: 360, y: 1330, s: 1, ry: -14 },
        { el: mac, at: T.every2, x: 560, y: 820, s: 1, ry: -10 },
        { el: ipad, at: T.every3, x: 700, y: 1230, s: 1, ry: -16 },
      ] : [
        { el: phone, at: T.every1, x: 1270, y: 560, s: 1, ry: -16 },
        { el: mac, at: T.every2, x: 1300, y: 470, s: 1, ry: -14 },
        { el: ipad, at: T.every3, x: 1530, y: 600, s: 1, ry: -18 },
      ];
      for (const p of place) {
        const k = enter(p.at);
        const settle = ease.inOutCubic(prog(t, T.every3 + BEAT, T.secure));
        css(p.el, {
          opacity: clamp(k * 2) * (1 - out),
          transform: `translate(${lerp(p.x + 520, p.x, k) - settle * 40}px, ${p.y}px) translate(-50%, -50%) perspective(1600px) rotateY(${lerp(p.ry - 28, p.ry, k) + settle * 6}deg) scale(${(lerp(0.86, 1, k) * (1 - out * 0.08)).toFixed(4)})`,
          filter: out > 0.01 ? `blur(${(out * 12).toFixed(2)}px)` : 'none',
        });
      }
      const tk = spring(t - T.secure - 0.1, 0.7, 0.85);
      const tOut = ease.inCubic(prog(t, T.endIn - 0.62, T.endIn - 0.25));
      const tunnelScale = V ? [0.92, 1.0] : [1.3, 1.45];
      css(tunnel, { opacity: clamp(tk * 1.6) * (1 - tOut), transform: `translate(${FORMAT.w / 2}px, ${V ? 1000 : 545}px) translate(-50%, -50%) scale(${(lerp(tunnelScale[0], tunnelScale[1], clamp(tk)) * (1 - tOut * 0.06)).toFixed(4)})` });
      dots.forEach((d, i) => {
        const p = ((t - T.secure) * 0.55 + i / dots.length) % 1;
        css(d, { left: `${(p * 100).toFixed(2)}%`, opacity: Math.sin(p * Math.PI) * clamp(tk) });
      });
    }

    // ── the end
    const eOn = t >= T.endIn - 0.6;
    css(endLayer, { display: eOn ? 'block' : 'none', opacity: ease.inOutQuad(prog(t, T.endIn - 0.32, T.endIn + 0.12)) });
    if (!eOn) return;
    const heroT = t - T.endIn + 3.2;
    if (!hopped && t >= T.endIn) { hero.hop(3.2, 1); hopped = true; }
    hero.renderAt(heroT);
    const push = ease.inOutSine(prog(t, T.endIn - 0.5, DURATION));
    css(heroStage, { transform: `scale(${lerp(V ? 1.04 : 1.06, 1.0, push).toFixed(4)})` });
    const show = (el, at, d = 0.7) => {
      const k = ease.outExpo(prog(t, at, at + d));
      css(el, { opacity: k, transform: `translateY(${((1 - k) * 28).toFixed(2)}px)`, filter: k < 0.98 ? `blur(${((1 - k) * 10).toFixed(2)}px)` : 'none' });
    };
    show(word, T.wordmark, 0.9);
    show(tag, T.tagline);
    show(details, T.details);
    show(url, T.url);
    css(veil, { opacity: ease.inOutQuad(prog(t, T.wordmark - 0.2, T.wordmark + 0.6)) });
  };
}
