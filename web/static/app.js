import { Engine, Phase, defaultConfig, isBreak } from "./engine.js";
import { buildHeatmap, firstWeekday } from "./heatmap.js";
import { BOIL_MS, glyph, ring, square } from "./ink.js";
import { IntervalEngine, IntervalPhase, defaultIntervalConfig } from "./intervals.js";
import { createPalette } from "./palette.js";
import { VIDEOS, markWatched, today as inspoToday, watched, watchedBefore } from "./inspo.js";
import { SAMPLE_TAGS, sampleYear } from "./sample.js";
import { chime, wakeAudio } from "./sound.js";
import { Store } from "./store.js";
import { USERNAME, cleanUsername, usernameAvailable } from "./supabase.js";

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

const settings = { sound: true, autoSync: true, ...load(KEY.settings, {}) };
// Dark unless picked; the site's demo starts in the visitor's own mode.
// Old "auto" choices fall back the same way.
if (!["light", "dark"].includes(settings.theme)) {
  settings.theme = demo && matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
}
settings.config = { ...defaultConfig, ...settings.config };
settings.intervals = { ...defaultIntervalConfig, ...settings.intervals };
if (!["pomodoro", "intervals"].includes(settings.mode)) settings.mode = "pomodoro";

const store = new Store({ offline: demo });
store.autoSync = settings.autoSync;
const saved = load(KEY.timer, null);
const engine = new Engine(settings.config, saved?.engine);
const intervals = new IntervalEngine(settings.intervals, saved?.intervals);
/** "pomodoro" or "intervals": which timer the face shows. Only one can be
 *  off idle at a time, since the switch waits for idle. */
let mode = settings.mode;
const inIntervals = () => mode === "intervals";
const timer = () => (inIntervals() ? intervals : engine);
/** The tag in effect for the running focus block, captured when it starts. */
let blockTag = saved?.blockTag ?? null;
let tagFilter = null;
let hovered = null;

function persistTimer() {
  save(KEY.timer, { engine: engine.state, intervals: intervals.state, blockTag });
}

/** Both timers, as another tab or the lock holder last saved them. */
function restoreTimer(stored) {
  if (!stored) return;
  if (stored.engine) Object.assign(engine, stored.engine);
  if (stored.intervals) Object.assign(intervals, stored.intervals);
  blockTag = stored.blockTag ?? null;
}

// MARK: Copy (DrillApp/Copy.swift)

const PHASE_NAME = { focus: "focus", shortBreak: "break", longBreak: "long break" };

/** "focus" / "break", or "run" / "walk" in interval mode. */
const phaseName = () => (inIntervals() ? intervals.phase : PHASE_NAME[engine.phase]);

function statusWord() {
  const t = timer();
  if (t.isIdle) return inIntervals() || engine.phase === Phase.focus ? "" : PHASE_NAME[engine.phase];
  if (!t.isRunning) return "paused";
  return phaseName();
}

/** What a screen reader says for the countdown: "focus, 12 minutes left". */
function spoken(ms) {
  const t = timer();
  const total = Math.ceil(ms / 1000);
  const m = Math.ceil(total / 60);
  const left = total >= 60 ? (m === 1 ? "1 minute left" : `${m} minutes left`)
    : total === 1 ? "1 second left" : `${total} seconds left`;
  return `${phaseName()}${!t.isIdle && !t.isRunning ? ", paused" : ""}, ${left}`;
}

/** The banner when a phase runs out, as in Copy.finished. */
function finished(phase, next) {
  if (phase !== Phase.focus) return ["break over", "back to focus"];
  return ["focus done", `take a break · ${Math.max(1, Math.round(engine.config[next] / 60))} min`];
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
  const t = timer(), starting = t.isIdle;
  t.toggle(Date.now());
  if (starting) {
    askForNotifications();
    if (!inIntervals() && engine.phase === Phase.focus) captureTag();
  }
  if (settings.sound) wakeAudio();
  changed();
}

function skip() {
  if (inIntervals()) cue(intervals.skip(Date.now()));
  else handle(engine.skip(Date.now()));
  changed();
}

/** "reset" on the pomodoro; "done" (stop and log the workout) on intervals. */
function reset() {
  if (inIntervals()) {
    const record = intervals.stop(Date.now());
    if (record) logWorkout(record);
  } else {
    const record = engine.reset(Date.now());
    if (record) store.log(record, blockTag);
  }
  changed();
}

