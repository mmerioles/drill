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
