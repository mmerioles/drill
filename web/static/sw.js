// A small service worker: it keeps the app shell for offline use, and it's
// what shows notifications, since Android Chrome only takes them from here.
// Paths are relative, so it works at a server's root and under /drill/try/.

const CACHE = "drill-v1";
const SHELL = [
  "./", "index.html", "style.css", "theme.js", "app.js", "engine.js", "heatmap.js", "ink.js",
  "inspo.js", "inspo-videos.js", "store.js", "manifest.webmanifest",
  "icon.png", "icon-192.png", "icon-512.png",
];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

// Network first, so an update shows up on the next load; the cache is only
// for when the network isn't there. Sync calls are never cached.
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin ||
      !url.href.startsWith(self.registration.scope) || url.pathname.includes("/v1/")) return;
  e.respondWith(fetch(e.request).then((response) => {
    if (response.ok && url.search === "") {
      const copy = response.clone();
      caches.open(CACHE).then((c) => c.put(e.request, copy));
    }
    return response;
  }).catch(() => caches.match(e.request, { ignoreSearch: true })
    .then((hit) => hit ?? (e.request.mode === "navigate" ? caches.match("./") : undefined))
    .then((hit) => hit ?? Response.error())));
});

// "start break" / "start focus" on the banner, or a click on the banner
// itself: bring drill forward, and start the next phase if asked.
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const start = e.action === "start" ? e.notification.data?.next : null;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((tabs) => {
    const tab = tabs.find((t) => t.url.startsWith(self.registration.scope) && !/[?&]demo/.test(t.url));
    if (tab) {
      if (start) tab.postMessage({ start });
      return tab.focus();
    }
    return self.clients.openWindow(start ? `./?start=${encodeURIComponent(start)}` : "./");
  }));
});
