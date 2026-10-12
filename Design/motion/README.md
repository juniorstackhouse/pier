# Pier — the film

A 52-second launch film about the two places Pier lives: the **edge tab** on the Mac (one indicator per agent, growing
into the Inbox when one needs you; an answer in a keystroke) and the **Dynamic Island** on the iPhone (the Live
Activity, a question dropping out of the island, its answers a long press away, the Lock Screen's Allow). It ends on
the site's night harbour (`Design/hero`).

Everything is drawn in a browser page and placed by `renderAt(t)` from one clock, so every frame is reproducible and
every sound lands on its frame:

| File | What |
|---|---|
| `src/time.js` | The tempo (112.5 BPM: a beat is 32 frames at 60 fps) and the story's cues, bar by bar. The picture and the sound read the same cues. |
| `src/format.js` | The frame: 1920 × 1080, or 1080 × 1920 with `?format=vertical` (each scene frames the same story for it). |
| `src/lang.js` | The words: English, or Brazilian Portuguese with `?lang=pt`. Every text on screen is `say(english, portuguese)` where it is drawn; the interface's words are the app's own (`App/Resources/Localizable.xcstrings`), the montage shows the site's screenshots in the same language. |
| `src/ui/edgeTab.js` | The Mac's tab, from PierKit's `EdgeOutline` / `EdgeMetrics` and the plugin's indicator drawing. |
| `src/ui/inboxPanel.js`, `src/ui/mac.js` | The Inbox card (PanelStyle) and the Mac's display: wallpaper, menu bar, editor, pointer. |
| `src/ui/iphone.js` | The iPhone: Home Screen, Lock Screen, the island (compact / expanded, after `SessionActivityViews`), the notification and its actions, the Live Activity's card. |
| `src/scenes/*.js` | The camera and the timing of each part. |
| `src/captions.js` | The words on screen. |
| `src/audio.js` | The music and the sound design, synthesized offline (WebAudio) from the same cues. |
| `symbols.swift` | Exports the SF Symbols the app uses as white PNGs (`assets/symbols`). |
| `render.mjs` | Stills, the soundtrack, the video (frames piped into ffmpeg, optional motion blur) and the mastered mux. |

The SF fonts and SF Symbols are Apple's and stay on the Mac: `render.mjs` serves the fonts from
`/System/Library/Fonts` while rendering, and `symbols.swift` exports the symbols into `assets/symbols` (gitignored) —
neither is copied into the repository, so rendering needs a Mac.

## Render

```sh
npm ci && npx playwright install chromium-headless-shell
swift symbols.swift assets/symbols                 # once: the SF Symbols, as tintable PNGs
npm run build
node render.mjs stills 9.6,11.8,24.2          # frames at those seconds, in out/stills
node render.mjs audio                          # out/audio.wav (32-bit float, before mastering)
node render.mjs video --blur 4                 # out/video.mp4, 1080p60 with motion blur (--scale 2 for 4K)
node render.mjs video --blur 4 --format vertical --out out/vertical.mp4   # the 1080 × 1920 cut (same story, same sound)
node render.mjs video --blur 4 --lang pt --out out/pt.mp4               # in Portuguese (with --format vertical too)
node render.mjs mux                            # out/pier.mp4: the video with the sound at -14 LUFS
```
