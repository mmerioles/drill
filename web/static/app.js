import { Engine, Phase, defaultConfig, isBreak } from "./engine.js";
import { buildHeatmap } from "./heatmap.js";
import { BOIL_MS, drill, ring, square } from "./ink.js";
import { VIDEOS, markWatched, today as inspoToday, watched, watchedBefore } from "./inspo.js";
import { Store } from "./store.js";

const $ = (id) => document.getElementById(id);
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
/** On the download site, as a try-out: no sync, no notification prompt, and
 *  a sample year so the heatmap shows what it's for. */
const demo = new URLSearchParams(location.search).has("demo");
if (demo) document.documentElement.classList.add("demo");

// MARK: Persistence

const KEY = { timer: "drill.timer", settings: "drill.settings", tag: "drill.tag" };
const load = (key, fallback) => {
  try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; }
};
const save = (key, value) => {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch {}
};

const settings = { theme: "auto", sound: true, ...load(KEY.settings, {}) };
settings.config = { ...defaultConfig, ...settings.config };

const store = new Store();
let saved = load(KEY.timer, null);
const engine = new Engine(settings.config, saved?.engine);
/** The tag in effect for the running focus block, captured when it starts. */
let blockTag = saved?.blockTag ?? null;
let tagFilter = null;
let hovered = null;

function persistTimer() {
  save(KEY.timer, { engine: engine.state, blockTag });
}

// MARK: Copy (DrillApp/Copy.swift)

function statusWord() {
  if (engine.phase === Phase.focus && engine.isIdle) return "";
  if (!engine.isIdle && !engine.isRunning) return "paused";
  return { focus: "focus", shortBreak: "break", longBreak: "long break" }[engine.phase];
}

function clock(ms) {
  const total = Math.ceil(ms / 1000);
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
  const pad = (n) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

function amount(seconds) {
  const minutes = Math.floor(seconds / 60), h = Math.floor(minutes / 60), m = minutes % 60;
  if (h === 0) return `${m}m`;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}

const dayFormat = new Intl.DateTimeFormat(undefined, { weekday: "short", month: "short", day: "numeric" });
const monthFormat = new Intl.DateTimeFormat(undefined, { month: "short" });

// MARK: Intents

function toggle() {
  const starting = engine.isIdle;
  engine.toggle(Date.now());
  if (starting) {
    askForNotifications();
    if (engine.phase === Phase.focus) captureTag();
  }
  changed();
}

function skip() {
  handle(engine.skip(Date.now()));
  changed();
}

function reset() {
  const record = engine.reset(Date.now());
  if (record) store.log(record, blockTag);
  changed();
}

function captureTag() {
  const t = $("tag").value.trim().toLowerCase();
  blockTag = t || null;
}

function handle(t) {
  if (t.record) store.log(t.record, blockTag);
  if (t.next === Phase.focus && engine.isRunning) captureTag();
  if (!t.natural) return;
  const [title, body] = t.finished === Phase.focus
    ? ["focus done", "time for a break"] : ["break over", "back to focus"];
  notify(title, body);
  if (settings.sound) chime(t.finished === Phase.focus);
}

function changed() {
  persistTimer();
  schedule();
  renderTimer();
}

// MARK: Clock

let ticker = null;
function schedule() {
  if (engine.isRunning && !ticker) {
    ticker = setInterval(() => {
      const t = engine.tick(Date.now());
      if (t) { handle(t); persistTimer(); schedule(); }
      renderTimer();
    }, 250);
  } else if (!engine.isRunning && ticker) {
    clearInterval(ticker);
    ticker = null;
  }
}

// MARK: Rendering

let lastBoil = -1;
function renderTimer() {
  const now = Date.now();
  const boiling = engine.isRunning && !reduceMotion.matches;
  const tick = boiling ? Math.floor(now / BOIL_MS) : 0;

  $("status").textContent = statusWord() || " ";
  const text = clock(engine.remaining(now));
  if ($("clock").textContent !== text) $("clock").textContent = text;
  document.title = engine.isIdle ? "drill" : `${text} · ${statusWord()}`;

  const toggleLabel = engine.isRunning ? "pause" : engine.isIdle ? "start" : "resume";
  $("toggle").textContent = toggleLabel;
  $("reset").hidden = engine.isIdle;

  const dots = $("dots");
  if (dots.children.length !== engine.config.longBreakEvery) {
    dots.replaceChildren(...[...Array(engine.config.longBreakEvery)].map(() => document.createElement("i")));
  }
  [...dots.children].forEach((d, i) => d.classList.toggle("on", i < engine.cyclePosition));

  if (tick !== lastBoil || !boiling) {
    lastBoil = tick;
    const r = ring(270, engine.progress(now), tick);
    const svg = $("ring");
    svg.querySelector(".track").setAttribute("d", r.track);
    svg.querySelector(".arc").setAttribute("d", r.arc);
    const tip = svg.querySelector(".tip");
    tip.style.display = r.tip ? "" : "none";
    if (r.tip) { tip.setAttribute("cx", r.tip[0]); tip.setAttribute("cy", r.tip[1]); }
    $("mark").querySelector("path").setAttribute("d", drill(22, tick));
  }
}

function renderTags() {
  const tags = store.tags(6);
  if (tagFilter && !tags.includes(tagFilter)) tagFilter = null;

  const current = $("tag").value.trim().toLowerCase();
  $("suggest").replaceChildren(...tags.filter((t) => t !== current).slice(0, 4).map((t) =>
    button(t, () => { $("tag").value = t; save(KEY.tag, t); renderTags(); })));

  $("filter").replaceChildren(
    button("all", () => { tagFilter = null; renderYear(); renderTags(); }, tagFilter === null),
    ...tags.map((t) => button(t, () => { tagFilter = t; renderYear(); renderTags(); }, tagFilter === t)));
}

function button(label, action, pressed) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = "link";
  b.textContent = label;
  if (pressed !== undefined) b.setAttribute("aria-pressed", String(pressed));
  b.addEventListener("click", action);
  return b;
}

