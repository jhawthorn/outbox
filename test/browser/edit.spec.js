// @ts-check
// Editing while reviewing: a file in its diff, folded into a commit or as a
// new one; a commit's message where it is shown; the menu that squashes,
// moves and drops commits; undoing; and what is said when an edit cannot be
// made. Each test has a repository of its own (see server.rb): main has
// three staged commits, "Add one", "Add two" and "Add three", each adding
// the file it names, the last also adding a line to one.txt.
const { test, expect } = require("@playwright/test");

// The branch's own commits, newest first, as the branch page lists them.
const subjects = (page) => page.locator(".history:not(.dropped) .commit:not(.base):not(.stub) .subject");
// A file of the diff, by its path.
const file = (page, path) => page.locator("diffs-container", { hasText: path });
const bar = (page) => page.locator(".edit-bar");
const raw = async (page, repo, path) => (await page.request.get(`/repos/${repo}/raw/main/${path}`)).text();
// The diff viewer has taken over the page. It moves everything in <main>
// into its own header as it does, which closes a menu that was open and
// takes the focus from a message being edited, so wait for it first.
const mounted = (page) => expect(page.locator("main.codeview")).toBeVisible();

// Click a line of an editor, to put the caret at its end. The caret is
// placed a moment after the pointer is up, and keys typed before that go
// nowhere, so wait for the line to be the editor's active one. The editor
// also draws its lines again as highlighting arrives, and a click on one
// replaced under the pointer is lost, so click again if it is not.
async function caretAt(page, container, text) {
  await expect(async () => {
    await container.getByText(text, { exact: true }).filter({ visible: true }).first().click({ timeout: 2000 });
    await expect(container.locator("[data-line][data-editor-active-line]")).toHaveText(text, { timeout: 1000 });
  }).toPass();
  await page.keyboard.press("End");
}

// Put a file of the diff in edit mode, with the caret at the end of the
// line that reads text. The summary's link brings the file to the top of
// the view, which only draws the files near it. The editor is there once
// the whole file has loaded.
async function editAt(page, path, text) {
  await page.locator(".patch-summary").getByRole("link", { name: path, exact: true }).click();
  const container = file(page, path);
  await container.getByRole("button", { name: "Edit", exact: true }).click();
  await expect(container.getByRole("button", { name: "Editing" })).toBeVisible();
  await expect(container.locator("[contenteditable=true]")).toBeVisible();
  await caretAt(page, container, text);
}

test("a file is edited in its diff and folded into the commit that last changed it", async ({ page }) => {
  await page.goto("/repos/edit-diff/branches/main");
  await expect(bar(page)).toBeHidden();
  const two = file(page, "two.txt");
  await editAt(page, "two.txt", "two");
  await expect(bar(page)).toContainText("Editing two.txt");
  await expect(bar(page).getByRole("button", { name: "Amend commit" })).toBeDisabled();

  // Letters that are shortcuts elsewhere on the page are only typed.
  await page.keyboard.type(", just the second");
  await expect(two).toContainText("two, just the second");
  await expect(page.locator("dialog[open]")).toHaveCount(0);
  await expect(bar(page)).toContainText("two.txt edited");
  // The last of the branch's commits to touch the file is where it goes.
  await expect(bar(page).getByRole("combobox").locator("option:checked")).toContainText("Add two");

  // From the editor, without reaching for the bar.
  await page.keyboard.press("Control+Enter");
  const edited = page.locator(".panel.edited");
  await expect(edited).toContainText("reviewer edited main");
  await expect(edited).toContainText("Edited two.txt in");
  await expect(page).toHaveURL(/\/repos\/edit-diff\/branches\/main/);
  await expect(subjects(page)).toHaveText(["Add three", "Add two", "Add one"]);
  expect(await raw(page, "edit-diff", "two.txt")).toBe("two, just the second\n");
  await expect(file(page, "two.txt")).toContainText("two, just the second");

  await edited.getByRole("button", { name: "Undo" }).click();
  await expect(edited).toHaveCount(0);
  expect(await raw(page, "edit-diff", "two.txt")).toBe("two\n");
});

