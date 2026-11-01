# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    # Canonical topic permission is identical in compatibility and target modes.
    # The audience report still separates permission, reachability and geography.
    class CityServiceAlertCohortTest < ActiveSupport::TestCase
      CITY_KEY = "mi_city_service_alerts_viber"

      setup do
        @organization = create_organization
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk",
                                                name: { "sr" => "Pilot" }, slug: "pilot-#{SecureRandom.hex(4)}",
                                                zona: "grad")
        @elsewhere = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk",
                                                     name: { "sr" => "Drugdje" }, slug: "drugdje-#{SecureRandom.hex(4)}",
                                                     zona: "selo")
        @reachable = {}
      end

      def citizen(settings = {}, area: @area, reachable: true)
        user = FactoryBot.create(:user, :confirmed, organization: @organization, notification_settings: settings)
        Decidim::Bih::CitizenProfile.create!(organization: @organization, user:, komsiluk_id: area.id,
                                             source: "dropdown", assigned_at: Time.current)
        Decidim::Bih::TopicPreferences.set!(user, topic: "neighborhood_info", enabled: settings.fetch(CITY_KEY)) if settings.has_key?(CITY_KEY)
        @reachable[user.id] = reachable
        user
      end

      # Reachability is a fact about a proven phone, not a preference. Stubbed
      # so the cohort arithmetic is tested without minting authorizations.
      def audience(area_ids: [@area.id], **options)
        reachable = @reachable
        phone = lambda do |user:, organization:| # rubocop:disable Lint/UnusedBlockArgument
          reachable[user.id] ? "+38765000000" : nil
        end
        Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, phone) do
          CityServiceAlertPolicy.effective_audience(organization: @organization, area_ids:, **options)
        end
      end

      def activate_organization_default!(value = "allowed")
        Decidim::Bih::Messaging::OrganizationPolicy.create!(
          organization: @organization, policy_version: "pilot-#{SecureRandom.hex(4)}",
          defaults: { "city_service_alerts" => { "viber" => value } },
          effective_from: 1.day.ago, active: true
        )
      end

      test "default and explicit topic permission use the same reader" do
        citizen({})
        citizen({ CITY_KEY => true })
        citizen({ CITY_KEY => false })
        citizen({ "komsiluk_board" => false }) # obsolete JSON no longer overrides canonical settings

        counts = audience

        assert_equal 4, counts[:population]
        assert_equal 3, counts[:enqueue_candidates]
        assert_equal 3, counts[:permitted]
        assert_equal 2, counts[:missing_key]
        assert_equal 1, counts[:explicit_false]
      end

      test "missing canonical preference defaults on for both readers" do
        citizen({})
        counts = audience

        assert counts[:missing_key].positive?
        assert_equal counts[:enqueue_candidates], counts[:permitted]
      end

      test "organization channel defaults cannot override a canonical topic choice" do
        citizen({})
        citizen({})
        citizen({ CITY_KEY => false })
        activate_organization_default!("blocked")

        counts = audience

        assert_equal 2, counts.dig(:deliverable, :compatibility)
        assert_equal 2, counts.dig(:deliverable, :target)
        assert_operator counts.dig(:reason_codes, :target, :preference_blocked), :>=, 1
      end

      test "default on does not need an activated organization policy" do
        citizen({})
        citizen({})

        counts = audience

        assert_equal 2, counts.dig(:deliverable, :target)
        assert_equal counts.dig(:deliverable, :target), counts.dig(:deliverable, :compatibility)
      end

      test "permission is not reachability: an unreachable citizen is permitted and not deliverable" do
        citizen({ CITY_KEY => true }, reachable: false)

        counts = audience

        assert_equal 1, counts[:permitted]
        assert_equal 0, counts.dig(:deliverable, :compatibility)
        assert_operator counts.dig(:reason_codes, :compatibility, :destination_unknown), :>=, 1
      end

      test "only members of the given areas are counted and the geographic gate is not re-evaluated here" do
        citizen({ CITY_KEY => true })
        citizen({ CITY_KEY => true }, area: @elsewhere)

        assert_equal 1, audience[:population]
        assert_equal 2, audience(area_ids: [@area.id, @elsewhere.id])[:population]
        assert_equal 0, audience(area_ids: [])[:population]
      end

      # Structural, not a substring scan: a count that happens to equal a user
      # id would make a substring assertion flaky in both directions. Every leaf
      # of this artifact is an Integer count or a reason Symbol, and that is
      # what makes it safe to log or export.
      test "the artifact is aggregate only and carries no identifier" do
        citizen({ CITY_KEY => true })
        citizen({}, reachable: false)

        counts = audience

        assert_equal [:deliverable, :enqueue_candidates, :explicit_false, :message_class, :missing_key, :per_event_scope, :permitted, :population, :producer_gate, :reason_codes],
                     counts.keys.sort
        assert_equal PilotAudience::CITY_ALERT_CLASS, counts[:message_class]
        assert(counts.values_at(:population, :enqueue_candidates, :permitted, :missing_key, :explicit_false).all?(Integer))
        assert(counts[:deliverable].values.all?(Integer))
        assert(counts[:reason_codes].values.flat_map(&:keys).all?(Symbol))
        assert(counts[:reason_codes].values.flat_map(&:values).all?(Integer))
      end
    end
  end
end