/** A workout is an ordinary completed session tagged "intervals". */
function logWorkout({ startedAt, endedAt, seconds }) {
  const s = Math.round(seconds);
  store.log({ startedAt, endedAt, focusSeconds: s, plannedSeconds: s, completed: true }, "intervals");
}

/** Switches the face between the pomodoro and intervals, while idle. */
function switchMode(to = inIntervals() ? "pomodoro" : "intervals") {
  if (to === mode || !timer().isIdle) return;
  mode = settings.mode = to;
  save(KEY.settings, settings);
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
  const [title, body] = finished(t.finished, t.next);
  // Offer the next phase when it won't start by itself.
  notify(title, body, engine.isRunning ? null : t.next);
  if (settings.sound) chime(t.finished === Phase.focus);
}

/** The cues at an interval end, natural or skipped: a buzz where the device
 *  can, the chime, and a banner for a backgrounded tab. */
function cue(t) {
  if (!t) return;
  const toRun = t.next === IntervalPhase.run;
  const pulses = toRun ? [400, 150, 400] : [250];
  try { navigator.vibrate?.(pulses); } catch {}
  if (settings.sound) chime(toRun);
  notify(toRun ? `run · round ${t.round}` : "walk",
    `${Math.max(1, Math.round(intervals.config[t.next] / 60))} min`, null, pulses);
}

function changed() {
  persistTimer();
  schedule();
  renderTimer();
}

// MARK: Clock

/** Moves the timer on, in one tab only: with several open, the first to get
 *  the lock takes the transition, and the rest pick up its saved state, so
 *  a phase end chimes, notifies and logs once. */
function advance() {
  let ran = false;
  const run = () => {
    ran = true;
    restoreTimer(load(KEY.timer, null));
    const now = Date.now();
    const t = engine.tick(now), it = intervals.tick(now);
    if (t || it) {
      // Saved first, so a throw below can't leave the phase to end, and log, again.
      persistTimer();
      if (t) handle(t);
      // Several interval ends while asleep cue once, for the latest.
      if (it) cue(it);
      persistTimer();
    }
    schedule();
    renderTimer();
  };
  if (typeof navigator.locks?.request !== "function") return Promise.resolve(run());
  // Run without the lock only when the lock itself failed (say a SecurityError),
  // never a second time because run threw.
  return navigator.locks.request("drill.timer", run).catch((err) => {
    if (ran) throw err;
    run();
  });
}

const visible = () => document.visibilityState === "visible";

// While visible: a wakeup as each displayed second turns over, plus the
// ink's boil. While hidden, the browser throttles timers anyway, so it's one
// wakeup a minute for the tab title, or at the phase end if that's sooner.
let ticker = null, boiler = null;
function schedule() {
  clearTimeout(ticker);
  ticker = null;
  const t = timer();
  if (t.isRunning) {
    const left = t.status.endsAt - Date.now();
    // +5ms lands just past the boundary, so the clock has already turned.
    const wait = visible() ? (left % 1000 || 1000) + 5 : Math.min(left, left % 60_000 || 60_000) + 5;
    ticker = setTimeout(advance, Math.max(5, wait));
  }
  const boil = t.isRunning && visible() && !reduceMotion.matches;
  if (boil && !boiler) boiler = setInterval(renderRing, BOIL_MS);
  else if (!boil && boiler) { clearInterval(boiler); boiler = null; }
}

// MARK: Rendering

const view = {
  status: $("status"), clock: $("clock"), toggle: $("toggle"), reset: $("reset"), dots: $("dots"),
  mark: $("mark"), glyph: $("glyph"), round: $("round"), tagBox: $("tag-box"),
  track: $("ring").querySelector(".track"), arc: $("ring").querySelector(".arc"),
  tip: $("ring").querySelector(".tip"),
};
const MARK = 20;
const shown = {};
/** Writes to the page only what changed since the last render. */
function put(key, value, write) {
  if (shown[key] === value) return;
  shown[key] = value;
  write(value);
}

