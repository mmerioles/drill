// Sessions kept in localStorage, synced with drill cloud by docs/SYNC.md.
// The browser is just another device: it pushes rows it wrote, pulls rows
// it hasn't seen, and merges with one rule — newer updatedAt wins.
//
// Each account keeps its own sessions, under drill.u.<userID>.*; the plain
// drill.* keys are the offline store, used only while nobody is signed in.
// An account that shouldn't stay signed in lives in sessionStorage, keys and
// all, so closing the tab forgets it.

import * as cloud from "./supabase.js";

const KEY = { account: "drill.account", device: "drill.deviceID", split: "drill.storesSplit" };
const OFFLINE = { sessions: "drill.sessions", dirty: "drill.dirty", cursor: "drill.cursor" };
const keysFor = (userID) => userID
  ? { sessions: `drill.u.${userID}.sessions`, dirty: `drill.u.${userID}.dirty`, cursor: `drill.u.${userID}.cursor` }
  : OFFLINE;

const read = (area, key, fallback) => {
  try { return JSON.parse(area.getItem(key)) ?? fallback; } catch { return fallback; }
};
const write = (area, key, value) => {
  try { area.setItem(key, JSON.stringify(value)); } catch { /* full or blocked */ }
};
const remove = (area, ...keys) => {
  try { for (const k of keys) area.removeItem(k); } catch {}
};
const areas = () => {
  const list = [];
  try { list.push(sessionStorage); } catch {}
  try { list.push(localStorage); } catch {}
  return list;
};

/** The account's Supabase user id, from the token when an old copy lacks it. */
function userIDOf(account) {
  if (!account) return null;
  if (account.userID) return account.userID;
  try {
    const part = account.token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(atob(part)).sub ?? null;
  } catch { return null; }
}

/** Once: an account signed in before stores were split takes the device's
 *  sessions, push state and all, so nothing uploads again. */
