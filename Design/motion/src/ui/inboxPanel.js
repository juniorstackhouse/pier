// The Inbox card beside the edge tab (Mac/PierMenuBar: SidePanel, InboxCardPanel, PanelStyle): one question at a time,
// its answers as rows with keycaps; "1" chooses, the row turns green, "Sending… Esc undoes", then "Sent to Claude".
import { h, css, sym, text } from '../dom.js';
import { clamp, lerp, ease, prog } from '../anim.js';
import { say } from '../lang.js';

export const PANEL_W = 520;

function keycap(n, color) {
  return h('span', { class: 'keycap', style: { color } }, String(n));
}

export function createInboxPanel() {
  const opts = [
    { n: 1, title: say('Allow', 'Permitir'), sub: say('Yes', 'Sim'), color: 'var(--green)' },
    { n: 2, title: say('Always allow', 'Permitir sempre'), sub: say('Yes, and don’t ask again for npm install commands in storefront',
      'Sim, e não perguntar de novo para comandos npm install em storefront'), color: 'var(--green)' },
    { n: 3, title: say('Deny', 'Negar'), sub: say('No, and tell Claude what to do differently (esc)', 'Não, e dizer ao Claude o que fazer diferente (esc)'), color: 'var(--red)' },
  ];
  const rows = opts.map((o) => {
    const cap = keycap(o.n, o.color);
    const check = h('span', { class: 'keycap-check' }, sym('checkmark', 11, '#16181B'));
    const row = h('div', { class: 'ip-opt' },
      h('span', { class: 'ip-cap' }, cap, check),
      h('div', {}, h('div', { class: 'ip-opt-title', style: { color: o.color } }, o.title), h('div', { class: 'ip-opt-sub' }, o.sub)));
    return { row, cap, check };
  });
  const status = h('div', { class: 'ip-status' });
  const hint = h('div', { class: 'ip-hint' }, say('Press ', 'Pressione '), h('span', { class: 'keycap small' }, '1'), ' , ', h('span', { class: 'keycap small' }, '2'),
    say(' or ', ' ou '), h('span', { class: 'keycap small' }, '3'), say(' to answer', ' para responder'));
  const sending = h('div', { class: 'ip-sending' },
    h('span', { class: 'ip-spinner' }), h('span', {}, say('Sending… ', 'Enviando… ')), h('span', { class: 'ip-esc' }, h('span', { class: 'keycap small' }, 'esc'), say(' undoes', ' desfaz')),
    h('i', { class: 'ip-bar' }));
  const bar = sending.querySelector('.ip-bar');
  const sent = h('div', { class: 'ip-sent' }, sym('checkmark.circle.fill', 15, 'var(--green)'), h('span', {}, say('Sent to Claude', 'Enviado para Claude')));
  status.append(hint, sending, sent);

  const el = h('div', { class: 'inbox-panel' },
    h('div', { class: 'ip-pointer' }),
    h('div', { class: 'ip-head' }, h('div', { class: 'ip-title' }, 'Inbox'), h('div', { class: 'ip-close' }, sym('xmark', 13, 'rgba(255,255,255,0.75)'))),
    h('div', { class: 'ip-body' },
      h('div', { class: 'ip-item' },
        h('div', { class: 'ip-item-title' }, say('Add Stripe checkout to the pricing page', 'Adicionar o checkout do Stripe à página de preços')),
        h('div', { class: 'ip-pages' }, h('i', { class: 'on' }), h('i'), h('i'), h('i'))),
      h('div', { class: 'ip-agent' },
        h('div', { class: 'ip-avatar' }, 'C', h('i')),
        h('div', {}, h('div', { class: 'ip-agent-name' }, 'Claude Code'), h('div', { class: 'ip-agent-sub' }, say('Needs you', 'Precisa de você') + ' · storefront · stripe-checkout'))),
      h('div', { class: 'ip-q' }, say('Claude wants to run', 'Claude quer executar')),
      h('div', { class: 'ip-code' }, 'npm install stripe'),
      h('div', { class: 'ip-desc' }, say('Install the Stripe SDK for the checkout session', 'Instalar o SDK do Stripe para a sessão de checkout')),
      ...rows.map((r) => r.row),
      h('div', { class: 'ip-reply' }, h('span', {}, say('Reply to Claude…', 'Responder a Claude…')), sym('mic.fill', 14, 'rgba(255,255,255,0.55)'), sym('arrow.up.circle.fill', 22, 'rgba(255,255,255,0.28)')),
      h('div', { class: 'ip-actions' },
        h('span', { class: 'ip-btn blue' }, sym('arrow.up.forward.app', 13, 'var(--blue)'), say('Open session', 'Abrir sessão')),
        h('span', { class: 'ip-btn' }, sym('eye.slash', 13, 'rgba(255,255,255,0.7)'), say('Dismiss', 'Dispensar'))),
      status));

  /**
   * open: 0…1 (spring) · chosen: 0…1 (row 1 turning green) · sendK: 0…1 through the undo window (-1 before) ·
   * sentK: 0…1 · keyPress: 0…1 (the "1" keycap pushed)
   */
  function update({ open = 0, chosen = 0, sendK = -1, sentK = 0, keyPress = 0 }) {
    css(el, { opacity: clamp(open * 1.6), transform: `translate(${lerp(26, 0, open).toFixed(2)}px, 0) scale(${lerp(0.9, 1, open).toFixed(4)})` });
    const r1 = rows[0];
    const tint = `rgba(76,195,138,${(0.14 * chosen).toFixed(3)})`;
    css(r1.row, { background: `linear-gradient(${tint}, ${tint}), #1C1C1E`, borderColor: `rgba(76,195,138,${(0.45 * chosen).toFixed(3)})`,
      transform: `scale(${(1 - 0.012 * keyPress).toFixed(4)})` });
    css(r1.cap, { opacity: 1 - chosen, transform: `scale(${(1 - 0.08 * keyPress).toFixed(3)})` });
    css(r1.check, { opacity: chosen, transform: `scale(${lerp(0.6, 1, ease.outBack(clamp(chosen))).toFixed(3)})` });
    rows.slice(1).forEach((r) => css(r.row, { opacity: lerp(1, 0.45, chosen) }));
    const sendOn = sendK >= 0 && sentK < 1;
    css(hint, { opacity: sendK >= 0 ? 0 : 1 });
    css(sending, { opacity: sendOn ? clamp(1 - sentK * 2) : 0 });
    css(bar, { transform: `scaleX(${(1 - clamp(sendK)).toFixed(4)})` });
    css(sent, { opacity: clamp(sentK), transform: `translateY(${lerp(6, 0, ease.outCubic(clamp(sentK))).toFixed(2)}px)` });
  }

  return { el, update, rows };
}
