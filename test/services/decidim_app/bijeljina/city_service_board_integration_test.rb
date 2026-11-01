# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceBoardIntegrationTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-linked", name: { sr: "Povezana tabla" })
        @reader = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(@reader, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        @event = event("original")
        assert_equal :published, CityServiceEventPublisher.new(@event, actor: @admin).publish_board!.status
        @post = Decidim::Bih::KomsilukPost.find(@event.reload.komsiluk_post_id_values.sole)
      end

      test "official provenance and source links survive the bounded summary" do
        assert_equal "city_service", @post.origin
        assert_equal "Izmišljeni pružalac", @post.details.dig("source", "provider")
        assert_includes @post.details.dig("source", "urls"), @event.source_url
        assert_includes @post.details.dig("source", "event_ids"), @event.id
        assert_not_includes @post.body, @event.source_url
        assert_equal @event.publication_revision, @post.details.dig("source", "event_revision")
      end

      test "publication captures audience before workers and does not add later joiners" do
        identity = CityServiceIncidentIdentity.delivery_identity(@event)
        receipt = Decidim::Bih::PlatformDelivery.find_by!(user: @reader, identity:)
        assert_equal @post.id, receipt.komsiluk_post_id
        newcomer = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(newcomer, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        CityServiceBoardPublication.publish!(post: @post, identity:, expires_at: @event.ends_at,
                                             context: { event_id: @event.id, event_revision: @event.publication_revision })
        assert_not Decidim::Bih::PlatformDelivery.exists?(user: newcomer, identity:)
      end

      test "local hide cancels application work and survives a source correction on the same placement" do
        Decidim::Bih::Komsiluk::PostModeration.new(post: @post, actor: @admin, organization: @organization)
                                              .call(action: :hide, reason: "inaccurate", expected_version: @post.lock_version)
        assert_equal "hidden", @post.reload.status
        assert_equal true, @post.details.dig("moderation", "source_hold")
        assert Decidim::Bih::PlatformDelivery.where(komsiluk_post_id: @post.id).where.not(cancelled_at: nil).exists?
        assert_not CityServiceBoardVisibility.current_for_recipient?(event: @event, user_id: @reader.id)
        assert_equal :withdrawn, CityServicePublicationWithdrawal.call(event: @event, actor: @admin,
                                                                       review_token: @event.answer_review_token, note: "Ispravka sadržaja", correct: true)
        @event.reload.update!(summary: "Ispravljen servisni podatak")
        original_id = @post.id
        assert_no_difference "Decidim::Bih::KomsilukPost.count" do
          assert_equal :published, CityServiceEventPublisher.new(@event, actor: @admin).publish_board!.status
        end
        assert_equal original_id, @event.reload.komsiluk_post_id_values.sole
        assert_equal "hidden", @post.reload.status
      end

      test "one-source withdrawal preserves valid support and whole-notice withdrawal retires it" do
        supporting = event("support", incident: @event.incident)
        supporting.update!(starts_at: @event.starts_at, ends_at: @event.ends_at)
        assert_equal :published, CityServiceEventPublisher.new(supporting, actor: @admin).publish_board!.status
        assert_equal @post.id, supporting.reload.komsiluk_post_id_values.sole
        actions = CityServiceBoardActions.new(post: @post.reload, actor: @admin)
        assert_equal :withdrawn, actions.call(action: "withdraw_source", event_id: @event.id, token: actions.token, note: "Izvor povučen")
        assert_equal "open", @post.reload.status
        assert_equal "board_published", supporting.reload.state
        assert_equal :withdrawn, actions.call(action: "withdraw_all", event_id: nil, token: actions.token, note: "Obavještenje više ne važi")
        assert_equal "expired", @post.reload.status
        assert_equal "dismissed", supporting.reload.state
      end

      test "source action refuses a changed preview and an ordinary member" do
        actions = CityServiceBoardActions.new(post: @post, actor: @admin)
        token = actions.token
        @event.update!(summary: "Nova činjenica poslije pregleda")
        assert_equal :stale_review, actions.call(action: "withdraw_all", event_id: nil, token:, note: "Povlačenje")
        assert_equal "board_published", @event.reload.state
        citizen_actions = CityServiceBoardActions.new(post: @post, actor: @reader)
        assert_equal :not_authorized, citizen_actions.call(action: "withdraw_all", event_id: nil, token: citizen_actions.token, note: "Povlačenje")
      end

      test "missing author and forged source details alone do not establish source authority" do
        legacy = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @area, title: "Legacy",
                                                    body: "Legacy body", category: "general", details: { source: { event_ids: [@event.id] } })
        assert_not CityServiceBoardVisibility.linked?(legacy)
        assert_empty CityServiceBoardModeration.review_links(post: legacy, user: @admin, organization: @organization)
      end

      test "board-only broad water coverage cannot become an urgent phone audience" do
        @event.update!(source_key: "water_service", extraction_metadata: @event.extraction_metadata.merge(
          "coverage" => { "scope_precision" => "unspecified_street_segment" }
        ))
        CityServiceSources.stub(:alerts_enabled?, true) do
          assert_equal "phone_audience_unverified", CityServiceBoardVisibility.phone_blocker(post: @post, user: @reader)
        end
      end

      private

      def event(fingerprint, incident: nil)
        CityServiceEvent.create!(organization: @organization, incident:, source_key: "electricity_outages", source_label: "Izmišljeni pružalac",
                                 source_fingerprint: fingerprint, source_url: "https://example.test/#{fingerprint}",
                                 event_type: "planned_outage", severity: "service_outage", targeting_level: "komsiluk", affected_area_slugs: [@area.slug],
                                 affected_text: "Dio naselja", title: "Planirano isključenje", summary: "Najavljeni prekid", starts_at: 1.hour.from_now, ends_at: 4.hours.from_now,
                                 state: "pending_review", lifecycle: "scheduled", parser_version: "fixture", content_version: "version-1",
                                 extraction_metadata: { "source_snapshot_complete" => true, "complete" => true })
      end
    end
  end
end
