const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(
  path.join(__dirname, "../../public/mi/mi-install.js"),
  "utf8"
);

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

class ClassList {
  constructor() {
    this.values = new Set();
  }

  add(value) {
    this.values.add(value);
  }

  remove(value) {
    this.values.delete(value);
  }

  contains(value) {
    return this.values.has(value);
  }
}

class Element extends Events {
  constructor(document) {
    super();
    this.document = document;
    this.children = [];
    this.attributes = {};
    this.hidden = false;
    this.style = {};
    this.classList = new ClassList();
    this._innerHTML = "";
  }

  set innerHTML(value) {
    this._innerHTML = value;
    this.children = [];
    const ids = [...value.matchAll(/<button\b[^>]*\bid="([^"]+)"/g)].map((match) => match[1]);
    ids.forEach((id) => {
      const button = new Element(this.document);
      button.id = id;
      this.children.push(button);
    });
  }

  get innerHTML() {
    return this._innerHTML;
  }

  setAttribute(name, value) {
    this.attributes[name] = value;
    if (name === "id") this.id = value;
  }

  querySelectorAll(selector) {
    return selector === "button" ? this.children : [];
  }

  appendChild(child) {
    this.children.push(child);
    this.document.register(child);
    return child;
  }

  getClientRects() {
    return this.hidden ? [] : [{}];
  }

  remove() {
    this.document.unregister(this);
  }
}

class Document extends Events {
  constructor(dataset) {
    super();
    this.title = "MI!";
    this.readyState = "complete";
    this.currentScript = { dataset };
    this.cookie = "";
    this.elements = {};
    this.documentElement = new Element(this);
    this.body = new Element(this);
  }

  createElement() {
    return new Element(this);
  }

  getElementById(id) {
    return this.elements[id] || null;
  }

  register(element) {
    if (element.id) this.elements[element.id] = element;
    element.children.forEach((child) => this.register(child));
  }

  unregister(element) {
    if (element.id && this.elements[element.id] === element) delete this.elements[element.id];
    element.children.forEach((child) => this.unregister(child));
    this.body.children = this.body.children.filter((child) => child !== element);
  }
}

function load({
  signedIn = false,
  allowed = true,
  search = "?app=1",
  hash = "#after",
  userAgent = "Mozilla/5.0 Chrome/140",
  standalone = false,
  consent = false,
  storage = {},
  session = {}
} = {}) {
  const document = new Document({
    installText: "Instaliraj MI! aplikaciju na telefon.",
    iosText: "Dodaj MI! na početni ekran.",
    manualText: "Otvori meni preglednika i izaberi Dodaj na početni ekran.",
    webviewText: "Otvori MI! u Chromeu ili Safariju.",
    installLabel: "Instaliraj",
    dismissLabel: "Ne sada"
  });
  const pageContext = new Element(document);
  pageContext.id = "mi-install-context";
  pageContext.dataset = { signedIn: signedIn ? "1" : "0", allowed: allowed ? "1" : "0" };
  document.register(pageContext);
  if (consent) {
    const banner = new Element(document);
    banner.id = "dc-dialog-wrapper";
    document.register(banner);
  }
  const timers = [];
  const window = new (class extends Events {})();
  window.location = { pathname: "/dobrodoslica", search, hash, href: `https://mi.test/dobrodoslica${search}${hash}` };
  window.history = {
    state: { page: 1 },
    replaceState(state, _title, url) {
      this.state = state;
      this.replaced = url;
    }
  };
  window.matchMedia = () => ({ matches: standalone });
  window.navigator = { standalone, userAgent };
  window.sessionStorage = {
    getItem(key) { return Object.prototype.hasOwnProperty.call(session, key) ? session[key] : null; },
    setItem(key, value) { session[key] = String(value); }
  };
  window.Decidim = {};
  window.MutationObserver = class {
    observe() {}
    disconnect() {}
  };
  window.setTimeout = (callback, delay) => {
    const timer = { callback, due: delay, cancelled: false };
    timers.push(timer);
    return timer;
  };
  window.clearTimeout = (timer) => {
    if (timer) timer.cancelled = true;
  };
  const localStorage = {
    getItem(key) { return Object.prototype.hasOwnProperty.call(storage, key) ? storage[key] : null; },
    setItem(key, value) { storage[key] = String(value); }
  };
  const context = {
    window,
    document,
    navigator: window.navigator,
    localStorage,
    URLSearchParams,
    decodeURIComponent,
    clearTimeout: window.clearTimeout,
    setTimeout: window.setTimeout,
    MutationObserver: window.MutationObserver,
    Promise,
    console
  };
  vm.runInNewContext(source, context, { filename: "mi-install.js" });
  return {
    document,
    window,
    storage,
    advance(ms) {
      timers.slice().forEach((timer) => {
        if (!timer.cancelled && timer.due <= ms) {
          timer.cancelled = true;
          timer.callback();
        }
      });
    },
    prompt() {
      const event = {
        type: "beforeinstallprompt",
        prevented: false,
        preventDefault() { this.prevented = true; },
        prompt() { this.prompted = true; },
        userChoice: Promise.resolve({ outcome: "accepted" })
      };
      window.dispatchEvent(event);
      return event;
    },
    resolveConsent() {
      const banner = document.getElementById("dc-dialog-wrapper");
      if (banner) banner.hidden = true;
      document.dispatchEvent({ type: "dataconsent" });
    }
  };
}

