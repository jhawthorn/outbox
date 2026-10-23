// Renders the diffs on branch and commit pages. The server emits one
// <details class="file"> per file inside a root element that carries the URL
// of the raw patch (data-patch-url); each has the path, blob ids and what its
// header shows besides path and counts as data attributes. That markup is
// what a page without this script shows.
//
// This fetches the patch, parses it, and replaces the files with a single
// @pierre/diffs CodeView. CodeView owns its scroll container, so once it
// mounts the page below the site header becomes that container: everything
// above the files (title, review panel, commits, summary) is its header
// element and scrolls with them, so there is still one scrollbar. It draws
// only the files near the viewport, keeps the current file's header stuck to
// the top, and highlights in a pool of web workers (public/diffs/worker.js)
// instead of on the main thread.
//
// File headers are pierre's: change icon, old → new name on a rename, and
// line counts. The slots around the name carry what pierre does not know: a
// fold toggle, mode changes, binary files, and lines with hidden characters.
import { CodeView, parsePatchFiles } from "@pierre/diffs";
import { getOrCreateWorkerPoolSingleton } from "@pierre/diffs/worker";

const THEME = { light: "pierre-light", dark: "pierre-dark" };

const OPTIONS = {
  theme: THEME,
  themeType: "system",
  overflow: "wrap",
  stickyHeaders: true,
  // Clickable separators between hunks that reveal the unchanged lines.
  hunkSeparators: "line-info",
  expansionLineCount: 20,
  collapsedContextThreshold: 3,
  layout: { paddingTop: 0, paddingBottom: 64, gap: 12 },
};

async function fetchText(url) {
  const res = await fetch(url, { headers: { accept: "text/plain" } });
  if (!res.ok) throw new Error(`request failed with status ${res.status}`);
  return res.text();
}

function workerPool() {
  if (typeof Worker === "undefined") return undefined;
  try {
    return getOrCreateWorkerPoolSingleton({
      poolOptions: {
        workerFactory: () => new Worker("/diffs/worker.js", { type: "module" }),
        poolSize: Math.min(4, navigator.hardwareConcurrency || 2),
      },
      highlighterOptions: { theme: THEME },
    });
  } catch {
    return undefined; // fall back to highlighting on the main thread
  }
}

// Reader preferences, kept across pages.
const prefs = {
  get(key) {
    try { return localStorage.getItem(`outbox:${key}`) ?? DEFAULT_PREFS[key]; } catch { return DEFAULT_PREFS[key]; }
  },
  set(key, value) {
    try { localStorage.setItem(`outbox:${key}`, value); } catch {}
  },
};
const DEFAULT_PREFS = { diffStyle: "unified" };

function el(tag, className, text) {
  const e = document.createElement(tag);
  if (className) e.className = className;
  if (text != null) e.textContent = text;
  return e;
}

function button(label, title, onclick) {
  const b = el("button", null, label);
  b.type = "button";
  b.title = title;
  b.addEventListener("click", onclick);
  return b;
}

