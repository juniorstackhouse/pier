// Bars 1–9: the agents' indicators alone in the dark, the tab forming around them, the pull back to the whole Mac; an
// agent needs you, the tab grows, the Inbox opens, "1" answers; a hover down the tab; then the Mac steps back.
import { css, attr } from '../dom.js';
import { CUE, at, BEAT } from '../time.js';
import { clamp, lerp, ease, prog, spring, springTrack, cubicPoint, tween, bezier } from '../anim.js';
import { createMac, MAC_W, MAC_H, MENU_H, TAB_CENTER } from '../ui/mac.js';
import { CW, column } from '../ui/edgeTab.js';

const BASE = 1920 / MAC_W;           // display points → frame pixels at zoom 1
const N = 4;

/** Camera keyframes: the display point F shown at frame point S, zoom z. Between two keys, eased. */
function cameraAt(t, keys) {
  let a = keys[0], b = keys[0];
  for (let i = 0; i < keys.length; i++) {
    if (t >= keys[i].t) { a = keys[i]; b = keys[i + 1] || keys[i]; }
  }
  if (a === b || t <= a.t) return { ...a };
  const p = prog(t, a.t, b.t);
  const k = (b.ease || ease.inOutCubic)(p), ks = (b.easeS || b.ease || ease.inOutCubic)(p);
  // zoom eases in log space (a steady feel of distance); the anchor points may ease on their own curve
  const z = Math.exp(lerp(Math.log(a.z), Math.log(b.z), k));
  return { fx: lerp(a.fx, b.fx, ks), fy: lerp(a.fy, b.fy, ks), sx: lerp(a.sx, b.sx, ks), sy: lerp(a.sy, b.sy, ks), z };
}