test("consumes only app=1 and preserves other query parameters and hash", () => {
  const env = load({ search: "?next=%2F&app=1&app=2", hash: "#finish" });

  assert.equal(env.window.history.replaced, "/dobrodoslica?next=%2F&app=2#finish");
  assert.equal(env.document.getElementById("mi-install-banner"), null);
  env.prompt();
  assert.ok(env.document.getElementById("mi-install-banner"));
});

test("captures a delayed beforeinstallprompt and upgrades the one shared banner", () => {
  const env = load();

  env.advance(1000);
  assert.equal(env.document.getElementById("mi-install-banner"), null);
  const event = env.prompt();
  const banner = env.document.getElementById("mi-install-banner");
  assert.ok(banner);
  assert.ok(env.document.getElementById("mi-install-go"));
  assert.equal(event.prevented, true);
});

test("shows mobile manual guidance without a dead install button when no prompt arrives", () => {
  const env = load({ userAgent: "Mozilla/5.0 (Linux; Android 14) Chrome/140 Mobile" });

  env.advance(1500);
  const banner = env.document.getElementById("mi-install-banner");
  assert.match(banner.innerHTML, /Dodaj na početni ekran/);
  assert.equal(env.document.getElementById("mi-install-go"), null);
});

test("does not show a manual fallback on desktop when no prompt arrives", () => {
  const env = load();

  env.advance(1500);
  assert.equal(env.document.getElementById("mi-install-banner"), null);
});

test("uses browser guidance for an embedded webview", () => {
  const env = load({ userAgent: "Mozilla/5.0; wv) Chrome/140" });
  const banner = env.document.getElementById("mi-install-banner");

  assert.match(banner.innerHTML, /Chromeu ili Safariju/);
  assert.equal(env.document.getElementById("mi-install-go"), null);
});

test("uses iOS manual guidance without pretending to invoke an install prompt", () => {
  const env = load({
    userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
      "AppleWebKit/605.1.15 Safari/604.1"
  });
  const banner = env.document.getElementById("mi-install-banner");

  assert.match(banner.innerHTML, /Dodaj MI! na početni ekran/);
  assert.equal(env.document.getElementById("mi-install-go"), null);
});

test("consent gating keeps the shared banner hidden until consent resolves", () => {
  const env = load({ consent: true });
  env.prompt();
  assert.equal(env.document.getElementById("mi-install-banner"), null);

  env.resolveConsent();
  assert.ok(env.document.getElementById("mi-install-banner"));
});

test("standalone mode consumes the marker and shows no banner", () => {
  const env = load({ standalone: true });

  assert.equal(env.window.history.replaced, "/dobrodoslica#after");
  assert.equal(env.document.getElementById("mi-install-banner"), null);
});

test("dismissal prevents a repeated offer after reload", () => {
  const storage = {};
  const first = load({ storage });
  first.prompt();
  const beforeDismissal = Date.now();
  first.document.getElementById("mi-install-close").dispatchEvent({ type: "click" });
  const afterDismissal = Date.now();
  const snoozedUntil = JSON.parse(storage.miInstall).snoozedUntil;
  const threeDays = 3 * 24 * 60 * 60 * 1000;
  assert.ok(snoozedUntil >= beforeDismissal + threeDays);
  assert.ok(snoozedUntil <= afterDismissal + threeDays);

  const second = load({ search: "?next=%2F#finish", storage });
  second.advance(2000);
  assert.equal(second.document.getElementById("mi-install-banner"), null);
});

test("authenticated offer does not become a generic 3-visit offer on refresh", () => {
  const storage = { miInstall: JSON.stringify({ visits: 2 }) };
  const session = {};
  const first = load({ storage, session });
  first.prompt();
  assert.ok(first.document.getElementById("mi-install-banner"));

  const second = load({ search: "?next=%2F#finish", storage, session });
  second.advance(2000);
  assert.equal(second.document.getElementById("mi-install-banner"), null);
});


test("iPhone install guidance returns after Turbo replaces a signed-in page", () => {
  const env = load({ signedIn: true, search: "", userAgent: "iPhone AppleWebKit CriOS Safari" });
  assert.ok(env.document.getElementById("mi-install-banner"));
  env.document.dispatchEvent({ type: "turbo:before-cache" });
  assert.equal(env.document.getElementById("mi-install-banner"), null);
  env.document.dispatchEvent({ type: "turbo:load" });
  assert.ok(env.document.getElementById("mi-install-banner"));
});

test("Turbo sign-in offers installation and form pages and sign-out suppress it", () => {
  const env = load({ search: "", userAgent: "iPhone AppleWebKit CriOS Safari" });
  assert.equal(env.document.getElementById("mi-install-banner"), null);
  const context = env.document.getElementById("mi-install-context");
  context.dataset.signedIn = "1";
  env.document.dispatchEvent({ type: "turbo:load" });
  assert.ok(env.document.getElementById("mi-install-banner"));
  context.dataset.allowed = "0";
  env.document.dispatchEvent({ type: "turbo:load" });
  assert.equal(env.document.getElementById("mi-install-banner"), null);
  context.dataset.allowed = "1";
  context.dataset.signedIn = "0";
  env.document.dispatchEvent({ type: "turbo:load" });
  assert.equal(env.document.getElementById("mi-install-banner"), null);
});

test("a cached page keeps the installation snooze", () => {
  const env = load({ signedIn: true, search: "", userAgent: "iPhone AppleWebKit CriOS Safari" });
  env.document.getElementById("mi-install-close").dispatchEvent({ type: "click" });
  env.document.dispatchEvent({ type: "turbo:load" });
  assert.equal(env.document.getElementById("mi-install-banner"), null);
});