test("an edit becomes a new commit, once it has a message", async ({ page }) => {
  await page.goto("/repos/edit-new/branches/main");
  await editAt(page, "three.txt", "three");
  await page.keyboard.type("!");
  const message = bar(page).getByRole("textbox", { name: "Message for the new commit" });
  await expect(message).toBeHidden();
  await bar(page).getByRole("combobox").selectOption({ label: "New commit…" });
  await expect(message).toBeFocused();
  const commit = bar(page).getByRole("button", { name: "Commit", exact: true });
  await expect(commit).toBeDisabled();
  await message.fill("Shout three");
  await expect(commit).toBeEnabled();
  await page.keyboard.press("Control+Enter");
  await expect(subjects(page)).toHaveText(["Shout three", "Add three", "Add two", "Add one"]);
  await expect(page.locator(".panel.edited")).toContainText("Edited three.txt in a new commit");
  expect(await raw(page, "edit-new", "three.txt")).toBe("three!\n");
});

test("a commit's message and its files are edited on its page", async ({ page }) => {
  await page.goto("/repos/edit-commit/branches/main");
  await page.getByRole("link", { name: "Add one" }).click();
  await expect(page.locator(".commit-nav")).toContainText("commit 1 of 3");
  const before = page.url();
  await mounted(page);

  // The message, in place of itself.
  await page.getByRole("button", { name: "Edit message" }).click();
  const text = page.getByRole("textbox", { name: "Commit message" });
  await expect(text).toBeFocused();
  await expect(text).toHaveValue("Add one");
  await expect(page.locator(".commit-title")).toBeHidden();
  await page.keyboard.press("Escape");
  await expect(page.locator(".commit-title")).toHaveText("Add one");
  await page.getByRole("button", { name: "Edit message" }).click();
  await text.fill("Add the first file\n\nOne comes first.\n");
  await page.keyboard.press("Control+Enter");
  // The commit's page again: it is a new commit now.
  await expect(page.locator(".commit-title")).toHaveText("Add the first file");
  await expect(page.locator(".commit-head pre.message")).toHaveText("One comes first.");
  await expect(page.locator(".commit-nav")).toContainText("commit 1 of 3");
  expect(page.url()).not.toBe(before);

  // Its file as it is in this commit, which a later one adds to.
  const one = file(page, "one.txt");
  await expect(one).not.toContainText("and a bit");
  await editAt(page, "one.txt", "one");
  await page.keyboard.type(", first");
  await expect(bar(page).getByRole("combobox").locator("option:checked")).toContainText("Add the first file");
  const reworded = page.url();
  await bar(page).getByRole("button", { name: "Amend commit" }).click();
  await expect(page.locator(".panel.edited")).toContainText("Edited one.txt in");
  await expect(page.locator(".commit-title")).toHaveText("Add the first file");
  expect(page.url()).not.toBe(reworded);
  await expect(file(page, "one.txt")).toContainText("one, first");
  // The later commit's line is still there, after it.
  expect(await raw(page, "edit-commit", "one.txt")).toBe("one, first\nuno\neins\nand a bit\n");
});

test("commits are reworded, moved, folded together and dropped from the list", async ({ page }) => {
  await page.goto("/repos/edit-menu/branches/main");
  const row = (subject) => page.locator(".history .commit", { has: page.locator(`.subject:text-is("${subject}")`) });
  const menu = async (subject) => {
    await mounted(page);
    await page.getByRole("button", { name: `Edit commit ${subject}`, exact: true }).click();
    return page.locator(".commit-menu:popover-open");
  };

  // The message, where the commit is listed.
  await (await menu("Add two")).getByRole("button", { name: "Edit message" }).click();
  const text = row("Add two").getByRole("textbox", { name: "Commit message" });
  await expect(text).toHaveValue("Add two\n\nTwo is the second.");
  await text.fill("Add the second\n\nTwo is the second.\n");
  await row("Add two").getByRole("button", { name: "Save message" }).click();
  await expect(subjects(page)).toHaveText(["Add three", "Add the second", "Add one"]);
  await expect(page.locator(".panel.edited")).toContainText("Reworded");

  // The oldest has nothing before it to go into or past; the newest nothing after.
  const oldest = await menu("Add one");
  await expect(oldest.getByRole("button", { name: /Squash into/ })).toHaveCount(0);
  await expect(oldest.getByRole("button", { name: "Move down" })).toHaveCount(0);
  await page.keyboard.press("Escape");
  await expect(oldest).toHaveCount(0);

  await (await menu("Add the second")).getByRole("button", { name: "Move up" }).click();
  await expect(subjects(page)).toHaveText(["Add the second", "Add three", "Add one"]);

  await (await menu("Add the second")).getByRole("button", { name: "Fixup into Add three" }).click();
  await expect(subjects(page)).toHaveText(["Add three", "Add one"]);
  expect(await raw(page, "edit-menu", "two.txt")).toBe("two\n");

  page.once("dialog", (d) => d.accept());
  await (await menu("Add three")).getByRole("button", { name: "Drop commit" }).click();
  await expect(subjects(page)).toHaveText(["Add one"]);
  await expect(page.locator(".panel.edited")).toContainText("Dropped");
  await page.locator(".panel.edited").getByRole("button", { name: "Undo" }).click();
  await expect(subjects(page)).toHaveText(["Add three", "Add one"]);
});

