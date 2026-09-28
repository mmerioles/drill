// The pomodoro state machine, ported from TetodoroCore/PomodoroEngine.swift.
// Time is passed in (epoch ms), so it never drifts and survives a closed tab:
// the host calls tick(now) as often as it likes and gets back a transition
// when a phase ends.

export const Phase = { focus: "focus", shortBreak: "shortBreak", longBreak: "longBreak" };
export const isBreak = (phase) => phase !== Phase.focus;

export const defaultConfig = {
  focus: 25 * 60,
  shortBreak: 5 * 60,
  longBreak: 15 * 60,
  longBreakEvery: 4,
  autoStartBreaks: true,
  autoStartFocus: false,
};

/** Cut-short focus blocks shorter than this aren't worth logging. */
const MINIMUM_LOGGABLE = 60;

export class Engine {
  constructor(config = defaultConfig, state = null) {
    this.config = { ...defaultConfig, ...config };
    this.phase = Phase.focus;
    // { kind: "idle" } | { kind: "running", endsAt } | { kind: "paused", remaining }
    this.status = { kind: "idle" };
    this.focusCount = 0;
    this.blockStartedAt = null;
    this.accrued = 0;
    this.runStartedAt = null;
    if (state) Object.assign(this, state);
  }

  /** Everything but the config, as plain JSON, for localStorage. */
  get state() {
    const { phase, status, focusCount, blockStartedAt, accrued, runStartedAt } = this;
    return { phase, status, focusCount, blockStartedAt, accrued, runStartedAt };
  }

  get isRunning() { return this.status.kind === "running"; }
  get isIdle() { return this.status.kind === "idle"; }
  get duration() { return this.config[this.phase] * 1000; }
  get cyclePosition() { return this.focusCount % this.config.longBreakEvery; }

  remaining(now) {
    switch (this.status.kind) {
      case "idle": return this.duration;
      case "paused": return this.status.remaining;
      default: return Math.max(0, this.status.endsAt - now);
    }
  }

  progress(now) {
    if (this.duration <= 0) return 0;
    return Math.min(1, Math.max(0, 1 - this.remaining(now) / this.duration));
  }

  // Controls

  start(now) {
    if (this.status.kind === "running") return;
    if (this.status.kind === "idle") {
      this.blockStartedAt = now;
      this.accrued = 0;
      this.#run(this.duration, now);
    } else {
      this.#run(this.status.remaining, now);
    }
  }

  pause(now) {
    if (this.status.kind !== "running") return;
    this.accrued += now - (this.runStartedAt ?? now);
    this.runStartedAt = null;
    this.status = { kind: "paused", remaining: Math.max(0, this.status.endsAt - now) };
  }

  toggle(now) {
    this.isRunning ? this.pause(now) : this.start(now);
  }

  /** Advances the clock. Returns a transition if the running phase hit zero. */
  tick(now) {
    if (this.status.kind !== "running" || now < this.status.endsAt) return null;
    return this.#finish(this.status.endsAt, true, now);
  }

  /** Ends the current phase early and moves to the next one, left idle. */
  skip(now) {
    return this.#finish(now, false, now);
  }

  /** Rewinds the current phase. Focus already spent is still returned. */
  reset(now) {
    const record = this.phase === Phase.focus ? this.#record(now, false) : null;
    this.#clear();
    return record;
  }

  // Internals

  #run(ms, now) {
    this.runStartedAt = now;
    this.status = { kind: "running", endsAt: now + ms };
  }

  #elapsed(at) {
    const live = this.runStartedAt == null ? 0 : Math.max(0, at - this.runStartedAt);
    return Math.min(this.duration, this.accrued + live);
  }

  #record(endedAt, completed) {
    if (this.blockStartedAt == null) return null;
    const focused = this.#elapsed(endedAt) / 1000;
    if (!completed && focused < MINIMUM_LOGGABLE) return null;
    return {
      startedAt: this.blockStartedAt, endedAt, focusSeconds: focused,
      plannedSeconds: this.config.focus, completed,
    };
  }

  #clear() {
    this.blockStartedAt = null;
    this.runStartedAt = null;
    this.accrued = 0;
    this.status = { kind: "idle" };
  }

  #finish(endedAt, natural, now) {
    const finished = this.phase;
    let record = null;

    if (finished === Phase.focus) {
      record = this.#record(endedAt, natural);
      // A skipped focus block still counts as a round, so skipping keeps
      // building towards the long break like any pomodoro timer.
      this.focusCount += 1;
      const longDue = this.focusCount % this.config.longBreakEvery === 0;
      this.phase = longDue ? Phase.longBreak : Phase.shortBreak;
    } else {
      this.phase = Phase.focus;
    }
    this.#clear();

    // Auto-started phases begin now, not at the old deadline, so a tab left
    // closed through several phases wakes to one transition.
    const auto = isBreak(this.phase) ? this.config.autoStartBreaks : this.config.autoStartFocus;
    if (natural && auto) this.start(now);

    return { finished, next: this.phase, record, natural };
  }
}
