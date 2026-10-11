// The Mac's edge tab, drawn as the app draws it (PierKit's EdgeOutline / EdgeMetrics, SurfaceStyle's IndicatorDrawing):
// a black drop hanging from the screen's right edge, one indicator per agent, growing in place into its buttons.
// Units are points; the element is `CW` wide, its right side on the screen edge.
import { h, s, css, attr, sym, text } from '../dom.js';
import { clamp, lerp } from '../anim.js';

// EdgeMetrics.metrics(.medium)
const M = { tabWidth: 23, expandedWidth: 30, indicator: 12, indicatorGap: 5, inboxButton: 28, button: 26, buttonGap: 3, glyph: 14,
  padding: 2, grownPadding: 5, sectionGap: 7 };
export const CW = 220;          // the element: the grown tab and its labels beside it
const STATE = { needsYou: '#F5A35C', working: '#4A99FA', done: '#4CC38A', idle: '#7A818B' };

const bodyWidth = (o) => M.tabWidth + (M.expandedWidth - M.tabWidth) * o;
const flareLength = (w) => Math.sqrt(1.2) * w;
const padding = (o) => M.padding + (M.grownPadding - M.padding) * o;

/** EdgeMetrics.column: the slots' centers (Inbox, the indicators, +, Talk, Point, More) for openness `o`. */
export function column(o, n) {
  const slots = [{ size: M.inboxButton * o, gap: 0 }];
  for (let i = 0; i < n; i++) slots.push({ size: M.indicator, gap: i === 0 ? M.sectionGap * o : M.indicatorGap });
  slots.push({ size: M.button * o, gap: M.sectionGap * o });
  slots.push({ size: M.button * o, gap: M.buttonGap * o });
  slots.push({ size: M.button * o, gap: M.buttonGap * o });
  slots.push({ size: M.button * o, gap: M.sectionGap * o });
  const first = M.indicator / 2 + (M.inboxButton / 2 - M.indicator / 2) * o;
  let y = flareLength(bodyWidth(o)) + padding(o) - first;
  const out = [];
  for (const sl of slots) { y += sl.gap; out.push({ top: y, size: sl.size, center: y + sl.size / 2, gap: sl.gap }); y += sl.size; }
  return { slots: out, bottom: y };
}

/** EdgeMetrics.height */
export function tabHeight(o, n) {
  const last = M.indicator / 2 + (M.button / 2 - M.indicator / 2) * o;
  return column(o, n).bottom - last + padding(o) + flareLength(bodyWidth(o));
}

/** EdgeOutline: tip on the edge, the concave flare into the round end, down the face, mirrored at the bottom. */
function outline(w, H) {
  const r1 = 0.6 * w, r2 = 0.5 * w, L = flareLength(w);
  const a = Math.atan2(L, w - r2 - r1);
  const xi = r1 + r1 * Math.cos(a), yi = r1 * Math.sin(a);
  const f = (n) => n.toFixed(3);
  return `M0,0 A${f(r1)},${f(r1)} 0 0 0 ${f(xi)},${f(yi)} A${f(r2)},${f(r2)} 0 0 1 ${f(w)},${f(L)} L${f(w)},${f(H - L)} ` +
    `A${f(r2)},${f(r2)} 0 0 1 ${f(xi)},${f(H - yi)} A${f(r1)},${f(r1)} 0 0 0 0,${f(H)} Z`;
}

const TOOLS = [
  { name: 'tray.fill', size: 15, title: 'Inbox' },
  { name: 'plus', size: 15, title: 'New task' },
  { name: 'bubble.left.and.text.bubble.right.fill', size: 13, title: 'Talk' },
  { name: 'camera.fill', size: 14, title: 'Point' },
  { name: 'ellipsis', size: 12, title: 'More' },
];

