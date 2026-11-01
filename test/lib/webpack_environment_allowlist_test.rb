# frozen_string_literal: true

require "test_helper"
require "open3"

# shakapacker 8.3 hands the whole build environment to webpack's
# EnvironmentPlugin (GHSA-96qw-h329-v5rg); config/webpack/webpack.config.js
# swaps it for a NODE_ENV/RAILS_ENV allowlist. The proof is a node script that
# compiles with synthetic secrets, but neither the full release gate nor the
# change mapper runs test/scripts/*.cjs unless that file itself changes — so a
# webpack, shakapacker or lockfile change could quietly undo the allowlist.
# Running it from the Rails suite puts it in every deep gate.
#
# Skips only when node or the installed webpack is missing, naming the fix.
class WebpackEnvironmentAllowlistTest < ActiveSupport::TestCase
  SCRIPT = "test/scripts/webpack_environment_test.cjs"

  test "browser bundles receive only the allowlisted build environment" do
    skip("node is not on PATH — install Node 22.x to run #{SCRIPT}") unless node_available?
    skip("node_modules/webpack is missing — run `npm ci` before #{SCRIPT}") unless Rails.root.join("node_modules/webpack/package.json").file?

    stdout, stderr, status = Open3.capture3("node", SCRIPT, chdir: Rails.root.to_s)

    assert status.success?, "`node #{SCRIPT}` failed:\n#{stdout}\n#{stderr}"
    assert_includes stdout, "vulnerable control reproduced"
  end

  private

  def node_available?
    _stdout, _stderr, status = Open3.capture3("node", "--version")
    status.success?
  rescue Errno::ENOENT
    false
  end
end