function splitStores() {
  if (localStorage.getItem(KEY.split)) return;
  const id = userIDOf(read(localStorage, KEY.account, null));
  if (id) {
    const to = keysFor(id);
    for (const k of Object.keys(OFFLINE)) {
      const v = localStorage.getItem(OFFLINE[k]);
      if (v !== null) localStorage.setItem(to[k], v);
    }
    remove(localStorage, ...Object.values(OFFLINE));
  }
  localStorage.setItem(KEY.split, "1");
}

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
    try { splitStores(); } catch {}
    this.syncing = null;
    /** When the last sync started, so coming back doesn't sync twice. */
    this.lastStarted = 0;
    /** Bumped by every swap of the active store: a sync run started before
     *  belongs to an old account, and its answers are dropped. */
    this.generation = 0;
    this.#activate(false);

    // Another tab wrote: follow its sign-in or sign-out, or pick up its sessions.
    addEventListener("storage", (e) => {
      if (e.key === null || e.key === KEY.account) {
        if (userIDOf(this.account) !== this.userID) this.#activate();
      } else if (e.storageArea === this.area && (e.key === this.keys.sessions || e.key === this.keys.dirty)) {
        this.sessions = read(this.area, this.keys.sessions, {});
        this.#changed();
      }
    });
  }

  /** { username, userID, token, refreshToken, expiresAt, ephemeral? } once
   *  signed in, else null. This tab's ephemeral account comes first. */
  get account() {
    for (const area of areas()) {
      const account = read(area, KEY.account, null);
      if (account) return account;
    }
    return null;
  }

  /** Where the account (or the offline store) keeps its keys. */
  #areaOf(account) {
    return account?.ephemeral ? sessionStorage : localStorage;
  }

  /** Opens the store for whoever is signed in now. */
  #activate(announce = true) {
    const account = this.account;
    this.userID = userIDOf(account);
    this.area = this.#areaOf(account);
    this.keys = keysFor(this.userID);
    this.sessions = read(this.area, this.keys.sessions, {});
    this.generation++;
    this.syncState = account ? "synced" : "signedOut"; // signedOut | syncing | synced | offline
    if (!announce) return;
    this.dispatchEvent(new Event("account"));
    this.#changed();
    this.#emit();
  }

  #saveAccount(account) {
    write(this.#areaOf(account), KEY.account, account);
  }

  /** Signs in, or creates the account when `create` is set. Without `stay`,
   *  the account and its sessions last as long as the tab. Throws an Error
   *  whose message is fit to show, like "wrong username or password". */
  async signIn(username, password, create = false, stay = true) {
    const account = await (create ? cloud.signUp(username, password) : cloud.signIn(username, password));
    if (!stay) account.ephemeral = true;
    account.userID = userIDOf(account);
    const area = this.#areaOf(account), to = keysFor(account.userID);
    if (create) {
      // A new account takes what was logged offline; nothing else ever crosses.
      const rows = read(localStorage, OFFLINE.sessions, {});
      write(area, to.sessions, rows);
      write(area, to.dirty, Object.keys(rows));
      remove(localStorage, ...Object.values(OFFLINE));
    }
    write(area, to.cursor, "0");
    for (const a of areas()) remove(a, KEY.account);
    this.#saveAccount(account);
    this.#activate();
    // A sync for the store before this one may still be finishing.
    if (this.syncing) await this.syncing;
    await this.sync();
  }

  /** Pushes what's left (up to 10s), then forgets the account and its
   *  sessions and goes back to the offline store. Resolves to false, having
   *  done nothing, when sessions couldn't be pushed and `force` isn't set. */
  async signOut(force = false) {
    const account = this.account;
    if (!account) return true;
    if (!force && !this.offline && this.unpushed() > 0) {
      const push = (async () => {
        if (this.syncing) await this.syncing;
        await this.sync();
      })();
      await Promise.race([push, new Promise((r) => setTimeout(r, 10_000))]);
      if (userIDOf(this.account) !== userIDOf(account)) return true;
      if (this.unpushed() > 0) return false;
    }
    this.#forget(account);
    if (!this.offline) cloud.signOut(account);
    return true;
  }

  /** Drops an account and its sessions, and opens the offline store. */
  #forget(account) {
    const area = this.#areaOf(account), id = userIDOf(account);
    if (id) remove(area, ...Object.values(keysFor(id)));
    remove(area, KEY.account);
    this.#activate();
  }

  /** How many local changes haven't been pushed yet. */
  unpushed() { return read(this.area, this.keys.dirty, []).length; }

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
    const dirty = new Set(read(this.area, this.keys.dirty, []));
    let changed = false;
    for (const row of rows) {
      const mine = this.sessions[row.id];
      if (mine && Date.parse(mine.updatedAt) >= Date.parse(row.updatedAt) && !local) continue;
      this.sessions[row.id] = row;
      if (local) dirty.add(row.id);
      changed = true;
    }
    if (!changed) return;
    write(this.area, this.keys.sessions, this.sessions);
    write(this.area, this.keys.dirty, [...dirty]);
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
    // answers belong to the old store, so they're dropped from then on.
    const generation = this.generation;
    const { area, keys } = this;
    const current = () => this.generation === generation;
    const stale = () => Object.assign(new Error("stale"), { stale: true });
    const refresh = async (force) => {
      const fresh = await cloud.refreshed(account, force);
      if (!current()) throw stale();
      if (fresh !== account) {
        account = { ...fresh, userID: userIDOf(fresh), ...(account.ephemeral && { ephemeral: true }) };
        this.#saveAccount(account);
      }
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

      const dirty = read(area, keys.dirty, []);
      for (let i = 0; i < dirty.length; i += 200) {
        const ids = dirty.slice(i, i + 200);
        const sessions = ids.map((id) => this.sessions[id]).filter(Boolean);
        if (sessions.length) await call((token) => cloud.push(sessions, token));
        // Only clear what was sent; a block logged meanwhile stays queued.
        const left = new Set(read(area, keys.dirty, []));
        ids.forEach((id) => left.delete(id));
        write(area, keys.dirty, [...left]);
      }

      let more = true;
      while (more) {
        const cursor = read(area, keys.cursor, "0");
        const page = await call((token) => cloud.pull(cursor, token));
        this.#merge(page.sessions, false);
        write(area, keys.cursor, page.cursor);
        more = page.more;
      }
      this.#setState("synced");
    } catch (e) {
      if (e.stale || !current()) return;
      if (e.signedOut) {
        // The account's sessions stay put for its next sign-in.
        remove(area, KEY.account);
        return this.#activate();
      }
      this.#setState("offline");
    }
  }
}
