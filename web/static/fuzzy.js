// The command palette's fuzzy match, the same on every platform: greedy
// left to right, with bonuses for word starts and runs, less the index of
// the first match.

const BOUNDARY = " -_/";

/** { score, indices } when every query letter is found in order, else null. */
export function match(query, text) {
  const q = query.toLowerCase().replaceAll(" ", ""), t = text.toLowerCase();
  if (!q) return { score: 0, indices: [] };
  const indices = [];
  let score = 0, at = -1;
  for (const c of q) {
    const i = t.indexOf(c, at + 1);
    if (i < 0) return null;
    score += 1;
    if (i === 0 || BOUNDARY.includes(t[i - 1])) score += 5;
    if (indices.length && i === at + 1) score += 3;
    indices.push(i);
    at = i;
  }
  return { score: score - indices[0], indices };
}

/** The score alone, or null for no match. */
export const score = (query, text) => match(query, text)?.score ?? null;

/** Items ({ id, title, keywords }) to show for `query`. Empty: the recently
 *  run ids first, then the rest in order. Otherwise the matches, best first,
 *  each with the title's matched `indices`; a keyword match counts 2 less.
 *  Items marked `last` skip scoring and go at the end. */
export function rank(items, query, recent = []) {
  const fixed = items.filter((it) => it.last);
  const pool = items.filter((it) => !it.last);
  if (!query.trim()) {
    const first = recent.map((id) => pool.find((it) => it.id === id)).filter(Boolean);
    return [...first, ...pool.filter((it) => !first.includes(it)), ...fixed]
      .map((it) => ({ ...it, indices: [] }));
  }
  const scored = [];
  pool.forEach((it, order) => {
    const title = match(query, it.title);
    let best = title?.score ?? null;
    for (const k of it.keywords ?? []) {
      const s = score(query, k);
      if (s !== null && (best === null || s - 2 > best)) best = s - 2;
    }
    if (best !== null) scored.push({ ...it, indices: title?.indices ?? [], score: best, order });
  });
  scored.sort((a, b) => b.score - a.score || a.order - b.order);
  return [...scored, ...fixed.map((it) => ({ ...it, indices: [] }))];
}