/** A made-up year of focus for the demo, the same on every visit. */
let sample = null;
function sampleYear() {
  if (sample) return sample;
  let seed = 7;
  const next = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
  sample = [];
  for (let d = 1; d < 365; d++) {
    if (next() < 0.35) continue;
    const day = new Date();
    day.setHours(10, 0, 0, 0);
    day.setDate(day.getDate() - d);
    const blocks = 1 + Math.floor(next() * 6);
    sample.push({ startedAt: day.toISOString(), focusSeconds: blocks * 25 * 60 });
  }
  return sample;
}

// Heatmap geometry, as in HeatmapView.swift: the grid stretches to the width.
const GAP = 0.24, MONTH_ROW = 16, MARGIN = 3;
const INK = [0, 0.16, 0.36, 0.62, 0.92];
let heat = null, metrics = null;

function renderYear() {
  const svg = $("grid");
  const width = svg.clientWidth || 700;
  const weeks = width < 520 ? 26 : 53;
  const sessions = [...(demo && !tagFilter ? sampleYear() : []), ...store.live()]
    .filter((s) => !tagFilter || s.tag === tagFilter);
  heat = buildHeatmap(sessions, weeks);

  const pitch = (width - MARGIN * 2) / (weeks - GAP), size = pitch * (1 - GAP);
  const height = MONTH_ROW + 7 * pitch - (pitch - size) + MARGIN;
  metrics = { pitch, size };
  svg.setAttribute("viewBox", `${-MARGIN} 0 ${width} ${height}`);
  svg.style.height = `${height}px`;

  const ns = "http://www.w3.org/2000/svg";
  const el = (tag, attrs) => {
    const e = document.createElementNS(ns, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    return e;
  };
  const nodes = [];
  const today = new Date().setHours(0, 0, 0, 0);
  let lastMonth = -1;
  heat.weeks.forEach((week, w) => {
    const first = week.find(Boolean);
    if (first) {
      const d = new Date(first.date), month = d.getMonth();
      // Label a month at its first full column, not the half-column at the left edge.
      if (month !== lastMonth) {
        if (lastMonth !== -1 || d.getDate() <= 7) {
          const t = el("text", { x: w * pitch, y: 9, class: "month" });
          t.textContent = monthFormat.format(d).toLowerCase();
          nodes.push(t);
        }
        lastMonth = month;
      }
    }
    week.forEach((day, d) => {
      if (!day) return;
      const x = w * pitch, y = MONTH_ROW + d * pitch;
      const cell = el("path", { d: square(x, y, size, (w * 7 + d) * 31 + 7), class: "cell" });
      if (day.level > 0) cell.style.fill = `color-mix(in srgb, var(--accent) ${INK[day.level] * 100}%, transparent)`;
      nodes.push(cell);
      if (day.date === today) nodes.push(outline(x, y, "today"));
    });
  });
  nodes.push(outline(0, 0, "hover"));
  svg.replaceChildren(...nodes);
  renderHover();
}

function outline(x, y, className) {
  const { size } = metrics;
  const r = document.createElementNS("http://www.w3.org/2000/svg", "rect");
  for (const [k, v] of Object.entries({ x: x - 1.75, y: y - 1.75, width: size + 3.5, height: size + 3.5, rx: 3 })) {
    r.setAttribute(k, v);
  }
  r.setAttribute("class", className);
  return r;
}

/** Moves the hover outline and swaps the caption, without redrawing cells. */
function renderHover() {
  const box = $("grid").querySelector(".hover");
  if (box) {
    box.style.display = hovered ? "" : "none";
    if (hovered) {
      box.setAttribute("x", hovered.w * metrics.pitch - 1.75);
      box.setAttribute("y", MONTH_ROW + hovered.d * metrics.pitch - 1.75);
    }
  }
  renderCaption();
}

function renderCaption() {
  const cap = $("caption");
  if (hovered) {
    const d = el2("span", "date", dayFormat.format(new Date(hovered.date)).toLowerCase());
    cap.replaceChildren(d, document.createTextNode(" — "),
      document.createTextNode(hovered.seconds > 0 ? amount(hovered.seconds) : "nothing logged."));
    cap.style.gap = "6px";
    return;
  }
  cap.style.gap = "";
  const stat = (label, value) => {
    const s = el2("span", "", label);
    s.append(el2("b", "", value));
    return s;
  };
  const legend = el2("span", "legend", "less");
  INK.forEach((ink, i) => {
    const sq = document.createElement("i");
    if (i > 0) sq.style.background = `color-mix(in srgb, var(--accent) ${ink * 100}%, transparent)`;
    legend.append(sq);
  });
  legend.append("more");
  cap.replaceChildren(
    stat("today", amount(heat.today)),
    stat("this week", amount(heat.thisWeek)),
    stat("streak", heat.streak === 1 ? "1 day" : `${heat.streak} days`),
    legend);
}

function el2(tag, className, text) {
  const e = document.createElement(tag);
  if (className) e.className = className;
  e.textContent = text;
  return e;
}

function dayAt(event) {
  const svg = $("grid"), box = svg.getBoundingClientRect();
  const x = event.clientX - box.left - MARGIN, y = event.clientY - box.top - MONTH_ROW;
  const w = Math.floor(x / metrics.pitch), d = Math.floor(y / metrics.pitch);
  if (y < 0 || d > 6 || w < 0 || w >= heat.weeks.length || !heat.weeks[w][d]) return null;
  return { ...heat.weeks[w][d], w, d };
}

let lastSyncState = store.syncState;
let syncedFlash = null;

/** The header word, the settings row, and a brief "synced" after a sync. */
function renderSync() {
  const state = store.syncState, account = store.account;
  if (lastSyncState === "syncing" && state === "synced") {
    clearTimeout(syncedFlash);
    syncedFlash = setTimeout(() => { syncedFlash = null; renderSync(); }, 2000);
  }
  lastSyncState = state;
  $("sync").textContent = {
    signedOut: "sync", syncing: "syncing…", offline: "offline", unconfirmed: "confirm email",
    synced: syncedFlash ? "synced" : "sync",
  }[state];
  $("account-line").textContent = account?.email ?? "sync";
  $("account-action").textContent = account ? "sign out" : "sign in";
  $("sync-note").textContent = {
    signedOut: "sign in to keep your sessions on every device.",
    syncing: "syncing…",
    synced: "synced.",
    offline: "can't reach the server. sessions stay here until it's back.",
    unconfirmed: "confirm your email to start syncing. check your inbox.",
  }[state];
}

// MARK: Account dialog

let creating = false;

function openAccount() {
  creating = false;
  $("account-form").reset();
  renderAccount();
  $("account").showModal();
}

function renderAccount(error = "") {
  $("account-title").textContent = creating ? "create an account" : "sign in to sync";
  $("account-submit").textContent = creating ? "create" : "sign in";
  $("account-switch").textContent = creating ? "i have an account" : "create an account";
  $("password").autocomplete = creating ? "new-password" : "current-password";
  $("account-error").textContent = error;
}

async function submitAccount(e) {
  e.preventDefault();
  const button = $("account-submit");
  button.disabled = true;
  try {
    await store.signIn($("email").value, $("password").value, creating);
    $("account").close();
  } catch (err) {
    renderAccount(err.message);
  } finally {
    button.disabled = false;
  }
}

// MARK: Theme, sound, notifications

function applyTheme() {
  if (settings.theme === "auto") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = settings.theme;
}

let audio = null;
function chime(focusDone) {
  try {
    audio ??= new AudioContext();
    const notes = focusDone ? [880, 1318.5] : [659.3];
    notes.forEach((freq, i) => {
      const t = audio.currentTime + i * 0.16;
      const osc = audio.createOscillator(), gain = audio.createGain();
      osc.type = "sine";
      osc.frequency.value = freq;
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.18, t + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.9);
      osc.connect(gain).connect(audio.destination);
      osc.start(t);
      osc.stop(t + 1);
    });
  } catch {}
}

