// What every page does in the browser besides the diff viewer (diffs.js):
// the branch and tag picker, finding a file by name, copying, keyboard
// shortcuts, filtering the branch list, and rendering markdown. Pages work
// without it: the picker's menu links to the branch list, markdown shows
// as its source, and every button that only this drives is a convenience.
//
// Everything listens on the document, so the repository page, which swaps
// in new content when something changes (the script in views/layout.erb),
// needs only its markdown drawn again ("outbox:swap").

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

function el(tag, attrs = {}, ...children) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === "class") e.className = v;
    else if (k === "text") e.textContent = v;
    else e.setAttribute(k, v === true ? "" : v);
  }
  e.append(...children.filter((c) => c != null));
  return e;
}

// A branch name or path in a URL: each segment escaped, slashes kept.
const urlPath = (path) => path.split("/").map(encodeURIComponent).join("/");

function toast(text) {
  const t = el("div", { class: "toast", role: "status", text });
  document.body.append(t);
  setTimeout(() => t.remove(), 1400);
}

// --- copying ------------------------------------------------------------

// navigator.clipboard only exists on https and localhost; a server on the
// LAN is neither, so fall back to the old way.
async function copy(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const area = el("textarea", { style: "position:fixed;opacity:0" });
    area.value = text;
    document.body.append(area);
    area.select();
    document.execCommand("copy");
    area.remove();
  }
  toast("Copied");
}

document.addEventListener("click", (e) => {
  const b = e.target.closest?.("[data-copy]");
  if (!b) return;
  e.preventDefault();
  copy(b.dataset.copy);
});

// --- menus that drop from a <details> -------------------------------------

// One open at a time; a click outside or Escape closes it.
document.addEventListener("click", (e) => {
  for (const d of $$("details.refpick[open], details.clone[open]")) {
    if (!d.contains(e.target)) d.open = false;
  }
});

// --- the branch and tag picker ------------------------------------------

const GROUPS = { branch: "Branches", tag: "Tags", remote: "Remote branches" };
let refsCache = null;

async function refs(url) {
  refsCache ??= fetch(url, { headers: { accept: "application/json" } }).then((r) => (r.ok ? r.json() : []));
  return refsCache;
}

function setupPicker(picker) {
  if (picker.dataset.ready) return;
  picker.dataset.ready = "1";
  const input = $("input.filter", picker);
  const list = $("ul.refs", picker);
  let all = [];
  let selected = 0;

  const draw = () => {
    const q = input.value.trim().toLowerCase();
    const shown = all.filter((r) => r.name.toLowerCase().includes(q)).slice(0, 200);
    list.replaceChildren();
    let group = null;
    shown.forEach((r, i) => {
      if (r.kind !== group) {
        group = r.kind;
        list.append(el("li", { class: "group", role: "presentation", text: GROUPS[r.kind] ?? r.kind }));
      }
      const a = el("a", {
        href: picker.dataset.href.replace("{rev}", urlPath(r.name)),
        class: r.name === picker.dataset.current ? "current" : null,
        role: "option",
        "aria-selected": String(i === selected),
      }, el("span", { class: "ref", text: r.name }), r.default ? el("span", { class: "badge same", text: "default" }) : null);
      list.append(el("li", {}, a));
    });
    if (!shown.length) list.append(el("li", { class: "group", text: "Nothing matches" }));
  };
  const options = () => $$("a[role=option]", list);
  const mark = () => options().forEach((a, i) => {
    a.setAttribute("aria-selected", String(i === selected));
    if (i === selected) a.scrollIntoView({ block: "nearest" });
  });

  const opened = async () => {
    if (!picker.open) return;
    for (const other of $$("details.refpick[open], details.clone[open]")) if (other !== picker) other.open = false;
    input.focus();
    all = await refs(picker.dataset.refsUrl);
    selected = 0;
    draw();
  };
  picker.addEventListener("toggle", opened);
  opened(); // set up by the first toggle, which this listener missed
  input.addEventListener("input", () => { selected = 0; draw(); });
  input.addEventListener("keydown", (e) => {
    const n = options().length;
    if (e.key === "ArrowDown") { selected = Math.min(selected + 1, n - 1); mark(); e.preventDefault(); }
    else if (e.key === "ArrowUp") { selected = Math.max(selected - 1, 0); mark(); e.preventDefault(); }
    else if (e.key === "Enter") { options()[selected]?.click(); e.preventDefault(); }
  });
}