function renderTimer() {
  const t = timer(), now = Date.now(), left = t.remaining(now);
  const text = clock(left);
  // A background tab shows only its title, and that in minutes: it's
  // redrawn once a minute there.
  put("title", t.isIdle ? "drill" : visible() ? `${text} · ${statusWord()}`
    : `${Math.ceil(left / 60_000)} min · ${statusWord()}`, (v) => { document.title = v; });
  if (!visible()) return;

  put("status", statusWord() || "\u00a0", (v) => { view.status.textContent = v; });
  put("clock", text, (v) => { view.clock.textContent = v; });
  put("spoken", spoken(left), (v) => view.clock.setAttribute("aria-label", v));
  put("switch", t.isIdle, (v) => view.clock.classList.toggle("switch-mode", v));
  put("toggle", t.isRunning ? "pause" : t.isIdle ? "start" : "resume",
      (v) => { view.toggle.textContent = v; });
  put("reset", t.isIdle, (v) => { view.reset.hidden = v; });
  put("resetWord", inIntervals() ? "done" : "reset", (v) => { view.reset.textContent = v; });
  put("mode", mode, (v) => {
    const on = v === "intervals";
    view.dots.hidden = on;
    view.mark.hidden = !on;
    view.tagBox.hidden = on;
  });
  put("round", inIntervals() && !t.isIdle ? `round ${intervals.round} · ${amount(intervals.elapsed(now) / 1000)}` : "",
      (v) => { view.round.textContent = v; });
  put("dots", `${engine.config.longBreakEvery}:${engine.cyclePosition}`, () => {
    const dots = view.dots;
    if (dots.children.length !== engine.config.longBreakEvery) {
      dots.replaceChildren(...[...Array(engine.config.longBreakEvery)].map(() => document.createElement("i")));
    }
    [...dots.children].forEach((d, i) => d.classList.toggle("on", i < engine.cyclePosition));
  });
  renderRing();
}

/** The ring. Boiling, it's redrawn every boil step; still,
 *  only when the arc would visibly move. */
function renderRing() {
  const t = timer(), now = Date.now();
  const boiling = t.isRunning && !reduceMotion.matches;
  const tick = boiling ? Math.floor(now / BOIL_MS) : 0;
  const progress = t.progress(now);
  put("ring", `${tick}:${Math.round(progress * 720)}`, () => {
    const r = ring(270, progress, tick);
    view.track.setAttribute("d", r.track);
    view.arc.setAttribute("d", r.arc);
    view.tip.style.display = r.tip ? "" : "none";
    if (r.tip) { view.tip.setAttribute("cx", r.tip[0]); view.tip.setAttribute("cy", r.tip[1]); }
  });
  if (!inIntervals()) return;
  // The runner on a run (and at rest, since a run comes first), the sneaker on a walk.
  const kind = intervals.phase === IntervalPhase.walk ? "sneaker" : "runner";
  put("glyph", `${kind}:${tick}`, () => {
    view.glyph.replaceChildren(...glyph(kind, MARK, tick).map((d) => svgEl("path", { d })));
  });
}

/** Tags to offer, most recent first; the demo's sample classes come after yours. */
function tagList() {
  const tags = store.tags(6);
  if (demo) for (const t of SAMPLE_TAGS) if (!tags.includes(t) && tags.length < 6) tags.push(t);
  return tags;
}

let filterTags = null, tagsDrawn = null;
/** The suggestions under the field and the tabs over the year. Skipped
 *  when neither the tags, the filter nor the field changed. */
function renderTags() {
  const tags = tagList();
  if (tagFilter && !tags.includes(tagFilter)) tagFilter = null;

  const current = $("tag").value.trim().toLowerCase();
  const key = JSON.stringify([tags, tagFilter, current]);
  if (key === tagsDrawn) return;
  tagsDrawn = key;
  $("suggest").replaceChildren(...tags.filter((t) => t !== current).slice(0, 4).map((t) =>
    button(t, () => setTag(t))));

  const filter = $("filter");
  if (String(tags) !== String(filterTags)) {
    filterTags = tags;
    filter.replaceChildren(button("all", () => showTag(null)), ...tags.map((t) => button(t, () => showTag(t))));
  }
  const buttons = [...filter.querySelectorAll(".link")];
  buttons.forEach((b, i) => b.setAttribute("aria-pressed", String((i === 0 ? null : tags[i - 1]) === tagFilter)));
  const on = buttons[tagFilter === null ? 0 : tags.indexOf(tagFilter) + 1];
  fadeEdge();
  // A chosen tab under a faded edge slides to the middle of the row. Only
  // the row scrolls, never the page around it.
  const fade = 24, left = filter.scrollLeft, right = left + filter.clientWidth;
  if (filter.scrollWidth > filter.clientWidth &&
      (on.offsetLeft + on.offsetWidth > right - fade || on.offsetLeft < left + fade)) {
    filter.scrollTo({ left: on.offsetLeft + on.offsetWidth / 2 - filter.clientWidth / 2,
                      behavior: reduceMotion.matches ? "auto" : "smooth" });
  }
}

