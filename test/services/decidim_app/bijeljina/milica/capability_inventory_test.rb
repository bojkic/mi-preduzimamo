# frozen_string_literal: true

require "test_helper"
require "yaml"

module DecidimApp
  module Bijeljina
    module Milica
      class CapabilityInventoryTest < ActiveSupport::TestCase
        test "every current legacy handler and classifier intent has an explicit route" do
          inventory = YAML.safe_load_file(Rails.root.join("test/fixtures/files/milica/capability_inventory.yml"))

          assert_equal Decidim::Bih::Concierge::Responder::DEFAULT_HANDLERS.map(&:to_s).sort, inventory.fetch("handlers").keys.sort
          assert_equal Decidim::Bih::Concierge::IntentClassifier::INTENTS.map(&:to_s).sort, inventory.fetch("legacy_classifier_intents").sort
          assert(inventory.fetch("handlers").values.all? { |handler| handler.fetch("route").present? && handler.fetch("effect").present? })
        end

        test "retired effects do not redefine guidance as a completed action" do
          handlers = YAML.safe_load_file(Rails.root.join("test/fixtures/files/milica/capability_inventory.yml")).fetch("handlers")

          assert_equal "implicit_publication", handlers.fetch("komsiluk_post_reply").fetch("retired")
          assert_equal "ambiguous_automatic_intake", handlers.fetch("report_reply").fetch("retired")
          assert_equal "handoff", handlers.fetch("komsiluk_post_reply").fetch("effect")
          assert_equal "handoff", handlers.fetch("report_reply").fetch("effect")
        end
      end
    end
  end
end
