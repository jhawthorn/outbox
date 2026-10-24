// Renders the diffs on branch and commit pages. The server emits one
// <details class="file"> per file inside a root element that carries the URL
// of the raw patch (data-patch-url); each has the path, blob ids and what its
// header shows besides path and counts as data attributes. That markup is
// what a page without this script shows.
//
// This fetches the patch, parses it, and replaces the files with a single
// @pierre/diffs CodeView. The patch is read as it arrives and parsed a file
// at a time in slices of a few milliseconds, the way diffshub.com does, so
// a diff of any size shows its first files at once and the page never
// freezes; the rest are added to the view as they are parsed. CodeView owns its scroll container, so once it
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
import { CodeView, processFile } from "@pierre/diffs";
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

// The tree beside a diff earns its room from a handful of files on, unless
// the reader has said otherwise.
const TREE_FROM = 5;

// Files the reader has marked viewed, kept across pages. The key is the
// repository, the file's path, both blob ids and any mode change, so a
// file that changes after it was viewed (a new push) is unviewed again, as
// on GitHub.
const REPO = /^\/repos\/([^/]+)/.exec(location.pathname)?.[1] ?? "";
const viewed = {
  key: (data) => `outbox:viewed:${REPO}:${data.path}:${data.oldBlob ?? ""}:${data.newBlob ?? ""}:${data.mode ?? ""}`,
  get(data) {
    try { return localStorage.getItem(this.key(data)) === "1"; } catch { return false; }
  },
  set(data, on) {
    try { on ? localStorage.setItem(this.key(data), "1") : localStorage.removeItem(this.key(data)); } catch {}
  },
};

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

// The patch's files as text, one at a time, as they arrive. A file ends where
// the next "diff --git" line starts, which the diff lines themselves cannot
// contain: they begin with a space, + or -. Chunks are searched on their
// own, with the last few characters held back in case the line is split
// between two, so a file of many megabytes is not searched over and over.
const FILE_BREAK = "\ndiff --git ";

async function* patchFiles(res) {
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let pieces = [];
  let held = "";
  const next = (text) => {
    pieces.push(text);
    const file = pieces.join("");
    pieces = [];
    return file;
  };
  for (;;) {
    const { done, value } = await reader.read();
    let text = held + (done ? decoder.decode() : decoder.decode(value, { stream: true }));
    held = "";
    for (let i; (i = text.indexOf(FILE_BREAK)) >= 0; ) {
      const file = next(text.slice(0, i + 1));
      text = text.slice(i + 1);
      if (file.startsWith("diff --git ")) yield file;
    }
    if (done) {
      const file = next(text);
      if (file.startsWith("diff --git ")) yield file;
      return;
    }
    const keep = Math.max(0, text.length - FILE_BREAK.length + 1);
    pieces.push(text.slice(0, keep));
    held = text.slice(keep);
  }
}

const yieldToBrowser = () => (globalThis.scheduler?.yield ? scheduler.yield() : new Promise((resolve) => setTimeout(resolve)));
// How long the parser runs before the page gets a turn.
const SLICE_MS = 8;