function setTag(t) {
  $("tag").value = t;
  save(KEY.tag, t);
  renderTags();
}

/** Filters the year to one tag, or all with null. */
function showTag(t) {
  if (tagFilter === t) return;
  tagFilter = t;
  renderYear(true);
  renderTags();
}

function fadeEdge() {
  const filter = $("filter");
  filter.classList.toggle("more-left", filter.scrollLeft > 1);
  filter.classList.toggle("more-right", filter.scrollLeft + filter.clientWidth < filter.scrollWidth - 1);
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

// Heatmap geometry, as in HeatmapView.swift: the grid stretches to the width.
const GAP = 0.24, MONTH_ROW = 16, MARGIN = 3;
const INK = [0, 0.16, 0.36, 0.62, 0.92];
let heat = null, metrics = null;

let cells = [], drawn = "";
const weekStart = firstWeekday();

const cellFill = (level) =>
  level > 0 ? `color-mix(in srgb, var(--accent) ${INK[level] * 100}%, transparent)` : "var(--wash)";

/** Draws the year. With `fade` (a new tab), the same grid stays and only
 *  the colours change, so cells fade from one subject to the next. */
function renderYear(fade = false) {
  const svg = $("grid");
  const width = svg.clientWidth || 700;
  const weeks = width < 520 ? 26 : 53;
  const sessions = [...(demo ? sampleYear() : []), ...store.live()]
    .filter((s) => !tagFilter || s.tag === tagFilter);
  heat = buildHeatmap(sessions, weeks, Date.now(), weekStart);

  const shape = `${width}:${weeks}:${new Date().toDateString()}`;
  if (shape === drawn && cells.length) {
    heat.weeks.flat().filter(Boolean).forEach((day, i) => { cells[i].style.fill = cellFill(day.level); });
    if (fade && !reduceMotion.matches) $("caption").animate([{ opacity: 0.2 }, { opacity: 1 }], { duration: 420, easing: "ease-out" });
    renderHover();
    return;
  }
  drawn = shape;
  cells = [];

  const pitch = (width - MARGIN * 2) / (weeks - GAP), size = pitch * (1 - GAP);
  const height = MONTH_ROW + 7 * pitch - (pitch - size) + MARGIN;
  metrics = { pitch, size };
  svg.setAttribute("viewBox", `${-MARGIN} 0 ${width} ${height}`);
  svg.style.height = `${height}px`;

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
          const t = svgEl("text", { x: w * pitch, y: 9, class: "month" });
          t.textContent = monthFormat.format(d).toLowerCase();
          nodes.push(t);
        }
        lastMonth = month;
      }
    }
    week.forEach((day, d) => {
      if (!day) return;
      const x = w * pitch, y = MONTH_ROW + d * pitch;
      const cell = svgEl("path", { d: square(x, y, size, (w * 7 + d) * 31 + 7), class: "cell" });
      cell.style.fill = cellFill(day.level);
      // A gentle left-to-right wave when a tab changes the colours.
      cell.style.transitionDelay = `${Math.round(w / weeks * 180)}ms`;
      nodes.push(cell);
      cells.push(cell);
      if (day.date === today) nodes.push(outline(x, y, "today"));
    });
  });
  nodes.push(outline(0, 0, "hover"));
  svg.replaceChildren(...nodes);
  renderHover();
}

function svgEl(tag, attrs) {
  const e = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  return e;
}