document.addEventListener("toggle", (e) => {
  if (e.target.matches?.("details.refpick")) setupPicker(e.target);
}, true);

// --- the file finder ----------------------------------------------------

// Fuzzy: the query's characters in order, anywhere in the path. Matches
// that start a name, run on from the last, or fall in the file's own name
// rank higher; then shorter paths. Returns [score, positions] or null.
function fuzzy(path, query) {
  const lower = path.toLowerCase();
  const base = lower.lastIndexOf("/") + 1;
  const positions = [];
  let score = 0;
  let from = 0;
  for (const ch of query) {
    let i = lower.indexOf(ch, from);
    if (i < 0) return null;
    // Prefer an occurrence that starts a word, if there is one ahead.
    const prev = positions.at(-1);
    if (prev !== i - 1) {
      let j = i;
      while (j >= 0 && !/[/._-]/.test(lower[j - 1] ?? "/")) j = lower.indexOf(ch, j + 1);
      if (j >= 0) i = j;
    }
    if (prev === i - 1) score += 5;
    if (i === 0 || /[/._-]/.test(lower[i - 1])) score += 3;
    if (i >= base) score += 2;
    positions.push(i);
    from = i + 1;
  }
  return [score * 10 - path.length, positions];
}

function highlighted(text, positions) {
  const out = document.createDocumentFragment();
  let last = 0;
  for (const p of positions) {
    if (p > last) out.append(text.slice(last, p));
    out.append(el("b", { text: text[p] }));
    last = p + 1;
  }
  out.append(text.slice(last));
  return out;
}

const finderFiles = new Map();

async function openFinder(button) {
  const treeBase = button.dataset.treeBase;
  const dialog = el("dialog", { class: "overlay finder", "aria-label": "Go to file" });
  const input = el("input", { class: "find", type: "text", placeholder: "Find a file…", "aria-label": "Find a file", spellcheck: "false", autocomplete: "off" });
  const list = el("ul", { role: "listbox" });
  const foot = el("div", { class: "foot", text: "Loading files…" });
  dialog.append(input, list, foot);
  document.body.append(dialog);
  dialog.addEventListener("close", () => dialog.remove());
  dialog.addEventListener("click", (e) => { if (e.target === dialog) dialog.close(); });
  dialog.showModal();

  const url = button.dataset.finder;
  if (!finderFiles.has(url)) {
    finderFiles.set(url, fetch(url).then((r) => (r.ok ? r.text() : Promise.reject(new Error(r.status)))).then((t) => (t ? t.split("\0") : [])));
  }
  let files = [];
  try {
    files = await finderFiles.get(url);
  } catch (err) {
    finderFiles.delete(url);
    foot.textContent = `Could not load the file list (${err.message}).`;
    return;
  }
  let selected = 0;
  let shown = [];
  const draw = () => {
    const q = input.value.replace(/\s+/g, "").toLowerCase();
    if (!q) shown = files.slice(0, 50).map((f) => [f, []]);
    else {
      const scored = [];
      for (const f of files) {
        const m = fuzzy(f, q);
        if (m) scored.push([f, m[1], m[0]]);
      }
      scored.sort((a, b) => b[2] - a[2]);
      shown = scored.slice(0, 50);
    }
    selected = Math.min(selected, Math.max(shown.length - 1, 0));
    list.replaceChildren(...shown.map(([f, pos], i) => el("li", {}, el("a", {
      href: `${treeBase}/${urlPath(f)}`, role: "option", "aria-selected": String(i === selected),
    }, el("span", {}, highlighted(f, pos))))));
    foot.textContent = `${files.length.toLocaleString()} files · ↑↓ to choose · Enter to open · Esc to close`;
  };
  const mark = () => $$("a", list).forEach((a, i) => {
    a.setAttribute("aria-selected", String(i === selected));
    if (i === selected) a.scrollIntoView({ block: "nearest" });
  });
  input.addEventListener("input", () => { selected = 0; draw(); });
  input.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")) { selected = Math.min(selected + 1, shown.length - 1); mark(); e.preventDefault(); }
    else if (e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")) { selected = Math.max(selected - 1, 0); mark(); e.preventDefault(); }
    else if (e.key === "Enter") { $$("a", list)[selected]?.click(); e.preventDefault(); }
  });
  draw();
}