async function mount(root) {
  const res = await fetch(root.dataset.patchUrl, { headers: { accept: "text/plain" } }).catch((err) => {
    throw new Error(`patch ${err.message}`);
  });
  if (!res.ok) throw new Error(`patch request failed with status ${res.status}`);

  // One entry per server-rendered file, in the server's order and with its
  // id (f0, f1, …), so the summary's links keep working. A file is added to
  // the view once the patch has reached it.
  const slots = new Map();
  for (const details of root.querySelectorAll("details.file")) slots.set(details.dataset.path, { id: details.id, data: details.dataset });
  const slotIds = new Set([...slots.values()].map((s) => s.id));
  const files = [];
  const byId = new Map();
  const blobs = new WeakMap();
  const item = (f) => ({ id: f.id, type: "diff", fileDiff: f.fileDiff, collapsed: f.collapsed, version: f.version });
  // Whether the reader has collapsed everything, which files still to come join.
  let collapsedAll = false;

  // Everything on the page above the files becomes CodeView's header, and
  // a note about any file the patch lacks (it was truncated) its footer.
  const main = root.closest("main");
  const header = el("div", "codeview-head");
  const footer = el("div", "codeview-foot");
  const footnote = (text) => {
    footer.replaceChildren(text);
    const a = el("a", null, "View raw patch");
    a.href = root.dataset.patchUrl;
    footer.append(a);
  };

  const options = {
    ...OPTIONS,
    diffStyle: prefs.get("diffStyle"),
    // Patches only carry a few lines of context. The full files are fetched
    // by blob id the first time a separator is clicked.
    loadDiffFiles: async (diff) => {
      const { oldBlob, newBlob } = blobs.get(diff) ?? slots.get(diff.name)?.data ?? {};
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
      const notes = [hiddenBadge(f), wholeToggle(f, () => showWhole(f, !f.whole)), viewedToggle(f, () => markViewed(f, !f.viewed))].filter(Boolean);
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
    renderCodeViewFooter: () => footer,
  };
  const view = new CodeView(options, workerPool());

  const setCollapsed = (list, collapsed) => {
    if (list === files) collapsedAll = collapsed;
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
      f.fileDiff = processFile(f.text, { isGitDiff: true });
      blobs.set(f.fileDiff, f.data);
    }
    view.updateItem(item(f));
  };

  // Parses files until a slice of time is used up (or the patch ends) and
  // returns them. Waiting for the network does not count, but a slice never
  // lasts more than a moment longer than that.
  const stream = patchFiles(res);
  let finished = false;
  let failure = null;
  const readSlice = async () => {
    const batch = [];
    let worked = 0;
    const began = performance.now();
    while (worked < SLICE_MS && performance.now() - began < 250) {
      let done, text;
      try {
        ({ done, value: text } = await stream.next());
      } catch (err) {
        failure = err;
        done = true;
      }
      if (done) {
        finished = true;
        break;
      }
      const t = performance.now();
      const fileDiff = processFile(text, { isGitDiff: true });
      const slot = fileDiff && (slots.get(fileDiff.name) ?? slots.get(fileDiff.prevName));
      if (slot) batch.push({ id: slot.id, data: slot.data, fileDiff, text, collapsed: false, version: 0, whole: false, instance: null });
      worked += performance.now() - t;
    }
    return batch;
  };
  // Files count as there once the view has them.
  const commit = (batch) => {
    for (const f of batch) {
      f.viewed = viewed.get(f.data);
      f.collapsed = collapsedAll || f.viewed;
      files.push(f);
      byId.set(f.id, f);
      blobs.set(f.fileDiff, f.data);
    }
    return batch.map(item);
  };

  const first = await readSlice();
  if (failure && !first.length) throw new Error(`patch ${failure.message}`);
  root.replaceChildren(diffControls(view, options, files, setCollapsed, slots.size > 1 && toggleTree, slots.size >= TREE_FROM));
  header.append(...main.childNodes);
  main.classList.add("codeview");
  document.body.classList.add("codeview");
  view.setup(main);
  view.setItems(commit(first));

  const top = (i) => view.getTopForItem(files[i].id);
  // The file last moved to is outlined, since one near the end may not
  // reach the top. A rule, not a class, as rendered items are reused.
  const highlight = document.head.appendChild(el("style"));
  const go = (i, behavior = "instant") => {
    if (!files[i]) return;
    view.scrollTo({ type: "item", id: files[i].id, align: "start", behavior });
    history.replaceState(history.state, "", `#${files[i].id}`);
    highlight.textContent = `main.codeview diffs-container[data-file="${files[i].id}"] { border-color: var(--accent); }`;
    // The tree says so, and keeps saying so until the reader scrolls: a
    // file near the end may never reach the top.
    pinned = true;
    tree?.current(files[i].id);
  };
  let pinned = false;
  for (const type of ["wheel", "touchstart", "pointerdown"]) main.addEventListener(type, () => { pinned = false; }, { passive: true });
  document.addEventListener("keydown", (e) => { if (e.key !== "j" && e.key !== "k") pinned = false; });
  const navigated = navigation(main, view, files, top, go);

  // The summary's links, and the tree's, point at files that may not be in
  // the DOM.
  const jump = (e) => {
    const a = e.target.closest?.("a[href^='#f']");
    const href = a?.getAttribute("href");
    const i = a ? files.findIndex((f) => `#${f.id}` === href) : -1;
    if (i < 0) {
      // A file the patch has not reached yet: go there once it has.
      if (a && notYet(href.slice(1))) {
        e.preventDefault();
        onceAdded(href.slice(1), () => a.click());
      }
      return;
    }
    e.preventDefault();
    setCollapsed([files[i]], false);
    go(i, "smooth");
    navigated(i);
  };
  main.addEventListener("click", jump);

  // Viewed files fold away, and the tree and its count say so.
  const markViewed = (f, on) => {
    f.viewed = on;
    viewed.set(f.data, on);
    f.version++;
    setCollapsed([f], on);
    view.updateItem(item(f));
    tree?.viewed(f.id, on);
  };

  // The files as a tree beside the diff, for a diff of more than one.
  let tree = null;
  function toggleTree(show) {
    prefs.set("fileTree", show ? "shown" : "hidden");
    document.body.classList.toggle("with-tree", show);
    if (show && !tree) {
      tree = fileTree([...slots.values()], jump);
      document.body.insertBefore(tree.element, main);
      for (const f of files) if (f.viewed) tree.viewed(f.id, true);
      for (const [, slot] of slots) if (viewed.get(slot.data)) tree.viewed(slot.id, true);
    }
  }
  const treeShown = () => (prefs.get("fileTree") ?? (slots.size >= TREE_FROM ? "shown" : "hidden")) === "shown";
  if (slots.size > 1 && treeShown()) toggleTree(true);
  // The file at the top of the view is the current one in the tree.
  let tracking = 0;
  view.subscribeToScroll((scrollTop) => {
    if (!tree || tracking || pinned) return;
    tracking = requestAnimationFrame(() => {
      tracking = 0;
      let i = files.length - 1;
      while (i > 0 && top(i) > scrollTop + 1) i--;
      if (files[i]) tree.current(files[i].id);
    });
  });

  // Files are added as the patch is parsed. Something aimed at one that is
  // not there yet waits for it.
  const waiting = [];
  const notYet = (id) => !finished && slotIds.has(id) && !byId.has(id);
  const onceAdded = (id, fn) => waiting.push([id, fn]);

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
    const id = /^#(f\d+)/.exec(hash)?.[1];
    if (id && notYet(id)) return onceAdded(id, () => follow(hash, scroll));
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

  // Where the page was opened to: the file in the URL, or where the reader
  // was before a reload. Once the files that takes are in the view.
  const place = history.state?.place;
  const opened = () => {
    follow(location.hash, !(place && byId.has(place.id)));
    if (place && byId.has(place.id)) view.scrollTo({ type: "item", id: place.id, align: "start", offset: -place.offset });
  };
  const wanted = [/^#(f\d+)/.exec(location.hash)?.[1], place?.id].filter(Boolean);
  let arrived = false;
  const arrive = () => {
    if (arrived || !(finished || wanted.every((id) => !notYet(id)))) return;
    arrived = true;
    opened();
  };
  arrive();
  main.focus({ preventScroll: true });

  // The rest of the patch, a slice at a time.
  const progress = () => footer.replaceChildren(`Reading the patch: ${files.length} of ${slotIds.size} files…`);
  while (!finished) {
    progress();
    await yieldToBrowser();
    const batch = await readSlice();
    if (batch.length) view.addItems(commit(batch));
    for (const entry of waiting.splice(0)) {
      if (!notYet(entry[0])) entry[1]();
      else waiting.push(entry);
    }
    arrive();
  }
  footer.replaceChildren();
  const missing = [...slots].filter(([, slot]) => !byId.has(slot.id)).map(([path]) => path);
  if (failure) {
    console.error(failure);
    footnote(`The patch could not be read to the end (${failure.message}), so files after ${files.at(-1)?.data.path ?? "the start"} are not shown. `);
  } else if (missing.length) {
    footnote(`Not in the patch, so not shown: ${missing.join(", ")}. `);
  }
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

function viewedToggle(file, onchange) {
  const label = el("label", "viewed");
  label.title = "Mark the file viewed: it folds away until it changes";
  const box = el("input");
  box.type = "checkbox";
  box.checked = file.viewed;
  box.addEventListener("click", (e) => e.stopPropagation());
  box.addEventListener("change", () => onchange());
  label.addEventListener("click", (e) => e.stopPropagation());
  label.append(box, "Viewed");
  return label;
}

// The files of a diff as a tree of directories, a directory with one child
// directory drawn as one ("lib/active_record"). Each file links to its
// place in the diff (#f3). Returns the element and what updates it: the
// current file, and whether a file is viewed.
function fileTree(slots, jump) {
  // Directories and files in the order they first appear, which is the
  // diff's, so the tree reads down the way j does.
  const newDir = () => ({ dirs: new Map(), entries: [] });
  const root = newDir();
  for (const slot of slots) {
    const parts = slot.data.path.split("/");
    const name = parts.pop();
    let node = root;
    for (const part of parts) {
      if (!node.dirs.has(part)) {
        const dir = newDir();
        node.dirs.set(part, dir);
        node.entries.push({ name: part, dir });
      }
      node = node.dirs.get(part);
    }
    node.entries.push({ name, slot });
  }
  const links = new Map();
  const draw = (node) => {
    const ul = el("ul");
    for (const entry of node.entries) {
      const li = el("li");
      if (entry.dir) {
        let { name, dir } = entry;
        while (dir.entries.length === 1 && dir.entries[0].dir) {
          name = `${name}/${dir.entries[0].name}`;
          dir = dir.entries[0].dir;
        }
        const head = el("div", "dir");
        head.append(el("span", "n", name));
        head.title = name;
        head.addEventListener("click", () => li.classList.toggle("closed"));
        li.append(head, draw(dir));
      } else {
        const { name, slot } = entry;
        const a = el("a");
        a.href = `#${slot.id}`;
        a.append(el("span", `st ${slot.data.status}`), el("span", "n", name));
        if (slot.data.add != null) {
          const counts = el("span", "count");
          counts.append(el("span", "count add", `+${slot.data.add}`), " ", el("span", "count del", `−${slot.data.del}`));
          a.append(counts);
        }
        a.title = `${slot.data.path} (${slot.data.status})`;
        links.set(slot.id, a);
        li.append(a);
      }
      ul.append(li);
    }
    return ul;
  };
  const element = el("aside", "filetree");
  element.setAttribute("aria-label", "Files in this diff");
  const head = el("div", "tree-head");
  const filter = el("input");
  filter.type = "search";
  filter.placeholder = "Filter files";
  filter.setAttribute("aria-label", "Filter files");
  const progress = el("div", "progress-line");
  const meter = el("span", "meter");
  const fill = el("i");
  meter.append(fill);
  const count = el("span");
  progress.append(meter, count);
  head.append(filter, progress);
  const list = draw(root);
  element.append(head, list);
  element.addEventListener("click", jump);

  const seen = new Set();
  const total = slots.length;
  const tally = () => {
    count.textContent = `${seen.size} / ${total} viewed`;
    fill.style.width = `${(100 * seen.size) / total}%`;
  };
  tally();
  filter.addEventListener("input", () => {
    const q = filter.value.trim().toLowerCase();
    for (const [, a] of links) a.parentElement.hidden = q && !a.title.toLowerCase().includes(q);
    for (const li of list.querySelectorAll("li:has(> .dir)")) {
      li.hidden = !li.querySelector("li:not([hidden]) > a");
    }
  });
  let current = null;
  return {
    element,
    current(id) {
      const a = links.get(id);
      if (!a || a === current) return;
      current?.removeAttribute("aria-current");
      a.setAttribute("aria-current", "true");
      current = a;
      for (let li = a.closest("li.closed"); li; li = li.parentElement.closest("li.closed")) li.classList.remove("closed");
      a.scrollIntoView({ block: "nearest" });
    },
    viewed(id, on) {
      const a = links.get(id);
      if (!a) return;
      a.classList.toggle("viewed", on);
      on ? seen.add(id) : seen.delete(id);
      tally();
    },
  };
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

function diffControls(view, options, files, setCollapsed, toggleTree, treeByDefault) {
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
  if (toggleTree) {
    const b = button("Files", "Show or hide the list of files beside the diff", () => {
      const show = !document.body.classList.contains("with-tree");
      toggleTree(show);
      b.setAttribute("aria-pressed", String(show));
    });
    b.setAttribute("aria-pressed", String((prefs.get("fileTree") ?? (treeByDefault ? "shown" : "hidden")) === "shown"));
    b.className = "tree-toggle";
    bar.append(b);
  }
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
    // The page above it names the file and says what it is.
    disableFileHeader: true,
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
