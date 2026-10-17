// @ts-check
// Browser tests: Playwright drives a real server (test/browser/server.rb)
// in Chromium. Run with `rake browser`, or directly:
//
//   pnpm exec playwright test -c test/browser            # all
//   pnpm exec playwright test -c test/browser --headed   # watch it
//   pnpm exec playwright test -c test/browser --ui       # step through
const { defineConfig, devices } = require("@playwright/test");
const path = require("node:path");

const PORT = Number(process.env.OUTBOX_TEST_PORT || 48080);
const PASSWORD = "browser-test-password";

module.exports = defineConfig({
  testDir: __dirname,
  testMatch: "*.spec.js",
  outputDir: path.join(__dirname, "test-results"),
  fullyParallel: true,
  workers: 4,
  reporter: process.env.CI ? "dot" : "list",
  timeout: 30_000,
  expect: { timeout: 10_000 },
  use: {
    ...devices["Desktop Chrome"],
    baseURL: `http://127.0.0.1:${PORT}`,
    httpCredentials: { username: "reviewer", password: PASSWORD },
    trace: "retain-on-failure",
  },
  globalSetup: require.resolve("./global-setup"),
  webServer: {
    command: "bundle exec ruby test/browser/server.rb",
    cwd: path.join(__dirname, "../.."),
    port: PORT,
    env: { OUTBOX_TEST_PORT: String(PORT), OUTBOX_PASSWORD: PASSWORD },
    reuseExistingServer: false,
    gracefulShutdown: { signal: "SIGTERM", timeout: 5_000 },
    stdout: "ignore",
    stderr: "pipe",
  },
});
