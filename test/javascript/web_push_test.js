const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const test = require("node:test");
const source = fs.readFileSync(`${__dirname}/../../app/packs/src/decidim/sw/push-permissions.js`, "utf8");

async function setup({ supported = true, permission = "default", existing = null, failSave = false, offer = false, choice = null, registered = true, ios = !supported, standalone = false } = {}) {
  const calls = [];
  let load, change, sendTest, beforeCache;
  const requests = [];
  const testButton = { disabled: true, addEventListener: (_name, handler) => { sendTest = handler; } };
  const toggle = { dataset: {}, checked: false, addEventListener: (name, handler) => { change = handler; } };
  const status = {};
  const storage = new Map(choice ? [["account-key", choice]] : []);
  const enableButton = { addEventListener: (_name, handler) => { enableButton.click = handler; } };
  const dismissButton = { addEventListener: (_name, handler) => { dismissButton.click = handler; } };
  toggle.dispatchEvent = () => { toggle.pending = change(); };
  const fingerprint = require("node:crypto").createHash("sha256").update("auth").digest("hex");
  const container = { dataset: { ...Object.fromEntries(["install", "unsupported", "blocked", "enabled", "disabled", "ready", "failed", "test_queued"].map((key) => [key, key])), testUrl: "/biceriseno/push-notification-test", unsubscribeUrl: "/biceriseno/push-subscription" },
    hidden: true, hasAttribute: () => offer,
    querySelector: (key) => {
      if (key.includes("toggle")) return toggle;
      if (key.includes("status")) return status;
      if (key.includes("fingerprints")) return { value: JSON.stringify(registered ? [fingerprint] : []) };
      if (key.includes("enable")) return enableButton;
      if (key.includes("dismiss")) return dismissButton;
      return offer ? null : testButton;
    } };
  toggle.closest = () => offer ? container : null;
  const subscription = { toJSON: () => ({ keys: { auth: "auth" } }), unsubscribe: async () => { calls.push("unsubscribe"); return true; } };
  const Notification = { permission, requestPermission: async () => { calls.push("permission"); Notification.permission = "granted"; return "granted"; } };
  const window = { Notification, localStorage: { getItem: (key) => storage.get(key), setItem: (key, value) => storage.set(key, value), removeItem: (key) => storage.delete(key) }, crypto: require("node:crypto").webcrypto, matchMedia: () => ({ matches: standalone }), ...(supported ? { PushManager: {} } : {}) };
  const navigator = { userAgent: ios ? "iPhone" : "Chrome", serviceWorker: { ready: Promise.resolve({ pushManager: {
    getSubscription: async () => existing ? subscription : null,
    subscribe: async () => { calls.push("subscribe"); return subscription; }
  } }) } };
  const document = { addEventListener: (name, handler) => { if (name === "turbo:load") load = handler; else beforeCache = handler; }, querySelectorAll: () => [toggle], querySelector: (selector) => {
    if (selector.includes("offer-key")) return { dataset: { pushOfferKey: "account-key" } };
    if (selector.includes("container")) return container;
    if (selector.includes("sub-keys")) return { value: '["auth"]' };
    if (selector.includes("vapid")) return { value: "[1,2,3]" };
    return { content: "csrf" };
  } };
  vm.runInNewContext(source, { window, navigator, document, Event: class {}, Uint8Array, TextEncoder, setTimeout: () => 0,
    fetch: async (url, options) => { calls.push(options.method); requests.push({ url, body: options.body }); return { ok: !failSave }; } });
  await load();
  return { toggle, status, calls, container, storage, enableButton, dismissButton, get change() { return change; }, sendTest, testButton, requests,
    restore: async () => { beforeCache(); change = null; await load(); } };
}

test("iPhone tab explains installation without prompting", async () => {
  const state = await setup({ supported: false });
  assert.equal(state.status.textContent, "install");
  assert.equal(state.toggle.disabled, true);
  assert.deepEqual(state.calls, []);
});
test("permission is requested only on interaction and subscription is saved", async () => {
  const state = await setup();
  assert.deepEqual(state.calls, []);
  state.toggle.checked = true;
  await state.change();
  assert.deepEqual(state.calls, ["permission", "subscribe", "POST"]);
  assert.equal(state.status.textContent, "enabled");
});
test("denied permission explains recovery", async () => {
  const state = await setup({ permission: "denied" });
  assert.equal(state.toggle.disabled, true);
  assert.equal(state.status.textContent, "blocked");
});
test("unsubscribe removes server registration before browser subscription", async () => {
  const state = await setup({ permission: "granted", existing: true });
  state.toggle.checked = false;
  await state.change();
  assert.deepEqual(state.calls, ["DELETE", "unsubscribe"]);
  assert.equal(state.status.textContent, "disabled");
});
test("failed unsubscribe keeps browser registration recoverable", async () => {
  const state = await setup({ permission: "granted", existing: true, failSave: true });
  state.toggle.checked = false;
  await state.change();
  assert.deepEqual(state.calls, ["DELETE"]);
  assert.equal(state.toggle.checked, true);
  assert.equal(state.status.textContent, "failed");
});
test("failed subscription save is not reported as enabled", async () => {
  const state = await setup({ failSave: true });
  state.toggle.checked = true;
  await state.change();
  assert.equal(state.toggle.checked, false);
  assert.equal(state.status.textContent, "failed");
});
test("self test sends a fingerprint and reports queued rather than delivered", async () => {
  const state = await setup({ permission: "granted", existing: true });
  assert.equal(state.testButton.disabled, false);
  await state.sendTest();
  assert.equal(state.requests[0].url, "/biceriseno/push-notification-test");
  assert.match(JSON.parse(state.requests[0].body).fingerprint, /^[0-9a-f]{64}$/);
  assert.equal(state.status.textContent, "test_queued");
});
test("returning to a Turbo cached settings page binds working controls again", async () => {
  const state = await setup();
  await state.restore();
  state.toggle.checked = true;
  await state.change();
  assert.equal(state.status.textContent, "enabled");
});

