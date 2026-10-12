// Renders the film. `node render.mjs stills <t,t,…> [out dir]` · `node render.mjs audio` · `node render.mjs video [--fps 60]
// [--scale 2] [--from s] [--to s]` · `node render.mjs page <file.html> <out.png> [w h scale]`.
// A small static server serves this folder; the SF fonts come from the system (never copied), so the UI looks like the
// Mac's and the iPhone's.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import ffmpegPath from 'ffmpeg-static';

const here = path.dirname(fileURLToPath(import.meta.url));
const SYSFONTS = { 'SFNS.ttf': 1, 'SFNSRounded.ttf': 1, 'SFNSMono.ttf': 1, 'SFNSItalic.ttf': 1 };
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.json': 'application/json', '.svg': 'image/svg+xml' };

function serve() {
  const server = http.createServer((req, res) => {
    const url = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    let file;
    if (url.startsWith('/sysfonts/') && SYSFONTS[url.slice(10)]) file = path.join('/System/Library/Fonts', url.slice(10));
    else if (url.startsWith('/site/')) file = path.join(here, '../../site', url.slice(6));
    else file = path.join(here, url === '/' ? 'index.html' : url);
    if (!file.startsWith(here) && !file.startsWith('/System/Library/Fonts') && !file.startsWith(path.join(here, '../../site'))) { res.writeHead(403); return res.end(); }
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); return res.end(); }
      res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream' });
      res.end(data);
    });
  });
  return new Promise((ok) => server.listen(0, '127.0.0.1', () => ok(server)));
}

async function open(page, w = 1920, h = 1080, scale = 1) {
  const server = await serve();
  const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--font-render-hinting=none'] });
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: scale, colorScheme: 'dark' });
  const p = await ctx.newPage();
  p.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') console.log('page:', m.type(), m.text().slice(0, 300)); });
  p.on('pageerror', (e) => console.log('pageerror:', e.message));
  await p.goto(`http://127.0.0.1:${server.address().port}/${page}`, { waitUntil: 'networkidle' });
  await p.evaluate(() => document.fonts.ready);
  return { p, browser, server };
}

const [cmd, ...args] = process.argv.slice(2);
const flag = (name, def) => { const i = args.indexOf('--' + name); return i >= 0 ? args[i + 1] : def; };

if (cmd === 'page') {
  const [file, out, w = 1920, h = 1080, scale = 1] = args;
  const { p, browser, server } = await open(file, +w, +h, +scale);
  await p.waitForTimeout(300);
  await p.screenshot({ path: out });
  await browser.close(); server.close();
}

// --format vertical: the 1080 × 1920 cut (the same story and sound, framed for phones); --lang pt: the words in Portuguese
const vertical = flag('format', 'wide') === 'vertical', lang = flag('lang', 'en');
const FW = vertical ? 1080 : 1920, FH = vertical ? 1920 : 1080;
const query = new URLSearchParams({ ...(vertical && { format: 'vertical' }), ...(lang !== 'en' && { lang }) }).toString();
const PAGE = 'index.html' + (query ? '?' + query : '');

if (cmd === 'stills') {
  const times = args[0].split(',').map(Number);
  const dir = args[1] && !args[1].startsWith('--') ? args[1] : 'out/stills';
  fs.mkdirSync(dir, { recursive: true });
  const { p, browser, server } = await open(PAGE, FW, FH, +flag('scale', 1));
  await p.waitForFunction(() => window.motion?.ready);
  for (const t of times) {
    await p.evaluate((t) => window.motion.renderAt(t), t);
    await p.screenshot({ path: path.join(dir, `t${t.toFixed(2).padStart(6, '0')}.png`) });
  }
  await browser.close(); server.close();
}

