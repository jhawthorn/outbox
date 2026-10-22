// @ts-check
// The branch and commit pages of the "review" repository, which no test
// changes: two staged commits touching four files, one of them in two
// places. Everything here is drawn by assets/diffs.js in the browser.
const { test, expect } = require("@playwright/test");

const BRANCH = "/repos/review/branches/main";

// The rendered diff of the file placeholder with this index.
const diff = (page, i) => page.locator(`#f${i} .diff`);

test("each file's diff is rendered from the raw patch", async ({ page }) => {
  await page.goto(BRANCH);
  await expect(page.locator("h1")).toContainText("main");
  await expect(page.locator("h1 .badge")).toHaveText("ready");
  await expect(page.locator("h2", { hasText: "Files changed (4)" })).toBeVisible();

  // Server-rendered summary and headers.
  const summary = page.locator(".patch-summary");
  await expect(summary.locator("li")).toHaveText([/README/, /lib\/long\.rb/, /lib\/thing\.rb.*added/s, /notes\.md.*deleted/s]);
  await expect(page.locator("details.file")).toHaveCount(4);

  // Browser-rendered bodies: the patch's lines, highlighted by type.
  await expect(diff(page, 0).getByText("hello world")).toBeVisible();
  await expect(diff(page, 0).locator("[data-line-type=change-addition]").first()).toBeVisible();
  await expect(diff(page, 1).getByText("line ten")).toBeVisible();
  await expect(diff(page, 1).getByText("line one hundred")).toBeVisible();
  await expect(diff(page, 2).getByText("class Thing")).toBeVisible();
  await expect(diff(page, 3).locator("[data-line-type=change-deletion]").first()).toBeVisible();
  await expect(page.locator(".diff-controls")).toBeVisible();
});

test("unchanged lines between hunks expand from the blob route", async ({ page }) => {
  const blobRequests = [];
  page.on("request", (r) => { if (r.url().includes("/repos/review/blobs/")) blobRequests.push(r.url()); });

  await page.goto(BRANCH);
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
  await expect(long.getByText("line 96", { exact: true }).first()).toBeVisible();
  await expect(long.getByText("line 76", { exact: true })).toHaveCount(0);
  await expect(between).toContainText("63 unmodified lines");
  // With the whole file known, the trailing separator can say how much is left.
  await expect(long.locator("[data-separator][data-expand-index='2']").first()).toContainText("17 unmodified lines");
  // Both sides of the file, each once.
  expect(blobRequests).toHaveLength(2);
  expect(new Set(blobRequests).size).toBe(2);
  for (const url of blobRequests) expect(url).toMatch(/\/repos\/review\/blobs\/[0-9a-f]{40}$/);
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

test("collapse all and expand all fold the file sections", async ({ page }) => {
  await page.goto(BRANCH);
  const files = page.locator("details.file");
  await expect(files).toHaveCount(4);
  for (const f of await files.all()) await expect(f).toHaveAttribute("open", "");

  await page.getByRole("button", { name: "Collapse all" }).click();
  for (const f of await files.all()) await expect(f).not.toHaveAttribute("open", "");
  await expect(diff(page, 0).getByText("hello world")).toBeHidden();

  await page.getByRole("button", { name: "Expand all" }).first().click();
  for (const f of await files.all()) await expect(f).toHaveAttribute("open", "");
  await expect(diff(page, 0).getByText("hello world")).toBeVisible();
});

test("j and k move between files", async ({ page }) => {
  await page.goto(BRANCH);
  await expect(diff(page, 3).locator("[data-line-type]").first()).toBeVisible();
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
  // The page scrolled to each file, not just changed the hash.
  const top = await page.locator("#f0").evaluate((el) => el.getBoundingClientRect().top);
  expect(top).toBeGreaterThanOrEqual(-1);
  expect(top).toBeLessThan(40);
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
  await expect(page.locator("details.file")).toHaveCount(2);
  await expect(diff(page, 0).getByText("hello world")).toBeVisible();
  await expect(page.locator("nav")).toContainText("← oldest");

  await page.getByRole("link", { name: /newer: Add thing/ }).click();
  await expect(page.locator("h1")).toHaveText("Add thing");
  await expect(page.locator("main")).toContainText("commit 2 of 2");
  await expect(page.locator("details.file summary")).toHaveText([/lib\/thing\.rb/, /notes\.md/]);
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
