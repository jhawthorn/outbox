// @ts-check
// Pages follow what happens elsewhere: pushes (made here over git, as an
// agent's would be) and jobs started in another tab. The "live" repository
// is these tests' alone; they run in order, each leaving it as the next
// expects.
const { test, expect } = require("@playwright/test");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

test.describe.configure({ mode: "default" });

const GIT_ENV = {
  ...process.env,
  GIT_AUTHOR_NAME: "Test", GIT_AUTHOR_EMAIL: "test@example.com",
  GIT_COMMITTER_NAME: "Test", GIT_COMMITTER_EMAIL: "test@example.com",
  GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null",
  GIT_TERMINAL_PROMPT: "0",
};

let work;
const git = (...args) => execFileSync("git", ["-C", work, ...args], { env: GIT_ENV, stdio: ["ignore", "pipe", "pipe"] }).toString();

test.beforeAll(() => {
  const { baseURL, httpCredentials } = test.info().project.use;
  const url = new URL("/live.git", baseURL);
  url.username = "agent";
  url.password = httpCredentials.password;
  work = fs.mkdtempSync(path.join(os.tmpdir(), "outbox-live-"));
  execFileSync("git", ["clone", "--quiet", url.href, work], { env: GIT_ENV, stdio: "ignore" });
});

test.afterAll(() => fs.rmSync(work, { recursive: true, force: true }));

// Commit one file and push it to the outbox. Returns the sha.
function push(file, content, message, branch = "main") {
  fs.writeFileSync(path.join(work, file), content);
  git("add", "--", file);
  git("commit", "--quiet", "-m", message);
  git("push", "--quiet", "origin", `HEAD:${branch}`);
  return git("rev-parse", "HEAD").trim();
}

// Survives the page swapping in a new <main>, not a navigation.
const mark = (page) => page.evaluate(() => { window.__marker = true; });
const marked = (page) => page.evaluate(() => window.__marker === true);

test("the index shows a push as it arrives", async ({ page }) => {
  await page.goto("/");
  const live = page.locator("li.repo", { has: page.locator(".repo-name", { hasText: /^live$/ }) });
  await expect(live).not.toHaveClass(/pending/);
  await mark(page);

  push("a.txt", "the first line\n", "First push");
  await expect(live).toHaveClass(/pending/);
  await expect(live.locator(".branch-name")).toHaveText("main");
  await expect(live.locator(".badge")).toHaveText("ready");
  await expect(live).toContainText("1 commit to push");
  expect(await marked(page)).toBe(true);
});

test("a branch page says when the branch moves, and does not change under the reader", async ({ page }) => {
  await page.goto("/repos/live/branches/main");
  await expect(page.locator("diffs-container[data-file=f0]").getByText("the first line")).toBeVisible();
  const first = await page.locator("input[name=expected]").first().inputValue();
  await mark(page);

  // Another branch moving is not this page's business.
  push("elsewhere.txt", "elsewhere\n", "Elsewhere", "other");
  await page.waitForTimeout(2_000);
  await expect(page.locator(".outdated")).toHaveCount(0);
  git("reset", "--quiet", "--hard", "HEAD~1");

  push("b.txt", "the second line\n", "Second push");
  const notice = page.locator(".outdated");
  await expect(notice).toContainText("This branch has changed since the page was loaded. Now: 2 commits to push.");
  // What was reviewed is still what is shown, and nothing can be approved
  // from it.
  await expect(page.locator("h2", { hasText: "Commits (1)" })).toBeVisible();
  await expect(page.locator("diffs-container[data-file=f0]").getByText("the first line")).toBeVisible();
  await expect(page.locator("input[name=expected]").first()).toHaveValue(first);
  await expect(page.getByRole("button", { name: "Approve and push to upstream" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Discard" })).toBeDisabled();
  expect(await marked(page)).toBe(true);

  await notice.getByRole("button", { name: "Reload" }).click();
  await expect(page.locator("h2", { hasText: "Commits (2)" })).toBeVisible();
  await expect(page.locator(".outdated")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Approve and push to upstream" })).toBeEnabled();
  expect(await marked(page)).toBe(false);
});

test("a job started in another tab shows on the page already open", async ({ page, context }) => {
  await page.goto("/repos/live");
  const row = page.locator("tbody tr", { has: page.locator("a", { hasText: /^main$/ }) });
  await expect(row).toContainText("2 commits to push");
  await mark(page);

  const other = await context.newPage();
  await other.goto("/repos/live/branches/main");
  await other.getByRole("button", { name: "Approve and push to upstream" }).click();
  await expect(other).toHaveURL("/repos/live");
  await other.close();

  await expect(page.locator("main")).toContainText("pushed main to upstream");
  await expect(row).toHaveCount(0);
  expect(await marked(page)).toBe(true);
});

test("a page that was hidden catches up when shown", async ({ page }) => {
  await page.goto("/repos/live");
  await expect(page.locator("main")).not.toContainText("hidden.txt");
  await mark(page);
  let streams = 0;
  page.on("request", (r) => { if (r.url().endsWith("/events")) streams++; });

  // As the browser does when the tab is switched away from and back.
  const visibility = (hidden) => page.evaluate((hidden) => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => hidden });
    document.dispatchEvent(new Event("visibilitychange"));
  }, hidden);
  await visibility(true);
  push("hidden.txt", "while hidden\n", "Pushed while hidden", "hidden");
  await page.waitForTimeout(2_000);
  await expect(page.locator("tbody tr")).toHaveCount(1); // only "other", from before
  await visibility(false);

  await expect(page.locator("tbody tr", { has: page.locator("a", { hasText: /^hidden$/ }) })).toHaveCount(1);
  expect(streams).toBe(1);
  expect(await marked(page)).toBe(true);
});
