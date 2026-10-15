// Sessions kept in localStorage, synced with drill cloud by docs/SYNC.md.
// The browser is just another device: it pushes rows it wrote, pulls rows
// it hasn't seen, and merges with one rule — newer updatedAt wins.

import * as cloud from "./supabase.js";

const KEY = { sessions: "drill.sessions", dirty: "drill.dirty",
              cursor: "drill.cursor", account: "drill.account", device: "drill.deviceID" };

const read = (key, fallback) => {
  try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; }
};
const write = (key, value) => {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* full or blocked */ }
};

// crypto.randomUUID needs a secure context; plain http on a LAN is not one.
function randomUUID() {
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  return formatUUID(b);
}

/** A stable id from a string, so two tabs logging the same block write one row. */
function hashedUUID(text) {
  let h1 = 0x811c9dc5, h2 = 0x01000193, h3 = 0xdeadbeef, h4 = 0x41c6ce57;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 0x01000193); h2 = Math.imul(h2 ^ c, 0x5bd1e995);
    h3 = Math.imul(h3 ^ c, 0x27d4eb2f); h4 = Math.imul(h4 ^ c, 0x165667b1);
  }
  const b = new Uint8Array(new Uint32Array([h1, h2, h3, h4]).buffer);
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  return formatUUID(b);
}

