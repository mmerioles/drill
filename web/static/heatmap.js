// A year of days in week columns, ported from DrillCore/Heatmap.swift.
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

// Where weeks don't start on monday, from CLDR's firstDay, for browsers
// without Intl.Locale#weekInfo (Firefox).
const SUNDAY = new Set(("AG AS BD BR BS BT BW BZ CA CN CO DM DO ET GT GU HK HN ID IL IN JM JP KE KH KR LA " +
  "MH MM MO MT MX MZ NI NP PA PE PH PK PR PT PY SA SG SV TH TT TW UM US VE VI WS YE ZA ZW").split(" "));
const SATURDAY = new Set("AE AF BH DJ DZ EG IQ IR JO KW LY OM QA SD SY".split(" "));

/** The locale's first weekday as Date#getDay counts (0 is sunday). Intl
 *  says 1 for monday through 7 for sunday; without it, the region decides. */
export function firstWeekday(language = navigator.language) {
  try {
    const locale = new Intl.Locale(language);
    const info = locale.getWeekInfo?.() ?? locale.weekInfo;
    if (info?.firstDay >= 1 && info.firstDay <= 7) return info.firstDay % 7;
    const region = locale.maximize().region;
    if (region) return SUNDAY.has(region) ? 0 : SATURDAY.has(region) ? 6 : 1;
  } catch {}
  return 0;
}

const startOfWeek = (ms, first) => addDays(startOfDay(ms), -((new Date(ms).getDay() - first + 7) % 7));

/** Row 0 is the locale's first weekday, like the mac's calendar. */
export function buildHeatmap(sessions, weeks = 53, now = Date.now(), first = firstWeekday()) {
  const totals = new Map();
  for (const s of sessions) {
    const day = startOfDay(Date.parse(s.startedAt));
    totals.set(day, (totals.get(day) ?? 0) + s.focusSeconds);
  }

  const today = startOfDay(now);
  const weekStart = startOfWeek(now, first);
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
