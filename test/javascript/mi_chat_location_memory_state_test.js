const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../../public/mi/mi-chat.js"), "utf8");
const helper = source.match(/^  function applyLocationMemoryState\([^\n]*\) \{[\s\S]*?^  \}/m);
assert.ok(helper, "widget must use the authoritative response status helper");

function memoryState() {
  const calls = [];
  const context = vm.createContext({ LOCATION_MEMORY_ENABLED: true, markLocationShare: (value) => calls.push(value) });
  vm.runInContext(helper[0], context, { timeout: 1000 });
  return { calls, apply: (value) => context.applyLocationMemoryState(value) };
}

test("HTTP 200 fallback after Redis failure cannot claim a new share", () => {
  const state = memoryState();
  state.apply("unknown");
  assert.deepEqual(state.calls, []);
});

test("failed forget cannot clear the last confirmed status", () => {
  const state = memoryState();
  state.apply("active");
  state.apply("unknown");
  assert.deepEqual(state.calls, [true]);
  state.apply("inactive");
  assert.deepEqual(state.calls, [true, false]);
});

test("a reload does not trust tab storage as proof of active server location", async () => {
  assert.doesNotMatch(source, /restoreLocationShare|LOCATION_SHARED_KEY/);
  const route = source.match(/^  function locationForMessage\([^\n]*\) \{[\s\S]*?^  \}/m);
  assert.ok(route);
  assert.match(route[0], /return ensureLocationMemoryState\(\)\.then/);
  let geolocationRequests = 0;
  let statusChecks = 0;
  const context = vm.createContext({
    locationRequested: () => true,
    ensureLocationMemoryState: () => { statusChecks += 1; return Promise.resolve(); },
    freshLocation: () => null,
    syncLocationButton: () => {},
    requestBrowserLocation: () => { geolocationRequests += 1; return Promise.resolve({ latitude: 44.7, longitude: 19.2 }); },
    addBubble: () => {},
    LOCATION_MEMORY_ENABLED: true,
    serverLocationActive: false,
    T: {},
    lastLocation: null,
    window: { sessionStorage: { getItem: () => { throw new Error("tab storage is not location proof"); } } }
  });
  vm.runInContext(route[0], context, { timeout: 1000 });
  const point = await context.locationForMessage("odavde");
  assert.equal(statusChecks, 1);
  assert.equal(geolocationRequests, 1);
  assert.equal(point.latitude, 44.7);
});
