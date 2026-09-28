// Shuzo Matsuoka's challenge messages, from his own site, numbered as he
// numbered them. Kept in step with Sources/TetodoroApp/Inspo.swift, list and
// shuffle both, so every device shows the same few videos on the same day.
// `daily` marks the rotation; the rest are tennis technique.

export const VIDEOS = [
  [1, true, "minus into plus", "make a habit of turning the negatives into positives.", "02"],
  [2, false, "take on your dream", "what to do now if you want to hold your own in the world.", "002"],
  [3, false, "aim for the grand slams", "not number one. the top 100, and the main draw.", "%e3%80%90%e4%bf%ae%e9%80%a0%e3%83%81%e3%83%a3%e3%83%ac%e3%83%b3%e3%82%b8%e3%80%913%e7%9b%ae%e6%8c%87%e3%81%9b%e3%82%b0%e3%83%a9%e3%83%b3%e3%83%89%e3%82%b9%e3%83%a9%e3%83%a0"],
  [4, false, "who raises a player", "not the coaches. your family and your home coach.", "%e3%80%90%e4%bf%ae%e9%80%a0%e3%83%81%e3%83%a3%e3%83%ac%e3%83%b3%e3%82%b8%e3%80%914%e9%81%b8%e6%89%8b%e3%82%92%e8%82%b2%e3%81%a6%e3%82%8b%e3%81%ae%e3%81%af"],
  [5, false, "the road to the world", "there’s something to do at every age on the way up.", "%e3%80%90%e4%bf%ae%e9%80%a0%e3%83%81%e3%83%a3%e3%83%ac%e3%83%b3%e3%82%b8%e3%80%915%e4%b8%96%e7%95%8c%e3%81%b8%e3%81%ae%e9%81%93"],
  [6, false, "tennis breathing", "how you breathe changes how you play.", "matsuoka06"],
  [7, true, "think! don’t think!", "think if it changes things. if it can’t, let it go.", "matsuoka07"],
  [8, true, "set your goals", "plan the week, then plan each day.", "matsuoka08"],
  [9, true, "don’t let the ball run you", "take the lead. run your own life, don’t let it run you.", "matsuoka09"],
  [10, true, "decide", "know when to keep it steady and when to go for it.", "matsuoka10"],
  [11, false, "your tennis moves forward", "meet the ball out in front.", "matsuoka11"],
  [12, false, "attack with your feet", "footwork, and why the first step matters.", "matsuoka12"],
  [13, true, "just listen", "when you can’t focus, listen to the ball and the racket. it calms you.", "matsuoka13"],
  [14, false, "the three brothers", "serve, return and the chance ball, and how they connect.", "%e3%80%90%e4%bf%ae%e9%80%a0%e3%83%81%e3%83%a3%e3%83%ac%e3%83%b3%e3%82%b8%e3%80%9114%e8%82%b2%e3%81%a6%e3%82%88%e3%81%86%e3%83%86%e3%83%8b%e3%82%b93%e5%85%84%e5%bc%9f"],
  [15, true, "your own clock", "switch on, switch off, and use the time in between.", "matsuoka15"],
  [16, true, "always 40-0 in your heart", "keep the calm of someone way ahead, whatever the score.", "matsuoka16"],
  [17, true, "advantage smile", "smile through the hard part. it moves you forward.", "matsuoka17"],
  [18, true, "hardship into happiness", "add one stroke to 辛 and it becomes 幸. one more push gets you through.", "matsuoka18"],
  [19, false, "no sorries needed", "you don’t have to keep apologising.", "matsuoka19"],
  [20, false, "ready changes everything", "how you stand ready changes your tennis.", "matsuoka20"],
  [21, false, "show me your shoulders", "form you can practise without a racket.", "matsuoka21"],
  [22, false, "timing matters", "in tennis, timing is everything.", "matsuoka22"],
  [23, false, "hit heavy", "to hold up in the world, a heavy ball beats a fast one.", "matsuoka23"],
  [24, false, "modern tennis", "how to hit with real power.", "matsuoka24"],
  [25, false, "wide stance, big base", "build a wide, steady foundation.", "matsuoka25"],
  [26, false, "200 km/h, bring it on", "welcoming a bullet-train serve.", "matsuoka26"],
  [27, true, "don’t fear change", "if you want to reach the world, you have to be willing to change.", "matsuoka27"],
  [28, true, "we’re watching you in ten years", "it’s not about winning today. it’s who you’re becoming.", "matsuoka28"],
  [29, true, "who makes your limits?", "you do. before you say “i can’t”, try once more.", "matsuoka29"],
  [30, true, "love beats perfect conditions", "you don’t need the best setup. care makes it the best place.", "matsuoka30"],
  [31, true, "basics first", "you can’t move forward without the fundamentals.", "matsuoka31"],
  [32, false, "heart, skill, body, and eyes", "why how you use your eyes matters.", "matsuoka32"],
  [33, false, "volley with a can", "a tin can trick for feeling the volley.", "matsuoka33"],
  [34, false, "make the space yours", "take up more of your own space and your tennis changes.", "matsuoka34"],
  [35, true, "the ones who repeat themselves care", "people who tell you the same thing again really mean it.", "matsuoka35"],
  [36, true, "don’t be afraid!", "a short one. exactly what it says.", "matsuoka36"],
  [37, true, "nice & easy, nice & smooth", "keep it simple. no extra force.", "matsuoka37"],
].map(([number, daily, title, summary, slug]) => ({
  number, daily, title, summary, url: `https://www.shuzo.co.jp/challenge_message/${slug}`,
}));

