// @ts-check
// Reading a repository: the code at a branch, its README, finding files,
// switching branches, history, blame and search. The "browse" repository
// (server.rb) is read-only.
const { test, expect } = require("@playwright/test");

test("the repository page shows the code and renders the README safely", async ({ page }) => {
  const outside = [];
  page.on("request", (r) => { if (!r.url().startsWith("http://127.0.0.1")) outside.push(r.url()); });
  await page.goto("/repos/browse");
  await expect(page.locator("details.refpick summary")).toHaveText("main");
  await expect(page.locator("table.tree td.name a")).toHaveText(["docs", "lib", "README.md"]);
  await expect(page.locator(".last-commit")).toContainText("Make the app answer");
  await expect(page.locator("table.tree td.msg")).toHaveText(["Initial commit", "Make the app answer", "Initial commit"]);

  const readme = page.locator(".readme .markdown-body");
  await expect(readme.locator("h1")).toContainText("Browse me");
  await expect(readme.getByRole("link", { name: "the guide" })).toHaveAttribute("href", "/repos/browse/tree/main/docs/guide.md");
  await expect(readme.getByRole("link", { name: "the top" })).toHaveAttribute("href", "/repos/browse/tree/main/lib/app.rb");
  await expect(readme.getByRole("link", { name: "below" })).toHaveAttribute("href", "#user-content-usage");
  await expect(readme.locator("img[alt=logo]")).toHaveAttribute("src", "/repos/browse/raw/main/docs/logo.svg");
  await expect.poll(() => readme.locator("img[alt=logo]").evaluate((img) => img.naturalWidth)).toBe(10);
  // Images from elsewhere wait to be asked for; ".." stops at the top.
  await expect(readme.locator("img[alt=tracker]")).toHaveCount(0);
  await expect(readme.locator("a.ext-img")).toHaveCount(3);
  await expect(readme.locator("a.ext-img").first()).toContainText("tracker (from example.invalid; click to load)");
  await expect(readme.locator("svg, image")).toHaveCount(0);
  expect(outside).toEqual([]);
  await expect(readme.getByRole("link", { name: "climb" })).toHaveAttribute("href", "/repos/browse/tree/main/etc/passwd");
  await expect(readme.getByRole("link", { name: "both" })).toHaveAttribute("href", "/repos/browse/tree/main/docs/guide.md?x=1#guide");
  await expect(readme).toContainText("☑ done");
  await expect(readme).toContainText("☐ to do");

  // Nothing the pusher wrote can act on this page.
  await expect(readme.locator("form, button, script, [onerror]")).toHaveCount(0);
  await expect(readme.locator("a[href^='javascript']")).toHaveCount(0);
  expect(await page.evaluate(() => window.pwned)).toBeUndefined();

  await readme.getByRole("link", { name: "the guide" }).click();
  await expect(page.locator("h1.path")).toHaveText("browse/docs/guide.md");
  await expect(page.locator(".markdown-body h1")).toContainText("Guide");
  await page.locator(".file-bar").getByRole("link", { name: "Code" }).click();
  await expect(page).toHaveURL("/repos/browse/tree/main/docs/guide.md?plain=1");
  await expect(page.locator("main.codeview diffs-container").getByText("Back to")).toBeVisible();
});

test("the branch picker moves to another branch at the same path", async ({ page }) => {
  await page.goto("/repos/browse/tree/main/lib");
  await page.locator("details.refpick summary").click();
  const menu = page.locator("details.refpick .menu");
  await expect(menu.locator("a[role=option]").first()).toHaveText(/main\s*default/);
  await menu.getByRole("searchbox").fill("topic");
  await expect(menu.locator("a[role=option]")).toHaveText(["topic/x"]);
  await menu.getByRole("searchbox").press("Enter");
  await expect(page).toHaveURL("/repos/browse/tree/topic/x/lib");
  await expect(page.locator("table.tree td.name a")).toContainText(["topic.rb"]);
  await expect(page.locator(".pending-note")).toContainText("topic/x has staged work awaiting review");
});