async function mount(root) {
  const patch = await fetchText(root.dataset.patchUrl).catch((err) => {
    throw new Error(`patch ${err.message}`);
  });
  const parsed = parsePatchFiles(patch).flatMap((p) => p.files);
  const byPath = new Map();
  for (const f of parsed) {
    byPath.set(f.name, f);
    if (f.prevName && !byPath.has(f.prevName)) byPath.set(f.prevName, f);
  }

  // One entry per server-rendered file, in the server's order and with its
  // id (f0, f1, …), so the summary's links keep working.
  const files = [];
  const missing = [];
  for (const details of root.querySelectorAll("details.file")) {
    const fileDiff = byPath.get(details.dataset.path);
    if (fileDiff == null) missing.push(details.dataset.path);
    else files.push({ id: details.id, data: details.dataset, fileDiff, collapsed: false, version: 0, whole: false, instance: null });
  }
  const byId = new Map(files.map((f) => [f.id, f]));
  const blobs = new WeakMap(files.map((f) => [f.fileDiff, f.data]));
  const item = (f) => ({ id: f.id, type: "diff", fileDiff: f.fileDiff, collapsed: f.collapsed, version: f.version });

  // Everything on the page above the files becomes CodeView's header, and
  // a note about any file the patch lacks (it was truncated) its footer.
  const main = root.closest("main");
  const header = el("div", "codeview-head");
  const footer = el("div", "codeview-foot");
  if (missing.length) {
    footer.append(`Not in the patch, so not shown: ${missing.join(", ")}. `);
    const a = el("a", null, "View raw patch");
    a.href = root.dataset.patchUrl;
    footer.append(a);
  }

  const options = {
    ...OPTIONS,
    diffStyle: prefs.get("diffStyle"),
    // Patches only carry a few lines of context. The full files are fetched
    // by blob id the first time a separator is clicked.
    loadDiffFiles: async (diff) => {
      const { oldBlob, newBlob } = blobs.get(diff) ?? byPath.get(diff.name)?.data ?? {};
      if (!oldBlob || !newBlob) return undefined;
      const blob = (id) => fetchText(`${root.dataset.blobUrl}/${id}`);
      const [oldContents, newContents] = await Promise.all([blob(oldBlob), blob(newBlob)]);
      return {
        oldFile: { name: diff.prevName ?? diff.name, contents: oldContents },
        newFile: { name: diff.name, contents: newContents },
      };
    },
    renderHeaderPrefix: (_diff, ctx) => {
      const f = byId.get(ctx.item.id);
      return foldToggle(f, () => setCollapsed([f], !f.collapsed));
    },
    renderHeaderFilenameSuffix: (diff, ctx) => fileNotes(byId.get(ctx.item.id), diff),
    renderHeaderMetadata: (_diff, ctx) => {
      const f = byId.get(ctx.item.id);
      const notes = [hiddenBadge(f), wholeToggle(f, () => showWhole(f, !f.whole))].filter(Boolean);
      if (!notes.length) return undefined;
      const span = el("span", "file-actions");
      span.append(...notes);
      return span;
    },
    // Rendered items come from a pool; this says which file each one is now.
    onPostRender: (node, instance, phase, ctx) => {
      if (phase === "unmount") delete node.dataset.file;
      else node.dataset.file = ctx.item.id;
      const f = byId.get(ctx.item.id);
      f.instance = instance;
      if (f.whole && !f.opened) queueMicrotask(() => openWhole(f));
    },
    // Clicking a line number selects it, shift-click a range; the URL says
    // which, so it can be shared.
    enableLineSelection: true,
    onSelectedLinesChange: (selection) => {
      const hash = selection ? `#${lineHash(selection)}` : "";
      history.replaceState(history.state, "", `${location.pathname}${location.search}${hash}`);
    },
    renderCodeViewHeader: () => header,
    renderCodeViewFooter: () => (missing.length ? footer : undefined),
  };
  const view = new CodeView(options, workerPool());

  const setCollapsed = (list, collapsed) => {
    for (const f of list) {
      if (f.collapsed === collapsed) continue;
      f.collapsed = collapsed;
      f.version++;
      view.updateItem(item(f));
    }
  };

  // The whole file, every gap opened: what shift-clicking each separator
  // does, once the file has been drawn. Back to only the changes is the
  // same file from the patch again.
  const openWhole = (f) => {
    if (!f.whole || f.opened || !f.instance) return;
    f.opened = true;
    for (let i = 0; i <= f.fileDiff.hunks.length; i++) f.instance.expandHunk(i, "both", Number.POSITIVE_INFINITY);
  };
  const showWhole = (f, whole) => {
    if (f.whole === whole) return;
    f.whole = whole;
    f.opened = false;
    f.version++;
    if (whole) {
      setCollapsed([f], false);
      openWhole(f);
    } else {
      f.fileDiff = parsePatchFiles(patch).flatMap((p) => p.files).find((d) => d.name === f.fileDiff.name);
      blobs.set(f.fileDiff, f.data);
    }
    view.updateItem(item(f));
  };

  root.replaceChildren(diffControls(view, options, files, setCollapsed));
  header.append(...main.childNodes);
  main.classList.add("codeview");
  document.body.classList.add("codeview");
  view.setup(main);
  view.setItems(files.map(item));

  const top = (i) => view.getTopForItem(files[i].id);
  // The file last moved to is outlined, since one near the end may not
  // reach the top. A rule, not a class, as rendered items are reused.
  const highlight = document.head.appendChild(el("style"));
  const go = (i, behavior = "instant") => {
    if (!files[i]) return;
    view.scrollTo({ type: "item", id: files[i].id, align: "start", behavior });
    history.replaceState(history.state, "", `#${files[i].id}`);
    highlight.textContent = `main.codeview diffs-container[data-file="${files[i].id}"] { border-color: var(--accent); }`;
  };
  const navigated = navigation(main, view, files, top, go);

  // The summary's links point at files that may not be in the DOM.
  main.addEventListener("click", (e) => {
    const a = e.target.closest?.("a[href^='#']");
    const i = a ? files.findIndex((f) => `#${f.id}` === a.getAttribute("href")) : -1;
    if (i < 0) return;
    e.preventDefault();
    setCollapsed([files[i]], false);
    go(i, "smooth");
    navigated(i);
  });

  // The window no longer scrolls, so the browser cannot put the reader back
  // where they were on reload or back/forward; this does. The place is kept
  // as a file and how far into it, since until CodeView has measured the
  // header a plain position would land somewhere else.
  let saving = null;
  view.subscribeToScroll((scrollTop) => {
    clearTimeout(saving);
    saving = setTimeout(() => {
      let i = files.length - 1;
      while (i > 0 && top(i) > scrollTop) i--;
      if (i < 0) return;
      history.replaceState({ ...history.state, place: { id: files[i].id, offset: scrollTop - top(i) } }, "");
    }, 150);
  });
  // Resolves once a file shown whole has its contents and has been drawn
  // with them. Nothing says when, so this looks each frame, for a while.
  const whenWhole = (f) => new Promise((resolve) => {
    let frames = 0;
    const check = () => {
      if (f.opened && !f.fileDiff.isPartial) requestAnimationFrame(() => requestAnimationFrame(resolve));
      else if (++frames < 600) requestAnimationFrame(check);
    };
    check();
  });

  // #f2 is a file, #f2-R10 a line on its new side (L the old), #f2-R10-R14
  // a range. A line the patch does not show opens the whole file.
  const follow = (hash, scroll) => {
    const i = files.findIndex((f) => `#${f.id}` === hash);
    if (i >= 0) {
      if (scroll) { go(i); navigated(i); }
      return;
    }
    const selection = parseLineHash(hash);
    const f = selection && byId.get(selection.id);
    if (!f) return;
    setCollapsed([f], false);
    const show = () => {
      view.setSelectedLines(selection, { notify: false });
      if (scroll) view.scrollTo({ type: "range", ...selection, align: "center" });
    };
    if (scroll) navigated(files.indexOf(f));
    show();
    if (!inHunks(f.fileDiff, selection.range)) {
      // The lines exist once the whole file has loaded and been drawn.
      showWhole(f, true);
      whenWhole(f).then(show);
    }
  };
  window.addEventListener("hashchange", () => follow(location.hash, true));

  const place = history.state?.place;
  follow(location.hash, !(place && byId.has(place.id)));
  if (place && byId.has(place.id)) view.scrollTo({ type: "item", id: place.id, align: "start", offset: -place.offset });
  main.focus({ preventScroll: true });
}

