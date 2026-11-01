# frozen_string_literal: true
require "test_helper"

module DecidimApp
  module Bijeljina
    class PublicCatalogDefaultsTest < ActiveSupport::TestCase
      setup do
        @gazette_source_env = %w(MI_GAZETTE_SOURCE_URL BIJELJINA_GAZETTE_URL).to_h { |key| [key, ENV[key]] }
        @gazette_source_env.each_key { |key| ENV.delete(key) }
      end
      teardown do
        @gazette_source_env.each { |key, prior| prior.nil? ? ENV.delete(key) : ENV[key] = prior }
      end
      test "unconfigured gazette has no municipal source default" do
        assert_empty Gazette::DEFAULT_SOURCE_URL
        assert_empty Gazette.source_url
      end
      test "community gazette source is explicit and takes precedence" do
        ENV["MI_GAZETTE_SOURCE_URL"] = "https://community.example.invalid/gazette"
        ENV["BIJELJINA_GAZETTE_URL"] = "https://legacy.example.invalid/gazette"
        assert_equal "https://community.example.invalid/gazette", Gazette.source_url
      end
      test "legacy source is retained only when explicitly configured" do
        ENV["BIJELJINA_GAZETTE_URL"] = "https://legacy.example.invalid/gazette"
        assert_equal "https://legacy.example.invalid/gazette", Gazette.source_url
      end
    end
  end
end
