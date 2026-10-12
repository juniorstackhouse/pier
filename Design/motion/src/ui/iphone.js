// The iPhone (a 402 × 874 pt screen, the 17 Pro's): the Home Screen with Pier's Live Activity in the Dynamic Island
// (compact, expanded), a notification dropping out of the island and its long-press actions, then the Lock Screen
// with the Live Activity's card (Allow / Deny → Working → Your turn). Layouts follow App/Shared/Views/SessionActivityViews.
import { h, css, sym, text } from '../dom.js';
import { clamp, lerp, ease, prog } from '../anim.js';
import { say } from '../lang.js';

export const SW = 402, SH = 874, BEZEL = 9;
export const ISLAND = { w: 126.67, h: 37.33, top: 11 };

const COLORS = { working: '#4A99FA', needs: '#F5A35C', done: '#4CC38A', red: '#E5675F' };

function glyph(size, letter = 'C', color = '#D9855B') {
  return h('div', { class: 'agent-glyph', style: { width: `${size}px`, height: `${size}px`, borderRadius: `${size * 0.3}px`, fontSize: `${size * 0.5}px`, color, background: `color-mix(in srgb, ${color} 16%, transparent)` } }, letter);
}

function statusBar() {
  return h('div', { class: 'ios-status' },
    h('span', { class: 'ios-time' }, '9:41'),
    h('span', { class: 'ios-icons' }, sym('cellularbars', 14, '#fff'), sym('wifi', 14, '#fff'), h('span', { class: 'ios-battery' }, h('i'))));
}

function homeScreen() {
  const apps = [
    ['FaceTime', '#2ECC71', 'iphone'], [say('Calendar', 'Calendário'), '#FFFFFF', null, '11'], [say('Photos', 'Fotos'), '#FFB347', 'sparkles'], [say('Camera', 'Câmera'), '#8E8E93', 'camera.fill'],
    ['Mail', '#3D8BFD', 'tray.fill'], [say('Notes', 'Notas'), '#FFD60A', 'list.number'], [say('Reminders', 'Lembretes'), '#FF6B5E', 'checkmark.circle.fill'], [say('Clock', 'Relógio'), '#1C1C1E', 'bell.fill'],
    [say('Weather', 'Tempo'), '#4FA3F7', 'sparkles'], [say('Maps', 'Mapas'), '#46C46E', 'arrow.up.forward.square'], ['Terminal', '#2B2B30', 'terminal.fill'], ['Pier', null],
    [say('Settings', 'Ajustes'), '#8E8E93', 'switch.2'], [say('Wallet', 'Carteira'), '#1C1C1E', 'server.rack'], [say('Music', 'Música'), '#FF4F6E', 'mic.fill'], ['GitHub', '#24292F', 'arrow.up.circle.fill'],
  ];
  const grid = h('div', { class: 'ios-grid' }, ...apps.map(([name, color, symbol, day]) => h('div', { class: 'ios-app' },
    name === 'Pier'
      ? h('img', { class: 'ios-icon', src: '/site/assets/icon.png' })
      : h('div', { class: 'ios-icon', style: { background: color === '#FFFFFF' ? '#fff' : `linear-gradient(160deg, color-mix(in srgb, ${color} 80%, white), ${color})` } },
          day ? h('div', { class: 'ios-cal' }, h('b', {}, say('SUN', 'DOM')), h('span', {}, day)) : sym(symbol, 30, 'rgba(255,255,255,0.95)')),
    h('span', {}, name))));
  const dock = h('div', { class: 'ios-dock' }, ...[['#2ECC71', 'iphone'], ['#3D8BFD', 'magnifyingglass'], ['#FF9F0A', 'bubble.left.and.text.bubble.right.fill'], ['#8E8E93', 'camera.fill']]
    .map(([c, s_]) => h('div', { class: 'ios-icon', style: { background: `linear-gradient(160deg, color-mix(in srgb, ${c} 80%, white), ${c})` } }, sym(s_, 30, '#fff'))));
  return h('div', { class: 'ios-home' }, grid, h('div', { class: 'ios-pages' }, h('i', { class: 'on' }), h('i')), dock);
}

function lockScreen() {
  return h('div', { class: 'ios-lock' },
    h('div', { class: 'ios-lock-date' }, say('Sunday, October 11', 'domingo, 11 de outubro')),
    h('div', { class: 'ios-lock-time' }, '9:41'),
    h('div', { class: 'ios-lock-btn left' }, sym('flashlight.off.fill', 20, '#fff')),
    h('div', { class: 'ios-lock-btn right' }, sym('camera.fill', 20, '#fff')));
}