const SIDES = { L: "deletions", R: "additions" };
const sideLetter = (side) => (side === "deletions" ? "L" : "R");

function lineHash({ id, range }) {
  const start = `${sideLetter(range.side)}${range.start}`;
  const end = `${sideLetter(range.endSide ?? range.side)}${range.end}`;
  return start === end ? `${id}-${start}` : `${id}-${start}-${end}`;
}

function parseLineHash(hash) {
  const m = /^#(f\d+)-([LR])(\d+)(?:-([LR])(\d+))?$/.exec(hash);
  if (!m) return undefined;
  const [, id, side, start, endSide = side, end = start] = m;
  return { id, range: { start: Number(start), side: SIDES[side], end: Number(end), endSide: SIDES[endSide] } };
}

// Whether the patch's hunks show both ends of a range.
function inHunks(fileDiff, { start, side, end, endSide }) {
  const shown = (n, s) => fileDiff.hunks.some((h) => (s === "deletions"
    ? n >= h.deletionStart && n < h.deletionStart + h.deletionCount
    : n >= h.additionStart && n < h.additionStart + h.additionCount));
  return shown(start, side) && shown(end, endSide ?? side);
}

// Only for a file whose two sides can be fetched: added and deleted files
// are whole already.
function wholeToggle(file, onclick) {
  const { oldBlob, newBlob } = file.data;
  if (!oldBlob || !newBlob || file.fileDiff.hunks.length === 0) return undefined;
  const b = button(file.whole ? "Show changes" : "Show whole file", "", (e) => { e.stopPropagation(); onclick(); });
  b.className = "whole";
  b.title = file.whole ? "Show only the changed lines and their context" : "Show every line of the file";
  b.setAttribute("aria-pressed", String(file.whole));
  return b;
}

function foldToggle(file, onclick) {
  const b = button("", "", (e) => { e.stopPropagation(); onclick(); });
  b.className = "fold";
  b.setAttribute("aria-expanded", String(!file.collapsed));
  b.setAttribute("aria-label", file.collapsed ? "Expand file" : "Collapse file");
  b.title = file.collapsed ? "Expand file" : "Collapse file";
  return b;
}

// What pierre's header does not show. Beside the name: a mode change, or
// that a file is binary or changed nothing.
function fileNotes(file, diff) {
  const { mode, binary } = file.data;
  const notes = [];
  if (mode) notes.push(`mode ${mode}`);
  if (binary != null) notes.push("binary, not shown");
  else if (diff.hunks.length === 0 && !mode) notes.push("no content changes");
  return notes.length ? el("span", "file-notes muted", notes.join(" · ")) : undefined;
}