function outline(x, y, className) {
  const { size } = metrics;
  return svgEl("rect", { x: x - 1.75, y: y - 1.75, width: size + 3.5, height: size + 3.5, rx: 3, class: className });
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
    const d = htmlEl("span", "date", dayFormat.format(new Date(hovered.date)).toLowerCase());
    cap.replaceChildren(d, document.createTextNode(" — "),
      document.createTextNode(hovered.seconds > 0 ? amount(hovered.seconds) : "nothing logged."));
    cap.style.gap = "6px";
    return;
  }
  cap.style.gap = "";
  const stat = (label, value) => {
    const s = htmlEl("span", "", label);
    s.append(htmlEl("b", "", value));
    return s;
  };
  const legend = htmlEl("span", "legend", "less");
  INK.forEach((_, i) => {
    const sq = document.createElement("i");
    if (i > 0) sq.style.background = cellFill(i);
    legend.append(sq);
  });
  legend.append("more");
  const streak = heat.streak === 1 ? "1 day" : `${heat.streak} days`;
  cap.replaceChildren(
    stat("today", amount(heat.today)),
    stat("this week", amount(heat.thisWeek)),
    stat("streak", streak),
    legend);
  $("grid").setAttribute("aria-label", `your year${tagFilter ? `, ${tagFilter}` : ""}: ` +
    `today ${amount(heat.today)}, this week ${amount(heat.thisWeek)}, streak ${streak}`);
}