test("an edit that cannot be made says why and changes nothing", async ({ page }) => {
  await page.goto("/repos/edit-refused/branches/main");
  await mounted(page);
  // Add three adds to the file Add one makes.
  page.once("dialog", (d) => d.accept());
  await page.getByRole("button", { name: "Edit commit Add one", exact: true }).click();
  await page.locator(".commit-menu:popover-open").getByRole("button", { name: "Drop commit" }).click();
  const refused = page.locator(".edit-error");
  await expect(refused).toContainText("“Add three” no longer applies: it conflicts in one.txt");
  await expect(subjects(page)).toHaveText(["Add three", "Add two", "Add one"]);
  await refused.getByRole("button", { name: "Dismiss" }).click();
  await expect(refused).toHaveCount(0);

  // A line Add three wrote cannot be changed in Add one. What was typed stays.
  const one = file(page, "one.txt");
  await editAt(page, "one.txt", "and a bit");
  await page.keyboard.type(" more");
  await bar(page).getByRole("combobox").selectOption({ index: 2 }); // newest first: three, two, one
  await bar(page).getByRole("button", { name: "Amend commit" }).click();
  await expect(bar(page).getByRole("alert")).toContainText("The change does not apply to");
  await expect(one).toContainText("and a bit more");
  expect(await raw(page, "edit-refused", "one.txt")).toBe("one\nuno\neins\nand a bit\n");

  // Discarding puts the file back as it was.
  page.once("dialog", (d) => d.accept());
  await bar(page).getByRole("button", { name: "Discard" }).click();
  await expect(bar(page)).toBeHidden();
  await expect(one).not.toContainText("and a bit more");
  await expect(one.getByRole("button", { name: "Edit", exact: true })).toBeVisible();
});

test("a file is edited where it is browsed", async ({ page }) => {
  await page.goto("/repos/edit-browse/branches/main");
  await page.getByRole("link", { name: "Browse files" }).click();
  await page.locator("table.tree").getByRole("link", { name: "lib" }).click();
  await page.locator("table.tree").getByRole("link", { name: "app.rb" }).click();
  await expect(page).toHaveURL("/repos/edit-browse/tree/main/lib/app.rb");
  const view = page.locator("main.codeview diffs-container");
  await page.getByRole("button", { name: "Edit", exact: true }).click();
  await caretAt(page, view, "end");
  await page.keyboard.type(" # App");
  // None of the branch's commits touch the file, so it is a commit of its own.
  await expect(bar(page).getByRole("combobox").locator("option:checked")).toHaveText("New commit…");
  await bar(page).getByRole("textbox", { name: "Message for the new commit" }).fill("Say what ends");
  await bar(page).getByRole("button", { name: "Commit", exact: true }).click();
  await expect(bar(page)).toBeHidden();
  await expect(view).toContainText("end # App");
  expect(await raw(page, "edit-browse", "lib/app.rb")).toBe("class App\n  def call = :ok\nend # App\n");
  await page.goto("/repos/edit-browse/branches/main");
  await expect(subjects(page)).toHaveText(["Say what ends", "Add three", "Add two", "Add one"]);
});