// Notifications need a secure context (https or localhost).
function askForNotifications() {
  if (!demo && "Notification" in window && isSecureContext && Notification.permission === "default") {
    Notification.requestPermission().catch(() => {});
  }
}

function notify(title, body) {
  if (!("Notification" in window) || Notification.permission !== "granted") return;
  if (document.visibilityState === "visible" && document.hasFocus()) return;
  try { new Notification(title, { body, icon: "icon.png", tag: "drill" }); } catch {}
}

// MARK: Inspo dialog

let inspoPage = "today";

function watchLink(video) {
  const a = Object.assign(document.createElement("a"), { href: video.url, target: "_blank", rel: "noopener" });
  a.addEventListener("click", () => { markWatched(video); renderInspo(); });
  return a;
}

function inspoRow(video, seen) {
  const a = watchLink(video);
  if (inspoPage === "all") {
    a.append(Object.assign(document.createElement("i"), { textContent: String(video.number).padStart(3, "0") }));
  }
  const text = document.createElement("div");
  text.append(Object.assign(document.createElement("b"), { textContent: video.title, className: seen.has(video.id) ? "on" : "" }),
    Object.assign(document.createElement("span"), { textContent: video.japanese }));
  a.append(text);
  const li = document.createElement("li");
  li.append(a);
  return li;
}

