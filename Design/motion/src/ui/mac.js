// The Mac: a 1512 × 850 pt display (a 14" MacBook Pro's width) with its wallpaper, the menu bar, a code editor, the
// pointer, the edge tab at the right edge and the Inbox card beside it.
import { h, s, css, sym } from '../dom.js';
import { createEdgeTab, CW } from './edgeTab.js';
import { createInboxPanel, PANEL_W } from './inboxPanel.js';

export const MAC_W = 1512, MAC_H = 850, MENU_H = 25;
export const TAB_CENTER = 0.36;            // the tab's centre, as a share of the area under the menu bar

const CODE = [
  [['k', 'import'], ['p', ' { money } '], ['k', 'from'], ['s', ' "./lib/format"']],
  [['k', 'import'], ['p', ' { checkout } '], ['k', 'from'], ['s', ' "./lib/stripe"']],
  [],
  [['k', 'type'], ['t', ' Plan'], ['p', ' = { name: '], ['t', 'string'], ['p', '; monthly: '], ['t', 'number'], ['p', ' }']],
  [],
  [['c', '// Renders the totals of an invoice.']],
  [['k', 'export function'], ['f', ' totals'], ['p', '(lines: '], ['t', 'Line'], ['p', '[]): '], ['t', 'string'], ['p', ' {']],
  [['p', '  '], ['k', 'const'], ['p', ' sum = lines.'], ['f', 'reduce'], ['p', '((acc, l) => acc + l.amount, '], ['n', '0'], ['p', ')']],
  [['p', '  '], ['k', 'return'], ['s', ' `Total: ${'], ['f', 'money'], ['s', '(sum)}`']],
  [['p', '}']],
  [],
  [['k', 'export async function'], ['f', ' subscribe'], ['p', '(plan: '], ['t', 'Plan'], ['p', ') {']],
  [['p', '  '], ['k', 'const'], ['p', ' session = '], ['k', 'await'], ['f', ' checkout'], ['p', '({ plan: plan.name, interval: '], ['s', '"month"'], ['p', ' })']],
  [['p', '  '], ['k', 'return'], ['p', ' session.url']],
  [['p', '}']],
  [],
  [['k', 'export function'], ['f', ' annual'], ['p', '(plan: '], ['t', 'Plan'], ['p', ') {']],
  [['p', '  '], ['k', 'return'], ['p', ' plan.monthly * '], ['n', '10']],
  [['p', '}']],
];

function editor() {
  const lines = CODE.map((parts, i) => h('div', { class: 'ed-line' }, h('span', { class: 'ed-num' }, String(i + 1)),
    h('span', { class: 'ed-code' }, ...parts.map(([k, t]) => h('span', { class: 'tk-' + k }, t)))));
  const caret = h('i', { class: 'ed-caret' });
  const win = h('div', { class: 'mac-window editor' },
    h('div', { class: 'win-bar' }, h('span', { class: 'lights' }, h('i'), h('i'), h('i')), h('span', { class: 'win-title' }, 'app.ts — storefront')),
    h('div', { class: 'ed-tabs' }, h('span', { class: 'on' }, 'app.ts'), h('span', {}, 'stripe.ts'), h('span', {}, 'pricing.tsx')),
    h('div', { class: 'ed-body' }, ...lines, caret));
  return { win, caret };
}

function menuBar() {
  const left = h('div', { class: 'mb-left' }, sym('apple.logo', 14, '#fff'), h('b', {}, 'Code'),
    ...['File', 'Edit', 'Selection', 'View', 'Go', 'Run', 'Terminal', 'Window', 'Help'].map((m) => h('span', {}, m)));
  const right = h('div', { class: 'mb-right' }, sym('battery.100percent', 12, '#fff'), sym('wifi', 12, '#fff'), sym('magnifyingglass', 12, '#fff'),
    sym('switch.2', 12, '#fff'), h('span', {}, 'Sun Oct 11'), h('span', {}, '9:41 AM'));
  return h('div', { class: 'menubar' }, left, right);
}

function pointer() {
  // the macOS arrow
  return s('svg', { class: 'pointer', width: '26', height: '34', viewBox: '0 0 26 34' },
    s('path', { d: 'M3 2 L3 26.5 L8.6 21.3 L12.4 30.2 L16.4 28.5 L12.7 19.8 L20.2 19.6 Z', fill: '#000', stroke: '#fff', 'stroke-width': '1.6', 'stroke-linejoin': 'round' }));
}

export function createMac() {
  const ed = editor();
  const tab = createEdgeTab(4);
  const panel = createInboxPanel();
  const cursor = pointer();
  const tabTop = MENU_H + TAB_CENTER * (MAC_H - MENU_H) - tab.canvasH / 2;
  css(tab.el, { left: MAC_W - CW, top: tabTop });
  // the card's pointer aims at the Inbox button (slot 0 of the grown tab)
  const display = h('div', { class: 'mac-display' },
    h('div', { class: 'wallpaper' }), ed.win, menuBar(), panel.el, tab.el, cursor);
  return { el: display, editor: ed, tab, panel, cursor, tabTop };
}

export { PANEL_W };