function htmlEl(tag, className, text) {
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

/** The header link, shown only while there's something to push, and the
 *  settings rows. Copy as in the mac's MainView and AccountRow. */
function renderSync() {
  const state = store.syncState, account = store.account;
  $("sync").hidden = !account || state === "syncing" || store.unpushed() === 0;
  $("sync").textContent = state === "offline" ? "offline" : "sync";
  $("auto-sync-row").hidden = !account;
  $("account-line").textContent = account?.username ?? "sync";
  $("account-action").textContent = account ? "sign out" : "sign in";
  $("sync-note").textContent = {
    signedOut: "sign in to sync across devices.",
    syncing: "syncing…",
    synced: "synced.",
    offline: "offline. your sessions are safe here.",
  }[state];
  if ($("account").open) renderAccount();
  syncLoop();
}

// MARK: Account dialog (AccountSheet.swift)

let creating = false, working = false, problem = "";
/** The live check on the create form: { name, state } with state one of
 *  checking | available | taken, or null when there's nothing to say. */
let availability = null, checkTimer = null;

function openAccount() {
  creating = false;
  problem = "";
  availability = null;
  clearTimeout(checkTimer);
  $("account-form").reset();
  renderAccount();
  $("account").showModal();
  $("username").focus();
  // Autofill can fill the fields without an input event (Safari): look again.
  requestAnimationFrame(() => renderAccount());
}

const username = () => $("username").value;
const validName = () => USERNAME.test(username());

/** Lowercases and drops spaces as you type, keeping the caret in place. */
function tidyUsername() {
  const field = $("username"), was = field.value, clean = cleanUsername(was);
  if (clean === was) return;
  const at = field.selectionStart ?? was.length;
  const caret = cleanUsername(was.slice(0, at)).length;
  field.value = clean;
  field.setSelectionRange(caret, caret);
}

/** 300ms after the last keystroke on the create form, asks whether the name
 *  is free. A reply for a name no longer in the field is ignored. */
function scheduleCheck() {
  clearTimeout(checkTimer);
  const name = username();
  if (!creating || !validName()) { availability = null; return; }
  if (availability?.name === name) return;
  availability = { name, state: "checking" };
  checkTimer = setTimeout(async () => {
    let state = null; // no answer: the mark clears, and "create" waits for the next try
    try { state = (await usernameAvailable(name)) ? "available" : "taken"; } catch {}
    if (username() !== name || !creating) return;
    availability = state && { name, state };
    renderAccount();
  }, 300);
}

function renderAccount() {
  const name = username(), password = $("password").value, confirm = $("confirm").value;
  const state = creating && availability?.name === name ? availability.state : null;
  const ready = creating
    ? state === "available" && password.length >= 8 && confirm === password
    : validName() && password.length >= 8;
  $("account-title").textContent = creating ? "make an account" : "sign in";
  $("account-submit").textContent = creating ? "create account" : "sign in";
  $("account-submit").disabled = !ready || working;
  $("account-switch").textContent = creating ? "have an account?" : "new here?";
  $("password").autocomplete = creating ? "new-password" : "current-password";
  $("confirm").hidden = $("confirm-hint").hidden = !creating;
  $("confirm-hint").textContent = creating && password && confirm && confirm !== password ? "passwords don't match" : "";
  $("account-error").textContent = problem || (creating ? "password needs 8+ characters." : " ");
  $("username-hint").textContent = creating && name && !validName() ? "3–20 letters, digits or _"
    : state === "taken" ? "taken" : "";

  // The mark at the field's edge: the working arc, a green check or a red cross.
  const mark = $("username-mark");
  mark.toggleAttribute("hidden", !state); // an <svg> has no .hidden
  if (state && mark.dataset.state !== state) {
    mark.dataset.state = state;
    const [kind, className] = { checking: ["working", "checking"], available: ["check", "ok"], taken: ["cross", "taken"] }[state];
    mark.setAttribute("class", `field-mark ${className}`);
    mark.replaceChildren(...glyph(kind, 14, 0).map((d) => svgEl("path", { d })));
  }
}

/** Runs one call at a time, and shows what went wrong. */
async function run(work) {
  if (working) return;
  working = true;
  problem = "";
  renderAccount();
  try {
    await work();
  } catch (err) {
    problem = err.message || "something went wrong. try again.";
  }
  working = false;
  renderAccount();
}

function submitAccount(e) {
  e.preventDefault();
  renderAccount(); // autofilled fields may not have said so yet
  if ($("account-submit").disabled) return;
  run(async () => {
    await store.signIn(username(), $("password").value, creating);
    $("account").close();
  });
}

// MARK: Theme, notifications

function applyTheme() {
  document.documentElement.dataset.theme = settings.theme;
  for (const meta of document.querySelectorAll('meta[name="theme-color"]')) {
    meta.content = settings.theme === "light" ? "#F2F0ED" : "#121211";
  }
}

// Notifications need a secure context (https or localhost).
function askForNotifications() {
  if (!demo && "Notification" in window && isSecureContext && Notification.permission === "default") {
    Notification.requestPermission().catch(() => {});
  }
}

/** Shows the banner through the service worker where there is one (the only
 *  way on Android Chrome), with "start break" / "start focus" when `next`
 *  won't start by itself; else the plain kind. `vibrate` is a pulse pattern
 *  for phones that buzz with a banner. */
async function notify(title, body, next, vibrate = null) {
  if (!("Notification" in window) || Notification.permission !== "granted") return;
  if (visible() && document.hasFocus()) return;
  const options = { body, icon: "icon-192.png", tag: "drill", renotify: true };
  if (vibrate) options.vibrate = vibrate;
  try {
    const sw = await navigator.serviceWorker?.getRegistration();
    if (sw) {
      if (next) {
        options.actions = [{ action: "start", title: isBreak(next) ? "start break" : "start focus" }];
        options.data = { next };
      }
      return await sw.showNotification(title, options);
    }
  } catch {}
  try { new Notification(title, options); } catch {}
}

/** The banner's start button names the phase it offered: start only if the
 *  timer is idle on that phase, never resume or start another. */
function startFromBanner(next) {
  if (!inIntervals() && engine.isIdle && engine.phase === next) toggle();
}

function registerWorker() {
  if (demo || !("serviceWorker" in navigator) || !isSecureContext) return;
  navigator.serviceWorker.register("sw.js").catch(() => {});
  navigator.serviceWorker.addEventListener("message", (e) => {
    if (e.data?.start) startFromBanner(e.data.start);
  });
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
  $("run").value = settings.intervals.run / 60;
  $("walk").value = settings.intervals.walk / 60;
  $("autoStartBreaks").checked = c.autoStartBreaks;
  $("autoStartFocus").checked = c.autoStartFocus;
  $("sound").checked = settings.sound;
  $("autoSync").checked = settings.autoSync;
  markTheme();
  renderSync();
  $("settings").showModal();
}

function markTheme() {
  for (const b of $("theme").children) {
    const on = b.value === settings.theme;
    b.setAttribute("aria-checked", String(on));
    b.tabIndex = on ? 0 : -1; // one stop for the group; arrows move within it
  }
}

function pickTheme(theme) {
  settings.theme = theme;
  save(KEY.settings, settings);
  markTheme();
  applyTheme();
}

function saveSettings() {
  // The mac's steppers: focus 5–120 and long breaks 5–60 in fives.
  const clamp = (id, min, max, step = 1) => {
    const n = Math.round(Number($(id).value) / step) * step;
    return Math.min(max, Math.max(min, Number.isFinite(n) && n > 0 ? n : min));
  };
  settings.config = {
    ...settings.config,
    focus: clamp("focus", 5, 120, 5) * 60,
    shortBreak: clamp("shortBreak", 1, 30) * 60,
    longBreak: clamp("longBreak", 5, 60, 5) * 60,
    longBreakEvery: clamp("longBreakEvery", 2, 8),
    autoStartBreaks: $("autoStartBreaks").checked,
    autoStartFocus: $("autoStartFocus").checked,
  };
  settings.intervals = { run: clamp("run", 1, 60) * 60, walk: clamp("walk", 1, 60) * 60 };
  settings.sound = $("sound").checked;
  engine.config = settings.config;
  intervals.config = settings.intervals;
  changed();
  setAutoSync($("autoSync").checked);
}

/** Saves the settings too. */
function setAutoSync(on) {
  const resumed = on && !settings.autoSync;
  settings.autoSync = store.autoSync = on;
  save(KEY.settings, settings);
  syncLoop();
  if (resumed) store.sync();
}

function openInspo() {
  inspoPage = "today";
  renderInspo();
  $("inspo").showModal();
  document.activeElement.blur(); // open quietly, without a ring on the first video
}

// MARK: Command palette

/** What the palette offers right now, in the order of the spec. */
function commands(query) {
  const account = !demo && !!store.account, t = timer();
  const tags = tagList();
  const typed = query.trim().toLowerCase().slice(0, 40);
  return [
    { id: "toggle", title: t.isRunning ? "pause" : t.isIdle ? "start" : "resume",
      keywords: ["timer"], hint: "space", run: toggle },
    { id: "skip", title: "skip", keywords: ["timer"], run: skip },
    !t.isIdle && { id: "reset", title: inIntervals() ? "done" : "reset", keywords: ["timer"], run: reset },
    t.isIdle && { id: "mode", title: inIntervals() ? "switch to pomodoro" : "switch to intervals",
                  keywords: ["mode", "timer", "run", "walk"], run: () => switchMode() },
    { id: "settings", title: "open settings", keywords: ["preferences"], run: openSettings },
    { id: "inspo", title: "open inspo", keywords: ["videos"], run: openInspo },
    account && { id: "sync", title: "sync now", run: () => store.sync() },
    account && { id: "autoSync", title: settings.autoSync ? "turn auto sync off" : "turn auto sync on",
                 keywords: ["sync"], run: () => setAutoSync(!settings.autoSync) },
    ...tags.map((t) => ({ id: `tag:${t}`, title: `studying ${t}`, keywords: ["tag"], run: () => setTag(t) })),
    { id: "show:", title: "show all", keywords: ["filter"], run: () => showTag(null) },
    ...tags.map((t) => ({ id: `show:${t}`, title: `show ${t}`, keywords: ["filter"], run: () => showTag(t) })),
    typed && !tags.includes(typed) && { id: "tag", title: `studying "${typed}"`, last: true, run: () => setTag(typed) },
  ].filter(Boolean);
}

// MARK: Wiring

$("toggle").addEventListener("click", toggle);
$("skip").addEventListener("click", skip);
$("reset").addEventListener("click", reset);
// The clock is the mode switch, while idle.
$("clock").addEventListener("click", () => switchMode());
$("open-settings").addEventListener("click", openSettings);
$("open-inspo").addEventListener("click", openInspo);
$("inspo").addEventListener("click", (e) => {
  if (e.target === e.currentTarget) return e.currentTarget.close();
  if (!e.target.dataset.page) return;
  inspoPage = e.target.dataset.page;
  renderInspo();
});

$("filter").addEventListener("scroll", fadeEdge, { passive: true });

const tagInput = $("tag");
tagInput.value = load(KEY.tag, "");
tagInput.addEventListener("input", () => { save(KEY.tag, tagInput.value); renderTags(); });
tagInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter" || e.key === "Escape") tagInput.blur();
});

