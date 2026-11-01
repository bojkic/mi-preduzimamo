# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class PublicToolEmptyScopeTest < ActiveSupport::TestCase
        MARKER = "public_catalog_material_needs_empty"

        def envelope(status:, warnings: [], operation: "read_catalog", arguments: { "topic" => "community", "view" => "material_needs" })
          PublicToolEvidence.envelope({ status:, facts: [], warnings: }, organization_id: 1,
            registry_epoch: "authored-public-tools-v1", operation:, arguments:)
        end

        test "only the owning material catalogue empty result carries a derived scoped empty signal" do
          result = envelope(status: "empty", warnings: ["authored_original_warning"])
          assert_equal "unsupported", result.status
          assert_includes result.warnings, MARKER
          assert_includes result.warnings, "authored_original_warning"
          assert_empty result.evidence
          %w(unsupported unavailable unreviewed).each do |status|
            assert_not_includes envelope(status:).warnings, MARKER
          end
        end

        test "an incoming marker cannot lend empty semantics to a failing source" do
          %w(unsupported unavailable unreviewed).each do |status|
            result = envelope(status:, warnings: [MARKER, "authored_original_warning"])
            assert_not_includes result.warnings, MARKER
            assert_includes result.warnings, "authored_original_warning"
          end
          assert_equal 1, envelope(status: "empty", warnings: [MARKER, MARKER]).warnings.count(MARKER)
        end

        test "other catalogue views topics and operations retain the original empty mapping" do
          [{ operation: "read_catalog", arguments: { "topic" => "community", "view" => "projects" } },
           { operation: "read_catalog", arguments: { "topic" => "volunteer", "view" => "material_needs" } },
           { operation: "read_public_notice", arguments: { "source" => "pio_notices" } }].each do |options|
            result = envelope(status: "empty", warnings: ["authored_original_warning"], **options)
            assert_equal "unsupported", result.status
            assert_equal ["authored_original_warning"], result.warnings
          end
        end
      end
    end
  end
end