/** The Live Activity's island: compact (glyph · timer or ?3), expanded (glyph, title, phase, timer, step). */
function island() {
  const shape = h('div', { class: 'island' });
  const cLead = glyph(22);
  const cTrail = h('div', { class: 'isl-trail' });
  const timer = h('span', { class: 'isl-timer' }, '12:41');
  const ask = h('span', { class: 'isl-ask' }, sym('questionmark.bubble.fill', 15, COLORS.needs), h('b', {}, '3'));
  cTrail.append(timer, ask);
  const compact = h('div', { class: 'isl-compact' }, cLead, cTrail);
  const xTitle = h('div', { class: 'isl-x-title' }, say('Fix webhook retries', 'Corrigir retries do webhook'));
  const xProject = h('div', { class: 'isl-x-project' }, 'billing-api · webhook-retries');
  const xPhase = h('div', { class: 'isl-x-phase' }, say('Working', 'Trabalhando'));
  const xTimer = h('div', { class: 'isl-x-timer' }, '12:43');
  const xStep = h('div', { class: 'isl-x-step' }, say('Running pnpm test…', 'Rodando pnpm test…'));
  const expanded = h('div', { class: 'isl-expanded' },
    h('div', { class: 'isl-x-top' }, glyph(34), h('div', { class: 'isl-x-right' }, xPhase, xTimer)),
    h('div', { class: 'isl-x-center' }, xTitle, xProject),
    h('div', { class: 'isl-x-bottom' }, xStep));
  shape.append(compact, expanded);
  return { shape, compact, expanded, timer, ask, xTimer, xStep };
}

function banner() {
  return h('div', { class: 'ios-banner' },
    h('img', { class: 'ios-banner-icon', src: '/site/assets/icon.png' }),
    h('div', { class: 'ios-banner-text' },
      h('div', { class: 'ios-banner-head' }, h('b', {}, say('Claude needs you', 'Claude precisa de você')), h('span', {}, say('now', 'agora'))),
      h('div', { class: 'ios-banner-body' }, say('Build the pricing page — Which layout for the pricing page? · devbox',
        'Criar a página de preços — Qual layout para a página de preços? · devbox'))));
}

function actionMenu() {
  const items = [['1.circle', say('Three tiers', 'Três planos')], ['2.circle', say('One plan', 'Um plano')], ['3.circle', say('A table', 'Uma tabela')],
    ['arrow.up.forward.square', say('Open', 'Abrir')]];
  const rows = items.map(([s_, label]) => h('div', { class: 'ios-menu-row' }, sym(s_, 22, '#111'), h('span', {}, label)));
  return { el: h('div', { class: 'ios-menu' }, ...rows), rows };
}

/** The Live Activity on the Lock Screen (SessionLockScreenView). */
function lockCard() {
  const badgeIcon = { needs: sym('exclamationmark.bubble.fill', 11, COLORS.needs), working: sym('circle.dotted', 11, COLORS.working), done: sym('checkmark.circle.fill', 11, COLORS.done) };
  const badge = h('div', { class: 'lc-badge' });
  const badgeText = h('span', {});
  badge.append(badgeIcon.needs, badgeIcon.working, badgeIcon.done, badgeText);
  const timer = h('div', { class: 'lc-timer' }, '0:08');
  const detail = h('div', { class: 'lc-detail' });
  const deny = h('div', { class: 'lc-btn deny' }, sym('xmark', 13, COLORS.red), say('Deny', 'Negar'));
  const allow = h('div', { class: 'lc-btn allow' }, sym('checkmark', 13, '#16181B'), say('Allow', 'Permitir'));
  const buttons = h('div', { class: 'lc-buttons' }, deny, allow);
  const diff = h('div', { class: 'lc-diff' }, h('span', { class: 'add' }, '+128'), h('span', { class: 'del' }, '−34'));
  const review = h('div', { class: 'lc-review' }, sym('doc.text.magnifyingglass', 13, '#16181B'), say('Review', 'Revisar'));
  const doneRow = h('div', { class: 'lc-done' }, diff, review);
  const el = h('div', { class: 'lock-card' },
    h('div', { class: 'lc-top' }, glyph(34),
      h('div', { class: 'lc-titles' }, h('div', { class: 'lc-title' }, say('Add Stripe checkout', 'Checkout do Stripe')), h('div', { class: 'lc-project' }, 'storefront · stripe-checkout')),
      h('div', { class: 'lc-right' }, badge, timer)),
    detail, buttons, doneRow);
  return { el, badge, badgeText, badgeIcon, timer, detail, buttons, deny, allow, doneRow };
}

export function createPhone() {
  const isl = island();
  const ban = banner();
  const menu = actionMenu();
  const card = lockCard();
  const touch = h('div', { class: 'touch' }, h('i', { class: 'touch-ring' }));
  const home = homeScreen();
  const lock = lockScreen();
  const blur = h('div', { class: 'ios-blur' });
  const sheen = h('div', { class: 'glass-sheen' });
  const screen = h('div', { class: 'ios-screen' },
    h('div', { class: 'ios-wall' }), home, lock, card.el, blur, ban, menu.el, statusBar(), isl.shape, h('div', { class: 'ios-homebar' }), touch, sheen);
  const device = h('div', { class: 'iphone' }, h('div', { class: 'iphone-frame' }), h('div', { class: 'iphone-btn a' }), h('div', { class: 'iphone-btn b' }),
    h('div', { class: 'iphone-btn c' }), h('div', { class: 'iphone-btn d' }), screen);
  return { el: device, screen, home, lock, island: isl, banner: ban, menu, card, touch, blur, sheen };
}
