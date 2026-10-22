// @ts-check
// The branch and commit pages of the "review" repository, which no test
// changes: two staged commits touching four files, one of them in two
// places. Everything here is drawn by assets/diffs.js in the browser.
const { test, expect } = require("@playwright/test");

const BRANCH = "/repos/review/branches/main";
const HEADERS = "/repos/headers/branches/main";

// The rendered file with this index (f0, f1, …), header and diff. Only files
// near the view are in the DOM.
const diff = (page, i) => page.locator(`main.codeview diffs-container[data-file=f${i}]`);
const title = (page, i) => diff(page, i).locator("[data-diffs-header] [data-title]");
// Scroll the view to a file through its link in the summary, so it is
// drawn, and wait for the smooth scroll to finish.
const reveal = async (page, i) => {
  await page.locator(`.patch-summary a[href="#f${i}"]`).click();
  await expect(diff(page, i)).toBeInViewport();
  const at = () => page.locator("main").evaluate((m) => m.scrollTop);
  for (let last = -1, now = await at(); now !== last; ) {
    await page.waitForTimeout(100);
    [last, now] = [now, await at()];
  }
};
// How far the top of an element is below the top of the scrolling <main>.
const fromTop = (page, locator) => locator.evaluate((el) => el.getBoundingClientRect().top - document.querySelector("main").getBoundingClientRect().top);

test("each file's diff is rendered from the raw patch", async ({ page }) => {
  await page.goto(BRANCH);
  await expect(page.locator("h1")).toContainText("main");
  await expect(page.locator("h1 .badge")).toHaveText("ready");
  await expect(page.locator("h2", { hasText: "Files changed (4)" })).toBeVisible();

  // Server-rendered summary; the server's file sections give way to one
  // CodeView, with pierre's file headers.
  const summary = page.locator(".patch-summary");
  await expect(summary.locator("li")).toHaveText([/README/, /lib\/long\.rb/, /lib\/thing\.rb.*added/s, /notes\.md.*deleted/s]);
  await expect(page.locator("main.codeview")).toBeVisible();
  await expect(page.locator("details.file")).toHaveCount(0);
  await expect(title(page, 0)).toHaveText("README");
  await expect(diff(page, 0).locator("[data-diffs-header]")).toHaveAttribute("data-change-type", "change");
  await expect(diff(page, 1).locator("[data-additions-count]")).toHaveText("+2");
  await expect(diff(page, 1).locator("[data-deletions-count]")).toHaveText("-2");

  // The patch's lines, highlighted by type.
  await expect(diff(page, 0).getByText("hello world")).toBeVisible();
  await expect(diff(page, 0).locator("[data-line-type=change-addition]").first()).toBeVisible();
  await reveal(page, 1);
  await expect(diff(page, 1).getByText("line ten")).toBeVisible();
  await expect(diff(page, 1).getByText("line one hundred")).toBeVisible();
  await reveal(page, 3);
  await expect(diff(page, 2).locator("[data-diffs-header]")).toHaveAttribute("data-change-type", "new");
  await expect(diff(page, 2).getByText("class Thing")).toBeVisible();
  await expect(diff(page, 3).locator("[data-diffs-header]")).toHaveAttribute("data-change-type", "deleted");
  await expect(diff(page, 3).locator("[data-line-type=change-deletion]").first()).toBeVisible();
  await expect(page.locator(".diff-controls")).toBeVisible();
});

test("unchanged lines between hunks expand from the blob route", async ({ page }) => {
  const blobRequests = [];
  page.on("request", (r) => { if (r.url().includes("/repos/review/blobs/")) blobRequests.push(r.url()); });

  await page.goto(BRANCH);
  await reveal(page, 1);
  const long = diff(page, 1);
  // The gutter and the content column each carry a copy of the separator.
  const between = long.locator("[data-separator][data-expand-index='1']").first();
  await expect(between).toContainText("83 unmodified lines");
  await expect(long.getByText("line 20", { exact: true })).toHaveCount(0);
  expect(blobRequests).toEqual([]);

  // The arrow reveals 20 of the hidden lines, those just above the second
  // hunk, from the full files fetched by blob id.
  await between.locator("[data-expand-down]").click();
  await expect(long.getByText("line 77", { exact: true }).first()).toBeVisible();
  await expect(long.getByText("line 76", { exact: true })).toHaveCount(0);
  await expect(between).toContainText("63 unmodified lines");
  await page.locator("main").evaluate((m) => m.scrollBy(0, 400));
  await expect(long.getByText("line 96", { exact: true }).first()).toBeInViewport();
  // With the whole file known, the trailing separator can say how much is left.
  await expect(long.locator("[data-separator][data-expand-index='2']").first()).toContainText("17 unmodified lines");
  // Both sides of the file, each once.
  expect(blobRequests).toHaveLength(2);
  expect(new Set(blobRequests).size).toBe(2);
  for (const url of blobRequests) expect(url).toMatch(/\/repos\/review\/blobs\/[0-9a-f]{40}$/);
});

