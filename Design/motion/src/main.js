// Pier's launch film. Every element is placed by `renderAt(t)` from the shared clock (time.js), so a frame is the
// same however it is reached; render.mjs steps through them at 60 fps and pipes them into ffmpeg.
import sizes from './symbols.json';
import { registerSymbols, h, css } from './dom.js';
import { CUE, at, BEAT, BAR, DURATION } from './time.js';
import { clamp, ease, prog, rand, spring, lerp } from './anim.js';
import { createCaptions } from './captions.js';
import { createMacScene } from './scenes/mac.js';
import { createPhoneScene } from './scenes/phone.js';
import { createOutroScene } from './scenes/outro.js';
import { FORMAT } from './format.js';
import { renderAudio } from './audio.js';

registerSymbols(sizes);

const frame = h('div', { id: 'frame' });
document.body.append(frame);
const layers = {};
for (const name of ['bg', 'mac', 'phone', 'montage', 'end', 'vignette', 'captions', 'grain', 'fade']) {
  layers[name] = h('div', { class: `layer layer-${name}` });
  frame.append(layers[name]);
}

layers.bg.append(h('div', { class: 'bg-glow a' }), h('div', { class: 'bg-glow b' }), h('div', { class: 'bg-glow c' }));
const macScene = createMacScene(layers.mac);
const phoneScene = createPhoneScene(layers.phone);
const outroScene = createOutroScene(layers.montage, layers.end);

const T = CUE;
const LEFT = 150;
const V = FORMAT.vertical;
// where the words go: wide, on the left of the picture; vertical, above or under it, centred
const W = (wide, vert) => (V ? vert : wide);
const left = (y, size) => ({ x: LEFT, y, size });
const centre = (x, y, size) => ({ x, y, size, align: 'center' });
const updateCaptions = createCaptions(layers.captions, [
  { t0: T.introLine, t1: T.pullBack - 0.15, lines: ['Your agents', 'are at work.'], ...W(left(540, 92), centre(540, 1540, 92)) },
  { t0: T.macLine, t1: T.pushIn + BEAT * 0.5, lines: W(['One tab. Every agent.'], ['One tab.', 'Every agent.']), ...W(left(968, 76), { x: 80, y: 1330, size: 100 }) },
  { t0: T.needsLine, t1: W(T.keyLine - 0.2, T.inboxClick - 0.15), outDur: W(0.38, 0.18), lines: ['When one', '*needs you*,'], ...W(left(520, 96), { x: 70, y: 560, size: 104 }) },
  { t0: T.keyLine, t1: T.editorLine - 0.5, lines: ['answer in', 'a keystroke.'], ...W(left(520, 96), centre(540, 1290, 96)) },
  { t0: T.editorLine, t1: T.toolNew - 0.5, lines: ['Never leave', 'your editor.'], ...W(left(520, 96), centre(540, 1360, 96)) },
  { t0: T.toolNew, t1: T.cursorOut, lines: ['Start a *task*.'], ...W(left(420, 84), { x: 70, y: 400, size: 92 }), accent: 'var(--cream)' },
  { t0: T.toolTalk, t1: T.cursorOut, lines: ['*Talk* to it.'], ...W(left(520, 84), { x: 70, y: 520, size: 92 }), accent: 'var(--cream)' },
  { t0: T.toolPoint, t1: T.cursorOut, lines: ['*Point* at it.'], ...W(left(620, 84), { x: 70, y: 640, size: 92 }), accent: 'var(--cream)' },
  { t0: T.stepLine, t1: T.phoneUp - 0.2, lines: ['Step away.'], ...W(centre(960, 540, 150), centre(540, 960, 150)) },
  { t0: T.followLine, t1: T.islandLine - 0.3, lines: ['They come', 'with you.'], ...W(left(540, 96), centre(540, 290, 96)) },
  { t0: T.islandLine, t1: T.askLine - 0.45, lines: ['Live, in the', '*Dynamic Island.*'], ...W(left(540, 96), centre(540, 290, 96)), accent: 'var(--blue)' },
  { t0: T.askLine, t1: T.menuLine - 0.3, lines: ['Every *question*', 'finds you.'], ...W(left(540, 96), centre(540, 290, 96)) },
  { t0: T.menuLine, t1: T.tapLine - 0.3, lines: ['Answer it from', 'the notification.'], ...W(left(540, 88), centre(540, 290, 88)) },
  { t0: T.tapLine, t1: T.lockCard - 0.2, lines: ['One tap.', 'Back to *work.*'], ...W(left(540, 96), centre(540, 290, 96)), accent: 'var(--blue)' },
  { t0: T.lockLine, t1: T.turnLine - 0.35, lines: ['Even from the', 'Lock Screen.'], ...W(left(540, 96), centre(540, 290, 96)) },
  { t0: T.turnLine, t1: T.phoneOut + 0.2, lines: ['*Your turn.*', 'Review when', 'you’re ready.'], ...W(left(540, 88), centre(540, 240, 84)), accent: 'var(--green)' },
  { t0: T.every1, t1: T.every2 - 0.1, outDur: 0.1, stagger: 0.05, lines: ['Every agent.'], ...W(left(540, 112), centre(540, 330, 112)) },
  { t0: T.every2, t1: T.every3 - 0.1, outDur: 0.1, stagger: 0.05, lines: ['Every box.'], ...W(left(540, 112), centre(540, 330, 112)) },
  { t0: T.every3, t1: T.secure - 0.2, outDur: 0.2, stagger: 0.05, lines: ['Anywhere.'], ...W(left(540, 112), centre(540, 330, 112)) },
  { t0: T.secure + 0.15, t1: T.endIn - 0.6, lines: W(['End-to-end encrypted.'], ['End-to-end', 'encrypted.']), ...W(centre(960, 250, 88), centre(540, 560, 92)) },
  { t0: T.keys, t1: T.endIn - 0.6, lines: W(['Your machines. *Your keys.*'], ['Your machines.', '*Your keys.*']), ...W(centre(960, 845, 64), centre(540, 1440, 76)), accent: '#7FE3DC' },
]);

