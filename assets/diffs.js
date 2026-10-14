// Renders the diffs on branch and commit pages. The server emits one
// placeholder per file (data-diff-file) inside a root element that carries
// the URL of the raw patch (data-patch-url). This fetches the patch, parses
// it, and mounts a @pierre/diffs FileDiff into each placeholder, matched by
// path. Summary, badges, counts and file headers stay server-rendered.
//
// Large patches stay fast because of two things: files are drawn through a
// Virtualizer (only files near the viewport are in the DOM), and Shiki
// highlighting runs in a pool of web workers (public/diffs/worker.js) instead
// of on the main thread.
import { VirtualizedFileDiff, Virtualizer, parsePatchFiles } from "@pierre/diffs";
import { getOrCreateWorkerPoolSingleton } from "@pierre/diffs/worker";

const THEME = { light: "pierre-light", dark: "pierre-dark" };

const OPTIONS = {
  theme: THEME,
  themeType: "system",
  diffStyle: "unified",
  overflow: "wrap",
  disableFileHeader: true,
  // Clickable separators between hunks that reveal the unchanged lines.
  hunkSeparators: "line-info",
  expansionLineCount: 20,
  collapsedContextThreshold: 3,
};

async function fetchBlob(root, id) {
  const res = await fetch(`${root.dataset.blobUrl}/${id}`, { headers: { accept: "text/plain" } });
  if (!res.ok) throw new Error(`file request failed with status ${res.status}`);
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

async function mount(root) {
  const instances = [];
  const res = await fetch(root.dataset.patchUrl, { headers: { accept: "text/plain" } });
  if (!res.ok) throw new Error(`patch request failed with status ${res.status}`);
  const text = await res.text();

  const files = parsePatchFiles(text).flatMap((p) => p.files);
  const byPath = new Map();
  for (const f of files) {
    byPath.set(f.name, f);
    if (f.prevName && !byPath.has(f.prevName)) byPath.set(f.prevName, f);
  }

  setupControls(root, instances);
  const virtualizer = new Virtualizer();
  virtualizer.setup(document);
  const pool = workerPool();

  root.querySelectorAll("[data-diff-file]").forEach((el, i) => {
    const fileDiff = byPath.get(el.dataset.diffFile) ?? files[i];
    if (fileDiff == null) {
      el.textContent = "Could not find this file in the patch.";
      return;
    }
    el.textContent = "";
    // Patches only carry a few lines of context. The full files are fetched
    // by blob id the first time a separator is clicked.
    const { oldBlob, newBlob } = el.dataset;
    const options = { ...OPTIONS };
    if (oldBlob && newBlob) {
      options.loadDiffFiles = async (diff) => {
        const [oldContents, newContents] = await Promise.all([fetchBlob(root, oldBlob), fetchBlob(root, newBlob)]);
        return {
          oldFile: { name: diff.prevName ?? diff.name, contents: oldContents },
          newFile: { name: diff.name, contents: newContents },
        };
      };
    }
    options.diffStyle = prefs.get("diffStyle");
    const instance = new VirtualizedFileDiff(options, virtualizer, undefined, pool);
    instance.render({ fileDiff, containerWrapper: el });
    instances.push(instance);
  });
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

function button(label, title, onclick) {
  const b = document.createElement("button");
  b.type = "button";
  b.textContent = label;
  b.title = title;
  b.addEventListener("click", onclick);
  return b;
}

function setupControls(root, instances) {
  const files = [...root.querySelectorAll("details.file")];
  const bar = document.createElement("div");
  bar.className = "diff-controls";
  const style = document.createElement("span");
  style.className = "seg";
  const modes = { unified: "Unified", split: "Split" };
  const segButtons = Object.entries(modes).map(([mode, text]) => {
    const b = button(text, `${text} view`, () => {
      prefs.set("diffStyle", mode);
      for (const inst of instances) { inst.setOptions({ ...inst.options, diffStyle: mode }); inst.rerender(); }
      mark();
    });
    return [mode, b];
  });
  const mark = () => segButtons.forEach(([m, b]) => b.setAttribute("aria-pressed", String(m === prefs.get("diffStyle"))));
  mark();
  style.append(...segButtons.map(([, b]) => b));
  bar.append(
    style,
    button("Collapse all", "Collapse all files", () => files.forEach((d) => (d.open = false))),
    button("Expand all", "Expand all files", () => files.forEach((d) => (d.open = true))),
  );
  root.before(bar);

  // j / k move between files.
  let current = -1;
  const focusFile = (i) => {
    current = Math.max(0, Math.min(files.length - 1, i));
    files[current].scrollIntoView({ block: "start" });
    history.replaceState(null, "", `#${files[current].id}`);
  };
  const nearest = () => {
    const i = files.findIndex((d) => d.getBoundingClientRect().bottom > 60);
    return i < 0 ? files.length - 1 : i;
  };
  document.addEventListener("keydown", (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest?.("input, textarea, select")) return;
    if (e.key === "j") { focusFile((current < 0 ? nearest() - 1 : current) + 1); }
    else if (e.key === "k") { focusFile((current < 0 ? nearest() : current) - 1); }
    else return;
    e.preventDefault();
  });
}

for (const root of document.querySelectorAll("[data-patch-url]")) {
  mount(root).catch((err) => {
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
