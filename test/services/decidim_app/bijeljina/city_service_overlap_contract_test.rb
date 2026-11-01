# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceOverlapContractTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      include ActiveJob::TestHelper
      include ActiveSupport::Testing::TimeHelpers

      test "publishing an MZ notice preserves partial evidence through overlap queries without crossing tenants or granting board access" do
        travel_to Time.utc(2026, 9, 9, 5) do
          organization = create_organization
          other_organization = create_organization
          admin = FactoryBot.create(:user, :admin, :confirmed, organization:)
          mz = area(organization, "mz", "mz-authored-field")
          other_mz = area(organization, "mz", "mz-other")
          overlap = area(organization, "komsiluk", "komsiluk-overlap", parent: other_mz,
                                                                       primary_mz_slug: other_mz.slug, overlapping_mz_slugs: [mz.slug])
          area(other_organization, "komsiluk", overlap.slug)
          coverage = {
            "status" => "partial",
            "affected_places" => [{ "slug" => mz.slug, "kind" => "mz", "relation" => "part" }],
            "notification_candidates" => [{ "slug" => overlap.slug, "relation" => "possible_overlap" }]
          }
          event = event(organization, "reviewed-partial", affected_area_slugs: [mz.slug], extraction_metadata: { "coverage" => coverage })
          foreign = event(other_organization, "foreign", affected_area_slugs: [overlap.slug], state: "published", title: "FOREIGN TENANT NOTICE")
          25.times do |index|
            event(organization, "unrelated-#{index}", affected_area_slugs: ["mz-unrelated-#{index}"], state: "published", starts_at: Time.current + index.minutes)
          end

          publication = CityServiceEventPublisher.new(event, actor: admin).publish_board!
          assert_equal :published, publication.status
          assert_equal [mz.slug], event.reload.area_slugs
          assert_equal [overlap.slug], event.target_komsiluk_slugs
          assert_equal [organization.id], Decidim::Bih::KomsilukPost.where(id: publication.post_ids).pluck(:decidim_organization_id).uniq

          context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: organization.id, conversation_key: "f" * 64, now: Time.current, capabilities: ["public_reads"]
          )
          port = Milica::ReadPort.new(organization:)
          result = port.call(action: "ask_information", topic: "electricity", entities: { "area_slug" => overlap.slug }, context:, locale: "bs")
          assert_equal "ok", result.status
          assert_equal(["service_event:#{event.id}"], result.facts.map { |fact| fact.fetch("id") })
          fact = result.facts.sole
          assert_equal [mz.slug], fact.dig("coverage", "area_slugs")
          assert_equal "possible_overlap", fact.dig("coverage", "requested_relation")
          assert_equal "part", fact.dig("coverage", "affected_relations", 0, "relation")
          assert_includes fact.fetch("warning_codes"), "possible_geographic_overlap"
          assert_includes fact.fetch("text"), "uticaj na vašu ulicu nije potvrđen"
          assert_not_includes result.facts.to_json, foreign.title
          assert_equal ["public_reads"], context.capabilities

          denied = port.call(action: "ask_information", topic: "electricity", entities: { "area_slug" => overlap.slug },
                             context: context.with(capabilities: []), locale: "bs")
          assert_equal "not_authorized", denied.status
          assert_empty denied.facts
        end
      end

      private

      def area(organization, kind, slug, **attributes)
        Decidim::Bih::LocalArea.create!(organization:, kind:, slug:, name: { "sr" => slug }, **attributes)
      end

      def event(organization, fingerprint, **attributes)
        CityServiceEvent.create!({
          organization:, source_key: "electricity_outages", source_label: "Elektro Bijeljina",
          source_fingerprint: fingerprint, source_url: CityServiceSources.fetch("electricity_outages").fetch(:source_url),
          event_type: "planned_outage", severity: "service_outage", targeting_level: "mz",
          title: "Planirano isključenje", summary: "Dio Dvorova, jedan NN izlaz.",
          starts_at: 2.hours.from_now, ends_at: 7.hours.from_now, fetched_at: Time.current,
          state: "pending_review", lifecycle: "scheduled", parser_version: "fixture", content_version: "revision-1"
        }.merge(attributes))
      end
    end
  end
end
