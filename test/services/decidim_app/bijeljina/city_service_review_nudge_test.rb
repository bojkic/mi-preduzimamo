# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    # Ten alerts expired in the queue before anyone opened it (23.09.2026):
    # water notices arrive at 08:15 for a cut that runs 08:00-14:30, and the
    # only signal was a count on a dashboard nobody was looking at.
    class CityServiceReviewNudgeTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        @nudge = CityServiceReviewNudge.new(organization: @organization)
      end

      test "an alert waiting for review that starts within a day rings the operators once" do
        event = alert(starts_at: 2.hours.from_now)
        published = []
        Decidim::EventsManager.stub(:publish, ->(**args) { published << args }) do
          assert_equal 1, @nudge.call(events: [event])
          assert_equal 0, @nudge.call(events: [event])
        end

        assert_equal([[@admin]], published.map { |args| args.fetch(:affected_users) })
        assert_equal CityServiceReviewNudgeEvent, published.first.fetch(:event_class)
        assert_equal 1, published.first.dig(:extra, :count)
      end

      test "an alert already running still rings, because it can still be published" do
        assert_equal 1, count_published([alert(starts_at: 30.minutes.ago)])
      end

      test "far-future, finished and published alerts do not ring" do
        far = alert(starts_at: 3.days.from_now)
        over = alert(starts_at: 5.hours.ago, ends_at: 1.hour.ago)
        done = alert(starts_at: 1.hour.from_now, state: "board_published")

        assert_equal 0, count_published([far, over, done])
      end

      test "a changed version of the same alert rings again" do
        event = alert(starts_at: 1.hour.from_now)
        assert_equal 1, count_published([event])
        event.update!(content_version: "v2")
        assert_equal 1, count_published([event])
      end

      test "several alerts from one scrape ring once per operator" do
        events = [alert(starts_at: 1.hour.from_now), alert(starts_at: 2.hours.from_now)]
        published = []
        Decidim::EventsManager.stub(:publish, ->(**args) { published << args }) { @nudge.call(events:) }

        assert_equal 1, published.size
        assert_equal 2, published.first.dig(:extra, :count)
      end

      # city_alerts_manage is admin-only (OperatorRole::ADMIN_ONLY_PERMISSIONS).
      test "every admin rings, and nobody else" do
        second = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        FactoryBot.create(:user, :admin, :confirmed, organization: @organization, deleted_at: Time.current)
        FactoryBot.create(:user, :admin, :confirmed, organization: create_organization)
        published = []
        Decidim::EventsManager.stub(:publish, ->(**args) { published << args }) { @nudge.call(events: [alert(starts_at: 1.hour.from_now)]) }

        assert_equal [@admin, second].map(&:id).sort, published.flat_map { |args| args.fetch(:affected_users) }.map(&:id).sort
      end

      test "a notification failure never breaks the scrape" do
        Decidim::EventsManager.stub(:publish, ->(**) { raise "bell down" }) do
          assert_equal 0, @nudge.call(events: [alert(starts_at: 1.hour.from_now)])
        end
      end

      test "the bell names the queue and links to it" do
        event = CityServiceReviewNudgeEvent.new(resource: @admin, event_name: "decidim_app.city_service_review_nudge",
                                                user: @admin, extra: { "count" => 2, "title" => "Planirano isključenje struje: Batković" })
        I18n.with_locale(:sr) do
          assert_includes event.notification_title, "2"
          assert_includes event.notification_title, "Batković"
        end
        assert_includes event.resource_path, "tab=review"
      end

      test "each admin also gets one phone alert per alert version" do
        event = alert(starts_at: 1.hour.from_now)
        sent = []
        Decidim::Bih::AccountNotifications.stub(:enqueue!, ->(**args) { sent << args }) do
          Decidim::EventsManager.stub(:publish, ->(**) {}) { @nudge.call(events: [event]) }
        end
        assert_equal([[@admin.id, %w(viber)]], sent.map { |args| [args.fetch(:user).id, args.fetch(:channels)] })
        assert_includes sent.first.fetch(:text), event.title
        assert_includes sent.first.fetch(:text), "sat vremena"
      end

      private

      def count_published(events)
        published = []
        Decidim::EventsManager.stub(:publish, ->(**args) { published << args }) { @nudge.call(events:) }
        published.sum { |args| args.fetch(:affected_users).size }
      end

      def alert(starts_at:, ends_at: starts_at + 6.hours, state: "pending_review")
        @sequence = @sequence.to_i + 1
        CityServiceEvent.create!(organization: @organization, source_key: "water_service", source_label: "Vodovod", source_fingerprint: "nudge-#{@sequence}",
                                 source_url: "https://example.org/voda", event_type: "unplanned_interruption", severity: "service_outage",
                                 targeting_level: "unknown", affected_area_slugs: [], affected_text: "Batković", title: "Prekid vode #{@sequence}",
                                 summary: "Prekid vode", starts_at:, ends_at:, fetched_at: Time.current, state:, lifecycle: "scheduled",
                                 parser_version: "fixture", content_version: "v1", extraction_metadata: {})
      end
    end
  end
end
