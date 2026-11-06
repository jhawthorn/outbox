// @ts-check
// Pages on a phone's screen: nothing wider than it, so nothing scrolls
// sideways, and nothing drawn over anything else.
const { test, expect } = require("@playwright/test");

test.use({ viewport: { width: 320, height: 640 }, isMobile: true, hasTouch: true });

// What is wider than the screen: the page itself, or the diff view that is
// its scroller.
const tooWide = (page) => page.evaluate(() => [document.documentElement, document.querySelector("main")]
  .filter((el) => el && el.scrollWidth > el.clientWidth + 1).map((el) => `${el.tagName} ${el.scrollWidth} > ${el.clientWidth}`));

// Whether two elements' boxes overlap.
const overlap = async (a, b) => {
  const [r, s] = [await a.boundingBox(), await b.boundingBox()];
  return !!r && !!s && r.x < s.x + s.width && s.x < r.x + r.width && r.y < s.y + s.height && s.y < r.y + r.height;
};

// A page once diffs.js has drawn it.
const open = async (page, url) => {
  await page.goto(url);
  await page.waitForLoadState("networkidle");
};

for (const url of [
  "/", "/repos/review", "/repos/review/branches/main", "/repos/rebased/branches/feature", "/repos/headers/branches/main",
  "/repos/browse/code", "/repos/browse/branches", "/repos/review/commits", "/repos/review/blame/main/lib/long.rb",
  "/repos/browse/compare/main...topic/x",
]) {
  test(`${url} fits a phone's screen`, async ({ page }) => {
    await open(page, url);
    expect(await tooWide(page)).toEqual([]);
  });
}

test("a branch page's buttons wrap under its title rather than over it", async ({ page }) => {
  await open(page, "/repos/rebased/branches/feature");
  const h1 = page.locator(".page-head h1");
  // Squeezed beside the buttons, the title ran out of its box and under them.
  expect(await h1.evaluate((el) => el.scrollWidth <= el.clientWidth)).toBe(true);
  for (const button of await page.locator(".page-head > :not(h1)").all()) expect(await overlap(h1, button)).toBe(false);
});

test("a commit's hash, author, dates and size are not drawn over each other", async ({ page }) => {
  await open(page, "/repos/rebased/branches/feature");
  const commit = page.locator(".history .commit", { hasText: "Add docs" });
  const parts = [commit.locator(".hash"), commit.locator(".name").first(), commit.locator(".when").first(), commit.locator(".size")];
  for (let i = 0; i < parts.length; i++) {
    for (let j = i + 1; j < parts.length; j++) expect(await overlap(parts[i], parts[j]), `parts ${i} and ${j}`).toBe(false);
  }
});

test("the summary's file list keeps each path in view", async ({ page }) => {
  await open(page, "/repos/headers/branches/main");
  const widths = await page.locator(".patch-summary li .path").evaluateAll((paths) => paths.map((p) => p.getBoundingClientRect().width));
  expect(widths.length).toBe(5);
  for (const width of widths) expect(width).toBeGreaterThan(40);
});
