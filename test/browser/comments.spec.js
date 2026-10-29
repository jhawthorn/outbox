// @ts-check
// Review comments on the "comments" repository's main: the thread under
// the review panel, and line comments in the diff (assets/diffs.js). The
// "commented" repository is the live test's, so that neither counts the
// other's comments.
const { test, expect } = require("@playwright/test");

const BRANCH = "/repos/comments/branches/main";
const diff = (page) => page.locator("main.codeview diffs-container[data-file=f0]");

test("a comment on a line is posted from the diff and drawn under the line", async ({ page }) => {
  await page.goto(BRANCH);
  // Posting happens in place: the page is never loaded again.
  await page.evaluate(() => { window.notReloaded = true; });
  // Until there are comments, there is no thread to push the diff down.
  await expect(page.locator("section.comments")).toHaveCount(0);
  await expect(page.locator("#new-comment")).toBeHidden();
  // The number of the added line 2.
  const number = diff(page).locator('[data-line-type=change-addition][data-column-number="2"]').first();
  await expect(number).toBeVisible();

  // The + beside the line number opens a form under it. It shows where the
  // pointer is, so it is clicked where it shows.
  const plus = number.locator("[data-utility-button]");
  await expect(async () => {
    await number.hover();
    const at = await number.boundingBox();
    await page.mouse.move(at.x + 5, at.y + at.height / 2);
    await expect(plus).toBeVisible({ timeout: 500 });
  }).toPass();
  const box = await plus.boundingBox();
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  const form = diff(page).locator("form.comment-form.line");
  await expect(form).toBeVisible();
  await expect(form.locator("textarea")).toBeFocused();
  await expect(form.locator("textarea")).toHaveAttribute("placeholder", "Comment on line 2");
  await form.locator("textarea").fill("Why <new>?");
  await form.getByRole("button", { name: "Comment" }).click();

  // In the thread, with a link to the line, and in the diff, where the
  // form has closed.
  const thread = page.locator("section.comments");
  await expect(thread.locator("h2")).toHaveText("Comments (1)");
  await expect(thread.locator(".comment .text")).toHaveText("Why <new>?");
  await expect(thread.locator(".comment a")).toHaveAttribute("href", "#f0-R2-R2");
  await expect(diff(page).locator(".line-comments .comment .text")).toHaveText("Why <new>?");
  await expect(diff(page).locator(".line-comments .comment .meta")).toContainText("on line 2");
  await expect(form).toHaveCount(0);

  // And a comment on the whole of it, from the review panel.
  await page.locator(".review .actions").getByRole("button", { name: "Comment" }).click();
  const general = page.locator("#new-comment");
  await expect(general).toBeVisible();
  await general.locator("textarea").fill("Looks fine otherwise");
  await general.getByRole("button", { name: "Comment" }).click();
  await expect(thread.locator("h2")).toHaveText("Comments (2)");
  await expect(thread.locator(".comment .text").nth(1)).toHaveText("Looks fine otherwise");
  await expect(general).toBeHidden();
  // Not announced as someone else's, either.
  await page.waitForTimeout(1500);
  await expect(page.locator(".panel.new-comments")).toHaveCount(0);
  expect(await page.evaluate(() => window.notReloaded)).toBe(true);
});

test("a comment that cannot be posted says why in the form", async ({ page }) => {
  await page.goto("/repos/edited/branches/main");
  await expect(page.locator("main.codeview")).toBeVisible();
  await page.locator(".review .actions").getByRole("button", { name: "Comment" }).click();
  const general = page.locator("#new-comment");
  await general.locator("input[name=expected]").evaluate((input) => { input.value = "0".repeat(40); });
  await general.locator("textarea").fill("Too late");
  await general.getByRole("button", { name: "Comment" }).click();
  await expect(general.locator(".comment-error")).toContainText("changed since you read it");
  await expect(general).toBeVisible();
  await expect(general.locator("textarea")).toHaveValue("Too late");
  await expect(general.getByRole("button", { name: "Comment" })).toBeEnabled();
});

// Written elsewhere, another tab or another reviewer: the page says so,
// and stays usable, since a comment changes nothing that would be approved.
test("a comment written elsewhere is announced, and the page stays usable", async ({ page }) => {
  const BRANCH = "/repos/commented/branches/main";
  await page.goto(BRANCH);
  await expect(page.locator("main.codeview")).toBeVisible();
  const staged = (await page.locator("main").getAttribute("data-tips")).split(" ")[0];
  const post = (description) => page.request.post(`${BRANCH}/comments`, { form: { expected: staged, description }, maxRedirects: 0 });

  expect((await post("From another tab")).status()).toBe(303);
  const note = page.locator(".panel.new-comments");
  await expect(note).toContainText("The comments have changed since the page was loaded.");
  await expect(page.locator(".panel.warn.outdated")).toHaveCount(0);
  await expect(page.locator(".review .actions").getByRole("button", { name: "Approve and push to upstream" })).toBeEnabled();

  // Another changes nothing more until the reader reloads.
  await post("And another");
  await expect(page.locator("section.comments .comment")).toHaveCount(0);
  await expect(page.locator(".panel.new-comments")).toHaveCount(1);

  await note.getByRole("button", { name: "Reload" }).click();
  await expect(page.locator("section.comments .comment .text").last()).toHaveText("And another");
  await expect(page.locator(".panel.new-comments")).toHaveCount(0);
});

test("a comment is edited and deleted from the thread", async ({ page }) => {
  const BRANCH = "/repos/edited/branches/main";
  await page.goto(BRANCH);
  const staged = (await page.locator("main").getAttribute("data-tips")).split(" ")[0];
  await page.request.post(`${BRANCH}/comments`, { form: { expected: staged, description: "Frist" }, maxRedirects: 0 });
  await page.reload();
  await page.evaluate(() => { window.notReloaded = true; });

  const comment = page.locator("section.comments .comment");
  await comment.getByRole("button", { name: "Edit" }).click();
  const form = comment.locator("form.comment-form");
  await expect(form).toBeVisible();
  await expect(form.locator("textarea")).toHaveValue("Frist");
  await form.locator("textarea").fill("First");
  await form.getByRole("button", { name: "Save" }).click();
  await expect(comment.locator(".text")).toHaveText("First");
  await expect(comment.locator(".meta")).toContainText("edited");

  page.once("dialog", (d) => d.accept());
  await comment.getByRole("button", { name: "Delete" }).click();
  await expect(page.locator("section.comments")).toHaveCount(0);
  expect(await page.evaluate(() => window.notReloaded)).toBe(true);
});

