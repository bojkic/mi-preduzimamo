// Compile real webpack output with synthetic secrets; never source production .env.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const webpack = require("webpack");
process.env.NODE_ENV = "production";
process.env.RAILS_ENV = "production";
process.env.DATABASE_URL = "postgres://synthetic-private-sentinel/database";
process.env.SECRET_KEY_BASE = "synthetic-secret-key-sentinel";
// An innocuous-looking name: the allowlist must not depend on a variable looking secret.
process.env.MI_PUBLIC_LOOKING_FLAG = "synthetic-public-looking-sentinel";
process.env.WEBPACK_SERVE = "synthetic-webpack-serve-sentinel";
const config = require("../../config/webpack/webpack.config.js");
const plugins = config.plugins.filter(plugin => plugin instanceof webpack.EnvironmentPlugin);
assert.equal(plugins.length, 1);
assert.deepEqual([...plugins[0].keys].sort(), ["NODE_ENV", "RAILS_ENV"]);
// Shakapacker's own EnvironmentPlugin(process.env) must be gone, not merely outnumbered.
assert(!config.plugins.some(plugin => plugin.constructor && plugin.constructor.name === "EnvironmentPlugin" && plugin !== plugins[0]));
const noticePlugins = config.plugins.filter(plugin => plugin instanceof webpack.BannerPlugin);
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "mi-webpack-env-"));
fs.writeFileSync(path.join(directory, "entry.js"), `
  const { SECRET_KEY_BASE } = process.env;
  globalThis.result = [process.env.NODE_ENV, process.env.RAILS_ENV, process.env.DATABASE_URL, process.env['SECRET_KEY_BASE'], SECRET_KEY_BASE,
    process.env.MI_PUBLIC_LOOKING_FLAG, process.env.WEBPACK_SERVE];
`);
function compile(name, envPlugins) {
  return new Promise((resolve, reject) => {
    const compiler = webpack({mode: "production", entry: path.join(directory, "entry.js"),
      output: {path: directory, filename: name}, plugins: envPlugins,
      optimization: {minimize: false}});
    compiler.run((error, stats) => compiler.close(closeError => {
      if (error || closeError || stats.hasErrors()) reject(error || closeError || new Error(stats.toString()));
      else resolve(fs.readFileSync(path.join(directory, name), "utf8"));
    }));
  });
}
(async () => {
  try {
    const vulnerable = await compile("control.js", [new webpack.EnvironmentPlugin(process.env)]);
    assert(vulnerable.includes("synthetic-private-sentinel"), "control must reproduce exposure");
    const protectedOutput = await compile("protected.js", [...plugins, ...noticePlugins]);
    assert(protectedOutput.includes("Third-party licences and source notices: /mi/licenses/BROWSER_THIRD_PARTY_NOTICES.txt"),
      "browser output must point to the distributed licence/source notices");
    assert(!protectedOutput.includes("synthetic-private-sentinel"));
    for (const sentinel of ["synthetic-secret-key-sentinel", "synthetic-public-looking-sentinel", "synthetic-webpack-serve-sentinel"]) {
      assert(!protectedOutput.includes(sentinel), `${sentinel} reached the bundle`);
    }
    const sandbox = {process: {env: {}}};
    vm.runInNewContext(protectedOutput, sandbox);
    assert.equal(sandbox.result[0], "production");
    assert.equal(sandbox.result[1], "production");
    assert(sandbox.result.slice(2).every(value => value === undefined));
    console.log("webpack environment: vulnerable control reproduced; restricted output contains no synthetic secrets; public mode and licence notice retained");
  } finally {fs.rmSync(directory, {recursive: true, force: true});}
})().catch(error => {console.error(error); process.exitCode = 1;});
