const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../../public/mi/mi-chat.js"), "utf8");
// Execute the shipped helpers unchanged, without starting the widget or a
// browser. No duplicated link matcher can conceal a renderer regression.
const helpers = source.match(/^  function (?:el|linkPunctuation|validatedLink|replyLinkTarget|sameTabPaths|appendSafeText|addQuickReplies)\([^\n]*\) \{[\s\S]*?^  \}/gm);
assert.equal(helpers.length, 7);

function element(tag) {
  return {
    tagName: tag.toUpperCase(), attributes: {}, children: [], value: "", listeners: {},
    setAttribute(name, value) { this.attributes[name] = value; },
    addEventListener(name, handler) { this.listeners[name] = handler; },
    appendChild(child) { this.children.push(child); return child; },
    set textContent(value) { this.value = value; this.children = []; },
    get textContent() { return this.value + this.children.map((child) => child.textContent).join(""); },
    set innerHTML(_value) { throw new Error("reply markup must never be interpreted"); }
  };
}

// CFG mirrors the mi-chat-config meta. The default carries the registration
// path this host configures, because that is what production ships; pass {} to
// exercise a host that has not configured one.
function render(text, cfg) {
  const container = element("div");
  const context = vm.createContext({
    URL, container, text,
    CFG: cfg === undefined ? { registrationPath: "/registracija" } : cfg,
    window: { location: { origin: "https://milica.example.test" } },
    document: { createElement: element, createTextNode: (value) => ({ textContent: value }) }
  });
  vm.runInContext(helpers.join("\n"), context, { timeout: 1000 });
  vm.runInContext("appendSafeText(container, text)", context, { timeout: 1000 });
  assert.equal(container.textContent, text);
  return container.children.filter((node) => node.tagName === "A");
}

test("ordinary units, zone names and ratios stay plain text", () => {
  for (const text of ["1,50 KM/h", "crvena/I", "plava/II", "3/4 i 24/7", "file_/path"]) {
    assert.deepEqual(render(text), [], text);
  }
});

test("relative links cannot start inside Serbian letters or combining marks", () => {
  for (const text of ["č/ć š/ž đ/1", "Č/Ć Š/Ž Đ/II", "Комшилук/Дворови", "c\u030c/ž", "𐐀/path"]) {
    assert.deepEqual(render(text), [], text);
  }
});

test("separated internal and absolute links preserve punctuation and safe attributes", () => {
  const text = "/biceriseno/prijave/new, (/registracija). [/_status] https://example.test/a(b)). HTTP://example.test/ž?q=ћ!";
  const links = render(text);
  assert.deepEqual(links.map((node) => node.attributes.href), [
    "/biceriseno/prijave/new", "/registracija", "/_status", "https://example.test/a(b)", "HTTP://example.test/ž?q=ћ"
  ]);
  for (const link of links) {
    assert.equal(link.textContent, link.attributes.href);
    assert.equal(link.attributes.rel, "noopener noreferrer");
    // Everything here opens a separate tab except the configured registration
    // path, which continues in this one because registering resets the session.
    assert.equal(link.attributes.target, link.attributes.href === "/registracija" ? "_self" : "_blank");
  }
});

test("unsafe slash contexts and hostile markup remain plain text", () => {
  const text = "<img src=x onerror=alert(1)> <script>alert(2)</script> href='/bad' " +
    "//evil.test \\/evil.test javascript:/bad data:/bad /bad\\path /bad\u0001path";
  assert.deepEqual(render(text), []);
});

test("Milica session-only sign-in handoff navigates the current tab", () => {
  for (const href of ["/milica/prijava", "/milica/prijava?locale=sr", "https://milica.example.test/milica/prijava"]) {
    const links = render("Prijavi se na postojeći nalog ovdje: " + href);
    assert.equal(links.length, 1);
    assert.equal(links[0].attributes.href, href);
    assert.equal(links[0].attributes.target, "_self");
    assert.equal(links[0].attributes.rel, "noopener noreferrer");
  }
});

test("external handoff lookalikes, ordinary links and walking maps retain a separate tab", () => {
  for (const href of [
    "https://elsewhere.example.test/milica/prijava",
    "http://milica.example.test/milica/prijava",
    "/milica/prijava-other", "/milica/prijava/other",
    "/registracija-other", "/registracija/other",
    "https://www.google.com/maps/dir/?api=1&destination=44.75%2C19.21&travelmode=walking"
  ]) {
    const links = render(href);
    assert.equal(links.length, 1);
    assert.equal(links[0].attributes.href, href);
    assert.equal(links[0].attributes.target, "_blank");
  }
});

// Registering calls reset_session, so the chat tab left behind would hold a
// dead CSRF token — the same reason /milica/prijava has always been same-tab.
// The register answer stopped emitting /milica/prijava (its ten-minute ticket
// degraded to the LOGIN form), so the configured path has to carry the rule.
test("the configured registration path continues in the same tab", () => {
  const links = render("/registracija");
  assert.equal(links.length, 1);
  assert.equal(links[0].attributes.target, "_self");
});

// The path is read from config, never typed here: a host that configures a
// different one gets the rule, and a host that configures none is unchanged.
test("the same-tab rule follows the configured path rather than a literal", () => {
  assert.equal(render("/pridruzi-se", { registrationPath: "/pridruzi-se" })[0].attributes.target, "_self");
  assert.equal(render("/registracija", { registrationPath: "/pridruzi-se" })[0].attributes.target, "_blank");
  assert.equal(render("/registracija", {})[0].attributes.target, "_blank");
  assert.equal(render("/milica/prijava", {})[0].attributes.target, "_self");
});

test("both supported quick-reply URL fields already keep the handoff in the same tab", () => {
  for (const key of ["url", "href"]) {
    const body = element("div");
    const actions = [];
    const context = vm.createContext({
      body, items: [{ label: "Prijavi se", [key]: "/milica/prijava" }],
      window: { location: { assign: (href) => actions.push(["navigate", href]) } },
      document: { createElement: element },
      close: () => actions.push(["close"]), scrollToEnd() {},
      submit: () => assert.fail("A login link must not become a chat message")
    });
    vm.runInContext(helpers.join("\n"), context, { timeout: 1000 });
    vm.runInContext("addQuickReplies(items)", context, { timeout: 1000 });
    const chip = body.children[0].children[0];
    assert.equal(chip.attributes["data-mi-chat-action"], "navigate");
    chip.listeners.click();
    assert.deepEqual(actions, [["close"], ["navigate", "/milica/prijava"]]);
  }
});