/** Today's handful, or every video with the watched ones filled in. */
function renderInspo() {
  const seen = watched();
  const all = inspoPage === "all";
  $("inspo").dataset.page = inspoPage;
  for (const b of document.querySelectorAll(".inspo-head .link")) {
    b.setAttribute("aria-pressed", String(b.dataset.page === inspoPage));
  }
  $("inspo-all").hidden = !all;
  if (all) {
    $("inspo-squares").replaceChildren(...VIDEOS.map((v) => {
      const a = watchLink(v);
      a.title = `${v.number}. ${v.title}`;
      a.classList.toggle("on", seen.has(v.id));
      return a;
    }));
    $("inspo-count").textContent = `${seen.size} of ${VIDEOS.length} watched`;
  }
  $("inspo-list").replaceChildren(...(all ? VIDEOS : inspoToday(watchedBefore())).map((v) => inspoRow(v, seen)));
}

// MARK: Settings dialog

function openSettings() {
  const c = settings.config;
  $("focus").value = c.focus / 60;
  $("shortBreak").value = c.shortBreak / 60;
  $("longBreak").value = c.longBreak / 60;
  $("longBreakEvery").value = c.longBreakEvery;
  $("autoStartBreaks").checked = c.autoStartBreaks;
  $("autoStartFocus").checked = c.autoStartFocus;
  $("sound").checked = settings.sound;
  markTheme();
  renderSync();
  $("settings").showModal();
}

