const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const routes = [];
const fallbacks = [];
class NetworkOnly {}
const source = fs.readFileSync(path.join(__dirname, "../../app/packs/src/decidim/sw/sw.js"), "utf8")
  .replace(/import[\s\S]*?from "[^"]+";/g, "");
vm.runInNewContext(source, {
  self: {__WB_MANIFEST: [], skipWaiting() {}, addEventListener() {}},
  clientsClaim() {}, registerRoute: (match, strategy) => routes.push({match, strategy}),
  NetworkOnly, staticResourceCache() {}, imageCache() {},
  offlineFallback: options => fallbacks.push(options), URL
});
const navigationRoutes = pathname => routes.filter(route => route.match({request: {mode: "navigate"}, url: new URL(pathname, "https://community.example.invalid")}));
test("open-source pages in every locale use network-only navigation and the offline fallback", () => {
  for (const prefix of ["", "sr/", "sr-Cyrl/", "bs/", "hr/"]) {
    for (const suffix of ["", "/", "?locale=bs"]) {
      const matches = navigationRoutes(`/${prefix}otvoreni-kod${suffix}`);
      assert.equal(matches.length, 1);
      assert(matches[0].strategy instanceof NetworkOnly);
    }
  }
  assert.equal(fallbacks.length, 1);
  assert.equal(fallbacks[0].pageFallback, "/offline");
});
test("private navigation stays network-only and ordinary resources are not navigation routes", () => {
  for (const pathname of ["/users/sign_in", "/admin/participatory_processes/new", "/system/organizations"]) {
    assert(navigationRoutes(pathname).every(route => route.strategy instanceof NetworkOnly));
    assert.equal(navigationRoutes(pathname).length, 1);
  }
  assert.equal(routes.filter(route => route.match({request: {mode: "cors"}, url: new URL("https://community.example.invalid/otvoreni-kod")})).length, 0);
});
