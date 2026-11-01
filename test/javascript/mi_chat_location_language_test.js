const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const roots = [path.join(__dirname, "../..")];
if (process.env.MILICA_ENGINE_ROOT) roots.push(process.env.MILICA_ENGINE_ROOT);
for (const root of roots) {
  const source = fs.readFileSync(path.join(root, "public/mi/mi-chat.js"), "utf8");
  const helpers = source.match(/^  function (?:foldedText|locationRequested)\([^\n]*\) \{[\s\S]*?^  \}/gm);
  assert.equal(helpers.length, 2);
  const context = vm.createContext({});
  vm.runInContext(helpers.join("\n"), context, { timeout: 1000 });

  test(`${path.basename(root)}: explicit current-location forms in both scripts`, () => {
    for (const text of ["Sa moje lokacije.", "Kako da platim parking na mojoj lokaciji?", "Od trenutne lokacije",
      "Са моје локације", "На мојој локацији", "Од тренутне локације", "from my location", "odavde"]) {
      assert.equal(context.locationRequested(text), true, text);
    }
  });

  test(`${path.basename(root)}: unrelated messages do not request location`, () => {
    for (const text of ["status prijave", "kultura", "institucija", "Koliko košta autobuska karta?", "U Dvorovima",
      "Bez moje lokacije, molim.", "Без моје локације.", "Nemoj koristiti moju trenutnu lokaciju.",
      "Do not use my location.", "Without my location, tell me the fare."]) {
      assert.equal(context.locationRequested(text), false, text);
    }
  });
}