document.addEventListener("click", (e) => {
  const b = e.target.closest?.("[data-finder]");
  if (!b) return;
  e.preventDefault();
  openFinder(b);
});

// --- keyboard shortcuts -------------------------------------------------

const SHORTCUTS = [
  ["/", "Search code"],
  ["t", "Find a file by name"],
  ["y", "Make the URL a permalink (this commit, not the branch)"],
  ["b", "Blame the file"],
  ["h", "History of the file or directory"],
  ["j / k", "Next / previous file in a diff"],
  ["?", "This list"],
];

function showShortcuts() {
  if ($("dialog.shortcuts")) return;
  const dialog = el("dialog", { class: "overlay shortcuts", "aria-label": "Keyboard shortcuts" },
    el("h2", { text: "Keyboard shortcuts" }),
    el("table", { class: "keys" }, ...SHORTCUTS.map(([k, what]) => el("tr", {},
      el("td", {}, ...k.split(" / ").flatMap((key, i) => [i ? " / " : null, el("kbd", { text: key })])),
      el("td", { text: what })))));
  document.body.append(dialog);
  dialog.addEventListener("close", () => dialog.remove());
  dialog.addEventListener("click", (e) => { if (e.target === dialog) dialog.close(); });
  dialog.showModal();
}

document.addEventListener("click", (e) => {
  if (e.target.closest?.("[data-shortcuts]")) showShortcuts();
});

document.addEventListener("keydown", (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.target.closest?.("input, textarea, select, [contenteditable], dialog")) {
    if (e.key === "Escape" && e.target.matches?.("[data-hotkey]")) e.target.blur();
    return;
  }
  if (e.key === "Escape") {
    for (const d of $$("details.refpick[open], details.clone[open]")) d.open = false;
    return;
  }
  const click = (sel) => {
    const target = $(sel);
    if (!target) return false;
    e.preventDefault();
    target.click();
    return true;
  };
  switch (e.key) {
    case "/": {
      const input = $("[data-hotkey='/']");
      if (input) { e.preventDefault(); input.focus(); input.select(); }
      break;
    }
    case "t": click("[data-finder]"); break;
    case "b": click("[data-hotkey-blame]"); break;
    case "h": click("[data-hotkey-history]"); break;
    case "?": e.preventDefault(); showShortcuts(); break;
    case "y": {
      const link = $("[data-permalink]");
      if (link) {
        e.preventDefault();
        history.pushState(history.state, "", link.getAttribute("href") + location.search + location.hash);
        toast("URL is now a permalink");
      }
      break;
    }
  }
});

// --- filtering a list ---------------------------------------------------

document.addEventListener("input", (e) => {
  const input = e.target.closest?.("input[data-filter]");
  if (!input) return;
  const q = input.value.trim().toLowerCase();
  let any = false;
  for (const row of $$(input.dataset.filter)) {
    const hit = !q || row.dataset.name.toLowerCase().includes(q);
    row.hidden = !hit;
    any ||= hit;
  }
  for (const group of $$("details.ref-group")) {
    const rows = $$(input.dataset.filter, group);
    const visible = rows.filter((r) => !r.hidden).length;
    group.hidden = visible === 0;
    if (q && visible) group.open = true;
  }
  const empty = $("[data-filter-empty]");
  if (empty) empty.hidden = any;
});

// --- markdown -----------------------------------------------------------

