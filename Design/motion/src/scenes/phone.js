// Bars 10–18: the iPhone rises; the Live Activity in the Dynamic Island (compact, a long press opens it); a question
// drops out of the island as a notification, a long press shows its answers, one tap sends one; then the Lock Screen,
// where the card asks for a permission: Allow → Working → Your turn.
import { css, text } from '../dom.js';
import { CUE, BEAT } from '../time.js';
import { clamp, lerp, ease, prog, spring, springTrack } from '../anim.js';
import { createPhone, SW, SH, ISLAND } from '../ui/iphone.js';
import { FORMAT } from '../format.js';

const V = FORMAT.vertical;
const BASE = (V ? 1250 : 1000) / 892;      // the device's height at zoom 1 (vertical: the lower two thirds, the words above)
const T = CUE;

function camAt(t, keys) {
  let a = keys[0], b = keys[0];
  for (let i = 0; i < keys.length; i++) if (t >= keys[i].t) { a = keys[i]; b = keys[i + 1] || keys[i]; }
  if (a === b || t <= a.t) return { ...a };
  const k = (b.ease || ease.inOutCubic)(prog(t, a.t, b.t));
  return { fx: lerp(a.fx, b.fx, k), fy: lerp(a.fy, b.fy, k), sx: lerp(a.sx, b.sx, k), sy: lerp(a.sy, b.sy, k), z: Math.exp(lerp(Math.log(a.z), Math.log(b.z), k)) };
}

const mmss = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

