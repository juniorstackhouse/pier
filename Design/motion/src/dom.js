// A few DOM helpers: build elements, set styles only when they change (thousands of frames), and SF Symbols as
// tintable masks.

export function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'class') el.className = v;
    else if (k === 'style') Object.assign(el.style, v);
    else if (k === 'html') el.innerHTML = v;
    else el.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

const NS = 'http://www.w3.org/2000/svg';
export function s(tag, attrs = {}, ...children) {
  const el = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  for (const c of children.flat()) if (c) el.append(c);
  return el;
}

const cache = new WeakMap();
/** Sets style properties, touching the DOM only for the ones that changed. */
export function css(el, props) {
  let prev = cache.get(el);
  if (!prev) { prev = {}; cache.set(el, prev); }
  for (const [k, v] of Object.entries(props)) {
    const val = typeof v === 'number' && !UNITLESS.has(k) ? `${v}px` : String(v);
    if (prev[k] === val) continue;
    prev[k] = val;
    if (k.startsWith('--')) el.style.setProperty(k, val);
    else el.style[k] = val;
  }
}
const UNITLESS = new Set(['opacity', 'zIndex', 'flex', 'fontWeight', 'lineHeight', 'scale']);

export function attr(el, name, value) {
  const key = '__a_' + name;
  if (el[key] === value) return;
  el[key] = value;
  el.setAttribute(name, value);
}

export function text(el, value) {
  if (el.__t === value) return;
  el.__t = value;
  el.textContent = value;
}

/**
 * An SF Symbol (exported by symbols.swift at 96 pt, 2×) sized as the system draws it at `pointSize`, tinted `color`.
 * Its box is the glyph's own (wider or flatter than the point size, as the symbol is).
 */
export function sym(name, pointSize, color = 'currentColor', extra = {}) {
  const [w, h] = SYM_SIZE[name] || [192, 192];
  const el = h_('i', {
    class: 'sym',
    style: {
      width: `${(w / 192) * pointSize}px`, height: `${(h / 192) * pointSize}px`, background: color,
      maskImage: `url(/assets/symbols/${name}.png)`, webkitMaskImage: `url(/assets/symbols/${name}.png)`, ...extra,
    },
  });
  el.symW = (w / 192) * pointSize;
  el.symH = (h / 192) * pointSize;
  return el;
}
const h_ = (...a) => h(...a);
// each exported symbol's pixel size at 96 pt, 2×
export const SYM_SIZE = {};
export function registerSymbols(sizes) { Object.assign(SYM_SIZE, sizes); }

/** `transform` from parts. */
export const tf = ({ x = 0, y = 0, s = 1, sx, sy, r = 0, rx = 0, ry = 0, z = 0, p } = {}) =>
  `${p ? `perspective(${p}px) ` : ''}translate3d(${x}px, ${y}px, ${z}px) rotateX(${rx}deg) rotateY(${ry}deg) rotate(${r}deg) scale(${sx ?? s}, ${sy ?? s})`;
