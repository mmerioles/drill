// The run / walk interval timer, a sibling of engine.js: time is passed in
// (epoch ms), the state is plain JSON, and the host calls tick(now) to get
// back a transition when an interval ends. Interval ends chain from the old
// deadline, so a tab asleep through several of them steps through each
// without drift.

export const IntervalPhase = { run: "run", walk: "walk" };

export const defaultIntervalConfig = { run: 5 * 60, walk: 60 };

const MINIMUM_LOGGABLE = 60;
const DAY = 24 * 3600 * 1000;

export class IntervalEngine {
  constructor(config = defaultIntervalConfig, state = null) {
    this.config = { ...defaultIntervalConfig, ...config };
    this.phase = IntervalPhase.run;
    // { kind: "idle" } | { kind: "running", endsAt } | { kind: "paused", remaining }
    this.status = { kind: "idle" };
    this.round = 0;
    this.workoutStartedAt = null;
    this.accrued = 0;
    this.runStartedAt = null;
    if (state) Object.assign(this, state);
  }

  /** Everything but the config, as plain JSON, for localStorage. */
  get state() {
    const { phase, status, round, workoutStartedAt, accrued, runStartedAt } = this;
    return { phase, status, round, workoutStartedAt, accrued, runStartedAt };
  }

  get isRunning() { return this.status.kind === "running"; }
  get isIdle() { return this.status.kind === "idle"; }
  get duration() { return this.config[this.phase] * 1000; }

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

  /** Workout time so far, without pauses, in ms. */
  elapsed(now) {
    if (this.status.kind === "idle") return 0;
    const live = this.runStartedAt == null ? 0 : Math.max(0, now - this.runStartedAt);
    return Math.min(DAY, this.accrued + live);
  }

  // Controls

  start(now) {
    if (this.status.kind !== "idle") return this.resume(now);
    this.phase = IntervalPhase.run;
    this.round = 1;
    this.workoutStartedAt = now;
    this.accrued = 0;
    this.#run(this.duration, now);
  }

  pause(now) {
    if (this.status.kind !== "running") return;
    this.accrued += now - (this.runStartedAt ?? now);
    this.runStartedAt = null;
    this.status = { kind: "paused", remaining: Math.max(0, this.status.endsAt - now) };
  }

  resume(now) {
    if (this.status.kind !== "paused") return;
    this.#run(this.status.remaining, now);
  }

  toggle(now) {
    this.isRunning ? this.pause(now) : this.start(now);
  }

  /** Advances the clock, through every interval end since the last call.
   *  Returns the last transition, or null if none ended. */
  tick(now) {
    let last = null;
    while (this.status.kind === "running" && now >= this.status.endsAt) {
      last = this.#advance(this.status.endsAt);
    }
    return last;
  }

  /** Moves to the next interval now. Nothing while idle. */
  skip(now) {
    if (this.status.kind === "idle") return null;
    return this.#advance(now);
  }

  /** Ends the workout. A record comes back when it's worth logging. */
  stop(now) {
    const seconds = this.elapsed(now) / 1000;
    const startedAt = this.workoutStartedAt;
    this.phase = IntervalPhase.run;
    this.round = 0;
    this.workoutStartedAt = null;
    this.runStartedAt = null;
    this.accrued = 0;
    this.status = { kind: "idle" };
    if (startedAt == null || seconds < MINIMUM_LOGGABLE) return null;
    return { startedAt, endedAt: now, seconds };
  }

  // Internals

  #run(ms, now) {
    this.runStartedAt = now;
    this.status = { kind: "running", endsAt: now + ms };
  }

  /** The next interval starts at `from`: the old deadline, or now for a skip. */
  #advance(from) {
    const finished = this.phase;
    if (finished === IntervalPhase.run) {
      this.phase = IntervalPhase.walk;
    } else {
      this.phase = IntervalPhase.run;
      this.round += 1;
    }
    if (this.status.kind === "running") this.status = { kind: "running", endsAt: from + this.duration };
    else this.status = { kind: "paused", remaining: this.duration };
    return { finished, next: this.phase, round: this.round };
  }
}
