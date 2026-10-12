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
};

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
  const res = await fetch(root.dataset.patchUrl, { headers: { accept: "text/plain" } });
  if (!res.ok) throw new Error(`patch request failed with status ${res.status}`);
  const text = await res.text();

  const files = parsePatchFiles(text).flatMap((p) => p.files);
  const byPath = new Map();
  for (const f of files) {
    byPath.set(f.name, f);
    if (f.prevName && !byPath.has(f.prevName)) byPath.set(f.prevName, f);
  }

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
    new VirtualizedFileDiff(OPTIONS, virtualizer, undefined, pool).render({ fileDiff, containerWrapper: el });
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