if (cmd === 'video') {
  const fps = +flag('fps', 60), scale = +flag('scale', 1);
  const { p, browser, server } = await open(PAGE, FW, FH, scale);
  await p.waitForFunction(() => window.motion?.ready);
  const duration = await p.evaluate(() => window.motion.duration);
  const from = +flag('from', 0), to = Math.min(+flag('to', duration), duration);
  const out = flag('out', 'out/video.mp4');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  // motion blur: `blur` sub-frames over a 180° shutter, averaged by ffmpeg into each frame
  const blur = +flag('blur', 1), shutter = 0.5;
  const vf = blur > 1 ? ['-vf', `tmix=frames=${blur},select=eq(mod(n\\,${blur})\\,${blur - 1}),setpts=N/${fps}/TB`, '-r', String(fps)] : [];
  const ff = spawn(ffmpegPath, ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps * blur), '-c:v', 'png', '-i', '-', ...vf,
    '-c:v', 'libx264', '-preset', flag('preset', 'slow'), '-crf', flag('crf', '14'), '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out], { stdio: ['pipe', 'inherit', 'inherit'] });
  const cdp = await p.context().newCDPSession(p);
  const frames = Math.round((to - from) * fps);
  const t0 = Date.now();
  for (let i = 0; i < frames; i++) for (let k = 0; k < blur; k++) {
    await p.evaluate((t) => window.motion.renderAt(t), from + i / fps + (blur > 1 ? (k / blur) * (shutter / fps) : 0));
    const { data } = await cdp.send('Page.captureScreenshot', { format: 'png', optimizeForSpeed: true, clip: { x: 0, y: 0, width: FW, height: FH, scale } });
    if (!ff.stdin.write(Buffer.from(data, 'base64'))) await new Promise((r) => ff.stdin.once('drain', r));
    if (i % 60 === 0 && k === 0) process.stdout.write(`\r${i}/${frames} frames · ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  }
  ff.stdin.end();
  await new Promise((r) => ff.on('close', r));
  console.log(`\n${out}: ${frames} frames in ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  await browser.close(); server.close();
}

if (cmd === 'audio') {
  const out = flag('out', 'out/audio.wav');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  const { p, browser, server } = await open('index.html?audio', 640, 360, 1);
  await p.waitForFunction(() => window.motion?.ready);
  const stems = flag('stems', 'all');
  const chunks = await p.evaluate(async (stems) => {
    const wav = await window.motion.renderAudio({ stems });
    const out = [];
    const bytes = new Uint8Array(wav);
    for (let i = 0; i < bytes.length; i += 1 << 20) {
      let s = '';
      const part = bytes.subarray(i, i + (1 << 20));
      for (let j = 0; j < part.length; j += 0x8000) s += String.fromCharCode.apply(null, part.subarray(j, j + 0x8000));
      out.push(btoa(s));
    }
    return out;
  }, stems);
  fs.writeFileSync(out, Buffer.concat(chunks.map((c) => Buffer.from(c, 'base64'))));
  console.log(out, fs.statSync(out).size, 'bytes');
  await browser.close(); server.close();
}

if (cmd === 'mux') {
  // the picture and the sound, mastered: -14 LUFS, true peak under -1 dB (two passes of loudnorm, then a limiter)
  const video = flag('video', 'out/video.mp4'), audio = flag('audio', 'out/audio.wav'), out = flag('out', 'out/pier.mp4');
  const run = (a) => new Promise((ok, no) => { const p = spawn(ffmpegPath, a, { stdio: ['ignore', 'pipe', 'pipe'] }); let err = ''; p.stderr.on('data', (d) => (err += d)); p.on('close', (c) => (c ? no(new Error(err)) : ok(err))); });
  const probe = await run(['-hide_banner', '-nostats', '-i', audio, '-af', 'aformat=channel_layouts=stereo,loudnorm=I=-14:TP=-1.2:LRA=9:print_format=json', '-f', 'null', '-']);
  const m = JSON.parse(probe.slice(probe.lastIndexOf('{'), probe.lastIndexOf('}') + 1));
  const ln = `loudnorm=I=-14:TP=-1.2:LRA=9:measured_I=${m.input_i}:measured_TP=${m.input_tp}:measured_LRA=${m.input_lra}:measured_thresh=${m.input_thresh}:offset=${m.target_offset}:linear=true`;
  await run(['-y', '-hide_banner', '-i', video, '-i', audio, '-map', '0:v', '-map', '1:a', '-c:v', 'copy',
    '-af', `aformat=channel_layouts=stereo,${ln},alimiter=limit=0.87:attack=2:release=40:level=false,aresample=48000,aformat=channel_layouts=stereo`, '-c:a', 'aac', '-b:a', '320k', '-shortest', '-movflags', '+faststart', out]);
  console.log(out, 'loudness in', m.input_i, 'LUFS, true peak', m.input_tp);
}

if (cmd === 'sheet') {
  // `node render.mjs sheet <out.png> <columns> <cell width> <png…>`: images side by side, each labelled (for reviews)
  const [out, cols, cell, ...imgs] = args;
  const html = `<html><body style="margin:0;background:#888;display:grid;grid-template-columns:repeat(${cols},${cell}px);gap:6px;padding:6px;align-items:start">` +
    imgs.map((p) => `<div style="position:relative"><img src="data:image/png;base64,${fs.readFileSync(p).toString('base64')}" style="width:${cell}px;display:block"><span style="position:absolute;left:4px;top:4px;background:#000;color:#fff;font:12px sans-serif;padding:2px 5px">${path.basename(p)}</span></div>`).join('') + '</body></html>';
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: cols * (+cell + 6) + 6, height: 400 } });
  await page.setContent(html);
  await page.screenshot({ path: out, fullPage: true });
  await browser.close();
}
