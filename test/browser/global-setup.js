// @ts-check
// The server fetches every repository once at boot. Wait for that to finish
// so no test starts on a page that is still busy.
const { request } = require("@playwright/test");

module.exports = async function globalSetup(config) {
  const { baseURL, httpCredentials } = config.projects[0].use;
  const api = await request.newContext({ baseURL, httpCredentials });
  const deadline = Date.now() + 60_000;
  for (;;) {
    const res = await api.get("/");
    const body = await res.text();
    if (res.ok() && !body.includes('class="badge busy"')) break;
    if (Date.now() > deadline) {
      const busy = [...body.matchAll(/<li class="repo[^"]*">\s*<div class="repo-head">\s*<a class="repo-name" href="[^"]*">([^<]*)<\/a>[\s\S]*?<\/li>/g)]
        .filter((m) => m[0].includes('class="badge busy"')).map((m) => m[1]);
      throw new Error(`server still busy after 60s (status ${res.status()}): ${busy.join(", ") || body.slice(0, 500)}`);
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  await api.dispose();
};
