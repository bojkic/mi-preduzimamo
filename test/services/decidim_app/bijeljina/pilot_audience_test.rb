# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    # Read-only estimates share canonical topic decisions across routing modes.
    class PilotAudienceTest < ActiveSupport::TestCase
      REPORT_VIBER_KEY = "mi_report_updates_viber"
      CITY_KEY = "mi_city_service_alerts_viber"

      setup do
        @organization = create_organization
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk",
                                                name: { "sr" => "Pilot" }, slug: "pilot-#{SecureRandom.hex(4)}")
        @reachable = {}
      end

      def citizen(settings = {}, reachable: true)
        user = FactoryBot.create(:user, :confirmed, organization: @organization, notification_settings: settings)
        Decidim::Bih::CitizenProfile.create!(organization: @organization, user:, komsiluk_id: @area.id,
                                             source: "dropdown", assigned_at: Time.current)
        { REPORT_VIBER_KEY => "report_updates", CITY_KEY => "neighborhood_info" }.each do |key, topic|
          Decidim::Bih::TopicPreferences.set!(user, topic:, enabled: settings.fetch(key)) if settings.has_key?(key)
        end
        @reachable[user.id] = reachable
        user
      end

      def report_by(author)
        Decidim::Bih::Report.create!(organization: @organization, author:,
                                     description: "Prijava #{SecureRandom.hex(3)}")
      end

      def with_phones(&)
        reachable = @reachable
        phone = lambda do |user:, organization:| # rubocop:disable Lint/UnusedBlockArgument
          reachable[user.id] ? "+12025550101" : nil
        end
        Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, phone, &)
      end

      def report_audience = with_phones { PilotAudience.report_author_external_copy(organization: @organization) }

      def city_audience = with_phones { PilotAudience.city_service_alert(organization: @organization, area_ids: [@area.id]) }

      def activate_organization_default!(topic)
        Decidim::Bih::Messaging::OrganizationPolicy.create!(
          organization: @organization, policy_version: "pilot-#{SecureRandom.hex(4)}",
          defaults: { topic.to_s => { "viber" => "allowed" } },
          effective_from: 1.day.ago, active: true
        )
      end

      test "the report producer applies no preference gate, so a blocked author is still enqueued" do
        report_by(citizen({ REPORT_VIBER_KEY => false }))

        counts = report_audience

        assert_equal :none, counts[:producer_gate]
        assert_equal 1, counts[:population]
        assert_equal 1, counts[:enqueue_candidates], "the producer enqueues and the delivery gate refuses; that is the skipped/ineligible row"
        assert_equal 0, counts[:permitted]
        assert_equal 0, counts.dig(:deliverable, :compatibility)
        assert_operator counts.dig(:reason_codes, :compatibility, :preference_blocked), :>=, 1
      end

      test "canonical topic choices apply equally in both routing modes" do
        report_by(citizen({ REPORT_VIBER_KEY => true }))
        activate_organization_default!(:report_updates)

        counts = report_audience

        assert_equal 1, counts.dig(:deliverable, :compatibility)
        assert_equal counts.dig(:deliverable, :compatibility), counts.dig(:deliverable, :target),
                     "an explicit choice is a decision somebody made; an organization default must never overwrite it"
      end

      test "default on makes the missing-key cohort equal in both routing modes" do
        citizen({})
        citizen({})
        activate_organization_default!(:city_service_alerts)

        counts = city_audience

        assert_equal 2, counts.dig(:deliverable, :compatibility)
        assert_equal 2, counts.dig(:deliverable, :target)
      end

      test "the recipient is the report's own author: an anonymous report contributes nobody" do
        Decidim::Bih::Report.create!(organization: @organization, description: "Anonimna prijava",
                                     reporter_email: "niko@example.test")

        counts = report_audience

        assert_equal :single_author, counts[:per_event_scope]
        assert_equal 0, counts[:population]
      end

      test "one author with several reports is counted once" do
        author = citizen({ REPORT_VIBER_KEY => true })
        3.times { report_by(author) }

        assert_equal 1, report_audience[:population]
      end

      test "a blocked or unconfirmed author is not a recipient" do
        blocked = citizen({ REPORT_VIBER_KEY => true })
        report_by(blocked)
        # Deliberately not Decidim's block workflow: this asserts the RECIPIENT
        # filter, not the moderation flow, and that flow also nils the name.
        blocked.update_columns(blocked: true) # rubocop:disable Rails/SkipsModelValidations

        assert_equal 0, report_audience[:population]
      end

      test "both candidates return the same shape so their cohorts can be compared" do
        report_by(citizen({ REPORT_VIBER_KEY => true, CITY_KEY => true }))

        assert_equal city_audience.keys.sort, report_audience.keys.sort
        assert_equal PilotAudience::REPORT_EXTERNAL_COPY_CLASS, report_audience[:message_class]
        assert_equal PilotAudience::CITY_ALERT_CLASS, city_audience[:message_class]
      end
    end
  end
end
