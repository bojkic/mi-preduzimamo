# frozen_string_literal: true

require "minitest/autorun"
require "open3"

class DecodeUriComponentSecurityTest < Minitest::Test
  def test_linear_decoder_and_legacy_webpack_consumers
    root = File.expand_path("../..", __dir__)
    output, status = Open3.capture2e({ "NODE_ENV" => "test", "RAILS_ENV" => "test" },
                                     "node", "--test", File.join(root, "test/javascript/decode_uri_component_test.cjs"), chdir: root)
    assert status.success?, output
  end
end
