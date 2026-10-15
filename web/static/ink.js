// Hand-drawn strokes, ported from InkKit (Doodle.swift, DoodleRing.swift).
// Every stroke is jittered by a seeded wobble; stepping
// the seed every 0.4s gives the hand-drawn "boil".

export const BOIL_MS = 400;

function wobble(seed) {
  let s = BigInt.asUintN(64, BigInt(seed));
  return () => {
    s = BigInt.asUintN(64, s * 6364136223846793005n + 1442695040888963407n);
    return Number((s >> 33n) % 1000n) / 1000 - 0.5;
  };
}

function jitter(pts, seed, amp) {
  const next = wobble(seed);
  return pts.map(([x, y]) => [x + next() * amp * 2, y + next() * amp * 2]);
}

const f = (n) => n.toFixed(2);
const mid = (a, b) => [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2];

/** A soft curve through pts, as an SVG path. */
function curve(pts, closed) {
  if (pts.length < 2) return "";
  let d;
  if (closed) {
    const n = pts.length;
    const start = mid(pts[n - 1], pts[0]);
    d = `M${f(start[0])} ${f(start[1])}`;
    for (let i = 0; i < n; i++) {
      const m = mid(pts[i], pts[(i + 1) % n]);
      d += `Q${f(pts[i][0])} ${f(pts[i][1])} ${f(m[0])} ${f(m[1])}`;
    }
    return d + "Z";
  }
  d = `M${f(pts[0][0])} ${f(pts[0][1])}`;
  for (let i = 1; i < pts.length; i++) {
    const m = mid(pts[i - 1], pts[i]);
    d += `Q${f(pts[i - 1][0])} ${f(pts[i - 1][1])} ${f(m[0])} ${f(m[1])}`;
  }
  const last = pts[pts.length - 1];
  return d + `L${f(last[0])} ${f(last[1])}`;
}

/** A square whose edges wobble but whose corners stay corners. */
export function square(x, y, size, seed, amp = 0.35) {
  const c = [[x, y], [x + size, y], [x + size, y + size], [x, y + size]];
  const samples = [];
  c.forEach((a, i) => {
    const b = c[(i + 1) % 4];
    for (let t = 0; t < 3; t++) samples.push([a[0] + (b[0] - a[0]) * t / 3, a[1] + (b[1] - a[1]) * t / 3]);
  });
  const pts = jitter(samples, seed, amp);
  return "M" + pts.map(([px, py]) => `${f(px)} ${f(py)}`).join("L") + "Z";
}

const SEED = { check: 13, cross: 19, working: 29, runner: 37, sneaker: 41 };

/** The small marks, as in InkKit's Glyphs: strokes on a 48-unit grid scaled
 *  to `size`, with a little less wobble than the hand-drawn marks. A check,
 *  a cross and an open "working" arc for a field's status; the runner and
 *  sneaker for the intervals. Returns one SVG path per stroke. */
export function glyph(kind, size, tick) {
  const k = size / 48, amp = size / 60 * 0.8;
  const next = wobble(tick + (SEED[kind] ?? 41));
  const p = ([x, y]) => [x * k + next() * amp, y * k + next() * amp];
  const line = (pts, closed = false) =>
    "M" + pts.map(p).map(([x, y]) => `${f(x)} ${f(y)}`).join("L") + (closed ? "Z" : "");

  if (kind === "check") return [line([[9, 25], [20, 36], [40, 12]])];
  if (kind === "cross") return [line([[12, 12], [36, 36]]), line([[36, 12], [12, 36]])];
  if (kind === "working") {
    // Most of a circle, open at the top right, as the mac's spinner.
    const arc = [...Array(14)].map((_, i) => {
      const a = (i / 13 * 0.72 - 0.25) * 2 * Math.PI;
      return [24 + Math.cos(a) * 17, 24 + Math.sin(a) * 17];
    });
    return [curve(arc.map(p), false)];
  }
  if (kind === "runner") {
    const head = [...Array(12)].map((_, i) => {
      const a = i / 12 * 2 * Math.PI;
      return [31 + Math.cos(a) * 4, 8 + Math.sin(a) * 4];
    });
    return [
      curve(head.map(p), true),
      line([[28, 13], [22, 26]]),
      line([[27, 15], [19, 17], [15, 12]]),
      line([[27, 15], [33, 21], [39, 20]]),
      line([[22, 26], [30, 32], [26, 42]]),
      line([[22, 26], [14, 30], [7, 36]]),
    ];
  }
  return [
    line([[7, 22], [6, 34], [42, 34], [44, 31], [30, 25], [24, 19], [16, 21]], true),
    line([[8, 30], [41, 30]]),
    line([[17, 25], [22, 23]]),
    line([[20, 28], [25, 26]]),
  ];
}

/** The timer face: a dotted track and an inked arc from twelve o'clock. */
export function ring(size, progress, tick, lineWidth = 2.6) {
  const c = size / 2, r = size / 2 - lineWidth * 2, samples = 72;
  const point = (i, n, sweep) => {
    const a = -Math.PI / 2 + sweep * i / n;
    return [c + Math.cos(a) * r, c + Math.sin(a) * r];
  };
  const track = curve(jitter([...Array(samples)].map((_, i) => point(i, samples, 2 * Math.PI)), tick + 3, 0.7), true);
  const p = Math.min(1, Math.max(0, progress));
  if (p <= 0.001) return { track, arc: "", tip: null };
  const n = Math.max(2, Math.floor(samples * p));
  const pts = jitter([...Array(n + 1)].map((_, i) => point(i, n, 2 * Math.PI * p)), tick + 17, 0.9);
  return { track, arc: curve(pts, false), tip: pts[pts.length - 1] };
}
