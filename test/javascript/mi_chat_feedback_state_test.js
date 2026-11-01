const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

// Execute the shipped handler. The rating guidance must describe what these
// controls actually permit, including share-then-rate and unavailable tokens.
const source = fs.readFileSync(path.join(__dirname, "../../public/mi/mi-chat.js"), "utf8");
const handler = source.match(/^  function submitFeedback\([^\n]*\) \{[\s\S]*?^  \}/m)[0];
async function submit(value, response) {
  const buttons = ["helpful", "not_helpful", "share_question"].map((v) => ({
    disabled: false, attributes: { "data-value": v },
    getAttribute(k) { return this.attributes[k]; },
    setAttribute(k, x) { this.attributes[k] = x; }
  }));
  const status = { textContent: "" };
  const requests = [];
  const context = vm.createContext({
    FEEDBACK: {}, FEEDBACK_TIMEOUT_MS: 1000, csrfToken: () => "synthetic-csrf",
    timedFetch(url, options, _timeout, callback) {
      requests.push({ url, options });
      return Promise.resolve().then(() => callback({
        status: response, ok: response === 200,
        json: () => Promise.resolve({ status: response === 200 ? "ok" : "error" })
      }));
    }
  });
  vm.runInContext(handler, context);
  const wrap = { querySelectorAll: () => buttons };
  const click = (nextValue) => context.submitFeedback(
    { id: "synthetic-reply", token: "synthetic-token", url: "/feedback" }, nextValue, wrap, status);
  click(value);
  assert.ok(buttons.every((b) => b.disabled), "disable controls while submitting");
  await new Promise(setImmediate);
  return { buttons, status, requests, click };
}

test("a successful rating leaves only the other thumb available", async () => {
  const { buttons, requests } = await submit("helpful", 200);
  assert.deepEqual(buttons.map((b) => b.disabled), [true, false, true]);
  assert.equal(buttons[0].attributes["aria-pressed"], "true");
  assert.equal(requests.length, 1);
  assert.equal(JSON.parse(requests[0].options.body).value, "helpful");
});

test("saving a question leaves the thumbs available for a later rating", async () => {
  const { buttons } = await submit("share_question", 200);
  assert.deepEqual(buttons.map((b) => b.disabled), [false, false, true]);
});

test("a transient failure permits retry", async () => {
  const { buttons } = await submit("not_helpful", 500);
  assert.ok(buttons.every((b) => !b.disabled));
});

test("an expired or unavailable token leaves controls disabled with an explanation", async () => {
  const { buttons, status } = await submit("helpful", 422);
  assert.ok(buttons.every((b) => b.disabled));
  assert.match(status.textContent, /expired|unavailable/);
});


test("the opposite thumb updates the same reply and token without concurrent duplicates", async () => {
  const { buttons, requests, click } = await submit("helpful", 200);
  click("not_helpful");
  click("helpful");
  click("not_helpful");
  assert.equal(requests.length, 2);
  assert.ok(buttons.every((button) => button.disabled));
  await new Promise(setImmediate);
  assert.deepEqual(buttons.map((button) => button.disabled), [false, true, true]);
  assert.equal(buttons[0].attributes["aria-pressed"], "false");
  assert.equal(buttons[1].attributes["aria-pressed"], "true");
  assert.deepEqual(requests.map((request) => JSON.parse(request.options.body)), [
    { reply_id: "synthetic-reply", token: "synthetic-token", value: "helpful" },
    { reply_id: "synthetic-reply", token: "synthetic-token", value: "not_helpful" }
  ]);
  click("helpful");
  await new Promise(setImmediate);
  assert.deepEqual(buttons.map((button) => button.disabled), [true, false, true]);
});
