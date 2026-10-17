// @ts-check
// The application shell: the password, the index, installing as an app and
// the offline page.
const { test, expect } = require("@playwright/test");

test("without the password nothing is served", async ({ browser, baseURL }) => {
  // Explicitly none: test.use() ignores an undefined option, so a context
  // from the fixtures would carry the password.
  const context = await browser.newContext({ httpCredentials: undefined });
  const page = await context.newPage();
  const res = await page.goto(`${baseURL}/`);
  expect(res?.status()).toBe(401);
  await expect(page.locator("body")).toContainText("Authentication required");
  const patch = await page.goto(`${baseURL}/repos/review/branches/main.patch`);
  expect(patch?.status()).toBe(401);
  await context.close();
});

test("the index puts repositories with something to review first", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("h1")).toHaveText("Repositories");
  await expect(page.locator("main > p.muted")).toContainText(/\d+ branch(es)? awaiting review across \d+ repositories\./);
  const names = await page.locator("li.repo .repo-name").allTextContents();
  const pending = await page.locator("li.repo").evaluateAll((els) => els.map((e) => e.classList.contains("pending")));
  expect(names).toContain("review");
  expect(names).toContain("_config");
  // Pending ones come first, then the rest; no idle repo above a pending one.
  expect(pending.lastIndexOf(true)).toBeLessThan(pending.indexOf(false));
  const review = page.locator("li.repo", { has: page.locator(".repo-name", { hasText: /^review$/ }) });
  await expect(review.locator("ul.branches li")).toContainText(["ready main 2 commits to push"]);
  await review.getByRole("link", { name: "main" }).click();
  await expect(page).toHaveURL("/repos/review/branches/main");

  await expect(page.locator("details.add")).toBeHidden(); // only open when there is nothing but _config
});

test("the repo page shows the clone URL this server is reached at", async ({ page, baseURL }) => {
  await page.goto("/repos/review");
  await expect(page.locator(".toolbar")).toContainText(`clone ${baseURL}/review.git`);
  await expect(page.locator(".toolbar")).toContainText("upstream /");
  await expect(page.locator("tbody tr")).toHaveCount(1);
  await expect(page.locator("tbody tr td").nth(1)).toContainText("2 commits to push");
});

test("installs as an app and shows the offline page without a connection", async ({ page, context }) => {
  await page.goto("/");
  await expect(page.locator('link[rel="manifest"]')).toHaveAttribute("crossorigin", "use-credentials");
  const manifest = await page.evaluate(async () => {
    const href = document.querySelector('link[rel="manifest"]').getAttribute("href");
    return (await fetch(href, { credentials: "include" })).json();
  });
  expect(manifest.display).toBe("standalone");
  expect(manifest.start_url).toBe("/");

  // The service worker is in control and has cached the offline page.
  expect(await page.evaluate(() => navigator.serviceWorker.ready.then((r) => r.active?.state))).toBe("activated");
  await expect.poll(() => page.evaluate(() => caches.match("/offline").then((r) => r?.ok ?? false))).toBe(true);

  await context.setOffline(true);
  await page.goto("/repos/review");
  await expect(page.locator("h1")).toHaveText("You are offline");
  await context.setOffline(false);
  await page.getByRole("link", { name: "try again" }).click();
  await expect(page.locator("h1")).toHaveText("Repositories");
});