function markTheme() {
  for (const b of $("theme").children) b.setAttribute("aria-checked", String(b.value === settings.theme));
}

function saveSettings() {
  const clamp = (id, min, max) => {
    const n = Math.round(Number($(id).value));
    return Math.min(max, Math.max(min, Number.isFinite(n) && n > 0 ? n : min));
  };
  settings.config = {
    ...settings.config,
    focus: clamp("focus", 1, 120) * 60,
    shortBreak: clamp("shortBreak", 1, 30) * 60,
    longBreak: clamp("longBreak", 1, 60) * 60,
    longBreakEvery: clamp("longBreakEvery", 2, 8),
    autoStartBreaks: $("autoStartBreaks").checked,
    autoStartFocus: $("autoStartFocus").checked,
  };
  settings.sound = $("sound").checked;
  engine.config = settings.config;
  save(KEY.settings, settings);
  changed();
}

// MARK: Wiring

$("toggle").addEventListener("click", toggle);
$("skip").addEventListener("click", skip);
$("reset").addEventListener("click", reset);
$("open-settings").addEventListener("click", openSettings);
$("open-inspo").addEventListener("click", () => {
  inspoPage = "today";
  renderInspo();
  $("inspo").showModal();
  document.activeElement.blur(); // open quietly, without a ring on the first video
});
$("inspo").addEventListener("click", (e) => {
  if (e.target === e.currentTarget) return e.currentTarget.close();
  if (!e.target.dataset.page) return;
  inspoPage = e.target.dataset.page;
  renderInspo();
});

const tagInput = $("tag");
tagInput.value = load(KEY.tag, "");
tagInput.addEventListener("input", () => { save(KEY.tag, tagInput.value); renderTags(); });
tagInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter" || e.key === "Escape") tagInput.blur();
});

document.addEventListener("keydown", (e) => {
  if (e.key !== " " || e.repeat || e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.target.closest?.("input, button, dialog")) return;
  e.preventDefault();
  toggle();
});

const dialog = $("settings");
dialog.addEventListener("change", saveSettings);
dialog.addEventListener("close", saveSettings);
dialog.addEventListener("click", (e) => { if (e.target === dialog) dialog.close(); });
$("theme").addEventListener("click", (e) => {
  if (!e.target.value) return;
  settings.theme = e.target.value;
  save(KEY.settings, settings);
  markTheme();
  applyTheme();
});
$("sync").addEventListener("click", () => (store.account ? store.sync() : openAccount()));
$("account-action").addEventListener("click", () => {
  if (store.account) return store.signOut();
  $("settings").close();
  openAccount();
});
$("account-switch").addEventListener("click", () => { creating = !creating; renderAccount(); });
$("account-form").addEventListener("submit", submitAccount);
$("account").addEventListener("click", (e) => { if (e.target === e.currentTarget) e.currentTarget.close(); });

const grid = $("grid");
grid.addEventListener("pointermove", (e) => {
  const day = dayAt(e);
  if (day?.date === hovered?.date) return;
  hovered = day;
  renderHover();
});
grid.addEventListener("pointerleave", () => { hovered = null; renderHover(); });
new ResizeObserver(() => renderYear()).observe(grid);

store.addEventListener("change", () => { renderTags(); renderYear(); });
store.addEventListener("sync", renderSync);

// Another tab started, paused or finished the timer.
addEventListener("storage", (e) => {
  if (e.key !== KEY.timer) return;
  saved = load(KEY.timer, null);
  if (saved) Object.assign(engine, saved.engine);
  blockTag = saved?.blockTag ?? null;
  schedule();
  renderTimer();
});

// Catch up on sessions from other devices now and then, and whenever the
// tab comes back.
setInterval(() => store.sync(), 60_000);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") { store.sync(); renderTimer(); }
});
// Day rollover and relative stats.
setInterval(() => renderYear(), 5 * 60_000);

applyTheme();
// A phase may have ended while the tab was closed.
const missed = engine.tick(Date.now());
if (missed) handle(missed);
changed();
renderTags();
renderYear();
renderSync();
if (!demo) store.sync();