test("t finds a file by name", async ({ page }) => {
  await page.goto("/repos/browse");
  await page.keyboard.press("t");
  const finder = page.getByRole("dialog", { name: "Go to file" });
  await expect(finder).toBeVisible();
  await page.keyboard.type("lhel");
  await expect(finder.locator("a[role=option]").first()).toHaveText("lib/helper.rb");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL("/repos/browse/tree/main/lib/helper.rb");
  await expect(page.locator("main.codeview diffs-container").getByText("module Helper")).toBeVisible();
});

test("a file's history, blame and permalink", async ({ page }) => {
  await page.goto("/repos/browse/tree/main/lib/app.rb");
  await expect(page.locator("main.codeview diffs-container").getByText("class App")).toBeVisible();
  await page.keyboard.press("y");
  await expect(page).toHaveURL(/\/repos\/browse\/tree\/[0-9a-f]{40}\/lib\/app\.rb$/);

  await page.goto("/repos/browse/tree/main/lib/app.rb");
  await expect(page.locator("main.codeview diffs-container").getByText("class App")).toBeVisible();
  await page.keyboard.press("b");
  await expect(page).toHaveURL("/repos/browse/blame/main/lib/app.rb");
  await expect(page.locator("table.blame tr#L2 td.code")).toHaveText("  def call = :answer");
  await expect(page.locator("table.blame td.who")).toContainText(["Initial commit", "Make the app answer", "Initial commit"]);
  await expect(page.locator("table.blame tr#L1 td.code span[style]").first()).toHaveText("class"); // highlighted
  await page.locator("table.blame tr#L2").getByRole("link", { name: "Blame prior to this change" }).click();
  await expect(page.locator("table.blame tr#L2 td.code")).toHaveText("  def call = :ok");
  await page.goBack();

  await page.getByRole("link", { name: "History" }).click();
  await expect(page).toHaveURL("/repos/browse/commits/main/lib/app.rb");
  await expect(page.locator(".log-row .subject")).toHaveText(["Make the app answer", "Initial commit"]);
  await page.getByRole("link", { name: "Make the app answer" }).click();
  await expect(page).toHaveURL(/\/repos\/browse\/commit\/[0-9a-f]{40}$/);
  await expect(page.locator("h1.commit-title")).toHaveText("Make the app answer");
  await expect(page.locator(".patch-summary")).toContainText("lib/app.rb");
});

test("/ searches the code", async ({ page }) => {
  await page.goto("/repos/browse/tree/main/lib");
  await page.keyboard.press("/");
  await page.keyboard.type("answer");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/repos\/browse\/search\?q=answer&rev=main$/);
  await expect(page.locator(".result .box-head")).toHaveText(["lib/app.rb"]);
  await expect(page.locator(".result mark")).toHaveText(["answer"]);
});

test("the branch list filters as you type", async ({ page }) => {
  await page.goto("/repos/browse/branches");
  await expect(page.locator(".ref-row:visible .branch-name")).toContainText(["topic/x", "main"]);
  await page.getByRole("searchbox", { name: "Filter branches" }).fill("topic");
  await expect(page.locator(".ref-row:visible .branch-name")).toHaveText(["topic/x"]);
});

test("? lists the keyboard shortcuts", async ({ page }) => {
  await page.goto("/repos/browse");
  await page.keyboard.press("?");
  await expect(page.getByRole("dialog", { name: "Keyboard shortcuts" })).toContainText("Find a file by name");
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toHaveCount(0);
});

test("a branch compares with the default branch", async ({ page }) => {
  await page.goto("/repos/browse/tree/topic/x");
  await page.getByRole("link", { name: "Compare with main" }).click();
  await expect(page).toHaveURL("/repos/browse/compare/main...topic/x");
  await expect(page.locator(".log-row .subject")).toHaveText(["Add a topic"]);
  await expect(page.locator(".patch-summary")).toContainText("lib/topic.rb");
  await expect(page.locator("main.codeview diffs-container").getByText("TOPIC = 1")).toBeVisible();
});
