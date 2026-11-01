const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const test = require("node:test");
const source = fs.readFileSync(`${__dirname}/../../app/packs/src/decidim/sw/sw.js`, "utf8").replace(/import[\s\S]*?from "[^"]+";/g, "");

async function push({ displayFailure = false, receiptUrl = "/biceriseno/platform-receipt", networkFailure = false } = {}) {
  const calls = [];
  const handlers = {};
  let pending;
  const self = {
    location: { origin: "https://example.test" }, skipWaiting() {},
    addEventListener: (name, callback) => { handlers[name] = callback; },
    registration: { showNotification: async () => { calls.push("display"); if (displayFailure) throw new Error("denied"); } }
  };
  vm.runInNewContext(source, {
    self, URL, clientsClaim() {}, registerRoute() {}, NetworkOnly: class {},
    staticResourceCache() {}, imageCache() {}, offlineFallback() {},
    fetch: async (url, opts) => { calls.push({ url, opts }); if (networkFailure) throw new Error("offline"); }
  });
  handlers.push({ data: { json: () => ({ title: "Notice", data: { receipt_url: receiptUrl, receipt_token: "signed-capability" } }) }, waitUntil: (promise) => { pending = promise; } });
  try { await pending; } catch (_error) { calls.push("failed"); }
  return calls;
}

test("display API completion precedes same-origin receipt POST", async () => {
  const calls = await push();
  assert.equal(calls[0], "display");
  assert.equal(calls[1].url, "https://example.test/biceriseno/platform-receipt");
  assert.equal(calls[1].opts.method, "POST");
  assert.equal(calls[1].opts.credentials, "omit");
  assert.deepEqual(JSON.parse(calls[1].opts.body), { token: "signed-capability" });
});

test("failed display cannot acknowledge receipt", async () => {
  assert.deepEqual(await push({ displayFailure: true }), ["display", "failed"]);
});

test("receipt capabilities are never posted to another origin", async () => {
  assert.deepEqual(await push({ receiptUrl: "https://other.example/receipt" }), ["display"]);
});

test("offline receipt remains unconfirmed without failing a displayed notification", async () => {
  assert.equal((await push({ networkFailure: true })).length, 2);
});
