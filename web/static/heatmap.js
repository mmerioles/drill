// A year of days in week columns, ported from TetodoroCore/Heatmap.swift.
// Days are bucketed in the browser's own time zone.

/** Intensity 0–4. Fixed thresholds, so a cell means the same thing next year. */
export function level(seconds) {
  if (seconds < 60) return 0;
  if (seconds < 30 * 60) return 1;
  if (seconds < 90 * 60) return 2;
  if (seconds < 180 * 60) return 3;
  return 4;
}

const startOfDay = (ms) => { const d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); };
const addDays = (ms, n) => { const d = new Date(ms); d.setDate(d.getDate() + n); return d.getTime(); };
const startOfWeek = (ms) => addDays(startOfDay(ms), -new Date(ms).getDay());

export function buildHeatmap(sessions, weeks = 53, now = Date.now()) {
  const totals = new Map();
  for (const s of sessions) {
    const day = startOfDay(Date.parse(s.startedAt));
    totals.set(day, (totals.get(day) ?? 0) + s.focusSeconds);
  }

  const today = startOfDay(now);
  const weekStart = startOfWeek(now);
  const gridStart = addDays(weekStart, -7 * (weeks - 1));

  const columns = [...Array(weeks)].map((_, w) =>
    [...Array(7)].map((_, d) => {
      const date = addDays(gridStart, w * 7 + d);
      if (date > today) return null;
      const seconds = totals.get(date) ?? 0;
      return { date, seconds, level: level(seconds) };
    }));

  let thisWeek = 0;
  for (const [day, s] of totals) if (day >= weekStart) thisWeek += s;

  // A streak isn't broken before today's session has happened.
  let streak = 0, cursor = today;
  if (!(totals.get(cursor) > 0)) cursor = addDays(cursor, -1);
  while (totals.get(cursor) > 0) { streak += 1; cursor = addDays(cursor, -1); }

  return { weeks: columns, today: totals.get(today) ?? 0, thisWeek, streak };
}
