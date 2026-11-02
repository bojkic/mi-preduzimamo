/* eslint-disable */
process.env.NODE_ENV ??= "development"

const { webpackConfig, merge } = require("@decidim/webpacker")
const customConfig = require("./custom")

webpackConfig.optimization = {}
const combinedConfig = merge(webpackConfig, customConfig)

// Keep native build-host paths out of distributed production source maps.
if (process.env.NODE_ENV === "production") {
  combinedConfig.devtool = false
}

// Retain an explicit public build-environment allowlist after the upstream
// Shakapacker 9 upgrade. Only these public build-mode flags may be substituted into
// browser bundles; pack sources read nothing else from process.env. Proven by
// test/scripts/webpack_environment_test.cjs (run from the Rails suite).
const webpack = require("webpack")
combinedConfig.plugins = combinedConfig.plugins.filter(
  (plugin) => !(plugin instanceof webpack.EnvironmentPlugin)
)
combinedConfig.plugins.push(new webpack.EnvironmentPlugin({
  NODE_ENV: "development",
  RAILS_ENV: "development"
}))

// Preserve a visible notice location in every emitted browser JS/CSS chunk.
combinedConfig.plugins.push(new webpack.BannerPlugin({
  banner: "Third-party licences and source notices: /mi/licenses/BROWSER_THIRD_PARTY_NOTICES.txt",
  test: /\.(?:js|css)$/
}))

// Legacy form-storage/query-string consumers require a callable CommonJS export.
// Use the upstream 0.5.1 linear decoder with only its export adapted, so malformed
// percent-encoded input cannot enter the older exponential/quadratic fallback.
const path = require("path")
combinedConfig.resolve = combinedConfig.resolve || {}
combinedConfig.resolve.alias = {
  ...(combinedConfig.resolve.alias || {}),
  "decode-uri-component$": path.resolve(__dirname, "../../vendor/javascript/decode-uri-component/index.cjs")
}

module.exports = combinedConfig
