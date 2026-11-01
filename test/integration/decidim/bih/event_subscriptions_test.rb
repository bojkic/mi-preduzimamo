# frozen_string_literal: true

require "test_helper"
require "decidim/participatory_processes/test/factories"
require "decidim/proposals/test/factories"

module Decidim
  module Bih
    module Goodwill
      # Pins the AS-notification -> GoodwillAwardJob contracts so a Decidim
      # upgrade that renames an event (silent award loss) fails loudly here.
      class EventSubscriptionsTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "all subscribed topics have a registered listener" do
          EventSubscriptions::EVENT_NAMES.each_value do |topic|
            assert ActiveSupport::Notifications.notifier.listening?(topic),
                   "nothing is subscribed to #{topic} — award seam is dark"
          end
        end

        test "resource_liked enqueues a goodwill award for the liker" do
          assert_enqueued_with(job: GoodwillAwardJob) do
            ActiveSupport::Notifications.publish(
              EventSubscriptions::EVENT_NAMES[:like], extra: { liker_id: @user.id }
            )
          end
        end

        test "proposal_published enqueues a goodwill award for the author" do
          component = FactoryBot.create(:proposal_component, organization: @organization)
          proposal = FactoryBot.create(:proposal, component:)

          assert_enqueued_with(job: GoodwillAwardJob) do
            ActiveSupport::Notifications.publish(
              EventSubscriptions::EVENT_NAMES[:proposal], resource: proposal, extra: {}
            )
          end
        end
      end
    end
  end
end