function formatUUID(b) {
  const hex = [...b].map((x) => x.toString(16).padStart(2, "0")).join("").toUpperCase();
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** ISO-8601 UTC in whole seconds, the wire format. */
const iso = (ms) => new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(".000Z", "Z");

export class Store extends EventTarget {
  /** With `offline` (the site's demo), it never talks to the network. */
  constructor({ offline = false } = {}) {
    super();
    this.offline = offline;
    /** Off: only signing in and an explicit sync() talk to the cloud. */
    this.autoSync = true;
    this.deviceID = localStorage.getItem(KEY.device) || `web-${randomUUID()}`;
    try { localStorage.setItem(KEY.device, this.deviceID); } catch {}
    this.sessions = read(KEY.sessions, {});
    this.syncState = this.account ? "synced" : "signedOut"; // signedOut | syncing | synced | offline
    this.syncing = null;
    /** When the last sync started, so coming back doesn't sync twice. */
    this.lastStarted = 0;
    /** Bumped by every sign-in and sign-out: a sync run started before
     *  belongs to an old account, and its answers are dropped. */
    this.generation = 0;

    // Another tab wrote: pick up its sessions.
    addEventListener("storage", (e) => {
      if (e.key === KEY.sessions || e.key === KEY.dirty) {
        this.sessions = read(KEY.sessions, {});
        this.#changed();
      }
    });
  }

  /** { username, userID, token, refreshToken, expiresAt } once signed in, else null. */
  get account() { return read(KEY.account, null); }

  /** Signs in, or creates the account when `create` is set. Throws an Error
   *  whose message is fit to show, like "wrong username or password". */
  async signIn(username, password, create = false) {
    const account = await (create ? cloud.signUp(username, password) : cloud.signIn(username, password));
    write(KEY.account, account);
    this.generation++;
    // Everything on this device joins the account; then catch up from the top.
    write(KEY.dirty, Object.keys(this.sessions));
    write(KEY.cursor, "0");
    this.#setState("synced");
    // A sync for the account before this one may still be finishing.
    if (this.syncing) await this.syncing;
    await this.sync();
  }

  async signOut() {
    const account = this.account;
    try { localStorage.removeItem(KEY.account); } catch {}
    this.generation++;
    this.#setState("signedOut");
    if (account && !this.offline) cloud.signOut(account);
  }

  /** How many local changes haven't been pushed yet. */
  unpushed() { return read(KEY.dirty, []).length; }

  /** Live sessions, oldest first. */
  live() {
    return Object.values(this.sessions)
      .filter((s) => !s.deletedAt)
      .sort((a, b) => Date.parse(a.startedAt) - Date.parse(b.startedAt));
  }

  /** Distinct tags, most recently used first. */
  tags(limit = 6) {
    const seen = new Set();
    for (const s of this.live().reverse()) {
      if (s.tag && !seen.has(s.tag)) seen.add(s.tag);
      if (seen.size === limit) break;
    }
    return [...seen];
  }

  /** Logs a finished focus block from the engine. */
  log(record, tag) {
    const now = Date.now();
    const session = {
      id: hashedUUID(`${this.deviceID}:${record.startedAt}`),
      startedAt: iso(record.startedAt),
      endedAt: iso(record.endedAt),
      focusSeconds: Math.round(record.focusSeconds),
      plannedSeconds: record.plannedSeconds,
      completed: record.completed,
      tag: tag || null,
      deviceID: this.deviceID,
      updatedAt: iso(now),
      deletedAt: null,
    };
    this.#merge([session], true);
    if (this.autoSync) this.sync();
  }

  /** Last-writer-wins on updatedAt. Local writes are queued for push. */
  #merge(rows, local) {
    const dirty = new Set(read(KEY.dirty, []));
    let changed = false;
    for (const row of rows) {
      const mine = this.sessions[row.id];
      if (mine && Date.parse(mine.updatedAt) >= Date.parse(row.updatedAt) && !local) continue;
      this.sessions[row.id] = row;
      if (local) dirty.add(row.id);
      changed = true;
    }
    if (!changed) return;
    write(KEY.sessions, this.sessions);
    write(KEY.dirty, [...dirty]);
    this.#changed();
  }

  #changed() {
    this.dispatchEvent(new Event("change"));
  }

  #setState(state) {
    if (this.syncState === state) return;
    this.syncState = state;
    this.#emit();
  }

  #emit() {
    this.dispatchEvent(new Event("sync"));
  }

  /** Push, then pull until caught up. Safe to call often; runs one at a time. */
  sync() {
    if (this.offline) return Promise.resolve();
    if (!this.syncing) this.lastStarted = Date.now();
    this.syncing ??= this.#sync().finally(() => { this.syncing = null; });
    return this.syncing;
  }

  async #sync() {
    let account = this.account;
    if (!account) return this.#setState("signedOut");
    // Signing out, or into another account, partway through: this run's
    // answers belong to the old account, so they're dropped from then on.
    const generation = this.generation;
    const current = () => this.generation === generation;
    const stale = () => Object.assign(new Error("stale"), { stale: true });
    const refresh = async (force) => {
      const fresh = await cloud.refreshed(account, force);
      if (!current()) throw stale();
      if (fresh !== account) write(KEY.account, account = fresh);
    };
    // One try with the token in hand; a 401 swaps it for a fresh one and tries once more.
    const call = async (work) => {
      let body;
      try {
        body = await work(account.token);
      } catch (e) {
        if (!current()) throw stale();
        if (!e.signedOut) throw e;
        await refresh(true);
        body = await work(account.token);
      }
      if (!current()) throw stale();
      return body;
    };
    this.#setState("syncing");

    try {
      await refresh(false);

      const dirty = read(KEY.dirty, []);
      for (let i = 0; i < dirty.length; i += 200) {
        const ids = dirty.slice(i, i + 200);
        const sessions = ids.map((id) => this.sessions[id]).filter(Boolean);
        if (sessions.length) await call((token) => cloud.push(sessions, token));
        // Only clear what was sent; a block logged meanwhile stays queued.
        const left = new Set(read(KEY.dirty, []));
        ids.forEach((id) => left.delete(id));
        write(KEY.dirty, [...left]);
      }

      let more = true;
      while (more) {
        const cursor = read(KEY.cursor, "0");
        const page = await call((token) => cloud.pull(cursor, token));
        this.#merge(page.sessions, false);
        write(KEY.cursor, page.cursor);
        more = page.more;
      }
      this.#setState("synced");
    } catch (e) {
      if (e.stale || !current()) return;
      if (e.signedOut) {
        try { localStorage.removeItem(KEY.account); } catch {}
        this.generation++;
      }
      this.#setState(e.signedOut ? "signedOut" : "offline");
    }
  }
}
