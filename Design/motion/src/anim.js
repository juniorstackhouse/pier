// Motion curves. Everything is a pure function of time, so any frame renders the same on its own.

export const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
export const lerp = (a, b, k) => a + (b - a) * k;
/** 0 before `a`, 1 after `b`, linear between. */
export const prog = (t, a, b) => (b <= a ? (t >= a ? 1 : 0) : clamp((t - a) / (b - a)));

export const ease = {
  linear: (x) => x,
  inQuad: (x) => x * x,
  outQuad: (x) => 1 - (1 - x) * (1 - x),
  inOutQuad: (x) => (x < 0.5 ? 2 * x * x : 1 - Math.pow(-2 * x + 2, 2) / 2),
  inCubic: (x) => x * x * x,
  outCubic: (x) => 1 - Math.pow(1 - x, 3),
  inOutCubic: (x) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2),
  outQuart: (x) => 1 - Math.pow(1 - x, 4),
  inOutQuart: (x) => (x < 0.5 ? 8 * x * x * x * x : 1 - Math.pow(-2 * x + 2, 4) / 2),
  outQuint: (x) => 1 - Math.pow(1 - x, 5),
  inOutQuint: (x) => (x < 0.5 ? 16 * Math.pow(x, 5) : 1 - Math.pow(-2 * x + 2, 5) / 2),
  outExpo: (x) => (x >= 1 ? 1 : 1 - Math.pow(2, -10 * x)),
  inExpo: (x) => (x <= 0 ? 0 : Math.pow(2, 10 * x - 10)),
  inOutExpo: (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x < 0.5 ? Math.pow(2, 20 * x - 10) / 2 : (2 - Math.pow(2, -20 * x + 10)) / 2),
  outBack: (x, s = 1.70158) => 1 + (s + 1) * Math.pow(x - 1, 3) + s * Math.pow(x - 1, 2),
  inBack: (x, s = 1.70158) => (s + 1) * x * x * x - s * x * x,
  inOutSine: (x) => -(Math.cos(Math.PI * x) - 1) / 2,
};

/** A cubic-bezier timing function like CSS's, solved for x. */
export function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const sx = (t) => ((ax * t + bx) * t + cx) * t;
  const sy = (t) => ((ay * t + by) * t + cy) * t;
  const dx = (t) => (3 * ax * t + 2 * bx) * t + cx;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const e = sx(t) - x;
      if (Math.abs(e) < 1e-6) break;
      const d = dx(t);
      if (Math.abs(d) < 1e-6) break;
      t -= e / d;
    }
    return sy(clamp(t));
  };
}
// Apple's standard curves.
ease.apple = bezier(0.25, 0.1, 0.25, 1);
ease.appleInOut = bezier(0.42, 0, 0.58, 1);
ease.swift = bezier(0.3, 0.0, 0.0, 1.0);
ease.cinematic = bezier(0.7, 0, 0.2, 1);

/**
 * A spring's step response at `t` seconds after it started (0 before), as SwiftUI's
 * `.spring(response:dampingFraction:)`: `response` is the undamped period, `damping` 1 is critical (no overshoot).
 */
export function spring(t, response = 0.5, damping = 0.825) {
  if (t <= 0) return 0;
  if (!Number.isFinite(t) || t > response * 12) return 1;
  const w = (2 * Math.PI) / response;
  if (damping >= 1) return 1 - Math.exp(-w * t) * (1 + w * t);
  const wd = w * Math.sqrt(1 - damping * damping);
  return 1 - Math.exp(-damping * w * t) * (Math.cos(wd * t) + ((damping * w) / wd) * Math.sin(wd * t));
}

/** A value that springs from `from` to `to` starting at `t0`. */
export const springTo = (t, t0, from, to, response, damping) => lerp(from, to, spring(t - t0, response, damping));

/**
 * A sequence of springs on one value: [[time, target], …] from `initial`. Each change starts from where the value was
 * at that moment, so retargeting mid-flight stays smooth.
 */
export function springTrack(t, initial, changes, response = 0.5, damping = 0.825) {
  let value = initial, from = initial, start = -Infinity, target = initial;
  for (const [ct, to] of changes) {
    if (t < ct) break;
    from = lerp(from, target, spring(ct - start, response, damping));
    start = ct;
    target = to;
  }
  value = lerp(from, target, spring(t - start, response, damping));
  return value;
}

/** Eased tween over [a, b] from `v0` to `v1`. */
export const tween = (t, a, b, v0, v1, fn = ease.inOutCubic) => lerp(v0, v1, fn(prog(t, a, b)));

/** In over [a, a+d], out over [b, b+d]: 0 → 1 → 0. */
export function inOut(t, a, b, inDur = 0.3, outDur = 0.3, fnIn = ease.outCubic, fnOut = ease.inCubic) {
  if (t < a || t > b + outDur) return 0;
  if (t < a + inDur) return fnIn(prog(t, a, a + inDur));
  if (t <= b) return 1;
  return 1 - fnOut(prog(t, b, b + outDur));
}

/** A deterministic pseudo-random number for an integer seed. */
export function rand(seed) {
  let x = Math.sin(seed * 12.9898 + 78.233) * 43758.5453;
  return x - Math.floor(x);
}

/** A point along a cubic Bézier. */
export function cubicPoint(p0, p1, p2, p3, k) {
  const u = 1 - k;
  return [
    u * u * u * p0[0] + 3 * u * u * k * p1[0] + 3 * u * k * k * p2[0] + k * k * k * p3[0],
    u * u * u * p0[1] + 3 * u * u * k * p1[1] + 3 * u * k * k * p2[1] + k * k * k * p3[1],
  ];
}