export function createPhoneScene(layer) {
  const ph = createPhone();
  layer.append(ph.el);
  const isl = ph.island, card = ph.card;
  const bannerH = () => ph.banner.offsetHeight || 88;
  let menuTop = 0;

  const full = V ? { fx: SW / 2, fy: SH / 2, sx: 540, sy: 1240, z: 1 } : { fx: SW / 2, fy: SH / 2, sx: 1250, sy: 540, z: 1 };
  const islandClose = V ? { fx: SW / 2, fy: 95, sx: 540, sy: 800, z: 1.9 } : { fx: SW / 2, fy: 120, sx: 1210, sy: 390, z: 2.05 };
  const bannerClose = V ? { fx: SW / 2, fy: 230, sx: 540, sy: 1020, z: 1.72 } : { fx: SW / 2, fy: 225, sx: 1215, sy: 455, z: 1.72 };
  const cardClose = V ? { fx: SW / 2, fy: SH / 2, sx: 540, sy: 1169, z: 1.2 } : { fx: SW / 2, fy: 585, sx: 1215, sy: 560, z: 1.62 };
  const keys = [
    { t: 0, ...full },
    { t: T.islandPress - BEAT, ...full, z: 1.04, ease: ease.inOutSine },
    { t: T.islandOpen, ...islandClose, ease: ease.cinematic },
    { t: T.ask - BEAT * 0.5, ...islandClose, z: 2.0, ease: ease.inOutSine },
    { t: T.bannerPress, ...bannerClose, ease: ease.cinematic },
    { t: T.answered + BEAT, ...bannerClose, z: 1.76, ease: ease.inOutSine },
    { t: T.lockCard + 0.2, ...full, z: 1.06, ease: ease.cinematic },
    { t: T.lockCard + BEAT * 1.4, ...cardClose, ease: ease.cinematic },
    { t: T.phoneOut, ...cardClose, z: V ? 1.23 : 1.68, ease: ease.inOutSine },
    { t: T.phoneOut + 0.9, ...full, z: 0.82, sy: V ? 1240 : 560, ease: ease.cinematic },
  ];

  // the island's three shapes
  const compactW = 198;
  const shapes = {
    pill: { w: ISLAND.w, h: ISLAND.h, top: ISLAND.top, r: ISLAND.h / 2 },
    compact: { w: compactW, h: ISLAND.h, top: ISLAND.top, r: ISLAND.h / 2 },
    expanded: { w: 380, h: 150, top: 11, r: 46 },
  };

  return function update(t) {
    const live = t >= T.phoneUp - 0.1 && t < T.phoneOut + 1.4;
    css(layer, { display: live ? 'block' : 'none' });
    if (!live) return;

    // entrance: from below, tilted back, settling with a spring; exit: falling back and away
    const rise = spring(t - T.phoneUp, 0.85, 0.82);
    const fall = ease.inCubic(prog(t, T.phoneOut + 0.35, T.phoneOut + 1.15));
    const cam = camAt(t, keys);
    const s = BASE * cam.z;
    const x = cam.sx - (cam.fx + 9) * s, y = cam.sy - (cam.fy + 9) * s + (1 - rise) * 1100 + fall * 900;
    css(layer, { perspective: '2400px' });
    const tilt = (1 - rise) * 28 - fall * 18;
    css(ph.el, { opacity: 1 - fall, transform: `translate(${x.toFixed(2)}px, ${y.toFixed(2)}px) scale(${s.toFixed(5)}) rotateX(${tilt.toFixed(2)}deg)` });
    css(ph.sheen, { backgroundPosition: `${(-200 + rise * 160 + t * 6).toFixed(1)}px 0` });

    // which screen: home until the lock, then the Lock Screen
    const toLock = prog(t, T.lockCard - 0.22, T.lockCard + 0.12);
    const dimBlink = t >= T.lockCard - 0.22 && t < T.lockCard + 0.12 ? Math.sin(toLock * Math.PI) : 0;
    css(ph.home, { opacity: 1 - ease.inOutQuad(toLock), filter: dimBlink > 0.01 ? `brightness(${(1 - dimBlink * 0.7).toFixed(3)})` : 'none' });
    css(ph.lock, { opacity: ease.inOutQuad(toLock) });

    // the island: compact → (long press) expanded → compact; on the Lock Screen it gives way to the card
    const openK = springTrack(t, 0, [[T.islandOpen, 1], [T.islandClose, 0]], 0.5, 0.74);
    const appear = spring(t - T.phoneIn + 0.6, 0.55, 0.7);         // the pill widening into the compact activity
    const bump = t >= T.ask && t < T.ask + 0.6 ? Math.sin(prog(t, T.ask, T.ask + 0.6) * Math.PI) * Math.exp(-prog(t, T.ask, T.ask + 0.6) * 2) : 0;
    const lockHide = ease.inOutQuad(prog(t, T.lockCard - 0.2, T.lockCard + 0.05));
    const base = {
      w: lerp(shapes.pill.w, shapes.compact.w, appear), h: shapes.pill.h, top: shapes.pill.top, r: shapes.pill.r,
    };
    const ex = shapes.expanded;
    const o = clamp(openK, -0.2, 1.2);
    const w = lerp(base.w, ex.w, o) + bump * 26 * (1 - lockHide), hgt = lerp(base.h, ex.h, o) + bump * 6, r = lerp(base.r, ex.r, clamp(o));
    const iw = lerp(w, shapes.pill.w, lockHide);
    css(isl.shape, { width: iw, height: hgt, borderRadius: `${r.toFixed(2)}px`, transform: `translate(${(SW / 2 - iw / 2).toFixed(2)}px, ${ex.top}px)` });
    const compactAlpha = clamp(1 - o * 3.2) * clamp(appear * 1.3 - 0.2) * (1 - lockHide);
    const expandedAlpha = clamp((o - 0.45) * 2.4);
    css(isl.compact, { opacity: compactAlpha, filter: compactAlpha < 0.99 ? `blur(${((1 - compactAlpha) * 4).toFixed(2)}px)` : 'none' });
    css(isl.expanded, { opacity: expandedAlpha, transform: `scale(${lerp(0.94, 1, expandedAlpha).toFixed(4)})`, filter: expandedAlpha < 0.99 ? `blur(${((1 - expandedAlpha) * 6).toFixed(2)}px)` : 'none' });

    // the clock in the island: an agent working for 12 minutes, a question waiting
    const asking = t >= T.ask && t < T.answered + 0.1;
    const elapsed = 761 + (t - T.phoneIn);
    text(isl.timer, mmss(elapsed));
    text(isl.xTimer, mmss(elapsed));
    const askK = t < T.ask ? 0 : asking ? ease.outCubic(prog(t, T.ask, T.ask + 0.25)) : 1 - ease.outCubic(prog(t, T.answered + 0.1, T.answered + 0.35));
    css(isl.timer, { opacity: 1 - askK, transform: `translateY(${(askK * -8).toFixed(2)}px)` });
    css(isl.ask, { opacity: askK, transform: `translateY(${((1 - askK) * 8).toFixed(2)}px)` });

    // the notification drops out of the island, then folds back into it after the answer
    const drop = spring(t - T.ask - 0.1, 0.55, 0.76);
    const back = ease.inCubic(prog(t, T.answered, T.answered + 0.32));
    const banY = lerp(ISLAND.top, 60, drop) - back * 50;
    const banScale = lerp(0.36, 1, clamp(drop)) * lerp(1, 0.4, back);
    const pressK = t >= T.bannerPress && t < T.choose ? ease.outCubic(prog(t, T.bannerPress, T.bannerPress + 0.35)) : 0;
    css(ph.banner, {
      display: t >= T.ask + 0.08 && t < T.answered + 0.35 ? 'flex' : 'none',
      transform: `translate(0, ${banY.toFixed(2)}px) scale(${(banScale * (1 + pressK * 0.03)).toFixed(4)})`,
      opacity: clamp(drop * 2.5) * (1 - back), filter: drop < 0.6 || back > 0 ? `blur(${((1 - clamp(drop / 0.6)) * 8 + back * 8).toFixed(2)}px)` : 'none',
    });

    // a long press: the screen blurs, the answers appear under the notification
    menuTop = 60 + bannerH() * (1 + pressK * 0.03) + 12;
    const menuK = spring(t - T.menuOpen, 0.42, 0.78);
    const menuOut = ease.inCubic(prog(t, T.answered, T.answered + 0.25));
    const menuOn = t >= T.menuOpen && t < T.answered + 0.3;
    css(ph.blur, { opacity: (menuOn ? clamp(menuK * 1.4) : 0) * (1 - menuOut) });
    css(ph.menu.el, {
      display: menuOn ? 'block' : 'none', opacity: clamp(menuK * 1.5) * (1 - menuOut),
      transform: `translate(0, ${menuTop.toFixed(1)}px) scale(${(lerp(0.6, 1, menuK) * lerp(1, 0.9, menuOut)).toFixed(4)})`,
    });
    ph.menu.rows.forEach((row, i) => {
      const k = ease.outCubic(prog(t, T.menuOpen + 0.05 + i * BEAT / 4, T.menuOpen + 0.3 + i * BEAT / 4));
      const chosen = i === 0 && t >= T.choose && t < T.answered + 0.3 ? 1 : 0;
      css(row, { opacity: k, transform: `translateY(${((1 - k) * 8).toFixed(2)}px)`, background: chosen ? 'rgba(0,0,0,0.10)' : 'transparent' });
    });

    // the Lock Screen's card: Needs you (Allow / Deny) → Working → Your turn
    const cardIn = spring(t - T.lockCard - 0.05, 0.6, 0.78);
    const cardY = 600 + (1 - cardIn) * 40;
    css(card.el, { display: t >= T.lockCard - 0.05 ? 'block' : 'none', opacity: clamp(cardIn * 1.6), transform: `translate(0, ${cardY.toFixed(2)}px) scale(${lerp(0.94, 1, clamp(cardIn)).toFixed(4)})` });
    const phase = t < T.working ? 'needs' : t < T.yourTurn ? 'working' : 'done';
    const color = phase === 'needs' ? '#F5A35C' : phase === 'working' ? '#4A99FA' : '#4CC38A';
    text(card.badgeText, phase === 'needs' ? 'Needs you' : phase === 'working' ? 'Working' : 'Your turn');
    css(card.badge, { color, background: `color-mix(in srgb, ${color} 16%, transparent)` });
    for (const [k, icon] of Object.entries(card.badgeIcon)) css(icon, { display: k === phase ? 'inline-block' : 'none' });
    const phaseStart = phase === 'needs' ? T.lockCard - 8 : phase === 'working' ? T.working : T.yourTurn;
    text(card.timer, mmss(Math.max(0, t - phaseStart)));
    css(card.timer, { color, opacity: phase === 'done' ? 0 : 1 });
    if (phase === 'needs') { text(card.detail, 'Bash  npm install stripe'); card.detail.className = 'lc-detail mono'; }
    else if (phase === 'working') { text(card.detail, 'Running npm install stripe…'); card.detail.className = 'lc-detail'; css(card.detail, { color: '#8B9199' }); }
    else { text(card.detail, 'Added Stripe checkout to the pricing page. The tests pass.'); card.detail.className = 'lc-detail'; css(card.detail, { color: '#E6E8EB', fontSize: '13.5px' }); }
    const swap = (at) => (t >= at && t < at + 0.3 ? 1 - Math.sin(prog(t, at, at + 0.3) * Math.PI) * 0.75 : 1);
    css(card.detail, { opacity: Math.min(swap(T.working), swap(T.yourTurn)) });
    const btnK = 1 - ease.inOutCubic(prog(t, T.working, T.working + 0.32));
    const allowPress = t >= T.allowTap && t < T.allowTap + 0.22 ? Math.sin(prog(t, T.allowTap, T.allowTap + 0.22) * Math.PI) : 0;
    css(card.buttons, { opacity: btnK, height: `${(48 * btnK).toFixed(2)}px`, marginTop: `${(10 * btnK).toFixed(2)}px`, overflow: 'hidden' });
    css(card.allow, { transform: `scale(${(1 - allowPress * 0.06).toFixed(4)})`, filter: allowPress > 0 ? `brightness(${(1 + allowPress * 0.15).toFixed(3)})` : 'none' });
    const doneK = ease.outCubic(prog(t, T.yourTurn + 0.12, T.yourTurn + 0.5));
    css(card.doneRow, { opacity: doneK, height: `${(34 * doneK).toFixed(2)}px`, marginTop: `${(10 * doneK).toFixed(2)}px`, transform: `translateY(${((1 - doneK) * 6).toFixed(2)}px)`, overflow: 'hidden' });

    // the finger: a long press on the island and on the notification, taps on an answer and on Allow
    const touches = [
      { at: T.islandPress, x: SW / 2, y: ISLAND.top + ISLAND.h / 2, hold: T.islandOpen - T.islandPress + 0.08 },
      { at: T.bannerPress, x: SW / 2 + 40, y: 60 + 48, hold: T.menuOpen - T.bannerPress + 0.08 },
      { at: T.choose - 0.04, x: 150, y: menuTop + 25, hold: 0.12 },
      { at: T.allowTap - 0.04, x: 300, y: 600 + 109, hold: 0.12 },
    ];
    let shown = false;
    for (const tc of touches) {
      if (t >= tc.at - 0.12 && t < tc.at + tc.hold + 0.25) {
        const inK = ease.outCubic(prog(t, tc.at - 0.12, tc.at));
        const outK = ease.inCubic(prog(t, tc.at + tc.hold, tc.at + tc.hold + 0.25));
        const holdK = prog(t, tc.at, tc.at + tc.hold);
        css(ph.touch, { opacity: inK * (1 - outK), transform: `translate(${tc.x}px, ${tc.y}px) scale(${(lerp(1.3, 1, inK) * lerp(1, 0.86, Math.min(holdK * 3, 1)) * lerp(1, 1.25, outK)).toFixed(4)})` });
        css(ph.touch.firstChild, { opacity: tc.hold > 0.2 ? Math.sin(holdK * Math.PI) * 0.9 : 0, transform: `scale(${lerp(0.7, 1.25, holdK).toFixed(3)})` });
        shown = true;
      }
    }
    if (!shown) css(ph.touch, { opacity: 0 });
  };
}
