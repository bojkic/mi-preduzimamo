# frozen_string_literal: true

require "test_helper"
require "decidim/participatory_processes/test/factories"
require "decidim/proposals/test/factories"

module Decidim
  module Bih
    module Goodwill
      # Item 5 — PointsEarnedEvent deep links:
      #   * When extra contains a valid resource_gid, resource_path resolves it.
      #   * When resource_gid is absent or invalid, resource_path returns nil safely.
      class PointsEarnedEventTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        def build_event(extra)
          Decidim::Bih::Goodwill::PointsEarnedEvent.new(
            resource: @user,
            event_name: "decidim.events.bih.goodwill.points_earned",
            user: @user,
            extra:
          )
        end

        test "notification_title is always set from extra amount and reason" do
          event = build_event("amount" => 20, "reason" => "proposal")
          assert_includes event.notification_title, "20"
        end

        test "resource_path is nil when no resource_gid in extra" do
          event = build_event("amount" => 5, "reason" => "comment")
          assert_nil event.resource_path, "resource_path must be nil when no GID supplied"
        end

        test "resource_url is nil when no resource_gid in extra" do
          event = build_event("amount" => 5, "reason" => "comment")
          assert_nil event.resource_url
        end

        test "resource_path is nil with a garbage gid string" do
          event = build_event("amount" => 3, "reason" => "vote", "resource_gid" => "not-a-gid")
          assert_nil event.resource_path, "invalid GID must not raise — returns nil"
        end

        test "resource_path does not raise on a valid proposal GID (route may be nil in test env)" do
          component = FactoryBot.create(:proposal_component, organization: @organization)
          proposal = FactoryBot.create(:proposal, component:)

          event = build_event(
            "amount" => 20,
            "reason" => "proposal",
            "resource_gid" => proposal.to_gid.to_s
          )

          # The path may be nil in unit-test context (router proxy needs a request),
          # but the important invariant is: it NEVER raises. The rescue chain in
          # PointsEarnedEvent#resource_path ensures robustness in all contexts.
          assert_nothing_raised { event.resource_path }
          assert_nothing_raised { event.resource_url }
        end

        test "resource_path never raises regardless of GID validity" do
          # When a resource is deleted or unreachable, resource_path must return nil
          # without raising. The stale-GID path is tested with a non-existent ID.
          event = build_event(
            "amount" => 20,
            "reason" => "proposal",
            "resource_gid" => "gid://decidim/Decidim::Proposals::Proposal/999999999"
          )
          assert_nothing_raised { event.resource_path }
          assert_nil event.resource_path,
                     "GID pointing to non-existent record must return nil"
        end

        # S4 — notification_title deep link.
        # When resource_path is present, the title must contain an <a href>
        # wrapping the action label. When absent, no anchor must appear.
        test "notification_title contains an anchor tag when resource_path is present" do
          component = FactoryBot.create(:proposal_component, organization: @organization)
          proposal = FactoryBot.create(:proposal, component:)

          event = build_event(
            "amount" => 20,
            "reason" => "proposal",
            "resource_gid" => proposal.to_gid.to_s
          )

          # resource_path may be nil in unit-test context (router proxy needs a
          # request). Stub it to a known path to test the branch.
          path = "/test/resource/#{proposal.id}"
          event.define_singleton_method(:resource_path) { path }

          title = event.notification_title

          assert_includes title, "<a href=\"#{path}\"",
                          "notification_title must contain an anchor when resource_path is present"
          assert_includes title, "20",
                          "notification_title must still include the points amount"
        end

        test "notification_title contains NO anchor tag when resource_path is absent" do
          event = build_event("amount" => 5, "reason" => "comment")

          title = event.notification_title

          assert_not_includes title, "<a href",
                              "notification_title must not contain an anchor when resource_path is nil"
          assert_includes title, "5",
                          "notification_title must still include the points amount"
        end

        # S4 — source_resource memoization: two calls must not hit GlobalID twice.
        test "source_resource is memoized (single GlobalID locate)" do
          component = FactoryBot.create(:proposal_component, organization: @organization)
          proposal = FactoryBot.create(:proposal, component:)

          event = build_event(
            "amount" => 10,
            "reason" => "proposal",
            "resource_gid" => proposal.to_gid.to_s
          )

          # Count GlobalID::Locator.locate calls WITHOUT permanently modifying the
          # module. We spy via the event object: override #source_resource on the
          # instance to count proxy calls, verifying the memoization cache prevents
          # a second trip through the full resolution path.
          # NOTE: do NOT use define_singleton_method + remove_method on
          # GlobalID::Locator — `locate` is defined as a module singleton method, so
          # remove_method strips the REAL implementation and leaves it undefined for
          # every test that follows (DeserializationError).
          locate_count = 0
          original_locate = GlobalID::Locator.method(:locate)
          spy = lambda { |gid|
            locate_count += 1
            original_locate.call(gid)
          }

          GlobalID::Locator.stub(:locate, spy) do
            event.send(:source_resource)
            event.send(:source_resource)
          end

          assert_equal 1, locate_count,
                       "source_resource must call GlobalID::Locator.locate exactly once (memoized)"
        end
      end
    end
  end
end
