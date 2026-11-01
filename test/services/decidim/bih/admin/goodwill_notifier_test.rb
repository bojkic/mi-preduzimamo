# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Admin
      # T10a — the notifier owns the "publish a goodwill bell event, but never let
      # a notification failure break the already-committed admin action" shell
      # extracted from GoodwillController. Verifies the exact event published per
      # method AND that a publish failure is swallowed (returns nil) and logged.
      class GoodwillNotifierTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @ledger = Decidim::Bih::Goodwill::Ledger.new
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @notifier = GoodwillNotifier.new
        end

        def fulfillment
          @ledger.award(@citizen, 600, reason: "volunteer_hour")
          Decidim::Bih::Goodwill::RedeemReward.call(@citizen, "majica")
          Decidim::Bih::Goodwill::RewardFulfillment.last
        end

        def match_request
          group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                       extended_data: { "group" => true })
          group.update!(name: "Udruženje X", nickname: "udruzenje_x")
          Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: @organization, owner: group, points: 50,
            status: "pending", created_by: @citizen
          )
        end

        # Capture the kwargs of the single publish call the method makes.
        def capture_publish
          captured = nil
          Decidim::EventsManager.stub(:publish, ->(**kwargs) { captured = kwargs }) do
            yield
          end
          captured
        end

        test "reward_reserved publishes the reserved event for the citizen" do
          ful = fulfillment
          payload = capture_publish { @notifier.reward_reserved(ful) }

          assert_equal "decidim.events.bih.goodwill.reward_reserved", payload[:event]
          assert_equal Decidim::Bih::Goodwill::RewardReservedEvent, payload[:event_class]
          assert_equal ful.user, payload[:resource]
          assert_equal [ful.user], payload[:affected_users]
          assert payload[:force_send]
          assert_equal I18n.t("decidim.bih.goodwill.rewards.majica"), payload[:extra][:reward_name]
          assert payload[:extra].has_key?(:fulfillment)
        end

        test "reward_fulfilled publishes the fulfilled event for the citizen" do
          ful = fulfillment
          payload = capture_publish { @notifier.reward_fulfilled(ful) }

          assert_equal "decidim.events.bih.goodwill.reward_fulfilled", payload[:event]
          assert_equal Decidim::Bih::Goodwill::RewardFulfilledEvent, payload[:event_class]
          assert_equal ful.user, payload[:resource]
          assert_equal [ful.user], payload[:affected_users]
          assert payload[:force_send]
          assert_equal I18n.t("decidim.bih.goodwill.rewards.majica"), payload[:extra][:reward_name]
        end

        test "reward_canceled publishes the canceled event with the refunded cost" do
          ful = fulfillment
          payload = capture_publish { @notifier.reward_canceled(ful) }

          assert_equal "decidim.events.bih.goodwill.reward_canceled", payload[:event]
          assert_equal Decidim::Bih::Goodwill::RewardCanceledEvent, payload[:event_class]
          assert_equal ful.user, payload[:resource]
          assert_equal [ful.user], payload[:affected_users]
          assert_equal ful.cost, payload[:extra][:refunded]
        end

        test "match_request_decided publishes the decided event to the owner" do
          req = match_request
          payload = capture_publish { @notifier.match_request_decided(req, "approved") }

          assert_equal "decidim.events.bih.goodwill.match_request_decided", payload[:event]
          assert_equal Decidim::Bih::Goodwill::MatchRequestDecidedEvent, payload[:event_class]
          assert_equal req.owner, payload[:resource]
          assert_equal [req.owner], payload[:affected_users]
          assert_equal "approved", payload[:extra][:decision]
          assert_equal req.points, payload[:extra][:points]
        end

        test "match_request_decided is a no-op when the owner is not a user" do
          req = match_request
          req.stub(:owner, nil) do
            published = false
            Decidim::EventsManager.stub(:publish, ->(**) { published = true }) do
              assert_nil @notifier.match_request_decided(req, "approved")
            end
            assert_not published
          end
        end

        test "a publish failure is swallowed and logged, never raised (reward_fulfilled)" do
          ful = fulfillment
          assert_logs_error do
            Decidim::EventsManager.stub(:publish, ->(**) { raise StandardError, "boom" }) do
              assert_nil @notifier.reward_fulfilled(ful)
            end
          end
        end

        test "a publish failure is swallowed and logged, never raised (reward_reserved)" do
          ful = fulfillment
          assert_logs_error do
            Decidim::EventsManager.stub(:publish, ->(**) { raise StandardError, "boom" }) do
              assert_nil @notifier.reward_reserved(ful)
            end
          end
        end

        test "a publish failure is swallowed and logged, never raised (reward_canceled)" do
          ful = fulfillment
          assert_logs_error do
            Decidim::EventsManager.stub(:publish, ->(**) { raise StandardError, "boom" }) do
              assert_nil @notifier.reward_canceled(ful)
            end
          end
        end

        test "a publish failure is swallowed and logged, never raised (match_request_decided)" do
          req = match_request
          assert_logs_error do
            Decidim::EventsManager.stub(:publish, ->(**) { raise StandardError, "boom" }) do
              assert_nil @notifier.match_request_decided(req, "rejected")
            end
          end
        end

        private

        # Asserts the block logged at least one error mentioning the notifier.
        def assert_logs_error
          logged = []
          Rails.logger.stub(:error, ->(msg) { logged << msg }) do
            yield
          end
          assert(logged.any? { |m| m.to_s.include?("[Admin::Goodwill]") },
                 "expected a swallowed-notification error to be logged")
        end
      end
    end
  end
end
