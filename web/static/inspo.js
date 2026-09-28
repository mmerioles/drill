// Shuzo Matsuoka's challenge messages, from his own site. Kept in step with
// Inspo in Sources/TetodoroApp/Views/InspoView.swift, pool and shuffle both,
// so every device shows the same few videos on the same day.

const VIDEOS = [
  ["who makes your limits?", "you do. before you say “i can’t”, try once more.", "matsuoka29"],
  ["hardship into happiness", "add one stroke to 辛 and it becomes 幸. one more push gets you through.", "matsuoka18"],
  ["don’t fear change", "if you want to reach the world, you have to be willing to change.", "matsuoka27"],
  ["always 40-0 in your heart", "keep the calm of someone way ahead, whatever the score.", "matsuoka16"],
  ["your own clock", "switch on, switch off, and use the time in between.", "matsuoka15"],
  ["we’re watching you in ten years", "it’s not about winning today. it’s who you’re becoming.", "matsuoka28"],
  ["the ones who repeat themselves care", "people who tell you the same thing again really mean it.", "matsuoka35"],
  ["don’t be afraid!", "a short one. exactly what it says.", "matsuoka36"],
  ["advantage smile", "smile through the hard part. it moves you forward.", "matsuoka17"],
  ["love beats perfect conditions", "you don’t need the best setup. care makes it the best place.", "matsuoka30"],
  ["basics first", "you can’t move forward without the fundamentals.", "matsuoka31"],
  ["decide", "know when to keep it steady and when to go for it.", "matsuoka10"],
  ["don’t let the ball run you", "take the lead. run your own life, don’t let it run you.", "matsuoka09"],
  ["nice & easy, nice & smooth", "keep it simple. no extra force.", "matsuoka37"],
].map(([title, summary, slug]) => ({
  title, summary, url: `https://www.shuzo.co.jp/challenge_message/${slug}`,
}));

const PER_DAY = 5;

/** A tiny seeded generator, bit-for-bit the same as the Swift one. */
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return (t ^ (t >>> 14)) >>> 0;
  };
}

/** A fresh handful each day: the pool shuffled with the date as the seed. */
export function today(now = new Date()) {
  const next = mulberry32(now.getFullYear() * 10000 + (now.getMonth() + 1) * 100 + now.getDate());
  const pool = [...VIDEOS];
  for (let i = pool.length - 1; i > 0; i--) {
    const j = next() % (i + 1);
    [pool[i], pool[j]] = [pool[j], pool[i]];
  }
  return pool.slice(0, PER_DAY);
}
