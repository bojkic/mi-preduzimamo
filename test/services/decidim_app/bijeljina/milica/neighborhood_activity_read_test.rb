# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class NeighborhoodActivityReadTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @now = Time.utc(2026, 9, 12, 12, 0)
        end

        test "no selectable area asks for the place rather than reporting the catalog unavailable" do
          result = reader.call(areas: [], context: context, starts_at: @now, ends_at: @now + 7.days, explicit_time: false, locale: "sr")

          assert_equal "ambiguous", result.status
          assert_equal ["activity_area_required"], result.warnings
          assert_empty result.facts
          assert_empty result.warnings.grep(/time|date|day/)
        end

        test "a komsiluk with nothing scheduled is empty" do
          boundary = { "type" => "Polygon", "coordinates" => [[[19.21, 44.76], [19.22, 44.76], [19.22, 44.77], [19.21, 44.77], [19.21, 44.76]]] }
          area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-dvorovi", name: { "sr" => "Dvorovi" }, boundary:)

          result = reader.call(areas: [area], context: context, starts_at: @now, ends_at: @now + 7.days, explicit_time: false, locale: "sr")

          assert_equal "empty", result.status
          assert_includes result.warnings, "no_matching_public_activity"
          assert_equal "komsiluk-dvorovi", result.coverage.fetch("area_slug")
        end

        test "another organization's area is never read" do
          other = create_organization
          area = Decidim::Bih::LocalArea.create!(organization: other, kind: "komsiluk", slug: "komsiluk-tudji", name: { "sr" => "Tuđi" }, boundary: {})

          result = reader.call(areas: [area], context: context, starts_at: @now, ends_at: @now + 7.days, explicit_time: false, locale: "sr")

          assert_equal "ambiguous", result.status
          assert_empty result.facts
        end

        test "an opportunity without a komsiluk answers the komsiluk question labelled for the whole city" do
          area = komsiluk
          opportunity(title: "Gradska akcija")

          result = volunteers(area)

          assert_equal "ok", result.status
          fact = result.facts.sole
          assert_equal "citywide", fact.dig("coverage", "geographic_scope")
          assert_equal "covers_city", fact.dig("coverage", "relation")
          assert_empty fact.dig("coverage", "area_slugs")
          assert_equal "Gradska akcija\n#{citywide_label}", fact["text"]
          assert_not_includes result.warnings, "no_matching_public_activity"
        end

        test "a local opportunity keeps its komsiluk and is answered before the city-wide one" do
          area = komsiluk
          opportunity(title: "Gradska akcija", starts_at: @now + 1.hour, ends_at: @now + 2.hours)
          opportunity(title: "Komsijska akcija", komsiluk: area, starts_at: @now + 2.days, ends_at: @now + 2.days + 1.hour)

          facts = volunteers(area).facts

          assert_equal(["Komsijska akcija", "Gradska akcija\n#{citywide_label}"], facts.map { |fact| fact["text"] })
          assert_equal ["komsiluk-dvorovi"], facts.first.dig("coverage", "area_slugs")
          assert_equal "komsiluk", facts.first.dig("coverage", "geographic_scope")
          assert_equal "located_in", facts.first.dig("coverage", "relation")
          assert_not_includes facts.first["text"], citywide_label
        end

        test "a cancelled hidden unreviewed or closed city-wide opportunity is still excluded" do
          area = komsiluk
          opportunity(title: "Otkazana", cancelled_at: @now)
          opportunity(title: "Skrivena", active: false)
          opportunity(title: "Na cekanju", active: false, review_status: "pending")
          opportunity(title: "Zatvorene prijave", signup_deadline_at: @now - 1.minute)
          opportunity(title: "Tudja", organization: create_organization)

          result = volunteers(area)

          assert_equal "empty", result.status
          assert_empty result.facts
          assert_includes result.warnings, "no_matching_public_activity"
        end

        private

        def komsiluk
          boundary = { "type" => "Polygon", "coordinates" => [[[19.21, 44.76], [19.22, 44.76], [19.22, 44.77], [19.21, 44.77], [19.21, 44.76]]] }
          Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-dvorovi", name: { "sr" => "Dvorovi" }, boundary:)
        end

        def opportunity(**attributes)
          Decidim::Bih::VolunteerOpportunity.create!(organization: @organization, active: true, review_status: "approved",
                                                     starts_at: @now + 1.day, ends_at: @now + 1.day + 1.hour, **attributes)
        end

        def volunteers(area)
          reader.call(areas: [area], context: context, starts_at: @now, ends_at: @now + 7.days, explicit_time: false, locale: "sr",
                      family_keys: ["volunteers"])
        end

        def citywide_label
          I18n.t("decidim_app.milica.activity.citywide", locale: "sr")
        end

        def reader
          NeighborhoodActivityRead.new(organization: @organization)
        end

        def context
          Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: "a" * 64, actor_id: nil, account_state: "anonymous",
            capabilities: ["public_reads"], now: @now, deadline: nil
          )
        end
      end
    end
  end
end