test("a file can be shown whole, and back to only its changes", async ({ page }) => {
  await page.goto(BRANCH);
  await reveal(page, 1);
  const long = diff(page, 1);
  const whole = long.locator("button.whole");
  await expect(whole).toHaveText("Show whole file");
  await expect(long.getByText("83 unmodified lines").first()).toBeVisible();
  // Added and deleted files have no more to show.
  await reveal(page, 3);
  await expect(diff(page, 2).locator("button.whole")).toHaveCount(0);
  await expect(diff(page, 3).locator("button.whole")).toHaveCount(0);

  await reveal(page, 1);
  await whole.click();
  await expect(whole).toHaveText("Show changes");
  await expect(whole).toHaveAttribute("aria-pressed", "true");
  await expect(long.getByText("line 1", { exact: true }).first()).toBeVisible();
  await expect(long.locator("[data-separator]")).toHaveCount(0);
  await page.locator("main").evaluate((m) => m.scrollBy(0, 900));
  await expect(long.getByText("line 50", { exact: true }).first()).toBeInViewport();

  await reveal(page, 1);
  await whole.click();
  await expect(whole).toHaveText("Show whole file");
  await expect(long.getByText("83 unmodified lines").first()).toBeVisible();
  await expect(long.getByText("line 50", { exact: true })).toHaveCount(0);
});

test("selecting line numbers puts the lines in the URL", async ({ page }) => {
  await page.goto(BRANCH);
  await reveal(page, 1);
  const number = (n) => diff(page, 1).locator(`[data-column-number="${n}"]`).last();
  await number(11).click();
  await expect(page).toHaveURL(/#f1-R11$/);
  await number(13).click({ modifiers: ["Shift"] });
  await expect(page).toHaveURL(/#f1-R11-R13$/);
  await expect(diff(page, 1).locator("[data-line][data-selected-line]")).toHaveCount(3);
});

test("a link to lines scrolls to them and selects them, showing the whole file if it has to", async ({ page }) => {
  await page.goto(`${BRANCH}#f1-L100`);
  const long = diff(page, 1);
  const old100 = long.locator("[data-line][data-selected-line]");
  await expect(old100).toHaveCount(1);
  await expect(old100).toContainText("line 100");
  await expect(old100).toBeInViewport();
  await expect(long.locator("button.whole")).toHaveText("Show whole file");

  // Lines 50 to 55 are not in the patch.
  await page.goto("about:blank");
  await page.goto(`${BRANCH}#f1-R50-R55`);
  const selected = long.locator("[data-line][data-selected-line]");
  await expect(selected).toHaveCount(6);
  await expect(selected.first()).toHaveText("line 50");
  await expect(selected.first()).toBeInViewport();
  await expect(long.locator("button.whole")).toHaveText("Show changes");
});

test("unified or split view is remembered across pages", async ({ page }) => {
  await page.goto(BRANCH);
  const unified = page.getByRole("button", { name: "Unified", exact: true });
  const split = page.getByRole("button", { name: "Split", exact: true });
  await expect(unified).toHaveAttribute("aria-pressed", "true");
  await expect(diff(page, 0).locator("pre[data-diff-type=single]")).toBeVisible();

  await split.click();
  await expect(split).toHaveAttribute("aria-pressed", "true");
  await expect(unified).toHaveAttribute("aria-pressed", "false");
  await expect(diff(page, 0).locator("pre[data-diff-type=split]")).toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem("outbox:diffStyle"))).toBe("split");

  await page.reload();
  await expect(split).toHaveAttribute("aria-pressed", "true");
  await expect(diff(page, 0).locator("pre[data-diff-type=split]")).toBeVisible();

  await unified.click();
  await expect(diff(page, 0).locator("pre[data-diff-type=single]")).toBeVisible();
});

test("collapse all and expand all fold the files", async ({ page }) => {
  await page.goto(BRANCH);
  const folds = page.locator("main.codeview diffs-container button.fold");
  await expect(folds.first()).toHaveAttribute("aria-expanded", "true");

  // Folded, all four fit in the view.
  await page.getByRole("button", { name: "Collapse all" }).click();
  await expect(folds).toHaveCount(4);
  for (const f of await folds.all()) await expect(f).toHaveAttribute("aria-expanded", "false");
  await expect(diff(page, 0).getByText("hello world")).toHaveCount(0);
  await expect(title(page, 3)).toHaveText("notes.md"); // headers stay

  await page.getByRole("button", { name: "Expand all" }).click();
  await expect(diff(page, 0).locator("button.fold")).toHaveAttribute("aria-expanded", "true");
  await expect(diff(page, 0).getByText("hello world")).toBeVisible();
  await reveal(page, 3);
  await expect(diff(page, 3).locator("button.fold")).toHaveAttribute("aria-expanded", "true");
  await expect(diff(page, 3).locator("[data-line-type=change-deletion]").first()).toBeVisible();
});