// Space, or a plain Enter, starts and pauses, unless you're typing or on a
// button, which has its own.
document.addEventListener("keydown", (e) => {
  if ((e.key !== " " && e.key !== "Enter") || e.repeat || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
  if (e.target.closest?.("input, textarea, select, button, a, dialog, [contenteditable]")) return;
  e.preventDefault();
  toggle();
});

const palette = createPalette($("palette"), commands);
document.addEventListener("keydown", (e) => {
  if (e.key?.toLowerCase() !== "k" || !(e.metaKey || e.ctrlKey) || e.altKey || e.shiftKey) return;
  // Not over another dialog.
  if ([...document.querySelectorAll("dialog[open]")].some((d) => d.id !== "palette")) return;
  e.preventDefault();
  palette.toggle();
});

const dialog = $("settings");
dialog.addEventListener("change", saveSettings);
dialog.addEventListener("close", saveSettings);
dialog.addEventListener("click", (e) => { if (e.target === dialog) dialog.close(); });
$("theme").addEventListener("click", (e) => {
  if (e.target.value) pickTheme(e.target.value);
});
$("theme").addEventListener("keydown", (e) => {
  if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(e.key)) return;
  e.preventDefault();
  pickTheme(settings.theme === "light" ? "dark" : "light");
  [...$("theme").children].find((b) => b.value === settings.theme).focus();
});
$("sync").addEventListener("click", () => store.sync());
$("account-action").addEventListener("click", () => {
  if (store.account) return store.signOut();
  $("settings").close();
  openAccount();
});
$("account-switch").addEventListener("click", () => {
  creating = !creating;
  problem = "";
  scheduleCheck();
  renderAccount();
});
$("account-form").addEventListener("submit", submitAccount);
$("account-form").addEventListener("input", (e) => {
  if (e.target.id === "username") { tidyUsername(); scheduleCheck(); }
  renderAccount();
});
$("account-form").addEventListener("change", () => renderAccount());
for (const b of $("account").querySelectorAll("[data-close]")) {
  b.addEventListener("click", () => $("account").close());
}
$("account").addEventListener("click", (e) => { if (e.target === e.currentTarget) e.currentTarget.close(); });