// Beside the counts: lines with characters a reader would not see.
function hiddenBadge(file) {
  const { hidden } = file.data;
  if (!hidden) return undefined;
  const n = hidden.split(", ").length;
  const badge = el("span", "file-notes badge hidden", `hidden characters on ${n} ${n === 1 ? "line" : "lines"}`);
  badge.title = `Zero-width, bidi or control characters on lines ${hidden}`;
  return badge;
}

function diffControls(view, options, files, setCollapsed) {
  const bar = el("div", "diff-controls");
  const style = el("span", "seg");
  const modes = { unified: "Unified", split: "Split" };
  const segButtons = Object.entries(modes).map(([mode, text]) => [mode, button(text, `${text} view`, () => {
    prefs.set("diffStyle", mode);
    options.diffStyle = mode;
    view.setOptions({ ...options });
    mark();
  })]);
  const mark = () => segButtons.forEach(([m, b]) => b.setAttribute("aria-pressed", String(m === prefs.get("diffStyle"))));
  mark();
  style.append(...segButtons.map(([, b]) => b));
  bar.append(
    style,
    button("Collapse all", "Collapse all files", () => setCollapsed(files, true)),
    button("Expand all", "Expand all files", () => setCollapsed(files, false)),
  );
  return bar;
}

// j / k move between files: to the start of the next one, or back to the
// start of the one being read, then the one before. Files near the end may
// not reach the top of the view, so the last one moved to counts until the
// reader scrolls some other way.
function navigation(main, view, files, top, go) {
  let current = -1;
  let moved = true; // since the last j or k
  const scrolled = () => { moved = true; };
  for (const type of ["wheel", "touchstart", "pointerdown"]) main.addEventListener(type, scrolled, { passive: true });
  document.addEventListener("keydown", (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest?.("input, textarea, select")) return;
    if (e.key !== "j" && e.key !== "k") return scrolled(); // space, arrows, page keys
    e.preventDefault();
    let i = current;
    if (moved) {
      // The file whose start is at or above the top of the view; -1 above the first.
      const at = view.getScrollTop() + 1;
      i = files.length - 1;
      while (i >= 0 && top(i) > at) i--;
      if (e.key === "k" && i >= 0 && top(i) < at - 2) i++; // mid-file: k goes to its start
    }
    current = e.key === "j" ? Math.min(i + 1, files.length - 1) : Math.max(i - 1, 0);
    go(current);
    moved = false;
  });
  return (i) => { current = i; moved = false; };
}

// A single file, as it is in a commit: the same CodeView with one file item
// (pierre's File rendering) in place of diffs. The URL hash selects lines,
// #L10 or #L10-L14.
async function mountFile(root) {
  const name = root.dataset.fileName;
  const contents = await fetchText(root.dataset.blobUrl);
  const main = root.closest("main");
  const header = el("div", "codeview-head");
  const hash = ({ range: { start, end } }) => (start === end ? `#L${start}` : `#L${start}-L${end}`);
  const view = new CodeView({
    ...OPTIONS,
    enableLineSelection: true,
    onSelectedLinesChange: (selection) => {
      history.replaceState(history.state, "", `${location.pathname}${location.search}${selection ? hash(selection) : ""}`);
    },
    renderCodeViewHeader: () => header,
  }, workerPool());
  root.remove();
  header.append(...main.childNodes);
  main.classList.add("codeview");
  document.body.classList.add("codeview");
  view.setup(main);
  const id = "file";
  view.setItems([{ id, type: "file", file: { name, contents, cacheKey: root.dataset.blobUrl }, version: 0 }]);

  const m = /^#L(\d+)(?:-L?(\d+))?$/.exec(location.hash);
  if (m) {
    const start = Number(m[1]);
    const end = Number(m[2] ?? m[1]);
    view.setSelectedLines({ id, range: { start, end } });
    view.scrollTo({ type: "line", id, lineNumber: start, align: "center", behavior: "instant" });
  }
}

for (const root of document.querySelectorAll("[data-file-name]")) {
  mountFile(root).catch((err) => {
    console.error(err);
    root.textContent = `Could not render file (${err.message}). `;
    const a = document.createElement("a");
    a.href = root.dataset.blobUrl;
    a.textContent = "View raw file";
    root.appendChild(a);
  });
}

for (const root of document.querySelectorAll("[data-patch-url]")) {
  mount(root).catch((err) => {
    console.error(err);
    const link = root.dataset.patchUrl;
    root.querySelectorAll("[data-diff-file]").forEach((el) => {
      el.textContent = `Could not render diff (${err.message}). `;
      const a = document.createElement("a");
      a.href = link;
      a.textContent = "View raw patch";
      el.appendChild(a);
    });
  });
}
