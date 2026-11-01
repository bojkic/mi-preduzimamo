# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Concierge
      class CommandInventoryTest < ActiveSupport::TestCase
        test "responder answer intents are accepted by web chat feedback metadata" do
          responder_intents = Responder::HANDLER_ANSWER_INTENTS.values
          allowed = WebChatController::VALID_ANSWER_INTENTS

          responder_intents.each do |intent|
            assert_includes allowed, intent
          end
        end

        test "classifier enum and promotable handlers stay aligned" do
          promotable = Responder::INTENT_HANDLERS.keys

          promotable.each do |intent|
            assert_includes IntentClassifier::INTENTS, intent
          end

          assert_includes IntentClassifier::INTENTS, :report
          assert_not_includes promotable, :report
          assert_not_includes promotable, :komsiluk_post
          assert_not_includes promotable, :report_guidance
          assert_includes promotable, :participation_guidance
          assert_includes promotable, :volunteer_guidance
          assert_includes promotable, :local_area_guidance
          assert_includes promotable, :data_status
          assert_includes promotable, :city_event
          assert_includes promotable, :komsiluk_read
        end

        test "feedback allowlist covers non-handler web outcomes" do
          %w(account_linking fallback unknown).each do |intent|
            assert_includes WebChatController::VALID_ANSWER_INTENTS, intent
          end
        end
      end
    end
  end
end
