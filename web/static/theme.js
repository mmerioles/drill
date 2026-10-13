// The theme before first paint, so dark doesn't flash in after light. A
// plain script, not inline, so the server's CSP can stay strict. app.js
// makes the same choice: the saved one, else the visitor's own mode in the
// site's demo, else dark.
(() => {
  let light = false;
  try {
    const saved = JSON.parse(localStorage.getItem("drill.settings") || "{}").theme;
    light = saved === "light" || (saved !== "dark" && location.search.includes("demo")
      && matchMedia("(prefers-color-scheme: light)").matches);
  } catch {}
  document.documentElement.dataset.theme = light ? "light" : "dark";
  // The browser's own chrome follows the app's paper, not the system's mode.
  for (const meta of document.querySelectorAll('meta[name="theme-color"]')) {
    meta.content = light ? "#F2F0ED" : "#121211";
  }
})();
