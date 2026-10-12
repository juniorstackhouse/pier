// The words on screen: big Bricolage lines that rise in word by word on the beat and drift out.
import { h, css } from './dom.js';
import { clamp, ease, prog, lerp } from './anim.js';

/**
 * spec: { t0, t1, lines: ["text", …] (words between *asterisks* take `accent`), x, y, size, align: 'left'|'center',
 *         accent, stagger, weight }
 */
export function createCaptions(layer, specs) {
  const items = specs.map((sp) => {
    const box = h('div', { class: 'caption', style: { fontSize: `${sp.size || 76}px`, fontWeight: String(sp.weight || 700), textAlign: sp.align || 'left' } });
    const words = [];
    for (const line of sp.lines) {
      const ln = h('div', { class: 'cap-line' });
      let open = false;
      for (const raw of line.split(' ')) {
        // an accent runs from the word that opens it (*) to the word that closes it: "*needs you*," colours both
        const starts = raw.startsWith('*');
        const accent = open || starts;
        open = accent && !raw.slice(starts ? 1 : 0).includes('*');
        const word = raw.replace(/\*/g, '');
        const inner = h('span', { class: 'cap-word-in', style: accent ? { color: sp.accent || 'var(--amber)' } : {} }, word);
        const outer = h('span', { class: 'cap-word' }, inner);
        ln.append(outer, ' ');
        words.push(inner);
      }
      box.append(ln);
    }
    layer.append(box);
    return { sp, box, words };
  });

  return function update(t) {
    for (const { sp, box, words } of items) {
      const outDur = sp.outDur ?? 0.38;
      const live = t >= sp.t0 - 0.05 && t <= sp.t1 + outDur + 0.05;
      if (!live) { css(box, { display: 'none' }); continue; }
      const x = typeof sp.x === 'function' ? sp.x(t) : sp.x, y = typeof sp.y === 'function' ? sp.y(t) : sp.y;
      css(box, { display: 'block', transform: `translate(${x}px, ${y}px) translate(${sp.align === 'center' ? '-50%' : '0'}, -50%)` });
      const stagger = sp.stagger ?? 0.07;
      const out = ease.inCubic(prog(t, sp.t1, sp.t1 + outDur));
      words.forEach((w, i) => {
        const k = ease.outExpo(prog(t, sp.t0 + i * stagger, sp.t0 + i * stagger + 0.62));
        const blur = (1 - k) * 10 + out * 8;
        css(w, {
          opacity: clamp(k * 1.4) * (1 - out),
          transform: `translate(0, ${(lerp(0.62, 0, k) - out * 0.18).toFixed(4)}em)`,
          filter: blur > 0.05 ? `blur(${blur.toFixed(2)}px)` : 'none',
        });
      });
    }
  };
}
