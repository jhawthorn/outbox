// Renders the diffs on branch and commit pages. The server emits one
// placeholder per file (data-diff-file) inside a root element that carries
// the URL of the raw patch (data-patch-url). This fetches the patch, parses
// it, and mounts a @pierre/diffs FileDiff into each placeholder, matched by
// path. Summary, badges, counts and file headers stay server-rendered.
import { FileDiff, parsePatchFiles } from "@pierre/diffs";

const OPTIONS = {
  theme: { light: "pierre-light", dark: "pierre-dark" },
  themeType: "system",
  diffStyle: "unified",
  overflow: "wrap",
  disableFileHeader: true,
};

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

  root.querySelectorAll("[data-diff-file]").forEach((el, i) => {
    const fileDiff = byPath.get(el.dataset.diffFile) ?? files[i];
    if (fileDiff == null) {
      el.textContent = "Could not find this file in the patch.";
      return;
    }
    el.textContent = "";
    new FileDiff(OPTIONS).render({ fileDiff, containerWrapper: el });
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
