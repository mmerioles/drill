// ⌘K / ctrl K: a fuzzy finder over everything the home screen can do.
// `items(query)` gives the commands that apply right now, as
// { id, title, keywords?, hint?, last?, run }.

import { rank } from "./fuzzy.js";

const RECENT = 5;

export function createPalette(dialog, items) {
  const input = dialog.querySelector("input"), list = dialog.querySelector("ul");
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const recent = [];
  let rows = [], selected = 0, closing = null;

  function render() {
    rows = rank(items(input.value), input.value, recent);
    selected = 0;
    if (!rows.length) {
      list.replaceChildren(Object.assign(document.createElement("li"), { className: "empty", textContent: "no matches" }));
      input.removeAttribute("aria-activedescendant");
      return;
    }
    list.replaceChildren(...rows.map((row, i) => {
      const li = document.createElement("li");
      li.id = `palette-${i}`;
      li.setAttribute("role", "option");
      const title = document.createElement("span");
      for (let j = 0; j < row.title.length; j++) {
        const c = row.title[j];
        title.append(row.indices.includes(j) ? Object.assign(document.createElement("b"), { textContent: c }) : c);
      }
      li.append(title);
      if (row.hint) li.append(Object.assign(document.createElement("kbd"), { textContent: row.hint }));
      return li;
    }));
    list.scrollTop = 0;
    select(0);
  }

  function select(i, scroll = false) {
    if (!rows.length) return;
    list.children[selected]?.setAttribute("aria-selected", "false");
    selected = (i + rows.length) % rows.length;
    const li = list.children[selected];
    li.setAttribute("aria-selected", "true");
    input.setAttribute("aria-activedescendant", li.id);
    if (scroll) li.scrollIntoView({ block: "nearest" });
  }

  function runRow(i) {
    const row = rows[i];
    if (!row) return;
    const at = recent.indexOf(row.id);
    if (at >= 0) recent.splice(at, 1);
    recent.unshift(row.id);
    recent.length = Math.min(recent.length, RECENT);
    close(true);
    row.run();
  }

  function open() {
    clearTimeout(closing);
    closing = null;
    dialog.classList.remove("closing");
    input.value = "";
    render();
    if (!dialog.open) dialog.showModal();
    input.focus();
  }

  /** Fades out, unless `now` (a command is about to run) or motion is reduced. */
  function close(now = false) {
    if (!dialog.open) return;
    if (now || reduceMotion.matches) {
      clearTimeout(closing);
      closing = null;
      dialog.classList.remove("closing");
      return dialog.close();
    }
    if (closing) return;
    dialog.classList.add("closing");
    closing = setTimeout(() => { closing = null; dialog.classList.remove("closing"); dialog.close(); }, 80);
  }

  input.addEventListener("input", render);
  input.addEventListener("keydown", (e) => {
    if (e.isComposing) return;
    const key = e.ctrlKey && !e.metaKey && !e.altKey ? { n: "ArrowDown", p: "ArrowUp" }[e.key] ?? e.key : e.key;
    if (key === "ArrowDown" || key === "ArrowUp") {
      e.preventDefault();
      select(selected + (key === "ArrowDown" ? 1 : -1), true);
    } else if (key === "Enter") {
      e.preventDefault();
      runRow(selected);
    }
  });
  dialog.addEventListener("cancel", (e) => { e.preventDefault(); close(); });
  dialog.addEventListener("click", (e) => {
    if (e.target === dialog) return close();
    const li = e.target.closest("[role=option]");
    if (li) runRow([...list.children].indexOf(li));
  });
  // Keep the focus in the field while clicking a row.
  list.addEventListener("mousedown", (e) => e.preventDefault());
  list.addEventListener("pointermove", (e) => {
    const li = e.target.closest("[role=option]");
    const i = li ? [...list.children].indexOf(li) : -1;
    if (i >= 0 && i !== selected) select(i);
  });

  return {
    open,
    close,
    toggle: () => (dialog.open && !closing ? close() : open()),
  };
}
