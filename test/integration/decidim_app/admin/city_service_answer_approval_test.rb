# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require "capybara"

module DecidimApp
  module Admin
    class CityServiceAnswerApprovalTest < ActionDispatch::IntegrationTest
      include SyntheticEventSourceRegistry
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      NOW = Time.iso8601("2040-09-09T07:00:00+02:00")

      setup do
        travel_to NOW
        @organization = create_organization
        host! @organization.host
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-synthetic-field", name: { "sr" => "Izmišljeno polje" })
        @ingestor = Bijeljina::CityServiceEventIngestor.new(organization: @organization)
        @event = ingest.events.sole
      end

      teardown { travel_back }

      test "answer approval exposes only reviewed scoped facts without board posts jobs or publisher calls" do
        sign_in @admin
        get "/admin/bih/city-alerts", params: { tab: "review" }
        before_posts = Decidim::Bih::KomsilukPost.count
        before_audits = Decidim::Bih::OperatorAuditEvent.count
        Bijeljina::CityServiceNoticePublisher.stub(:new, ->(*) { flunk "Answer approval invoked outbound publication" }) do
          assert_no_enqueued_jobs { approve }
        end

        assert_redirected_to "/admin/bih/city-alerts?tab=review"
        assert @event.reload.answer_approved?
        assert_equal @event.content_version, @event.reviewed_content_version
        assert_equal @admin.id, @event.reviewed_by_id
        assert_nil @event.published_at
        assert_empty @event.komsiluk_post_id_values
        assert_equal before_posts, Decidim::Bih::KomsilukPost.count
        assert_equal before_audits + 1, Decidim::Bih::OperatorAuditEvent.count
        assert_equal [@event.id], query.events.map(&:id)
        assert_empty query(slugs: ["mz-another-area"]).events
        assert_empty query(organization: create_organization).events
        assert_empty query(starts_at: NOW + 2.days, ends_at: NOW + 3.days).events

        contracts = Decidim::Bih::Concierge::Dialogue
        context = contracts::Contracts::TrustedContext.new(
          organization_id: @organization.id, conversation_key: "a" * 64, actor_id: nil,
          account_state: "anonymous", capabilities: ["public_reads"], now: NOW, deadline: contracts::TurnBudget.new(timeout: 5)
        )
        result = Bijeljina::Milica::ReadPort.new(organization: @organization).call(
          action: "ask_information", topic: "electricity", entities: { "area_query" => "Izmišljeno polje", "time_expression" => "danas" }, context:
        )
        assert_equal "ok", result.status
        assert_equal(["service_event:#{@event.id}"], result.facts.map { |fact| fact.fetch("id") })
      end

      test "anonymous and ordinary citizens cannot approve and foreign tenant events stay inaccessible" do
        approve
        assert_response :redirect
        assert @event.reload.pending_review?
        citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        sign_in citizen
        approve
        assert_response :redirect
        assert @event.reload.pending_review?
        sign_out citizen
        sign_in @admin
        foreign = create_organization
        @event.update!(organization: foreign)
        approve
        assert_response :not_found
        assert @event.reload.pending_review?
      end

      test "stale version and concurrent local fact edits cannot be approved from an old form" do
        sign_in @admin
        approve(content_version: "earlier-source-version")
        assert @event.reload.pending_review?
        old_token = @event.answer_review_token
        @event.update!(summary: "Operator corrected the affected notice.")
        approve(review_token: old_token)
        assert @event.reload.pending_review?
        assert_nil @event.reviewed_at
        assert_equal [@event.id], query.events.map(&:id)
        assert_not @event.facts_confirmed?
      end

      test "partial evidence unknown geography and unversioned legacy records require resolution before approval" do
        sign_in @admin
        @event.update!(extraction_metadata: @event.extraction_metadata.merge("source_snapshot_complete" => false))
        approve
        assert @event.reload.pending_review?
        @event.update!(extraction_metadata: {}, content_version: nil)
        approve
        assert @event.reload.pending_review?
        @event.update!(content_version: "version-restored", extraction_metadata: { "complete" => true }, targeting_level: "unknown", affected_area_slugs: [])
        approve
        assert @event.reload.pending_review?
        assert_nil @event.reviewed_at
        assert_equal [@event.id], query.events.map(&:id)
        assert_not @event.facts_confirmed?
      end

      test "unchanged approved source stays approved while a complete source correction requires new review" do
        sign_in @admin
        approve
        reviewed_version = @event.reload.reviewed_content_version
        assert_equal @event.id, ingest.events.sole.id
        assert @event.reload.answer_approved?
        replacement = ingest(to: "15:00").events.sole
        assert @event.reload.superseded?
        assert_equal reviewed_version, @event.reviewed_content_version
        assert replacement.pending_review?
        assert_nil replacement.reviewed_content_version
        assert_equal [replacement.id], query.events.map(&:id)
        assert_not replacement.facts_confirmed?
        assert_empty @event.komsiluk_post_id_values
      end

      test "a canonical article date correction withdraws answer approval without inventing a paired occurrence" do
        sign_in @admin
        source = Bijeljina::CityServiceSources.fetch("water_service")
        url = "https://water.example.invalid/v2/notices/approval-revision/"
        original = Bijeljina::CityServiceArticle.extract(
          html: "<article><p>09.09.2040. od 08:00 do 14:00 prekid vodosnabdijevanja u Izmišljenom polju zbog radova.</p></article>", source_url: url
        ).sole
        @event = @ingestor.ingest_article(source:, article: original, fetched_at: NOW).events.sole
        approve
        assert @event.reload.answer_approved?
        revised = Bijeljina::CityServiceArticle.extract(html: original.html.sub("09.09.2040", "10.09.2040"), source_url: url).sole
        replacement = @ingestor.ingest_article(source:, article: revised, fetched_at: NOW).events.sole
        assert @event.reload.superseded?
        assert_nil @event.superseded_by_id
        assert replacement.pending_review?
        assert_nil replacement.reviewed_content_version
        assert_empty Bijeljina::CityServiceEvent.citizen_visible.where(id: [@event.id, replacement.id])
      end

      test "approved answers can later be published to the board by a separate action" do
        sign_in @admin
        komsiluk = Decidim::Bih::LocalArea.create!(
          organization: @organization, kind: "komsiluk", slug: "komsiluk-synthetic-field", name: { "sr" => "Izmišljeno polje 1" },
          parent: @area, primary_mz_slug: @area.slug, overlapping_mz_slugs: [@area.slug]
        )
        approve
        post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: @event.reload.answer_review_token }
        assert @event.reload.board_published?
        assert_equal 1, @event.komsiluk_post_id_values.size
        assert_equal [komsiluk.slug], @event.target_komsiluk_slugs
        assert_equal [@area.slug], @event.affected_area_slugs
      end

      test "a failed later board action preserves the existing answer approval and review receipt" do
        sign_in @admin
        approve
        receipt = @event.reload.attributes.slice("reviewed_at", "reviewed_by_id", "reviewed_content_version")
        # This tenant has an MZ but no target komsiluk for board publication.
        post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: @event.reload.answer_review_token }
        assert @event.reload.answer_approved?
        assert_equal receipt, @event.attributes.slice(*receipt.keys)
        assert_empty @event.komsiluk_post_id_values
        assert_equal [@event.id], query.events.map(&:id)
      end

      test "revoking review retains unconfirmed source facts and preserves prior review audit without fanout" do
        sign_in @admin
        approve
        @event.reload
        approved_version = @event.reviewed_content_version
        assert_no_enqueued_jobs do
          assert_no_difference "Decidim::Bih::KomsilukPost.count" do
            post "/admin/bih/city-alerts/#{@event.id}/revoke-answers",
                 params: { content_version: @event.content_version, review_token: @event.answer_review_token }
          end
        end
        assert_redirected_to "/admin/bih/city-alerts?tab=review"
        assert @event.reload.pending_review?
        assert_nil @event.reviewed_by_id
        assert_nil @event.reviewed_at
        assert_nil @event.reviewed_content_version
        assert_equal [@event.id], query.events.map(&:id)
        assert_not @event.facts_confirmed?
        audit = Decidim::Bih::OperatorAuditEvent.where(event_type: "city_service_event_answers_revoked", resource_id: @event.id).sole
        assert_equal approved_version, audit.metadata.dig("previous_review", "reviewed_content_version")
        assert_equal @admin.id, audit.metadata.dig("previous_review", "reviewed_by_id")
      end

      test "a stale revoke form cannot change an event since published to a board" do
        sign_in @admin
        approve
        @event.reload
        params = { content_version: @event.content_version, review_token: @event.answer_review_token }
        @event.update!(state: "board_published")
        post "/admin/bih/city-alerts/#{@event.id}/revoke-answers", params: params
        assert_redirected_to "/admin/bih/city-alerts?tab=history"
        assert @event.reload.board_published?
        assert_equal @event.content_version, @event.reviewed_content_version
      end

      test "review UI explains automatic source access and history keeps separate board publication" do
        sign_in @admin
        get "/admin/bih/city-alerts"
        assert_response :success
        assert_select "form[action='#{approval_path}']", count: 0
        assert_select "#milica-source-access-help"
        assert_select "form#city-service-bulk-review"
        Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-ready", name: { "sr" => "Spremno" }, parent: @area)
        approve
        get "/admin/bih/city-alerts", params: { tab: "review" }
        assert_select "#city-service-event-#{@event.id}[data-city-service-event-state='ready']"
        assert_select "#city-alert-editor-#{@event.id}[hidden]" do
          assert_select "form[action$='/publish-board']"
          assert_select "form[action$='/revoke-answers']", count: 1
          assert_select "form[action$='/publish-viber']", count: 0
        end
      end

      private

      def approval_path
        "/admin/bih/city-alerts/#{@event.id}/approve-answers"
      end

      def approve(**overrides)
        post approval_path, params: { content_version: @event.content_version, review_token: @event.answer_review_token }.merge(overrides)
      end

      def query(organization: @organization, slugs: [@area.slug], starts_at: NOW, ends_at: NOW + 1.day)
        Bijeljina::CityServiceEventFeed.new(organization:).query(topic: "electricity", area_identifiers: slugs, starts_at:, ends_at:, deadline: nil)
      end

      def ingest(to: "14:00")
        html = <<~HTML
          <p>09-09-2040</p><table>
          <tr><th>TJ</th><th>Objekat</th><th>Područje</th><th>Razlog</th><th>Početak</th><th>Završetak</th></tr>
          <tr><td>TESTNA JEDINICA</td><td>TESTNI OBJEKAT A</td><td>Izmišljeno polje</td><td>Radovi</td><td>08:00</td><td>#{to}</td></tr>
          </table>
        HTML
        @ingestor.ingest(source_key: "electricity_outages", html:, fetched_at: NOW)
      end
    end
  end
end
