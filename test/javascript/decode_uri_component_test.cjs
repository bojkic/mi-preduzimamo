const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { Worker } = require("node:worker_threads");
const root = path.resolve(__dirname, "../..");
const decoderPath = path.join(root, "vendor/javascript/decode-uri-component/index.cjs");
const decode = require(decoderPath);

test("legacy callable export preserves Unicode and one-pass percent decoding", () => {
  assert.equal(typeof decode, "function");
  for (const text of ["", "srpska latinica", "ћирилица", "bosanski čćšđž", "hrvatski", "😀 & + = %"]) {
    assert.equal(decode(encodeURIComponent(text)), text);
  }
  assert.equal(decode("%2525"), "%25");
  assert.equal(decode("%E2%82%AC%zz"), "€%zz");
  assert.equal(decode("%C2"), "\uFFFD");
  assert.equal(decode("%FE%FF"), "\uFFFD\uFFFD");
  assert.throws(() => decode(null), TypeError);
});

function boundedDecode(input) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(`
      const {parentPort, workerData} = require("node:worker_threads");
      const value = require(workerData.path)(workerData.input);
      parentPort.postMessage({length: value.length});
    `, {eval: true, workerData: {path: decoderPath, input}});
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      worker.terminate().then(() => error ? reject(error) : resolve(value));
    };
    const timer = setTimeout(() => finish(new Error("Malformed decoding exceeded bounded worker budget")), 5000);
    worker.once("message", value => finish(null, value));
    worker.once("error", error => finish(error));
    worker.once("exit", code => { if (!settled) finish(new Error(`Decoder worker exited before a result (${code})`)); });
  });
}

test("malformed recursive-decoder and distinct-run regressions complete under a bounded worker budget", async () => {
  let runs = "";
  for (let index = 0; index < 32000; index++) {
    runs += `%${Math.floor(index / 256).toString(16).padStart(2, "0")}%${(index % 256).toString(16).padStart(2, "0")}x`;
  }
  for (const input of ["%C0".repeat(32) + "%", runs + "%zz"]) {
    const result = await boundedDecode(input);
    assert.ok(result.length > 0 && result.length <= input.length);
  }
});

test("actual webpack alias keeps both legacy query-string consumers callable and excludes the vulnerable decoder", async () => {
  process.env.NODE_ENV = "test";
  process.env.RAILS_ENV = "test";
  const webpack = require("webpack");
  const config = require(path.join(root, "config/webpack/webpack.config.js"));
  fs.mkdirSync(path.join(root, "tmp"), {recursive: true});
  const work = fs.mkdtempSync(path.join(root, "tmp/decoder-webpack-"));
  const entry = path.join(work, "entry.cjs");
  fs.writeFileSync(entry, `
    module.exports = {
      legacy: require("query-string").parse("name=%C4%8D%20%26%20%25"),
      es5: require("query-string-es5").parse("name=%D1%9B%D0%B8%D1%80%D0%B8%D0%BB%D0%B8%D1%86%D0%B0"),
      malformed: require("query-string-es5").parse("name=%E2%82%AC%zz")
    };
  `);
  let compiler;
  try {
    compiler = webpack({mode: "development", target: "node", context: root, entry,
      resolve: config.resolve, devtool: false, cache: false,
      output: {path: path.join(work, "out"), filename: "result.cjs", library: {type: "commonjs2"}}});
    const stats = await new Promise((resolve, reject) => compiler.run((error, stats) => error ? reject(error) : resolve(stats)));
    assert.equal(stats.hasErrors(), false, stats.toString({all: false, errors: true}));
    const modules = [...stats.compilation.modules].map(mod => mod.identifier());
    assert.ok(modules.some(name => name.includes("vendor/javascript/decode-uri-component/index.cjs")));
    assert.equal(modules.some(name => /node_modules[/\\]decode-uri-component[/\\]index\.js/.test(name)), false);
    const output = require(path.join(work, "out/result.cjs"));
    assert.equal(output.legacy.name, "č & %");
    assert.equal(output.es5.name, "ћирилица");
    assert.equal(output.malformed.name, "€%zz");
  } finally {
    if (compiler) await new Promise((resolve, reject) => compiler.close(error => error ? reject(error) : resolve()));
    fs.rmSync(work, {recursive: true});
  }
});