test("default invitation shows without asking permission or changing subscriptions", async () => {
  const state = await setup({ offer: true });
  assert.equal(state.container.hidden, false);
  assert.deepEqual(state.calls, []);
  state.enableButton.click();
  assert.equal(state.calls[0], "permission");
  await state.toggle.pending;
  assert.deepEqual(state.calls, ["permission", "subscribe", "POST"]);
  assert.equal(state.container.hidden, true);
});
test("dismissal survives Turbo restoration without prompting", async () => {
  const state = await setup({ offer: true });
  state.dismissButton.click();
  await state.restore();
  assert.equal(state.container.hidden, true);
  assert.equal(state.storage.get("account-key"), "dismissed");
  assert.deepEqual(state.calls, []);
});
test("already subscribed and blocked devices do not get an invitation", async () => {
  for (const options of [{ permission: "granted", existing: true }, { permission: "denied" }]) {
    const state = await setup({ offer: true, ...options });
    assert.equal(state.container.hidden, true);
    assert.deepEqual(state.calls, []);
  }
});
test("prior unsubscribe is respected even when browser permission remains granted", async () => {
  const state = await setup({ offer: true, permission: "granted", existing: null });
  assert.equal(state.container.hidden, true);
  assert.deepEqual(state.calls, []);
});
test("explicit settings opt-out suppresses future offers and re-enable clears it", async () => {
  const state = await setup({ permission: "granted", existing: true });
  state.toggle.checked = false;
  await state.change();
  assert.equal(state.storage.get("account-key"), "disabled");
  state.toggle.checked = true;
  await state.change();
  assert.equal(state.storage.has("account-key"), false);
  const dismissed = await setup({ offer: true, choice: "disabled" });
  assert.equal(dismissed.container.hidden, true);
  assert.deepEqual(dismissed.calls, []);
});
test("iPhone invitation explains installation and offers no unusable enable button", async () => {
  const state = await setup({ offer: true, supported: false });
  assert.equal(state.container.hidden, false);
  assert.equal(state.status.textContent, "install");
  assert.equal(state.enableButton.hidden, true);
  assert.deepEqual(state.calls, []);
});
test("iPhone tabs need installation even when the push APIs are exposed", async () => {
  const state = await setup({ offer: true, supported: true, ios: true });
  assert.equal(state.status.textContent, "install");
  assert.equal(state.enableButton.hidden, true);
  assert.deepEqual(state.calls, []);
  const installed = await setup({ offer: true, supported: true, ios: true, standalone: true });
  assert.equal(installed.container.hidden, false);
  assert.equal(installed.enableButton.disabled, false);
  assert.equal(installed.status.textContent, "ready");
});
test("a different account needs its own subscription registration", async () => {
  const state = await setup({ offer: true, permission: "granted", existing: true, registered: false });
  assert.equal(state.container.hidden, false);
  assert.deepEqual(state.calls, []);
});

const workerSource = fs.readFileSync(`${__dirname}/../../app/packs/src/decidim/sw/sw.js`, "utf8");
function worker() {
  const handlers = {}, opened = [];
  vm.runInNewContext(workerSource.replace(/import[\s\S]*?from "[^"]+";/g, ""), {
    URL, self: { location: { origin: "https://platform.example" }, skipWaiting: () => {},
      addEventListener: (name, fn) => { handlers[name] = fn; },
      clients: { matchAll: async () => [], openWindow: async (url) => { opened.push(url); } } },
    clientsClaim: () => {}, registerRoute: () => {}, NetworkOnly: class {},
    imageCache: () => {}, staticResourceCache: () => {}, offlineFallback: () => {}
  });
  return { handlers, opened };
}
test("click rejects external links and defaults missing destinations to inbox", async () => {
  const { handlers, opened } = worker();
  let done;
  const event = (url) => ({ notification: { data: { url }, close: () => {} }, waitUntil: (promise) => { done = promise; } });
  handlers.notificationclick(event("https://external.example/private"));
  assert.equal(done, undefined);
  handlers.notificationclick(event(null));
  await done;
  assert.deepEqual(opened, ["https://platform.example/notifications"]);
});
