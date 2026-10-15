// The demo's made-up year: a few classes, each with its own rhythm, the same
// on every visit. A class takes `[min, max]` blocks on the weekdays it meets
// (0 is sunday), in the months it runs (0 is january).

const SAMPLE = {
  "15-213": { days: [1, 2, 3, 4], months: [0, 1, 2, 3, 4, 8, 9, 10, 11], blocks: [1, 4], skip: 0.25 },
  "linear algebra": { days: [1, 3, 5], months: [0, 1, 2, 3, 4], blocks: [1, 3], skip: 0.2 },
  "japanese": { days: [0, 1, 2, 3, 4, 5, 6], months: [...Array(12).keys()], blocks: [1, 2], skip: 0.3 },
  "piano": { days: [0, 6], months: [5, 6, 7, 8, 9], blocks: [1, 3], skip: 0.3 },
};

export const SAMPLE_TAGS = Object.keys(SAMPLE);

let sample = null;
export function sampleYear() {
  if (sample) return sample;
  let seed = 7;
  const next = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
  sample = [];
  for (let d = 1; d < 371; d++) {
    const day = new Date();
    day.setHours(10, 0, 0, 0);
    day.setDate(day.getDate() - d);
    for (const [tag, c] of Object.entries(SAMPLE)) {
      if (!c.days.includes(day.getDay()) || !c.months.includes(day.getMonth()) || next() < c.skip) continue;
      const blocks = c.blocks[0] + Math.floor(next() * (c.blocks[1] - c.blocks[0] + 1));
      sample.push({ startedAt: day.toISOString(), focusSeconds: blocks * 25 * 60, tag });
    }
  }
  return sample;
}
