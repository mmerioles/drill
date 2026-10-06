// Sessions kept in localStorage, synced with the server by docs/SYNC.md.
// The browser is just another device: it pushes rows it wrote, pulls rows
// it hasn't seen, and merges with one rule — newer updatedAt wins.

const KEY = { sessions: "drill.sessions", dirty: "drill.dirty",
              cursor: "drill.cursor", account: "drill.account", device: "drill.deviceID" };

const read = (key, fallback) => {
  try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; }
};
const write = (key, value) => {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* full or blocked */ }
};

// crypto.randomUUID needs a secure context; a home server is often plain http.
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
  constructor() {
    super();
    this.deviceID = localStorage.getItem(KEY.device) || `web-${randomUUID()}`;
    try { localStorage.setItem(KEY.device, this.deviceID); } catch {}
    this.sessions = read(KEY.sessions, {});
    this.syncState = this.account ? "synced" : "signedOut"; // signedOut | syncing | synced | offline | unconfirmed
    this.syncing = null;

    // Another tab wrote: pick up its sessions.
    addEventListener("storage", (e) => {
      if (e.key === KEY.sessions) {
        this.sessions = read(KEY.sessions, {});
        this.#changed();
      }
    });
  }

  /** { email, token, confirmed } once signed in, else null. */
  get account() { return read(KEY.account, null); }

  /** Signs in, or creates the account when `create` is set. Throws an Error
   *  whose message is fit to show, like "wrong email or password". */
  async signIn(email, password, create = false) {
    let r;
    try {
      r = await fetch(create ? "/v1/accounts" : "/v1/signin", {
        method: "POST", headers: { "Content-Type": "application/json" }, cache: "no-store",
        body: JSON.stringify({ email, password }),
      });
    } catch {
      throw new Error("can't reach the server.");
    }
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || "something went wrong. try again.");
    write(KEY.account, { email: body.email, token: body.token, confirmed: body.confirmed });
    // Everything on this device joins the account; then catch up from the top.
    write(KEY.dirty, Object.keys(this.sessions));
    write(KEY.cursor, "0");
    this.#setState("synced");
    return this.sync();
  }

  async signOut() {
    const token = this.account?.token;
    try { localStorage.removeItem(KEY.account); } catch {}
    this.#setState("signedOut");
    if (token) {
      fetch("/v1/signout", { method: "POST", headers: { Authorization: `Bearer ${token}` },
                             body: "{}" }).catch(() => {});
    }
  }

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
    this.sync();
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
    this.dispatchEvent(new Event("sync"));
  }

  /** Push, then pull until caught up. Safe to call often; runs one at a time. */
  sync() {
    this.syncing ??= this.#sync().finally(() => { this.syncing = null; });
    return this.syncing;
  }

  async #sync() {
    const account = this.account;
    if (!account) return this.#setState("signedOut");
    const headers = { "Content-Type": "application/json", Authorization: `Bearer ${account.token}` };
    const call = async (path, init = {}) => {
      const r = await fetch(path, { ...init, headers, cache: "no-store" });
      if (r.status === 401) throw Object.assign(new Error("signed out"), { signedOut: true });
      if (r.status === 403) throw Object.assign(new Error("unconfirmed"), { unconfirmed: true });
      if (!r.ok) throw new Error(`${r.status}`);
      return r.json();
    };
    this.#setState("syncing");

    try {
      const dirty = read(KEY.dirty, []);
      for (let i = 0; i < dirty.length; i += 200) {
        const ids = dirty.slice(i, i + 200);
        const sessions = ids.map((id) => this.sessions[id]).filter(Boolean);
        await call("/v1/sessions/push", {
          method: "POST", body: JSON.stringify({ deviceID: this.deviceID, sessions }),
        });
        // Only clear what was sent; a block logged meanwhile stays queued.
        const left = new Set(read(KEY.dirty, []));
        ids.forEach((id) => left.delete(id));
        write(KEY.dirty, [...left]);
      }

      let more = true;
      while (more) {
        const cursor = read(KEY.cursor, "0");
        const page = await call(`/v1/sessions/pull?cursor=${encodeURIComponent(cursor)}`);
        this.#merge(page.sessions, false);
        write(KEY.cursor, page.cursor);
        more = page.more;
      }
      this.#setState("synced");
    } catch (e) {
      if (e.signedOut) {
        try { localStorage.removeItem(KEY.account); } catch {}
      }
      this.#setState(e.signedOut ? "signedOut" : e.unconfirmed ? "unconfirmed" : "offline");
    }
  }
}