const PER_DAY = 5;
const WATCHED = "tetodoro.inspo.watchedOn";
/** Before days were kept: a plain list of numbers. */
const LEGACY = "tetodoro.inspo.watched";

/** A day as a number, like 20260928: the key for watched videos and the seed. */
export const day = (date = new Date()) =>
  date.getFullYear() * 10000 + (date.getMonth() + 1) * 100 + date.getDate();

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

function shuffled(videos, next) {
  const pool = [...videos];
  for (let i = pool.length - 1; i > 0; i--) {
    const j = next() % (i + 1);
    [pool[i], pool[j]] = [pool[j], pool[i]];
  }
  return pool;
}

/**
 * A fresh handful each day, seeded by the date, leaving out anything watched
 * before today. Mindset videos come first, technique once those run out, and
 * the full rotation again once you've seen everything. Videos watched today
 * stay put, so the list doesn't shift under you.
 */
export function today(seen, on = day()) {
  const next = mulberry32(on);
  const daily = shuffled(VIDEOS.filter((v) => v.daily), next);
  const rest = shuffled(VIDEOS.filter((v) => !v.daily), next);
  const fresh = [...daily, ...rest].filter((v) => !seen.has(v.number));
  return (fresh.length ? fresh : daily).slice(0, PER_DAY);
}

/** Video number to the day it was first opened in this browser. */
function watchedDays() {
  try {
    const days = JSON.parse(localStorage.getItem(WATCHED)) ?? {};
    const legacy = JSON.parse(localStorage.getItem(LEGACY));
    if (Array.isArray(legacy)) {
      for (const n of legacy) days[n] ??= 0;
      localStorage.setItem(WATCHED, JSON.stringify(days));
      localStorage.removeItem(LEGACY);
    }
    return days;
  } catch { return {}; }
}

/** Numbers of every video opened in this browser. */
export const watched = () => new Set(Object.keys(watchedDays()).map(Number));

/** Numbers of the videos opened before `on`. */
export function watchedBefore(on = day()) {
  return new Set(Object.entries(watchedDays()).filter(([, d]) => d < on).map(([n]) => Number(n)));
}

export function markWatched(video) {
  const days = watchedDays();
  days[video.number] ??= day();
  try { localStorage.setItem(WATCHED, JSON.stringify(days)); } catch {}
}
