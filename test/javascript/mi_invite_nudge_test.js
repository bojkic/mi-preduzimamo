/* Behaviour of public/mi/mi-invite-nudge.js — the snooze, the dismissal and the
   cookie-consent deferral. The strip ships hidden and this script is the only
   thing that ever reveals it, so an untested script means a nudge that either
   never appears or never goes away. */
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(
  path.join(__dirname, "../../public/mi/mi-invite-nudge.js"),
  "utf8"
);

const DAY_MS = 24 * 60 * 60 * 1000;

class Events {
  constructor() {
    this.listeners = {};
  }

  addEventListener(name, callback) {
    (this.listeners[name] ||= []).push(callback);
  }

  removeEventListener(name, callback) {
    this.listeners[name] = (this.listeners[name] || []).filter((item) => item !== callback);
  }

  dispatchEvent(event) {
    (this.listeners[event.type] || []).slice().forEach((callback) => callback(event));
  }
}

class Element extends Events {
  constructor(attributes = {}) {
    super();
    this.attributes = attributes;
    this.hidden = true;
    this.children = [];
  }

  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null;
  }

  querySelector(selector) {
    return this.children.find((child) => child.matches === selector) || null;
  }

  getClientRects() {
    return this.hidden ? [] : [{}];
  }
}

class Document extends Events {
  constructor(nudge, { consent = false } = {}) {
    super();
    this.readyState = "complete";
    this.nudge = nudge;
    this.banner = consent ? Object.assign(new Element(), { hidden: false }) : null;
  }

  querySelectorAll(selector) {
    return selector === "[data-invite-nudge]" && this.nudge ? [this.nudge] : [];
  }

  getElementById(id) {
    return id === "dc-dialog-wrapper" ? this.banner : null;
  }
}

// A nudge element with its dismiss button, shaped like the rendered partial.
function buildNudge({ key = "mi:invite-nudge:7", days = "7" } = {}) {
  const nudge = new Element({
    "data-invite-nudge-key": key,
    "data-invite-nudge-days": days
  });
  const dismiss = new Element();
  dismiss.matches = "[data-invite-nudge-dismiss]";
  nudge.children.push(dismiss);
  nudge.dismissButton = dismiss;
  return nudge;
}

function load({ storage = {}, consent = false, nudge = buildNudge(), throwOnStorage = false } = {}) {
  const document = new Document(nudge, { consent });
  const window = new (class extends Events {})();
  window.localStorage = {
    getItem(k) {
      if (throwOnStorage) throw new Error("storage disabled");
      return Object.prototype.hasOwnProperty.call(storage, k) ? storage[k] : null;
    },
    setItem(k, v) {
      if (throwOnStorage) throw new Error("storage disabled");
      storage[k] = String(v);
    }
  };
  window.MutationObserver = class {
    observe() {}
    disconnect() {}
  };
  vm.runInNewContext(source, { window, document, MutationObserver: window.MutationObserver, console }, {
    filename: "mi-invite-nudge.js"
  });
  return { document, nudge, storage };
}

test("a nudge that has never been dismissed is revealed", () => {
  const { nudge } = load();

  assert.equal(nudge.hidden, false);
});

test("dismissing hides the strip and snoozes it for the requested days", () => {
  const storage = {};
  const { nudge } = load({ storage });
  const before = Date.now();

  nudge.dismissButton.dispatchEvent({ type: "click" });

  assert.equal(nudge.hidden, true);
  const until = parseInt(storage["mi:invite-nudge:7"], 10);
  assert.ok(until >= before + 7 * DAY_MS, "snoozed at least seven days");
  assert.ok(until <= Date.now() + 7 * DAY_MS + 1000, "and not appreciably longer");
});

test("a live snooze keeps the strip hidden and wires up nothing", () => {
  const { nudge } = load({
    storage: { "mi:invite-nudge:7": String(Date.now() + 3 * DAY_MS) }
  });

  assert.equal(nudge.hidden, true);
});

test("an expired snooze reveals the strip again", () => {
  const { nudge } = load({
    storage: { "mi:invite-nudge:7": String(Date.now() - 1000) }
  });

  assert.equal(nudge.hidden, false);
});

test("a corrupt snooze value is treated as no snooze rather than forever", () => {
  const { nudge } = load({ storage: { "mi:invite-nudge:7": "not-a-number" } });

  assert.equal(nudge.hidden, false);
});

test("the snooze window comes from the markup and falls back to seven days", () => {
  const storage = {};
  const { nudge } = load({ storage, nudge: buildNudge({ days: "0" }) });
  const before = Date.now();

  nudge.dismissButton.dispatchEvent({ type: "click" });

  const until = parseInt(storage["mi:invite-nudge:7"], 10);
  assert.ok(until >= before + 7 * DAY_MS, "a nonsense day count still snoozes a week");
});

// Consent comes first: the strip must not appear over Decidim's cookie dialog.
test("the strip waits for the cookie banner and appears once consent resolves", () => {
  const { nudge, document } = load({ consent: true });

  assert.equal(nudge.hidden, true, "hidden while the consent dialog is up");

  document.banner.hidden = true;
  document.dispatchEvent({ type: "dataconsent" });

  assert.equal(nudge.hidden, false);
});

// Private mode: reading and writing storage both throw. Failing towards
// "shown, and dismissable for this page" is the safe direction.
test("a browser with no localStorage still shows and still dismisses", () => {
  const { nudge } = load({ throwOnStorage: true });

  assert.equal(nudge.hidden, false);

  nudge.dismissButton.dispatchEvent({ type: "click" });

  assert.equal(nudge.hidden, true);
});

test("a page with no nudge does nothing at all", () => {
  assert.doesNotThrow(() => load({ nudge: null }));
});