export function createMacScene(layer) {
  const mac = createMac();
  layer.append(mac.el);
  const tabCenterY = MENU_H + TAB_CENTER * (MAC_H - MENU_H);
  const tabX = MAC_W - 23 / 2;
  const grownTop = mac.tabTop + (mac.tab.canvasH - 0) / 2;   // the canvas is centred on the tab's middle
  const slotY = (slot, o = 1) => {
    const col = column(o, N);
    const H = col.bottom; // not used directly
    return mac.tabTop + (mac.tab.canvasH - tabHeightAt(o)) / 2 + col.slots[slot].center;
  };
  function tabHeightAt(o) {
    // EdgeMetrics.height, as edgeTab computes it
    const c = column(o, N);
    const last = 6 + 7 * o;
    return c.bottom - last + (2 + 3 * o) + Math.sqrt(1.2) * (23 + 7 * o);
  }
  const inboxY = slotY(0);
  // the card's pointer aims at the Inbox button; the card itself stays on the screen (SidePanel's clamp)
  const panelH = mac.panel.el.offsetHeight || 640;
  const panelTop = Math.min(Math.max(inboxY - 55, MENU_H + 8), MAC_H - 10 - panelH);
  css(mac.panel.el, { left: MAC_W - 30 - 6 - 9 - 520, top: panelTop });
  css(mac.panel.el.querySelector('.ip-pointer'), { top: inboxY - panelTop - 9 });

  // the dark around the agents before the pull back
  const night = document.createElement('div');
  night.className = 'mac-night';
  mac.el.insertBefore(night, mac.panel.el);

  const T = CUE;
  const close = { fx: 1215, fy: panelTop + panelH / 2, sx: 1440, sy: 545, z: 1.27 };
  const tabClose = { fx: 1497, fy: tabCenterY, sx: 1830, sy: 540, z: 2.9 };
  const camKeys = [
    { t: 0, fx: tabX, fy: tabCenterY, sx: 960, sy: 540, z: 6.0, ease: ease.linear },
    { t: T.pullBack, fx: tabX, fy: tabCenterY, sx: 960, sy: 540, z: 6.35, ease: ease.linear },
    { t: T.macIn + 0.35, fx: tabX, fy: tabCenterY, sx: tabX * BASE, sy: tabCenterY * BASE, z: 1, ease: ease.cinematic, easeS: ease.outQuint },
    { t: T.pushIn, fx: tabX, fy: tabCenterY, sx: tabX * BASE, sy: tabCenterY * BASE, z: 1.035, ease: ease.cinematic },
    // close on the tab before it calls: the amber dot and the growth fill the frame
    { t: T.needs - 0.12, ...tabClose, ease: ease.inOutSine },
    { t: T.cursorIn, ...tabClose, z: 3.0, ease: ease.cinematic },
    { t: T.inboxHover - 0.1, ...close, ease: ease.linear },
    { t: T.toolNew - BEAT * 0.75, ...close, z: 1.39, ease: ease.cinematic },
    { t: T.toolNew, fx: 1497, fy: tabCenterY, sx: 1874, sy: 540, z: 2.4, ease: ease.linear },
    { t: T.stepBack, fx: 1497, fy: tabCenterY, sx: 1874, sy: 540, z: 2.45, ease: ease.cinematic },
    { t: T.stepBack + 1.5, fx: 756, fy: 425, sx: 960, sy: 540, z: 0.56, ease: bezier(0.25, 0.0, 0.1, 1) },
  ];

  // the pointer's path: from the code to the Inbox, then down the tab, then away
  const P = {
    start: [640, 560], inbox: [MAC_W - 14, inboxY + 2],
    new: [MAC_W - 14, slotY(N + 1) + 2], talk: [MAC_W - 14, slotY(N + 2) + 2], point: [MAC_W - 14, slotY(N + 3) + 2], away: [1180, 560],
  };
  function pointerAt(t) {
    const seg = (t0, t1, a, b, c1, c2, fn = ease.inOutCubic) => (t >= t0 && t <= t1 ? cubicPoint(a, c1, c2, b, fn(prog(t, t0, t1))) : null);
    if (t < T.cursorIn) return null;
    return seg(T.cursorIn, T.inboxHover, P.start, P.inbox, [900, 600], [1380, inboxY + 30], ease.outQuart)
      || (t < T.toolNew - 0.3 ? P.inbox : null)
      || seg(T.toolNew - 0.3, T.toolNew, P.inbox, P.new, P.inbox, P.new, ease.inOutCubic)
      || seg(T.toolTalk - 0.22, T.toolTalk, P.new, P.talk, P.new, P.talk, ease.inOutCubic)
      || (t < T.toolTalk - 0.22 ? P.new : null)
      || seg(T.toolPoint - 0.22, T.toolPoint, P.talk, P.point, P.talk, P.point, ease.inOutCubic)
      || (t < T.toolPoint - 0.22 ? P.talk : null)
      || seg(T.cursorOut, T.cursorOut + 0.5, P.point, P.away, [1400, 560], [1260, 560], ease.inOutCubic)
      || (t < T.cursorOut ? P.point : P.away);
  }

  return function update(t) {
    const visible = t < T.stepBack + 2.2;
    css(layer, { display: visible ? 'block' : 'none' });
    if (!visible) return;

    // camera; between the pull back and the step back it never shows past the display's edges
    const cam = cameraAt(t, camKeys);
    const scale = BASE * cam.z;
    if (t > T.macIn + 0.3 && t < T.stepBack + 0.05) {
      const left = cam.sx - cam.fx * scale, top = cam.sy - cam.fy * scale;
      const right = left + MAC_W * scale, bottom = top + MAC_H * scale;
      if (right < 1920) cam.sx += 1920 - right;
      if (left > 0) cam.sx -= left;
      if (bottom < 1080) cam.sy += 1080 - bottom;
      if (top > 0) cam.sy -= top;
    }
    css(mac.el, { transform: `translate(${(cam.sx - cam.fx * scale).toFixed(3)}px, ${(cam.sy - cam.fy * scale).toFixed(3)}px) scale(${scale.toFixed(5)})` });

    // the night before the pull back, lifting as the camera leaves the tab
    const nightK = 1 - ease.inOutQuad(prog(t, T.pullBack + 0.2, T.macIn + 0.2));
    css(night, { opacity: nightK, display: nightK > 0.001 ? 'block' : 'none' });
    // until the pull back ends the display does not clip: past its edge the night (then the wallpaper) goes on
    css(mac.el, { overflow: t < T.macIn + 0.45 ? 'visible' : 'hidden' });

    // the Mac steps back: a rounded screen with a shadow, then away
    const back = ease.inOutCubic(prog(t, T.stepBack + 0.2, T.stepBack + 1.2));
    css(mac.el, { borderRadius: `${(back * 26).toFixed(2)}px`, boxShadow: back > 0 ? `0 ${40 * back}px ${120 * back}px rgba(0,0,0,${0.55 * back})` : 'none' });
    const away = ease.inCubic(prog(t, T.stepBack + 1.45, T.stepBack + 2.15));
    css(layer, { opacity: 1 - away, filter: away > 0.01 ? `blur(${(away * 14).toFixed(2)}px)` : 'none' });

    // depth of field: the code softens while the camera looks at the tab
    const dof = clamp((cam.z - 1.08) / 0.3) * (1 - back);
    css(mac.editor.win, { filter: dof > 0.01 ? `blur(${(dof * 5.5).toFixed(2)}px) brightness(${(1 - dof * 0.18).toFixed(3)})` : 'none' });

    // the caret, typing a little while the agents work
    const blink = Math.floor(t / (BEAT / 1)) % 2 === 0 ? 1 : 0.15;
    css(mac.editor.caret, { opacity: blink, transform: `translate(${(52 + 18 + 7.86 * 27).toFixed(1)}px, ${(14 + 17 * 23 + 2).toFixed(1)}px)` });

    // the agents: one needs you from the moment the tab grows until "Sent"
    const needs = t >= T.needs && t < T.sent;
    const states = ['working', needs ? 'needsYou' : 'working', 'done', 'working'];
    // intro: the indicators appear one by one on the eighth notes
    const indScale = [0, 1, 2, 3].map((i) => (i === 0 ? ease.outBack(prog(t, T.ringIn, T.ringIn + 0.5)) : ease.outBack(prog(t, T.rings + (i - 1) * BEAT / 2, T.rings + (i - 1) * BEAT / 2 + 0.45))));
    const shapeK = ease.inOutCubic(prog(t, T.tabForms, T.tabForms + BEAT * 1.1));

    // openness: grows by itself when an agent needs you (pinned), folds 0.4 s after the pointer left
    const o = springTrack(t, 0, [[T.needs, 1], [T.tabFolds, 0]], 0.26, 1);

    // hover: the Inbox, then the tools down the tab
    let hover = -1, hoverAmt = 0, labelText = '', labelSlot = 0, labelOpacity = 0;
    const tools = [[T.toolNew, N + 1, 'New task'], [T.toolTalk, N + 2, 'Talk'], [T.toolPoint, N + 3, 'Point']];
    if (t >= T.inboxHover - 0.08 && t < T.toolNew - 0.3) {
      hover = 0; hoverAmt = ease.outCubic(prog(t, T.inboxHover - 0.08, T.inboxHover + 0.12));
      labelText = 'Inbox'; labelSlot = 0;
      labelOpacity = ease.outCubic(prog(t, T.inboxHover, T.inboxHover + 0.16)) * (1 - prog(t, T.inboxClick + 0.05, T.inboxClick + 0.2));
    }
    for (const [tt, slot, name] of tools) {
      if (t >= tt - 0.1 && t < tt + BEAT - 0.12) {
        hover = slot; hoverAmt = ease.outCubic(prog(t, tt - 0.1, tt + 0.06));
        labelText = name; labelSlot = slot; labelOpacity = ease.outCubic(prog(t, tt - 0.04, tt + 0.12)) * (1 - prog(t, tt + BEAT - 0.24, tt + BEAT - 0.12));
      }
    }
    if (t >= T.toolPoint + BEAT - 0.12 && t < T.cursorOut + 0.1) { hover = N + 3; hoverAmt = 1 - prog(t, T.cursorOut, T.cursorOut + 0.1); }
    const press = t >= T.inboxClick && t < T.inboxClick + 0.18 ? Math.sin(prog(t, T.inboxClick, T.inboxClick + 0.18) * Math.PI) : 0;

    const badgeCount = t >= T.needs && t < T.sent ? 1 : 0;
    const badgeScale = 0.4 + 0.6 * spring(t - T.needs - 0.12, 0.38, 0.55);
    const spin = (t * 240) % 360;
    mac.tab.update({ o, states, spin, hover, hoverAmt, press, badgeCount, badgeScale, labelText, labelSlot, labelOpacity, indScale, shapeK,
      rim: shapeK * nightK, halo: nightK });

    // the Inbox card
    const open = springTrack(t, 0, [[T.inboxClick + 0.04, 1], [T.panelClose, 0]], 0.42, 0.74);
    css(mac.panel.el, { display: open > 0.002 || (t > T.inboxClick && t < T.panelClose) ? 'block' : 'none' });
    const keyPress = t >= T.press1 && t < T.press1 + 0.16 ? Math.sin(prog(t, T.press1, T.press1 + 0.16) * Math.PI) : 0;
    mac.panel.update({
      open: clamp(open, 0, 1.2),
      chosen: ease.outCubic(prog(t, T.press1 + 0.04, T.press1 + 0.24)),
      sendK: t >= T.press1 + 0.1 ? prog(t, T.press1 + 0.1, T.sent) : -1,
      sentK: prog(t, T.sent, T.sent + 0.3),
      keyPress,
    });

    // the pointer
    const p = pointerAt(t);
    if (p) {
      const pressK = Math.max(press, 0);
      css(mac.cursor, { display: 'block', opacity: clamp(prog(t, T.cursorIn, T.cursorIn + 0.15)) * (1 - prog(t, T.cursorOut + 0.4, T.cursorOut + 0.55)),
        transform: `translate(${(p[0] - 3).toFixed(2)}px, ${(p[1] - 2).toFixed(2)}px) scale(${(1 - 0.12 * pressK).toFixed(3)})` });
    } else css(mac.cursor, { display: 'none' });
  };
}