const grid = $("grid");
grid.addEventListener("pointermove", (e) => {
  const day = dayAt(e);
  if (day?.date === hovered?.date) return;
  hovered = day;
  renderHover();
});
grid.addEventListener("pointerleave", () => { hovered = null; renderHover(); });
// At most once a frame, however many resizes arrive.
let resizing = 0;
new ResizeObserver(() => {
  resizing ||= requestAnimationFrame(() => { resizing = 0; renderYear(); fadeEdge(); });
}).observe(grid);

store.addEventListener("change", () => { renderTags(); renderYear(); renderSync(); });
store.addEventListener("sync", renderSync);

// Another tab started, paused or finished the timer.
addEventListener("storage", (e) => {
  if (e.key !== KEY.timer) return;
  restoreTimer(load(KEY.timer, null));
  schedule();
  renderTimer();
});

// With auto sync: every five minutes while signed in and looking, never while
// the tab is hidden. Coming back syncs too, unless one started in the last 20s.
let syncTimer = null;
function syncLoop() {
  const on = !demo && settings.autoSync && !!store.account && visible();
  if (on && !syncTimer) syncTimer = setInterval(() => store.sync(), 5 * 60_000);
  else if (!on && syncTimer) { clearInterval(syncTimer); syncTimer = null; }
}

// The year turns over at midnight: one wakeup then, not a poll.
let midnight = null;
function scheduleMidnight() {
  clearTimeout(midnight);
  const next = new Date();
  next.setHours(24, 0, 1, 0);
  midnight = setTimeout(() => { renderYear(); scheduleMidnight(); }, next - Date.now());
}

document.addEventListener("visibilitychange", () => {
  if (visible()) {
    // Catch up: the phase may have ended, the day turned, or the computer slept.
    advance();
    renderYear();
    scheduleMidnight();
    if (!demo && settings.autoSync && store.account && Date.now() - store.lastStarted > 20_000) store.sync();
  } else {
    schedule();
    renderTimer();
  }
  syncLoop();
});
// Back from the back/forward cache, or the clock or time zone moved: redraw today.
addEventListener("pageshow", () => { renderYear(); scheduleMidnight(); });
addEventListener("focus", () => { advance(); renderYear(); });

applyTheme();
registerWorker();
// A block that ran out while the tab was closed is logged here, at its end.
const caughtUp = advance();
changed();
renderTags();
renderYear();
renderSync();
scheduleMidnight();
if (!demo && settings.autoSync) store.sync();
// Opened by a banner's start button when no tab was open.
const startParam = new URLSearchParams(location.search).get("start");
if (startParam) {
  history.replaceState(null, "", location.pathname);
  // After catching up, so the phase it offered can be the one that's next.
  caughtUp.finally(() => startFromBanner(startParam));
}