test("the toggle in a file's header folds just that file", async ({ page }) => {
  await page.goto(BRANCH);
  const fold = diff(page, 1).locator("button.fold");
  await expect(diff(page, 1).getByText("line ten")).toBeVisible();

  await fold.click();
  await expect(fold).toHaveAttribute("aria-expanded", "false");
  await expect(fold).toHaveAttribute("aria-label", "Expand file");
  await expect(diff(page, 1).getByText("line ten")).toHaveCount(0);
  await expect(diff(page, 0).getByText("hello world")).toBeVisible();

  await fold.click();
  await expect(diff(page, 1).getByText("line ten")).toBeVisible();
});

test("j and k move between files", async ({ page }) => {
  await page.goto(BRANCH);
  await expect(diff(page, 0).locator("[data-line-type]").first()).toBeVisible();
  const hash = () => page.evaluate(() => location.hash);

  await page.keyboard.press("j");
  expect(await hash()).toBe("#f0");
  await page.keyboard.press("j");
  expect(await hash()).toBe("#f1");
  await page.keyboard.press("j");
  await page.keyboard.press("j");
  expect(await hash()).toBe("#f3");
  await page.keyboard.press("j"); // stays on the last file
  expect(await hash()).toBe("#f3");
  await page.keyboard.press("k");
  expect(await hash()).toBe("#f2");
  await page.keyboard.press("k");
  await page.keyboard.press("k");
  expect(await hash()).toBe("#f0");
  // The view scrolled to each file, not just changed the hash.
  await expect.poll(() => fromTop(page, diff(page, 0))).toBeGreaterThanOrEqual(-1);
  expect(await fromTop(page, diff(page, 0))).toBeLessThan(2);
});

test("j reaches files too near the end to scroll to the top, and outlines them", async ({ page }) => {
  await page.goto(HEADERS);
  await expect(title(page, 0)).toHaveText("big.rb");
  const hash = () => page.evaluate(() => location.hash);
  for (const expected of ["#f0", "#f1", "#f2", "#f3", "#f4"]) {
    await page.keyboard.press("j");
    expect(await hash()).toBe(expected);
  }
  await expect(diff(page, 4)).toHaveCSS("border-top-color", "rgb(3, 102, 214)");
  await expect(diff(page, 3)).not.toHaveCSS("border-top-color", "rgb(3, 102, 214)");
  await page.keyboard.press("k");
  expect(await hash()).toBe("#f3");
});

