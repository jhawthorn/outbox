// @ts-check
// Review comments on the "comments" repository's main: the thread under
// the review panel, and line comments in the diff (assets/diffs.js).
const { test, expect } = require("@playwright/test");

const BRANCH = "/repos/comments/branches/main";
const diff = (page) => page.locator("main.codeview diffs-container[data-file=f0]");

test("a comment on a line is posted from the diff and drawn under the line", async ({ page }) => {
  await page.goto(BRANCH);
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

  // Back on the page: in the thread, with a link to the line, and in the diff.
  await expect(page).toHaveURL(/#comments$/);
  const thread = page.locator("section.comments");
  await expect(thread.locator("h2")).toHaveText("Comments (1)");
  await expect(thread.locator(".comment .text")).toHaveText("Why <new>?");
  await expect(thread.locator(".comment a")).toHaveAttribute("href", "#f0-R2-R2");
  await expect(diff(page).locator(".line-comments .comment .text")).toHaveText("Why <new>?");
  await expect(diff(page).locator(".line-comments .comment .meta")).toContainText("on line 2");

  // And a comment on the whole of it, from the review panel.
  await page.locator(".review .actions").getByRole("button", { name: "Comment" }).click();
  const general = page.locator("#new-comment");
  await expect(general).toBeVisible();
  await general.locator("textarea").fill("Looks fine otherwise");
  await general.getByRole("button", { name: "Comment" }).click();
  await expect(thread.locator("h2")).toHaveText("Comments (2)");
  await expect(thread.locator(".comment .text").nth(1)).toHaveText("Looks fine otherwise");
  await expect(general).toBeHidden();
});