export function createEdgeTab(n) {
  const canvasH = Math.ceil(tabHeight(1, n));
  const root = h('div', { class: 'edge-tab', style: { position: 'absolute', width: `${CW}px`, height: `${canvasH}px` } });
  const svg = s('svg', { width: CW, height: canvasH, viewBox: `0 0 ${CW} ${canvasH}`, style: 'position:absolute;inset:0;overflow:visible' });
  const defs = s('defs');
  const haloGrads = Object.entries(STATE).map(([k, c]) => s('radialGradient', { id: 'halo-' + k },
    s('stop', { offset: '0%', 'stop-color': c, 'stop-opacity': '0.55' }), s('stop', { offset: '100%', 'stop-color': c, 'stop-opacity': '0' })));
  defs.append(...haloGrads);
  const glowGrad = s('radialGradient', { id: 'tabGlow' },
    s('stop', { offset: '0%', 'stop-color': '#fff', 'stop-opacity': '1' }), s('stop', { offset: '100%', 'stop-color': '#fff', 'stop-opacity': '0' }));
  defs.append(glowGrad);
  svg.append(defs);
  const shapeG = s('g');
  const shape = s('path', { fill: '#000', stroke: 'rgba(255,255,255,0.0)', 'stroke-width': '0.6' });
  shapeG.append(shape);
  const glow = s('circle', { fill: 'url(#tabGlow)', opacity: '0' });
  const hairlines = [0, 1, 2].map(() => s('line', { stroke: 'rgba(255,255,255,0.16)', 'stroke-width': '1', 'stroke-linecap': 'round' }));
  const indicators = Array.from({ length: n }, () => ({
    halo: s('circle', { opacity: '0' }),
    g: s('g'),
    ring: s('circle', { fill: 'none', 'stroke-linecap': 'round' }),
    dot: s('circle', {}),
  }));
  indicators.forEach((i) => i.g.append(i.ring, i.dot));
  svg.append(shapeG, glow, ...hairlines, ...indicators.flatMap((i) => [i.halo, i.g]));
  root.append(svg);

  const glyphs = TOOLS.map((t) => {
    const g = sym(t.name, t.size, 'rgba(255,255,255,0.92)', { position: 'absolute', left: '0', top: '0' });
    root.append(g);
    return g;
  });
  const badge = h('div', { class: 'tab-badge' });
  root.append(badge);
  const label = h('div', { class: 'tab-label' });
  root.append(label);

  /**
   * o: openness 0…1 · states: per agent · dim: per agent · spin: degrees · hover: slot index or -1 · press: 0…1 ·
   * badge: count · label: { slot, text, opacity }
   */
  function update({ o = 0, states, dim = [], spin = 0, hover = -1, hoverAmt = 0, press = 0, badgeCount = 0, badgeScale = 1, labelText = '', labelSlot = 0, labelOpacity = 0,
    indScale = [], shapeK = 1, rim = 0, halo = 0 }) {
    o = clamp(o);
    const w = bodyWidth(o), H = tabHeight(o, n);
    const top = (canvasH - H) / 2;
    const col = column(o, n);
    attr(shape, 'd', outline(w, H));
    attr(shapeG, 'transform', `translate(${CW},${top.toFixed(3)}) scale(-1,1)`);
    attr(shape, 'opacity', shapeK.toFixed(3));
    attr(shape, 'stroke', `rgba(255,255,255,${(0.22 * rim).toFixed(3)})`);
    const cx = CW - w / 2;   // the face's middle: indicators and glyphs sit on the body's axis

    // indicators (EdgeMetrics: slot 1… after the Inbox)
    indicators.forEach((ind, i) => {
      const slot = col.slots[1 + i];
      const cy = top + slot.center;
      const st = states[i] || 'idle';
      const color = STATE[st];
      const k = indScale[i] ?? 1;
      attr(ind.g, 'transform', `translate(${cx.toFixed(3)} ${cy.toFixed(3)}) scale(${Math.max(k, 0.0001).toFixed(4)}) translate(${(-cx).toFixed(3)} ${(-cy).toFixed(3)})`);
      attr(ind.g, 'opacity', String(clamp(k * 1.5)));
      attr(ind.halo, 'cx', cx.toFixed(3)); attr(ind.halo, 'cy', cy.toFixed(3)); attr(ind.halo, 'r', (M.indicator * 1.5 * Math.max(k, 0)).toFixed(3));
      attr(ind.halo, 'fill', `url(#halo-${st})`); attr(ind.halo, 'opacity', (halo * clamp(k)).toFixed(3));
      if (st === 'working') {
        const r = M.indicator * 0.36, lw = Math.max(1.6, M.indicator * 0.14);
        const circ = 2 * Math.PI * r;
        attr(ind.ring, 'cx', cx.toFixed(3)); attr(ind.ring, 'cy', cy.toFixed(3)); attr(ind.ring, 'r', r.toFixed(3));
        attr(ind.ring, 'stroke', color); attr(ind.ring, 'stroke-width', lw.toFixed(2));
        attr(ind.ring, 'stroke-dasharray', `${(circ * 0.75).toFixed(3)} ${circ.toFixed(3)}`);
        attr(ind.ring, 'transform', `rotate(${(spin - 90).toFixed(2)} ${cx.toFixed(3)} ${cy.toFixed(3)})`);
        attr(ind.ring, 'opacity', '1');
        attr(ind.dot, 'opacity', '0');
      } else {
        const d = st === 'idle' ? M.indicator * 0.44 : M.indicator * 0.62;
        attr(ind.dot, 'cx', cx.toFixed(3)); attr(ind.dot, 'cy', cy.toFixed(3)); attr(ind.dot, 'r', (d / 2).toFixed(3));
        attr(ind.dot, 'fill', color);
        attr(ind.dot, 'opacity', String(dim[i] ? 0.5 : 1));
        attr(ind.ring, 'opacity', '0');
      }
    });

    // the buttons: drawn at their final size, fading in over the first half of the growth
    const glyphAlpha = clamp(o * 2 - 0.15);
    const toolSlots = [0, n + 1, n + 2, n + 3, n + 4];
    glyphs.forEach((g, i) => {
      const slot = col.slots[toolSlots[i]];
      const t = TOOLS[i];
      css(g, { transform: `translate(${(cx - g.symW / 2).toFixed(3)}px, ${(top + slot.center - g.symH / 2).toFixed(3)}px)`, opacity: glyphAlpha });
    });

    // hairlines between the sections, in the middle of their gaps
    const gapsAt = [1, n + 1, n + 4];
    hairlines.forEach((l, i) => {
      const slot = col.slots[gapsAt[i]];
      const y = top + slot.top - slot.gap / 2;
      attr(l, 'x1', (CW - w + 7).toFixed(3)); attr(l, 'x2', (CW - 7).toFixed(3));
      attr(l, 'y1', y.toFixed(3)); attr(l, 'y2', y.toFixed(3));
      attr(l, 'opacity', String(clamp(o * 1.4 - 0.4)));
    });

    // the soft light behind the item under the pointer
    if (hover >= 0 && hoverAmt > 0) {
      const slot = col.slots[hover];
      attr(glow, 'cx', cx.toFixed(3)); attr(glow, 'cy', (top + slot.center).toFixed(3));
      attr(glow, 'r', (Math.max(slot.size, 14) * 0.62).toFixed(3));
      attr(glow, 'opacity', String((0.22 + 0.12 * press) * hoverAmt));
    } else attr(glow, 'opacity', '0');

    // the Inbox count, at the glyph's top-trailing corner
    if (badgeCount > 0 && glyphAlpha > 0) {
      const slot = col.slots[0];
      const bw = Math.max(12, String(badgeCount).length * 5 + 6);
      text(badge, String(badgeCount));
      css(badge, {
        opacity: glyphAlpha, width: bw, transform: `translate(${(cx + 15 * 0.4 - bw / 2).toFixed(3)}px, ${(top + slot.center - 15 * 0.6 - 6).toFixed(3)}px) scale(${badgeScale})`,
      });
    } else css(badge, { opacity: 0 });

    // the label beside the item under the pointer
    if (labelOpacity > 0) {
      const slot = col.slots[labelSlot];
      text(label, labelText);
      css(label, { opacity: labelOpacity, transform: `translate(calc(${(CW - w - 8).toFixed(3)}px - 100%), calc(${(top + slot.center).toFixed(3)}px - 50%)) scale(${lerp(0.92, 1, labelOpacity)})` });
    } else css(label, { opacity: 0 });

    return { width: w, height: H, top, cx, col };
  }

  return { el: root, update, canvasH, slotOf: { inbox: 0, indicator: (i) => 1 + i, new: n + 1, talk: n + 2, point: n + 3, more: n + 4 } };
}
