// drill cloud: Supabase Auth for accounts, and the RPCs in supabase/migrations
// for sessions. Plain fetch, the same calls as the mac's SupabaseAPI. The
// publishable key is meant to ship in apps; row-level security keeps each
// account to its own rows.

export const PROJECT = "https://fgqtpetuzseozttapzem.supabase.co";
export const KEY = "sb_publishable_WeTl_T2-z_i1ycA7KSgCyQ_9a64WoAg";

export const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** What the field keeps as you type: lowercase, no spaces. */
export const cleanEmail = (text) => text.toLowerCase().replace(/\s+/g, "");
export const validEmail = (email) => email.length <= 254 && EMAIL.test(email);

/** Tokens this close to running out are swapped before a sync. */
const MARGIN = 5 * 60_000;

const TOO_MANY = "too many tries. give it a minute.";
const UNREACHABLE = "can't connect. try again in a bit.";

/** Supabase's error codes, in the app's words. */
const SENTENCES = {
  invalid_credentials: "wrong email or password",
  invalid_grant: "wrong email or password",
  user_already_exists: "an account with this email already exists",
  email_exists: "an account with this email already exists",
  email_address_invalid: "that email doesn't look right",
  weak_password: "use at least 6 characters",
  signup_disabled: "sign-ups are closed for now",
  over_request_rate_limit: TOO_MANY,
  22023: "couldn't sync. try updating the app.",
};

/** An error whose message is fit to show. `signedOut`: the token is no good;
 *  `unreachable`: no answer, or a broken one; else the call was rejected. */
function problem(message, flags = {}) {
  return Object.assign(new Error(message), flags);
}

// MARK: Accounts

/** { email, userID, token, refreshToken, expiresAt } */
export function signIn(email, password) {
  return tokens("auth/v1/token?grant_type=password", { email, password });
}

/** With confirmation off the reply carries tokens, like a sign-in. A taken
 *  email can come back as a database error. */
export async function signUp(email, password) {
  try {
    return await tokens("auth/v1/signup", { email, password });
  } catch (e) {
    if (/database error/i.test(e.detail ?? "")) throw problem(SENTENCES.user_already_exists);
    throw e;
  }
}

/** The account with a fresh token when the old one is about to run out (or
 *  `force`), else as it was. Throws `signedOut` once the refresh token is
 *  used up or revoked. */
export async function refreshed(account, force = false) {
  if (!account.refreshToken) throw problem("sign in again", { signedOut: true });
  if (!force && account.expiresAt && account.expiresAt - Date.now() > MARGIN) return account;
  try {
    return await tokens("auth/v1/token?grant_type=refresh_token", { refresh_token: account.refreshToken });
  } catch (e) {
    if (e.unreachable) throw e;
    throw problem("sign in again", { signedOut: true });
  }
}

export function signOut(account) {
  return call("auth/v1/logout?scope=local", {}, account.token).catch(() => {});
}

/** The live check while someone types an email. Anyone may ask. */
export async function emailAvailable(email) {
  const body = await call("rest/v1/rpc/email_available", { email });
  return body === true;
}

// MARK: Sessions

/** Last-writer-wins on the server; resolves to how many rows it took. */
export async function push(sessions, token) {
  const n = await call("rest/v1/rpc/push_sessions", { sessions }, token);
  return Number(n) || 0;
}

/** { sessions, cursor, more }: a page after `cursor`, in the FocusSession
 *  JSON the store keeps. */
export async function pull(cursor, token) {
  const page = await call("rest/v1/rpc/pull_sessions", { after: Number(cursor) || 0 }, token);
  if (!page || !Array.isArray(page.sessions)) throw problem(UNREACHABLE, { unreachable: true });
  return { sessions: page.sessions, cursor: String(page.cursor ?? cursor), more: page.more === true };
}

// MARK: Plumbing

async function tokens(path, fields) {
  const t = await call(path, fields);
  if (!t || typeof t.access_token !== "string" || typeof t.refresh_token !== "string") {
    throw problem(UNREACHABLE, { unreachable: true });
  }
  return {
    email: t.user?.email ?? null,
    userID: t.user?.id ?? null,
    token: t.access_token,
    refreshToken: t.refresh_token,
    expiresAt: Date.now() + (Number(t.expires_in) || 3600) * 1000,
  };
}

/** Auth errors come as `{ code: 400, error_code, msg }` (older ones as
 *  `{ error, error_description }`), database errors as `{ code: "42501",
 *  message }`. */
function errorCode(body) {
  const code = body?.error_code ?? body?.error ?? body?.code;
  return typeof code === "string" ? code : null;
}

async function call(path, body, token = null) {
  let r;
  try {
    r = await fetch(`${PROJECT}/${path}`, {
      method: "POST", cache: "no-store", body: JSON.stringify(body),
      headers: {
        "Content-Type": "application/json", apikey: KEY,
        ...(token && { Authorization: `Bearer ${token}` }),
      },
    });
  } catch {
    throw problem(UNREACHABLE, { unreachable: true });
  }
  const text = await r.text().catch(() => "");
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch {}
  if (r.ok) return json;

  const code = errorCode(json);
  const detail = json?.msg ?? json?.message ?? json?.error_description ?? "";
  if ((r.status === 401 && token) || (r.status === 403 && code === "28000")) {
    throw problem("sign in again", { signedOut: true, detail });
  }
  if (code) {
    if (SENTENCES[code]) throw problem(SENTENCES[code], { detail });
    if (r.status >= 500) throw problem(UNREACHABLE, { unreachable: true, detail });
    throw problem("something went wrong. try again.", { detail });
  }
  if (r.status === 429) throw problem(TOO_MANY, { detail });
  throw problem(UNREACHABLE, { unreachable: true, detail });
}