// Whatever is in the file is the pusher's, and the page is behind the
// reviewer's password, so it goes through DOMPurify with anything that can
// act removed: scripts and handlers (DOMPurify's own job), and forms, which
// could post an approval from this origin.
const FORBID_TAGS = ["form", "input", "button", "textarea", "select", "option", "style", "iframe", "frame", "object", "embed", "base", "link", "meta", "dialog"];

function slug(text) {
  return text.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s/g, "-");
}

// A link relative to the file, made into a page here: into the tree for
// links, raw for images. Absolute URLs and anchors stay as they are.
function resolveRelative(href, base, root) {
  if (!href || /^([a-z][a-z0-9+.-]*:|#|\/\/)/i.test(href)) return null;
  const [path, rest = ""] = href.split(/(?=[?#])/, 2);
  // A leading slash is the top of the repository, as on GitHub.
  const parts = (path.startsWith("/") ? root : base).split("/");
  for (const seg of path.split("/")) {
    if (seg === "..") parts.pop();
    else if (seg !== "." && seg !== "") parts.push(encodeURIComponent(decodeURIComponentSafe(seg)));
  }
  return parts.join("/") + rest;
}

function decodeURIComponentSafe(s) {
  try { return decodeURIComponent(s); } catch { return s; }
}

async function renderMarkdown(article) {
  if (article.dataset.rendered) return;
  const source = $("pre.md-source", article)?.textContent;
  if (source == null) return;
  const [{ marked }, { default: DOMPurify }] = await Promise.all([import("marked"), import("dompurify")]);
  // GFM task lists come out as disabled checkboxes, which the form rule
  // below would remove; draw them as characters instead.
  const html = marked.parse(source, { gfm: true })
    .replace(/<input [^>]*type="checkbox"[^>]*>/g, (box) => (/checked/.test(box) ? "☑" : "☐"));
  const clean = DOMPurify.sanitize(html, {
    FORBID_TAGS,
    FORBID_ATTR: ["style", "class", "id", "name", "form", "formaction"],
    ADD_ATTR: ["target"],
    RETURN_DOM_FRAGMENT: true,
  });
  const { treeBase, treeRoot, rawBase, rawRoot } = article.dataset;
  for (const a of clean.querySelectorAll("a[href]")) {
    const href = a.getAttribute("href");
    const local = resolveRelative(href, treeBase, treeRoot);
    if (local) a.setAttribute("href", local);
    else if (/^https?:|^\/\//i.test(href)) { a.target = "_blank"; a.rel = "noopener noreferrer"; }
    else if (href.startsWith("#")) a.setAttribute("href", `#user-content-${href.slice(1)}`);
    else a.removeAttribute("target");
  }
  for (const img of clean.querySelectorAll("img[src]")) {
    const local = resolveRelative(img.getAttribute("src"), rawBase, rawRoot);
    if (local) img.setAttribute("src", local);
    img.setAttribute("referrerpolicy", "no-referrer");
    img.setAttribute("loading", "lazy");
  }
  const seen = new Map();
  for (const h of clean.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
    let id = slug(h.textContent);
    const n = seen.get(id) ?? 0;
    seen.set(id, n + 1);
    if (n) id += `-${n}`;
    h.id = `user-content-${id}`;
    h.prepend(el("a", { class: "anchor", href: `#user-content-${id}`, "aria-label": "Link to this section", text: "#" }));
  }
  article.replaceChildren(clean);
  article.dataset.rendered = "1";
  if (location.hash.startsWith("#user-content-")) document.getElementById(location.hash.slice(1))?.scrollIntoView();
}

function hydrate() {
  for (const article of $$("[data-markdown]")) {
    renderMarkdown(article).catch((err) => console.error("markdown", err));
  }
  // A line in a markdown file's URL means its code, not its preview.
  if (/^#L\d+/.test(location.hash) && $("[data-markdown]") && $("a[href$='?plain=1']")) {
    location.replace(`${location.pathname}?plain=1${location.hash}`);
  }
}

document.addEventListener("outbox:swap", hydrate);
hydrate();
