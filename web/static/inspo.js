// Shuzo Matsuoka's short cheer-up videos: the "〜あなたに" messages from his
// official YouTube channel, with the clams clip first. The list lives in
// Support/inspo.json (see scripts/make-inspo.sh). The shuffle is kept in step
// with Sources/DrillApp/Inspo.swift, so every device shows the same few
// videos on the same day. `daily` marks the rotation; the rest are skits.

import { ROWS } from "./inspo-videos.js";

export const VIDEOS = ROWS.map(([id, daily, title, japanese], i) => ({
  number: i + 1, id, daily, title, japanese, url: `https://www.youtube.com/watch?v=${id}`,
}));

const PER_DAY = 5;
const WATCHED = "drill.inspo.seen";

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
 * before today. Cheer-up messages come first, the skits once those run out, and
 * the full rotation again once you've seen everything. Videos watched today
 * stay put, so the list doesn't shift under you.
 */
export function today(seen, on = day()) {
  const next = mulberry32(on);
  const daily = shuffled(VIDEOS.filter((v) => v.daily), next);
  const rest = shuffled(VIDEOS.filter((v) => !v.daily), next);
  const fresh = [...daily, ...rest].filter((v) => !seen.has(v.id));
  return (fresh.length ? fresh : daily).slice(0, PER_DAY);
}

/** YouTube id to the day it was first opened in this browser. */
function watchedDays() {
  try {
    return JSON.parse(localStorage.getItem(WATCHED)) ?? {};
  } catch { return {}; }
}

/** Ids of every video opened in this browser. */
export const watched = () => new Set(Object.keys(watchedDays()));

/** Ids of the videos opened before `on`. */
export function watchedBefore(on = day()) {
  return new Set(Object.entries(watchedDays()).filter(([, d]) => d < on).map(([id]) => id));
}

export function markWatched(video) {
  const days = watchedDays();
  days[video.id] ??= day();
  try { localStorage.setItem(WATCHED, JSON.stringify(days)); } catch {}
}
