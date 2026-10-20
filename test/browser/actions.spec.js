// @ts-check
// Approve, discard, force approve and fetch, through the buttons. Each test
// has a repository of its own (see server.rb). They still run in order, in
// one worker: "fetch all" fetches every repository, which would otherwise
// overwrite another test's "pushed main to upstream" with "fetched upstream"
// before it had seen it.
const { test, expect } = require("@playwright/test");

test.describe.configure({ mode: "default" });

// Pages re-fetch themselves and swap in the new <main> when the server says
// something they show changed. A marker set on window survives that and not
// a reload, so a test can tell which one brought the result in.
const mark = (page) => page.evaluate(() => { window.__marker = true; });
const marked = (page) => page.evaluate(() => window.__marker === true);

// Answer the next confirm() with accept or dismiss and return its message.
// The button's click only completes once the dialog is answered, so the
// handler has to be in place before the click, not awaited after it.
function answerConfirm(page, answer) {
  return new Promise((resolve) => {
    page.once("dialog", async (dialog) => {
      expect(dialog.type()).toBe("confirm");
      await dialog[answer]();
      resolve(dialog.message());
    });
  });
}

test("approve pushes the branch and the repo page updates in place", async ({ page }) => {
  await page.goto("/repos/approve/branches/main");
  await expect(page.locator("h1 .badge")).toHaveText("ready");
  await expect(page.locator(".review")).toContainText("1 commit to push");
  await page.getByRole("button", { name: "Approve and push to upstream" }).click();

  await expect(page).toHaveURL("/repos/approve");
  await mark(page);
  await expect(page.locator("main")).toContainText("pushed main to upstream");
  await expect(page.locator("main")).toContainText("1 branch in sync with upstream. Nothing to review.");
  await expect(page.locator(".badge.busy")).toHaveCount(0);
  expect(await marked(page)).toBe(true);
});

test("discard asks first, and declining changes nothing", async ({ page }) => {
  await page.goto("/repos/discard/branches/main");
  const discard = page.getByRole("button", { name: "Discard" });

  const declined = answerConfirm(page, "dismiss");
  await discard.click();
  expect(await declined).toBe("Discard staged changes on main?");
  await expect(page).toHaveURL("/repos/discard/branches/main");
  await page.reload();
  await expect(page.locator("h1 .badge")).toHaveText("ready");

  const accepted = answerConfirm(page, "accept");
  await discard.click();
  expect(await accepted).toBe("Discard staged changes on main?");
  await expect(page).toHaveURL("/repos/discard");
  await expect(page.locator("main")).toContainText("discarded staged changes on main");
  await expect(page.locator("main")).toContainText("Nothing to review");
  await expect(page.locator("a[href='/repos/discard/branches/main']")).toHaveCount(0);
});

test("a diverged branch needs a confirmed force approve", async ({ page }) => {
  await page.goto("/repos/diverged");
  const row = page.locator("tbody tr", { hasText: "main" });
  await expect(row.locator(".badge")).toHaveText("diverged");
  await expect(row.getByRole("button", { name: "Approve" })).toHaveCount(0);
  await row.getByRole("link", { name: "Review" }).click();

  await expect(page).toHaveURL("/repos/diverged/branches/main");
  await expect(page.locator("h1 .badge")).toHaveText("diverged");
  await expect(page.locator(".review")).toContainText("1 commit to push; upstream has 1 commit not in staged");
  await expect(page.locator(".panel.warn")).toContainText("Upstream has moved. Approving overwrites it.");
  await expect(page.locator("h2", { hasText: "Dropped from upstream (1)" })).toBeVisible();
  await expect(page.locator(".history.dropped .commit .subject")).toHaveText("Upstream change");
  await expect(page.locator(".history.dropped .count.add")).toHaveText("+1");
  await expect(page.getByRole("button", { name: "Approve and push to upstream" })).toHaveCount(0);

  const force = page.getByRole("button", { name: "Force approve" });
  const declined = answerConfirm(page, "dismiss");
  await force.click();
  expect(await declined).toBe("Force-push main to upstream? 1 upstream commit will be dropped.");
  await expect(page).toHaveURL("/repos/diverged/branches/main");

  const accepted = answerConfirm(page, "accept");
  await force.click();
  await accepted;
  await expect(page).toHaveURL("/repos/diverged");
  await expect(page.locator("main")).toContainText("pushed main to upstream");
  await expect(page.locator("main")).toContainText("1 branch in sync with upstream. Nothing to review.");
});

test("a fetch shows its progress live, then its failure, until dismissed", async ({ page }) => {
  test.slow(); // the stub upstream takes a couple of seconds to answer
  let fetches = 0;
  page.on("request", (r) => { if (r.headers()["x-requested-with"] === "live") fetches++; });
  await page.goto("/repos/slow");
  // The fetch at boot failed the same way; clear it so this test's is distinct.
  const failed = page.locator(".panel.danger");
  if (await failed.count()) {
    await failed.getByRole("button", { name: "Dismiss" }).click();
    await expect(failed).toHaveCount(0);
  }

  await page.getByRole("button", { name: "Fetch upstream" }).click();
  await expect(page).toHaveURL("/repos/slow");
  await mark(page);
  await expect(page.locator(".badge.busy")).toHaveText("working");
  await expect(page.locator(".panel")).toContainText("Fetching upstream");
  await expect(page.getByRole("button", { name: "Fetch upstream" })).toBeDisabled();

  // Swapped in by the page fetching itself, not a navigation.
  await expect(failed.locator(".badge.failed")).toHaveText("fetch failed");
  await expect(failed.locator("pre")).toContainText("not found");
  expect(await marked(page)).toBe(true);
  expect(fetches).toBeGreaterThan(0);
  await expect(page.getByRole("button", { name: "Fetch upstream" })).toBeEnabled();
  // Idle again: nothing changes, so the page stops fetching. (One fetch for
  // the last change may still be on its way.)
  await page.waitForTimeout(1_000);
  const settled = fetches;
  await page.waitForTimeout(3_000);
  expect(fetches).toBe(settled);

  await failed.getByRole("button", { name: "Dismiss" }).click();
  await expect(page).toHaveURL("/repos/slow");
  await expect(failed).toHaveCount(0);
  await expect(page.locator("main")).toContainText("No branches. Push something to");
});

test("fetch all queues every repository and comes back to the index", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: "Fetch all upstreams" }).click();
  await expect(page).toHaveURL("/");
  await expect(page.locator(".badge.busy").first()).toBeVisible();
  await mark(page);
  await expect(page.locator(".badge.busy")).toHaveCount(0, { timeout: 20_000 });
  expect(await marked(page)).toBe(true);
  // A repo with staged work is still waiting for review after a fetch.
  const review = page.locator("li.repo", { has: page.locator(".repo-name", { hasText: /^review$/ }) });
  await expect(review).toHaveClass(/pending/);
  await expect(review.locator(".branch-name")).toHaveText("main");
  await expect(review.locator(".badge")).toHaveText("ready");
});
