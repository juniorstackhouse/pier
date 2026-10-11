// The film's clock: one tempo for the picture and the sound, so every cut, pop and chime lands on the music.
// 112.5 BPM: a beat is exactly 32 frames at 60 fps, a bar 128.

export const BPM = 112.5;
export const BEAT = 60 / BPM;
export const BAR = BEAT * 4;
export const FPS = 60;

/** The time of bar `bar` (from 1), beat `beat` (from 1, fractions allowed). */
export const at = (bar, beat = 1) => (bar - 1) * BAR + (beat - 1) * BEAT;

export const DURATION = at(25) + 0.9;

// The story, bar by bar. Every scene and every sound reads its moments from here.
export const CUE = {
  // 1–2 · the agents at work, alone in the dark
  ringIn: at(1, 1),
  introLine: at(1, 2),
  rings: at(2, 1),
  tabForms: at(2, 3),
  pullBack: at(2, 4),

  // 3–8 · the Mac: the tab at the edge of the screen
  macIn: at(3, 1),
  macLine: at(3, 2),
  pushIn: at(4, 1),
  needs: at(4, 3),            // an agent needs you: the dot turns amber and the tab grows by itself
  needsLine: at(4, 3),
  cursorIn: at(5, 1),
  inboxHover: at(5, 2.5),
  inboxClick: at(5, 3),        // the Inbox opens beside the tab
  keyLine: at(6, 1),
  press1: at(6, 3),            // "1": Allow
  sent: at(7, 3),              // "Sent to Claude": the dot turns blue again
  editorLine: at(7, 3),
  panelClose: at(7, 4),
  toolNew: at(8, 1),           // a hover down the tab: New task, Talk, Point
  toolTalk: at(8, 2),
  toolPoint: at(8, 3),
  cursorOut: at(8, 4),
  tabFolds: at(8, 4.75),

  // 9–10 · step away
  stepBack: at(9, 1),
  stepLine: at(9, 3),
  phoneUp: at(10, 3),

  // 11–18 · the iPhone: the Dynamic Island, the notification, the Lock Screen
  phoneIn: at(11, 1),
  followLine: at(11, 2),
  islandPress: at(12, 1),
  islandOpen: at(12, 1.75),
  islandLine: at(12, 2),
  islandClose: at(13, 1),
  ask: at(13, 3),              // a question: the island pulses, the banner drops
  askLine: at(13, 3.5),
  bannerPress: at(14, 2),
  menuOpen: at(14, 2.75),
  menuLine: at(14, 3),
  choose: at(15, 1),           // "Three tiers"
  answered: at(15, 1.5),
  tapLine: at(15, 2),
  lockCard: at(16, 1),         // a permission on the Lock Screen
  lockLine: at(16, 1.5),
  allowTap: at(16, 3),
  working: at(16, 4),
  yourTurn: at(17, 3),
  turnLine: at(17, 3),
  phoneOut: at(18, 3),

  // 19–20 · everywhere
  every1: at(19, 1),
  every2: at(19, 2),
  every3: at(19, 3),
  secure: at(20, 1),
  keys: at(20, 3),

  // 21–24 · the mascot, the name
  endIn: at(21, 1),
  wordmark: at(21, 3),
  tagline: at(22, 1),
  details: at(22, 3),
  url: at(23, 1),
  fadeOut: at(24, 3),
};