// "1": a Mac key pressed on the beat, under "answer in a keystroke."
const key = h('div', { class: 'big-key' }, h('div', { class: 'big-key-cap' }, h('span', { class: 'shift' }, '!'), h('span', { class: 'main' }, '1')));
layers.captions.append(key);
function updateKey(t) {
  const inK = spring(t - (T.press1 - BEAT * 0.75), 0.5, 0.72);
  const out = ease.inCubic(prog(t, T.sent - 0.42, T.sent - 0.12));
  const on = t > T.press1 - BEAT && t < T.sent;
  const press = t >= T.press1 ? Math.max(0, 1 - spring(t - T.press1 - 0.09, 0.22, 0.6)) * (t < T.press1 + 0.09 ? prog(t, T.press1 - 0.02, T.press1 + 0.03) : 1) : 0;
  css(key, { display: on ? 'block' : 'none', opacity: clamp(inK * 1.5) * (1 - out),
    transform: `translate(${V ? 452 : LEFT}px, ${V ? 1480 : 720}px) translateY(${((1 - clamp(inK)) * 40 + out * 20).toFixed(2)}px) scale(${lerp(0.85, 1, clamp(inK)).toFixed(4)})` });
  css(key.firstChild, { transform: `translateY(${(press * 9).toFixed(2)}px)`, boxShadow: `0 ${(12 - press * 9).toFixed(1)}px 0 #0E0F11, 0 ${(22 - press * 14).toFixed(1)}px 40px rgba(0,0,0,0.5), inset 0 1px 0 rgba(255,255,255,0.12)` });
}

// film grain: a noise tile shifted every frame
const noise = document.createElement('canvas');
noise.width = noise.height = 256;
{
  const g = noise.getContext('2d');
  const img = g.createImageData(256, 256);
  for (let i = 0; i < img.data.length; i += 4) {
    const v = Math.floor(rand(i * 0.37 + 11) * 255);
    img.data[i] = img.data[i + 1] = img.data[i + 2] = v;
    img.data[i + 3] = 255;
  }
  g.putImageData(img, 0, 0);
}
css(layers.grain, { backgroundImage: `url(${noise.toDataURL()})`, opacity: 0.045, mixBlendMode: 'overlay' });

function renderAt(t) {
  macScene(t);
  phoneScene(t);
  outroScene(t);
  css(layers.bg, { opacity: ease.inOutQuad(prog(t, T.stepBack + 0.6, T.stepBack + 1.6)) * (1 - ease.inOutQuad(prog(t, T.endIn - 0.3, T.endIn + 0.2))) });
  css(layers.bg.children[0], { transform: `translate(${(Math.sin(t * 0.3) * 60).toFixed(1)}px, ${(Math.cos(t * 0.25) * 40).toFixed(1)}px)` });
  css(layers.bg.children[1], { transform: `translate(${(Math.cos(t * 0.22) * 70).toFixed(1)}px, ${(Math.sin(t * 0.27) * 50).toFixed(1)}px)` });
  updateCaptions(t);
  updateKey(t);
  const f = Math.floor(t * 60);
  css(layers.grain, { backgroundPosition: `${Math.floor(rand(f) * 256)}px ${Math.floor(rand(f + 7) * 256)}px` });
  // the opening and the end, from and to black
  const fadeIn = 1 - ease.outCubic(prog(t, 0, 0.6));
  const fadeOut = ease.inOutCubic(prog(t, T.fadeOut, DURATION - 0.1));
  css(layers.fade, { opacity: Math.max(fadeIn, fadeOut) });
}

window.motion = { duration: DURATION, renderAt, renderAudio, ready: false, cue: CUE };
document.fonts.ready.then(() => {
  // let every symbol mask load before the first frame
  const urls = Object.keys(sizes).map((n) => `/assets/symbols/${n}.png`);
  return Promise.all(urls.map((u) => new Promise((ok) => { const i = new Image(); i.onload = i.onerror = ok; i.src = u; })));
}).then(() => { renderAt(0); window.motion.ready = true; });