test("a link in the summary scrolls to its file", async ({ page }) => {
  await page.goto(HEADERS);
  await expect(title(page, 0)).toHaveText("big.rb");
  await expect(diff(page, 2)).toHaveCount(0); // far below, not drawn
  await page.locator(".patch-summary a", { hasText: "new_name.rb" }).click();
  await expect(title(page, 2)).toHaveText("new_name.rb");
  await expect(diff(page, 2)).toBeInViewport();
  await expect(page).toHaveURL(/#f2$/);
});

test("a reload comes back to the same place in the diff", async ({ page }) => {
  await page.goto(HEADERS);
  await expect(title(page, 0)).toHaveText("big.rb");
  await page.locator("main").evaluate((m) => { m.scrollTop = 4000; });
  const line = diff(page, 0).getByText("def method_150 = 300", { exact: true });
  await expect(line).toBeInViewport();
  const before = await fromTop(page, line);
  await page.waitForTimeout(400); // the place is saved once scrolling settles
  await page.reload();
  await expect(line).toBeInViewport();
  expect(Math.abs((await fromTop(page, line)) - before)).toBeLessThan(2);
});

test("file headers say what the patch alone does not", async ({ page }) => {
  await page.goto(HEADERS);
  await expect(title(page, 0)).toHaveText("big.rb");
  // Short files at the end are all drawn once the view is at the bottom.
  await page.locator("main").evaluate((m) => { m.scrollTop = m.scrollHeight; });

  await expect(title(page, 1)).toHaveText("logo.bin");
  await expect(diff(page, 1).locator(".file-notes")).toHaveText("binary, not shown");

  await expect(diff(page, 2).locator("[data-diffs-header]")).toHaveAttribute("data-change-type", "rename-changed");
  await expect(diff(page, 2).locator("[data-prev-name]")).toHaveText("old_name.rb");
  await expect(title(page, 2)).toHaveText("new_name.rb");
  await expect(diff(page, 2).getByText("line six")).toBeVisible();

  const hidden = diff(page, 3).locator(".badge.hidden");
  await expect(hidden).toHaveText("hidden characters on 1 line");
  await expect(hidden).toHaveAttribute("title", "Zero-width, bidi or control characters on lines +1");

  await expect(title(page, 4)).toHaveText("run.sh");
  await expect(diff(page, 4).locator(".file-notes")).toHaveText("mode 100644 → 100755");
});

test("a commit's full message unfolds and its page shows only its changes", async ({ page }) => {
  await page.goto(BRANCH);
  const commits = page.locator(".history .commit").filter({ has: page.locator(".subject") });
  await expect(commits.locator(".subject")).toHaveText(["Add thing", "Add greeting"]);

  const greeting = commits.nth(1);
  const body = greeting.locator("pre.message");
  await expect(body).toBeHidden();
  await greeting.locator("summary.ellipsis").click();
  await expect(body).toBeVisible();
  await expect(body).toContainText("The README now says hello to the world");

  await greeting.locator(".subject").click();
  await expect(page).toHaveURL(/\/repos\/review\/branches\/main\/commits\/[0-9a-f]{40}$/);
  await expect(page.locator("h1")).toHaveText("Add greeting");
  await expect(page.locator("main")).toContainText("commit 1 of 2");
  await expect(page.locator("pre.message")).toContainText("two lines of long.rb change");
  await expect(page.locator("main.codeview diffs-container")).toHaveCount(2);
  await expect(diff(page, 0).getByText("hello world")).toBeVisible();
  await expect(page.locator("nav")).toContainText("← oldest");

  await page.getByRole("link", { name: /newer: Add thing/ }).click();
  await expect(page.locator("h1")).toHaveText("Add thing");
  await expect(page.locator("main")).toContainText("commit 2 of 2");
  await expect(title(page, 0)).toHaveText("lib/thing.rb");
  await expect(title(page, 1)).toHaveText("notes.md");
  await expect(page.locator("nav")).toContainText("newest →");
});

test("when the patch cannot be fetched each file points at the raw patch", async ({ page }) => {
  await page.route("**/branches/main.patch", (route) => route.fulfill({ status: 500, body: "boom" }));
  await page.goto(BRANCH);
  const placeholders = page.locator("details.file .diff");
  await expect(placeholders).toHaveCount(4);
  for (const p of await placeholders.all()) {
    await expect(p).toHaveText("Could not render diff (patch request failed with status 500). View raw patch");
    await expect(p.getByRole("link", { name: "View raw patch" })).toHaveAttribute("href", `${BRANCH}.patch`);
  }
});

test("a rebased branch says so and shows only what changed besides the rebase", async ({ page }) => {
  await page.goto("/repos/rebased/branches/feature");
  await expect(page.locator("h1 .badge")).toHaveText("rebased");
  await expect(page.locator(".review .summary")).toHaveText("2 commits to push, rebased onto 1 newer upstream commit; replaces 2 upstream commits");
  await expect(page.locator(".review .rebase")).toContainText("Of upstream's 2 commits: 1 carried over unchanged, 1 changed, none dropped.");
  await expect(page.locator("h2", { hasText: "Dropped from upstream" })).toHaveCount(0);
  await expect(page.locator(".history .commit .subject")).toHaveText(["Add docs", "Add greeter"]);
  await expect(page.locator(".history .commit", { hasText: "Add docs" }).locator(".badge")).toHaveText("changed");
  await expect(page.locator(".history .commit", { hasText: "Add greeter" }).locator(".badge")).toHaveText("unchanged");
  await expect(page.locator(".history .commit.base")).toContainText("Upstream change");
  await expect(page.locator(".history .commit.base")).toContainText("upstream/main · rebased onto");
  await expect(page.locator("h2", { hasText: "Files changed (1)" })).toBeVisible();
  await expect(page.locator(".patch-summary")).toContainText("docs.md");
  await expect(page.locator(".patch-summary")).not.toContainText("other.txt");
  await expect(diff(page, 0).getByText("docs, with more")).toBeVisible();
});

test("a rebase that conflicted shows how it was resolved", async ({ page }) => {
  await page.goto("/repos/conflicted/branches/feature");
  await expect(page.locator("h1 .badge")).toHaveText("rebased");
  await expect(page.locator("h2", { hasText: "Files changed (1)" })).toBeVisible();
  await expect(page.locator("main")).toContainText("Replaying it conflicted in config.ini");
  await expect(diff(page, 0).getByText("<<<<<<<")).toBeVisible();
  await expect(diff(page, 0).getByText("setting_6 = 45")).toBeVisible();
});
