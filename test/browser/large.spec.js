// @ts-check
// A diff of about 22 MB: 400 added files and a lockfile of 100,000 lines
// (the "huge" repository). The page has to stay usable while the patch is
// read and parsed, and every file has to arrive.
const { test, expect } = require("@playwright/test");

const HUGE = "/repos/huge/branches/main";
const diff = (page, i) => page.locator(`main.codeview diffs-container[data-file=f${i}]`);
const title = (page, i) => diff(page, i).locator("[data-diffs-header] [data-title]");
const footer = (page) => page.locator("[data-diffs-code-view-footer]");

// Long tasks (the main thread busy for 50 ms or more) as they happen.
const watchLongTasks = (page) => page.addInitScript(() => {
  window.longTasks = [];
  new PerformanceObserver((list) => {
    for (const e of list.getEntries()) window.longTasks.push(e.duration);
  }).observe({ type: "longtask", buffered: true });
});
const longest = (page) => page.evaluate(() => Math.max(0, ...window.longTasks));

test("a huge patch is parsed in slices, so the page never freezes", async ({ page }) => {
  await watchLongTasks(page);
  await page.goto(`${HUGE}#f0`);
  await expect(title(page, 0)).toHaveText("vendor/gem_1/lib.rb", { timeout: 20_000 });
  await expect(diff(page, 0).getByText("def method_1_1(a, b)")).toBeVisible();

  // The rest follows; the note about reading the patch goes when it is all in.
  await expect(footer(page)).toBeEmpty({ timeout: 30_000 });
  expect(await longest(page)).toBeLessThan(500);
});

test("a file the patch has not reached yet is shown once it has", async ({ page }) => {
  await page.goto(HUGE);
  await expect(page.locator("main.codeview")).toBeVisible();
  // The last file, from the tree, whether or not it has been parsed.
  await page.locator('aside.filetree a[href="#f400"]').click();
  await expect(title(page, 400)).toHaveText("yarn.lock", { timeout: 30_000 });
  await expect(diff(page, 400).getByText("package-1@^1.0.1:")).toBeVisible();
  await expect(footer(page)).toBeEmpty();
  await expect(page).toHaveURL(/#f400$/);
});

test("a link to a file far down opens it on load", async ({ page }) => {
  await watchLongTasks(page);
  await page.goto(`${HUGE}#f300`);
  const name = await page.locator('.patch-summary a[href="#f300"]').textContent();
  await expect(title(page, 300)).toHaveText(name ?? "", { timeout: 30_000 });
  await expect(diff(page, 300)).toBeInViewport();
  expect(await longest(page)).toBeLessThan(500);
});
