# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require "capybara"

module DecidimApp
  module Admin
    class CityServiceEventsControllerTest < ActionDispatch::IntegrationTest
      include SyntheticEventSourceRegistry
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        @recipient = FactoryBot.create(
          :user,
          :confirmed,
          organization: @organization,
          email: "private-city-recipient@example.org"
        )
        @opted_out = FactoryBot.create(:user, :confirmed, organization: @organization)
        @mz = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-synthetic-field",
          name: { "sr" => "Izmišljeno polje" }
        )
        @komsiluk = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-synthetic-field",
          name: { "sr" => "Izmišljeno polje 1" },
          parent: @mz,
          primary_mz_slug: "mz-synthetic-field",
          overlapping_mz_slugs: ["mz-synthetic-field"]
        )
        Decidim::Bih::CitizenProfile.for_user(@recipient, organization: @organization).assign_komsiluk!(
          @komsiluk,
          source: "dropdown",
          resolved_mz: @mz
        )
        Decidim::Bih::CitizenProfile.for_user(@opted_out, organization: @organization).assign_komsiluk!(
          @komsiluk,
          source: "dropdown",
          resolved_mz: @mz
        )
        Decidim::Bih::TopicPreferences.set!(@opted_out, topic: :neighborhood_info, enabled: false)
        @event = create_event
      end

      # The operator reported "grupni pregled ne radi". The submitted params
      # carried review_note and selections but no bulk_action, so the service
      # refused every batch as :invalid_selection. The buttons that name the
      # action must be inside the form that carries the selections.
      test "the bulk review form submits which action was chosen" do
        event = create_event(source_fingerprint: "fingerprint-bulk-markup")
        sign_in @admin

        get decidim_app_admin_city_service_events_path(tab: "review")

        assert_response :success
        form_id = "city-service-bulk-review"
        assert_match(/<form[^>]+id="#{form_id}"/, response.body, "the bulk form must carry the id the selections reference")
        assert_match(/<input[^>]+name="selections\[#{event.id}\]\[content_version\]"[^>]+form="#{form_id}"/, response.body)
        assert_match(/<button[^>]+name="bulk_action"[^>]+value="review"/, response.body)
        assert_match(/<button[^>]+name="bulk_action"[^>]+value="dismiss"/, response.body)
      end

      # The action must survive a submit that carries no submitter, which is
      # what Decidim's confirm dialog produces (confirm.js calls
      # form.requestSubmit() with no argument).
      test "the bulk action travels in a field so a submitter-less submit still works" do
        create_event(source_fingerprint: "fingerprint-bulk-field")
        sign_in @admin

        get decidim_app_admin_city_service_events_path(tab: "review")

        assert_response :success
        assert_match(/<input[^>]+type="hidden"[^>]+name="bulk_action"/, response.body)
      end

      test "acting on one alert returns the operator to the review queue" do
        event = create_event(source_fingerprint: "fingerprint-queue-return")
        sign_in @admin

        post decidim_app_admin_city_service_event_dismiss_path(event),
             params: { review_note: "Nije za objavu." }

        assert_redirected_to decidim_app_admin_city_service_events_path(tab: "review")
      end

      # Hiding the send option silently read as a missing feature.
      test "the review editor says why there is no send option when sending is not ready" do
        create_event(source_fingerprint: "fingerprint-send-blocked")
        sign_in @admin

        get decidim_app_admin_city_service_events_path(tab: "review")

        assert_response :success
        assert_select "[data-city-alert-send-blocked]"
      end

      # The panel is an operator tool, but the rare destructive action must not
      # sit at the same level as the routine one.
      test "withdrawal is disclosed, and the send control is not" do
        sign_in @admin
        # Publish through the real path: the workflow only calls an alert
        # withdrawable once it actually has a visible board post.
        post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: @event.answer_review_token }

        with_viber_ready do
          get decidim_app_admin_city_service_events_path(tab: "published")
        end

        assert_response :success
        assert_select "details[data-city-alert-withdraw]"
        assert_select "details[data-city-alert-withdraw] input[name=?]", "viber_review_confirmed", count: 0
      end

      test "the timezone is not printed on a window that is already local" do
        create_event(source_fingerprint: "fingerprint-panel-zone")
        sign_in @admin

        get decidim_app_admin_city_service_events_path(tab: "review")

        assert_response :success
        window = css_select("[data-city-alert-window]").first

        assert window, "the reviewed window is still shown"
        assert_no_match(%r{Europe/Sarajevo}, window.text,
                        "the zone belongs in the evidence block, not on every window")
      end

      test "a bulk review marks the selected events reviewed" do
        event = create_event(source_fingerprint: "fingerprint-bulk-apply")
        sign_in @admin

        post decidim_app_admin_city_service_events_bulk_review_path,
             params: {
               bulk_action: "review",
               review_note: "Pregledano grupno.",
               selections: { event.id.to_s => { selected: "1", content_version: event.content_version, review_token: event.answer_review_token } }
             }

        assert_redirected_to decidim_app_admin_city_service_events_path(tab: "review")
        assert_nil flash[:alert], "a valid batch must not be refused"
        assert event.reload.reviewed_at.present?
      end

      test "fallback preview rolls back edits and binds edited text and exact audience" do
        attributes = { content_version: @event.content_version, review_token: @event.answer_review_token, summary: "Reviewed text" }
        preview = DecidimApp::Bijeljina::CityServiceApprovalPreview.new(event: @event, actor: @admin, attributes:)
        result = preview.call
        assert_equal :ready, result.status
        assert_equal 1, result.recipients
        assert_not_equal "Reviewed text", @event.reload.summary
        assert_nil @event.reviewed_at
        assert preview.valid?(result.token)
        changed = DecidimApp::Bijeljina::CityServiceApprovalPreview.new(event: @event, actor: @admin, attributes: attributes.merge(summary: "Changed"))
        assert_not changed.valid?(result.token)
        Decidim::Bih::TopicPreferences.set!(@recipient, topic: :neighborhood_info, enabled: false)
        assert_not preview.valid?(result.token)
      end

      test "combined fallback requires an audience confirmation before publication" do
        sign_in @admin
        with_viber_ready do
          assert_no_difference("Decidim::Bih::KomsilukPost.count") do
            patch "/admin/bih/city-alerts/#{@event.id}", params: { review_action: "publish", viber_fallback: "1", city_service_event: {
              content_version: @event.content_version, review_token: @event.answer_review_token, title: @event.title, summary: @event.summary, viber_text: @event.viber_text
            } }
          end
          assert_response :success
          assert_select "input[name=fallback_token]"
          assert_select "input[type=hidden][name=fallback_confirmed][value='1']"
          assert_select "input[type=checkbox][name=fallback_confirmed]", count: 0
          assert_not_includes response.body, @recipient.email
          assert_nil @event.reload.reviewed_at
        end
      end

      test "geometry changes invalidate a pending review token" do
        token = @event.answer_review_token
        @komsiluk.update!(boundary: { type: "Polygon", coordinates: [[[19.1, 44.7], [19.2, 44.7], [19.2, 44.8], [19.1, 44.7]]] })
        assert_not_equal token, @event.reload.answer_review_token
        sign_in @admin
        patch "/admin/bih/city-alerts/#{@event.id}", params: { review_action: "publish", city_service_event: {
          content_version: @event.content_version, review_token: token
        } }
        assert_empty @event.reload.komsiluk_post_ids
        assert_equal I18n.t("decidim_app.admin.city_service_events.update.stale_review"), flash[:alert]
      end

      test "published fallback refuses to bypass the audience preview" do
        sign_in @admin
        post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: @event.answer_review_token }
        with_viber_ready do
          post "/admin/bih/city-alerts/#{@event.id}/publish-viber", params: { review_token: @event.reload.answer_review_token, viber_review_confirmed: "1" }
          assert_response :success
          assert_select "form[action$='/publish-viber']"
          assert_select "input[name=fallback_token]"
          assert @event.reload.board_published?
          assert_equal 0, @event.viber_jobs_count
          token = published_fallback_token
          Decidim::Bih::TopicPreferences.set!(@recipient, topic: :neighborhood_info, enabled: false)
          post "/admin/bih/city-alerts/#{@event.id}/publish-viber", params: {
            review_token: @event.reload.answer_review_token, viber_review_confirmed: "1", fallback_confirmed: "1", fallback_token: token
          }
          assert_response :success
          assert_select "input[type=hidden][name=fallback_confirmed][value='1']"
          assert @event.reload.board_published?
        end
      end

      test "published send opens one signed confirmation with exact eligible count and no checkbox" do
        sign_in @admin
        post decidim_app_admin_city_service_event_publish_board_path(@event), params: { review_token: @event.answer_review_token }

        with_viber_ready do
          get decidim_app_admin_city_service_event_notification_preview_path(@event)
          assert_response :success
          assert_select "input[name=fallback_token]", count: 1
          assert_select "input[type=hidden][name=fallback_confirmed][value='1']", count: 1
          assert_select "input[type=checkbox][name=fallback_confirmed]", count: 0
          assert_includes response.body, "Podobni primaoci: 1"
          assert_select ".city-approval-preview button[type=submit]:not([disabled])", count: 1
          assert_includes response.headers["Cache-Control"], "no-store"
        end
      end

      test "broad water board publication cannot become a phone audience" do
        sign_in @admin
        post decidim_app_admin_city_service_event_publish_board_path(@event), params: { review_token: @event.answer_review_token }
        assert @event.reload.board_published?

        with_viber_ready do
          old_token = published_fallback_token
          @event.update!(source_key: "water_service", extraction_metadata: @event.extraction_metadata.merge(
            "coverage" => { "scope" => "source_named_water_locations", "scope_precision" => "unspecified_street_segment" }
          ))

          get decidim_app_admin_city_service_event_notification_preview_path(@event)
          assert_redirected_to decidim_app_admin_city_service_events_path(tab: "done", anchor: "city-service-event-#{@event.id}")
          assert_includes flash[:alert], "ne potvrđuje koji su korisnici pogođeni"

          post decidim_app_admin_city_service_event_publish_viber_path(@event), params: {
            review_token: @event.answer_review_token, viber_review_confirmed: "1", fallback_confirmed: "1", fallback_token: old_token
          }
          assert_redirected_to decidim_app_admin_city_service_events_path(tab: "done", anchor: "city-service-event-#{@event.id}")
          assert_equal 0, @event.reload.viber_jobs_count
          assert @event.board_published?
        end
      end

      test "a completed send has no fresh send card and only failed deliveries offer retry" do
        publish_fixture(@event)
        @event.update!(state: "published", extraction_metadata: @event.extraction_metadata.merge("publication_revision" => "sent-revision"))
        sign_in @admin

        get decidim_app_admin_city_service_events_path(tab: "done")
        assert_select "#city-service-event-#{@event.id} a[href='#{decidim_app_admin_city_service_event_notification_preview_path(@event)}']", count: 0
        get decidim_app_admin_city_service_event_notification_preview_path(@event)
        assert_redirected_to decidim_app_admin_city_service_events_path(tab: "review")
        assert_equal I18n.t("decidim_app.admin.city_service_events.publish_viber.board_first_required", locale: :sr), flash[:alert]
      end

      test "phone audience excludes an unconfirmed area member before signing" do
        sign_in @admin
        post decidim_app_admin_city_service_event_publish_board_path(@event), params: { review_token: @event.answer_review_token }
        @recipient.update_column(:confirmed_at, nil)

        with_viber_ready do
          get decidim_app_admin_city_service_event_notification_preview_path(@event)
          assert_response :success
          assert_includes response.body, "Područni kandidati za obavještenje: 0"
          assert_includes response.body, "Podobni primaoci: 0"
          assert_select ".city-approval-preview button[type=submit][disabled]", count: 1
        end
      end

      test "map endpoint keeps destination boundaries separate from unknown extent" do
        sign_in @admin
        @komsiluk.update!(boundary: { type: "Polygon", coordinates: [[[19.1, 44.7], [19.2, 44.7], [19.2, 44.8], [19.1, 44.7]]] })
        get "/admin/bih/city-alerts/#{@event.id}/map"
        assert_response :success
        payload = response.parsed_body
        assert_equal true, payload.fetch("unknown_extent")
        assert_empty payload.fetch("footprint").fetch("features")
        assert_equal([@komsiluk.id], payload.fetch("features").map { |feature| feature.dig("properties", "id") })
        assert_equal @event.answer_review_token, payload.fetch("review_token")
        assert_includes response.headers["Cache-Control"], "no-store"
      end

      test "citizens cannot read the operator map" do
        sign_in @citizen
        get "/admin/bih/city-alerts/#{@event.id}/map"
        assert_response :redirect
      end

      test "admin sees city-service event review queue without private recipient data" do
        sign_in @admin

        get "/admin/bih/city-alerts"

        assert_response :success
        assert_includes response.body, "admin-city-service-events"
        assert_select "#admin-city-service-events[data-city-alert-active-tab='review']"
        assert_select "#admin-city-alert-workflow-nav a[href='/admin/bih/city-alerts?tab=review'][aria-current='page']"
        assert_select "#admin-city-alert-workflow-nav a[href='/admin/bih/city-alerts?tab=automatic']"
        assert_select "#admin-city-alert-workflow-nav a[href='/admin/bih/city-alerts?tab=done']"
        assert_select "#city-alert-settings[href='/admin/bih/city-alerts?tab=settings']"
        assert_select "#admin-city-alert-readiness", count: 0
        assert_includes response.body, "admin-city-alert-state-summary"
        assert_includes response.body, "admin-city-alert-filters"
        assert_select "table.mi-admin-editor-table"
        assert_select "form.mi-admin-record-editor .mi-admin-form__field", minimum: 4
        assert_select "td[data-label]", minimum: 5
        assert_select "#admin-city-alert-filters input[name='tab'][value='review']"
        assert_includes response.body, @event.title
        assert_includes response.body, "komsiluk-synthetic-field"
        assert_select '.city-alerts-col-areas [data-city-area-slug="komsiluk-synthetic-field"]', text: /Izmišljeno polje 1/
        assert_select ".city-alerts-detail-row[hidden]", count: 1
        assert_select ".city-alerts-detail-row td[colspan='6']", count: 1
        assert_includes response.body, I18n.t("decidim_app.admin.city_service_events.auto_check.audience_estimate", count: 1, locale: :sr)
        assert_not_includes response.body, "viber_review_confirmed"
        assert_includes response.body, I18n.t("decidim_app.admin.city_service_events.compact.platform_first")
        assert_includes response.body, I18n.t("decidim_app.admin.city_service_events.index.actions.dismiss_confirm")
        assert_not_includes response.body, "private-city-recipient@example.org"
        assert_not_includes response.body, "viber-recipient"
      end

      test "admin city-alert workflow tabs focus readiness and history" do
        published = create_event(source_fingerprint: "fingerprint-published", title: "Objavljeno upozorenje")
        published.update!(state: "published", published_at: Time.current)

        sign_in @admin

        get "/admin/bih/city-alerts", params: { tab: "readiness" }
        assert_response :success
        assert_select "#admin-city-service-events[data-city-alert-active-tab='settings']"
        assert_select "#admin-city-alert-readiness"
        assert_select "#admin-city-alert-filters", count: 0
        assert_includes response.body, "bin/city-service-notices-dry-run.sh electricity_outages"
        assert_includes response.body, "script/mi_viber_launch_readiness_smoke"
        assert_includes response.body, I18n.t("decidim_app.admin.city_service_events.index.readiness.operator_details")
        assert_not_includes response.body, @event.title

        get "/admin/bih/city-alerts", params: { tab: "history", state: "finished" }
        assert_response :success
        assert_select "#admin-city-service-events[data-city-alert-active-tab='done']"
        assert_includes response.body, published.title
        assert_select ".city-alerts-summary-row", text: /#{Regexp.escape(@event.title)}/, count: 0

        get "/admin/bih/city-alerts", params: { tab: "all", state: "pending_review" }
        assert_response :success
        assert_select "#admin-city-service-events[data-city-alert-active-tab='review']"
        assert_includes response.body, @event.title
        assert_select ".city-alerts-summary-row", text: /#{Regexp.escape(published.title)}/, count: 0
      end

      test "admin sees board-published alerts in the Viber workflow tab" do
        publish_fixture(@event)

        sign_in @admin

        get "/admin/bih/city-alerts", params: { tab: "viber" }

        assert_response :success
        assert_select "#admin-city-service-events[data-city-alert-active-tab='done']"
        assert_includes response.body, @event.title
        assert_select "#admin-city-alert-readiness", count: 0
        assert_not_includes response.body, "viber_review_confirmed"
        assert_select "a[href*='/notification-preview']"
      end

      test "non-admin is denied" do
        sign_in @citizen

        get "/admin/bih/city-alerts"

        assert_response :redirect
      end

      test "active BIH operator without city-alert permission is denied" do
        operator = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::OperatorRole.create!(
          organization: @organization,
          user: operator,
          created_by: @admin,
          role: "komsiluk_moderator",
          expires_at: 1.month.from_now
        )

        sign_in operator

        get "/admin/bih/city-alerts"

        assert_response :redirect
      end

      test "admin updates review text" do
        sign_in @admin

        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "city_service_event_reviewed").count }, 1 do
          patch "/admin/bih/city-alerts/#{@event.id}",
                params: {
                  city_service_event: {
                    review_token: @event.answer_review_token, content_version: @event.content_version,
                    title: "Prekid struje: Izmišljeno polje",
                    summary: "Novi sažetak za građane.",
                    viber_text: "Izmišljeno polje: struja 09-12.",
                    review_note: "Provjereno sa izvorom"
                  }
                }
        end

        assert_redirected_to "/admin/bih/city-alerts?tab=review"
        @event.reload
        assert_equal "Prekid struje: Izmišljeno polje", @event.title
        assert_equal "Novi sažetak za građane.", @event.summary
        assert_equal @admin, @event.reviewer
        assert_not_nil @event.reviewed_at
      end

      test "admin cannot edit a published event" do
        sign_in @admin
        @event.update!(state: "published", published_at: Time.current, summary: "Original")

        patch "/admin/bih/city-alerts/#{@event.id}",
              params: {
                city_service_event: {
                  summary: "Changed after publication"
                }
              }

        assert_redirected_to "/admin/bih/city-alerts?tab=history"
        assert_equal "Original", @event.reload.summary
      end

      test "admin publishes a board post from a reviewed event" do
        sign_in @admin

        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "city_service_event_published").count }, 1 do
          assert_difference("Decidim::Bih::KomsilukPost.count", 1) do
            post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: @event.reload.answer_review_token }
          end
        end

        assert_redirected_to "/admin/bih/city-alerts?tab=review"
        assert_equal "board_published", @event.reload.state
        assert_equal [Decidim::Bih::KomsilukPost.last.id], @event.komsiluk_post_id_values
        assert_equal @komsiluk, Decidim::Bih::KomsilukPost.last.komsiluk
      end

      test "admin can run Viber review after board publication without duplicate board posts" do
        sign_in @admin

        post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: @event.reload.answer_review_token }
        board_post_ids = @event.reload.komsiluk_post_id_values

        with_viber_ready do
          get "/admin/bih/city-alerts", params: { tab: "viber" }
          assert_response :success
          assert_select "a[href*='/notification-preview']"
          assert_not_includes response.body, "/admin/bih/city-alerts/#{@event.id}/publish-board"

          assert_no_difference("Decidim::Bih::KomsilukPost.count") do
            post "/admin/bih/city-alerts/#{@event.id}/publish-viber",
                 params: { viber_review_confirmed: "1", fallback_confirmed: "1", fallback_token: published_fallback_token, review_token: @event.reload.answer_review_token }
          end
        end

        assert_redirected_to "/admin/bih/city-alerts?tab=done"
        assert_equal "published", @event.reload.state
        assert_equal board_post_ids, @event.komsiluk_post_id_values
      end

      # Phase 5 Task 5.2. The pre-existing readiness checks already refuse
      # everything this guard refuses, which is the point - it is an ADDITIVE
      # final recheck for consistency with the broadcast and operator-message
      # surfaces, not a new restriction. This test proves it is actually wired
      # into the path rather than sitting there as dead code.
      test "the shared dispatch guard is consulted before a Viber publication" do
        sign_in @admin

        post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: @event.reload.answer_review_token }

        blocked = Decidim::Bih::Messaging::DispatchGuard::Result.new([:channel_not_ready])
        with_viber_ready do
          Decidim::Bih::Messaging::DispatchGuard.stub(:evaluate, ->(**) { blocked }) do
            post "/admin/bih/city-alerts/#{@event.id}/publish-viber",
                 params: { viber_review_confirmed: "1", fallback_confirmed: "1", fallback_token: published_fallback_token, review_token: @event.reload.answer_review_token }
          end
        end

        assert_redirected_to "/admin/bih/city-alerts?tab=published"
        assert_equal "board_published", @event.reload.state,
                     "a blocked guard must stop the Viber publication"
      end

      test "Viber review is blocked without a current launch approval" do
        sign_in @admin
        @event.update!(state: "board_published", published_at: Time.current)

        post "/admin/bih/city-alerts/#{@event.id}/publish-viber",
             params: { viber_review_confirmed: "1", fallback_confirmed: "1", fallback_token: published_fallback_token, review_token: @event.reload.answer_review_token }

        assert_redirected_to "/admin/bih/city-alerts?tab=published"
        assert_equal "board_published", @event.reload.state
      end

      test "admin publish with viber requires explicit review confirmation" do
        sign_in @admin

        assert_no_difference("Decidim::Bih::KomsilukPost.count") do
          post "/admin/bih/city-alerts/#{@event.id}/publish-viber"
        end

        assert_redirected_to "/admin/bih/city-alerts?tab=review"
        assert_equal "pending_review", @event.reload.state
      end

      test "admin dismisses an event" do
        sign_in @admin

        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "city_service_event_dismissed").count }, 1 do
          post "/admin/bih/city-alerts/#{@event.id}/dismiss"
        end

        assert_redirected_to "/admin/bih/city-alerts?tab=review"
        assert_equal "dismissed", @event.reload.state
        assert_equal @admin, @event.reviewer
        assert_not_nil @event.dismissed_at
      end

      test "admin cannot dismiss a published event" do
        sign_in @admin
        @event.update!(state: "published", published_at: Time.current)

        post "/admin/bih/city-alerts/#{@event.id}/dismiss"

        assert_redirected_to "/admin/bih/city-alerts?tab=history"
        assert_equal "published", @event.reload.state
        assert_nil @event.dismissed_at
      end

      test "bulk selection UI separates Milica access from publication" do
        sign_in @admin
        get "/admin/bih/city-alerts"
        assert_response :success
        assert_select "#milica-source-access-help"
        assert_select "form#city-service-bulk-review[action='/admin/bih/city-alerts/bulk-review'][method='post']"
        assert_select "#city-service-select-page"
        assert_select "input.city-service-bulk-selection[form='city-service-bulk-review']", count: 1
        assert_select "form[action$='/approve-answers']", count: 0
        assert_select "form[action$='/revoke-answers']", count: 0
        assert_select "button[name='review_action'][value='publish']", count: 1
      end

      test "bulk review records the real reviewer for selected current versions without publishing" do
        other = create_event(source_fingerprint: "bulk-other")
        sign_in @admin
        selections = bulk_receipts(@event, other)
        selections[other.id.to_s]["selected"] = "0"
        assert_no_difference "Decidim::Bih::KomsilukPost.count" do
          assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "city_service_event_reviewed").count }, 1 do
            post "/admin/bih/city-alerts/bulk-review", params: { bulk_action: "review", review_note: "Pregledan izvor", selections: }
          end
        end
        assert_redirected_to "/admin/bih/city-alerts?tab=review"
        assert_equal @admin.id, @event.reload.reviewed_by_id
        assert_equal "Pregledan izvor", @event.review_note
        assert @event.pending_review?
        assert_empty @event.komsiluk_post_ids
        assert_nil other.reload.reviewed_at
      end

      test "bulk dismissal is atomic when a row version or review token changed" do
        other = create_event(source_fingerprint: "bulk-stale")
        selections = bulk_receipts(@event, other)
        other.update!(summary: "New source facts")
        sign_in @admin
        assert_no_difference "Decidim::Bih::OperatorAuditEvent.count" do
          post "/admin/bih/city-alerts/bulk-review", params: { bulk_action: "dismiss", review_note: "Not relevant", selections: }
        end
        assert @event.reload.pending_review?
        assert other.reload.pending_review?
        assert_includes flash[:alert], I18n.t("decidim_app.admin.city_service_events.bulk_review.stale_review")

        selections = bulk_receipts(@event, other)
        selections[@event.id.to_s]["content_version"] = "different-provider-version"
        post "/admin/bih/city-alerts/bulk-review", params: { bulk_action: "dismiss", review_note: "Not relevant", selections: }
        assert @event.reload.pending_review?
        assert other.reload.pending_review?
      end

      test "bulk dismissal only changes permitted tenant rows in editable states" do
        other = create_event(source_fingerprint: "bulk-foreign")
        other.update!(organization: create_organization)
        sign_in @admin
        post "/admin/bih/city-alerts/bulk-review", params: { bulk_action: "dismiss", review_note: "Not relevant", selections: bulk_receipts(@event, other) }
        assert @event.reload.pending_review?
        assert other.reload.pending_review?

        @event.update!(state: "published")
        post "/admin/bih/city-alerts/bulk-review", params: { bulk_action: "dismiss", review_note: "Not relevant", selections: bulk_receipts(@event) }
        assert @event.reload.published?

        @event.update!(state: "failed")
        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "city_service_event_dismissed").count }, 1 do
          post "/admin/bih/city-alerts/bulk-review", params: { bulk_action: "dismiss", review_note: "Not relevant", selections: bulk_receipts(@event) }
        end
        assert_redirected_to "/admin/bih/city-alerts?tab=review"
        assert @event.reload.dismissed?
        assert_equal @admin.id, @event.reviewed_by_id
      end

      test "bulk action rejects excessive selection unsupported actions and absent rationale" do
        sign_in @admin
        selections = (1..81).to_h { |id| [id.to_s, { selected: "1", content_version: "", review_token: "a" * 64 }] }
        [{ bulk_action: "dismiss", review_note: "Too many", selections: },
         { bulk_action: "publish_viber", review_note: "Unsupported", selections: bulk_receipts(@event) },
         { bulk_action: "review", review_note: "", selections: bulk_receipts(@event) }].each do |payload|
          assert_no_difference "Decidim::Bih::OperatorAuditEvent.count" do
            post "/admin/bih/city-alerts/bulk-review", params: payload
          end
          assert @event.reload.pending_review?
          assert_nil @event.reviewed_at
        end
      end

      test "bulk mutation requires permission and a CSRF token" do
        sign_in @citizen
        post "/admin/bih/city-alerts/bulk-review", params: { bulk_action: "dismiss", review_note: "Not authorized", selections: bulk_receipts(@event) }
        assert @event.reload.pending_review?
        assert_nil @event.reviewed_at
        sign_out @citizen
        sign_in @admin
        previous = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        post "/admin/bih/city-alerts/bulk-review", params: { bulk_action: "dismiss", review_note: "Missing CSRF", selections: bulk_receipts(@event) }
        assert_response :unprocessable_entity
        assert @event.reload.pending_review?
      ensure
        ActionController::Base.allow_forgery_protection = previous unless previous.nil?
      end

      test "no target stays accessible and never flashes publication success" do
        sign_in @admin
        @event.update!(targeting_level: "unknown", affected_area_slugs: [])
        assert_no_difference("Decidim::Bih::KomsilukPost.count") do
          post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: @event.answer_review_token }
        end
        assert_nil flash[:notice]
        assert_equal I18n.t("decidim_app.admin.city_service_events.workflow_results.no_target"), flash[:alert]
        follow_redirect!
        assert_select "#city-service-event-#{@event.id}"
      end

      test "save and publish uses edited content and rejects stale receipts" do
        sign_in @admin
        original = { content_version: @event.content_version, review_token: @event.answer_review_token, summary: "Corrected source summary" }
        patch "/admin/bih/city-alerts/#{@event.id}", params: { review_action: "publish", city_service_event: original }
        assert_equal "board_published", @event.reload.state
        post_record = Decidim::Bih::KomsilukPost.find(@event.komsiluk_post_id_values.first)
        assert_includes post_record.body, "Corrected source summary"
        assert_equal @event.ends_at, post_record.expires_at
        assert_no_difference("Decidim::Bih::KomsilukPost.count") do
          post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: original[:review_token] }
        end
        assert_equal I18n.t("decidim_app.admin.city_service_events.workflow_results.stale_review"), flash[:alert]
      end

      test "changed source and missing publication receipt are rejected" do
        sign_in @admin
        token = @event.answer_review_token
        @event.update!(summary: "New source facts")
        [token, nil].each do |receipt|
          assert_no_difference("Decidim::Bih::KomsilukPost.count") do
            post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: receipt }
          end
          assert_equal I18n.t("decidim_app.admin.city_service_events.workflow_results.stale_review"), flash[:alert]
        end
      end

      test "cancelled missing time and elapsed notices cannot publish" do
        sign_in @admin
        [{ lifecycle: "cancelled" }, { lifecycle: "scheduled", ends_at: nil },
         { starts_at: 2.hours.ago, ends_at: 1.hour.ago }].each do |attributes|
          @event.update!(attributes)
          assert_no_difference("Decidim::Bih::KomsilukPost.count") do
            post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: @event.answer_review_token }
          end
          assert_nil flash[:notice]
          assert flash[:alert].present?
        end
      end

      test "withdraw correct and republish preserves placements and changes delivery revision" do
        sign_in @admin
        post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: @event.answer_review_token }
        @event.reload
        old_ids = @event.komsiluk_post_id_values
        revision = @event.publication_revision
        post "/admin/bih/city-alerts/#{@event.id}/withdraw", params: { review_token: @event.answer_review_token, review_note: "Wrong time", withdraw_action: "correct" }
        assert_equal "pending_review", @event.reload.state
        assert_not @event.facts_confirmed?
        assert_not_equal revision, @event.publication_revision
        assert_empty Decidim::Bih::KomsilukPost.visible.where(id: old_ids)
        patch "/admin/bih/city-alerts/#{@event.id}", params: { review_action: "publish", city_service_event: {
          content_version: @event.content_version, review_token: @event.answer_review_token, summary: "Corrected notice"
        } }
        assert_equal "board_published", @event.reload.state
        assert_equal old_ids, @event.komsiluk_post_id_values
        assert_equal old_ids.sort, Decidim::Bih::KomsilukPost.visible.where(id: old_ids).order(:id).pluck(:id)
        assert_includes Decidim::Bih::KomsilukPost.find(old_ids.first).body, "Corrected notice"
      end

      test "corrected republication records the old automatic decision" do
        publish_fixture(@event)
        old_revision = "automatic-before-correction"
        @event.update!(extraction_metadata: @event.extraction_metadata.merge("publication_revision" => old_revision))
        decision = DecidimApp::Bijeljina::CityServiceAutomationDecision.create!(
          event: @event, policy_version: DecidimApp::Bijeljina::CityServiceAutomationPolicy::VERSION,
          content_version: @event.content_version, mode: "automatic", outcome: "published",
          publication_revision: old_revision, blockers: [], target_slugs: [@komsiluk.slug]
        )
        sign_in @admin
        post decidim_app_admin_city_service_event_withdraw_path(@event),
             params: { review_token: @event.answer_review_token, review_note: "Pogrešno vrijeme", withdraw_action: "correct" }
        assert_equal "pending_review", @event.reload.state
        patch decidim_app_admin_city_service_event_path(@event), params: { review_action: "publish", city_service_event: {
          content_version: @event.content_version, review_token: @event.answer_review_token, summary: "Ispravljena objava"
        } }

        assert_equal "board_published", @event.reload.state
        assert_equal "corrected", decision.reload.check_result
        assert_equal old_revision, decision.checked_publication_revision
        assert_equal @admin.id, decision.checked_by_id
        assert_equal "done", DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: @organization).entries.fetch(@event.id).tab
      end

      test "withdrawal requires current receipt permission and reason" do
        sign_in @admin
        post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: @event.answer_review_token }
        @event.reload
        post "/admin/bih/city-alerts/#{@event.id}/withdraw", params: { review_token: @event.answer_review_token }
        assert @event.reload.board_published?
        post "/admin/bih/city-alerts/#{@event.id}/withdraw", params: { review_token: "stale", review_note: "Withdraw" }
        assert @event.reload.board_published?
        sign_in @citizen
        post "/admin/bih/city-alerts/#{@event.id}/withdraw", params: { review_token: @event.answer_review_token, review_note: "Withdraw" }
        assert @event.reload.board_published?
        sign_in @admin
        post "/admin/bih/city-alerts/#{@event.id}/withdraw", params: { review_token: @event.answer_review_token, review_note: "Cancelled by provider" }
        assert @event.reload.dismissed?
        assert_empty DecidimApp::Bijeljina::CityServiceEvent.milica_available.where(id: @event.id)
        assert_empty Decidim::Bih::KomsilukPost.visible.where(id: @event.komsiluk_post_id_values)
      end

      test "reviewed notices leave review and elapsed board notices leave Viber" do
        sign_in @admin
        @event.mark_reviewed!(actor: @admin)
        get "/admin/bih/city-alerts", params: { state: "review" }
        assert_select "#city-service-event-#{@event.id}", count: 0
        get "/admin/bih/city-alerts", params: { tab: "reviewed" }
        assert_select "#city-service-event-#{@event.id}"
        @event.update!(state: "board_published", starts_at: 2.hours.ago, ends_at: 1.hour.ago)
        get "/admin/bih/city-alerts", params: { tab: "done", state: "published" }
        assert_select "#city-service-event-#{@event.id}", count: 0
        get "/admin/bih/city-alerts", params: { tab: "history" }
        assert_select "#city-service-event-#{@event.id}"
      end

      test "unconfirmed fact edits cannot silently publish old target or time" do
        sign_in @admin
        assert_no_difference("Decidim::Bih::KomsilukPost.count") do
          patch "/admin/bih/city-alerts/#{@event.id}", params: { review_action: "publish", city_service_event: {
            content_version: @event.content_version, review_token: @event.answer_review_token,
            ends_at_local: 8.hours.from_now.in_time_zone("Europe/Sarajevo").iso8601, summary: "Must not silently save"
          } }
        end
        assert_not_equal "Must not silently save", @event.reload.summary
        assert_equal I18n.t("decidim_app.admin.city_service_events.update.facts_confirmation_required"), flash[:alert]
      end

      test "empty phone audience does not consume a later send" do
        sign_in @admin
        post "/admin/bih/city-alerts/#{@event.id}/publish-board", params: { review_token: @event.answer_review_token }
        Decidim::Bih::TopicPreferences.set!(@recipient, topic: :neighborhood_info, enabled: false)
        with_viber_ready do
          post "/admin/bih/city-alerts/#{@event.id}/publish-viber",
               params: { review_token: @event.reload.answer_review_token, viber_review_confirmed: "1", fallback_confirmed: "1", fallback_token: published_fallback_token }
          assert_response :success
          assert_select ".city-approval-preview button[type=submit][disabled]", count: 1
          assert_equal 0, @event.reload.viber_jobs_count
          assert_nil flash[:notice]

          Decidim::Bih::TopicPreferences.set!(@recipient, topic: :neighborhood_info, enabled: true)
          get decidim_app_admin_city_service_event_notification_preview_path(@event)
          assert_response :success
          assert_includes response.body, "Podobni primaoci: 1"
          assert_select ".city-approval-preview button[type=submit]:not([disabled])", count: 1
        end
        assert @event.reload.board_published?
        assert_equal 0, @event.viber_jobs_count
      end

      test "state filters cannot restore reviewed or ended records to active queues" do
        sign_in @admin
        @event.mark_reviewed!(actor: @admin)
        get "/admin/bih/city-alerts", params: { tab: "review", state: "review" }
        assert_select "#city-service-event-#{@event.id}", count: 0
        @event.update!(state: "board_published", starts_at: 2.hours.ago, ends_at: 1.hour.ago)
        get "/admin/bih/city-alerts", params: { tab: "done", state: "published" }
        assert_select "#city-service-event-#{@event.id}", count: 0
        get "/admin/bih/city-alerts", params: { tab: "history", state: "finished" }
        assert_select "#city-service-event-#{@event.id}"
      end

      test "expiry changes badge counts filters and actions without changing publication history" do
        @event.update!(ends_at: @event.ends_at.change(usec: 0))
        publish_fixture(@event)
        sign_in @admin
        travel_to @event.ends_at - 1.second do
          get "/admin/bih/city-alerts", params: { tab: "published", state: "published" }
          assert_select "#city-service-event-#{@event.id}[data-city-service-event-state='published']"
          assert_select "[data-city-alert-state='published'] strong", text: "1"
          assert_select "form[action$='/withdraw']"
        end
        travel_to @event.ends_at do
          get "/admin/bih/city-alerts", params: { tab: "published", state: "published" }
          assert_select "#city-service-event-#{@event.id}", count: 0
          assert_select "[data-city-alert-state='published'] strong", text: "0"
          assert_select "[data-city-alert-state='finished'] strong", text: "1"
          get "/admin/bih/city-alerts", params: { tab: "history", state: "finished" }
          assert_select "#city-service-event-#{@event.id}[data-city-service-event-state='finished'] .city-alerts-end-reason", text: /Isteklo/
          assert_select "#city-alert-editor-#{@event.id} form", count: 0
          assert_select ".city-service-bulk-selection", count: 0
          assert @event.reload.board_published?
        end
      end

      test "reviewed invalid targets need attention and invisible posts are archived" do
        @event.mark_reviewed!(actor: @admin)
        @event.update!(targeting_level: "unknown", affected_area_slugs: [])
        workflow = DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: @organization)
        assert_equal "review", workflow.entries.fetch(@event.id).status
        assert_equal :no_target, workflow.entries.fetch(@event.id).blocker
        @event.update!(targeting_level: "mz", affected_area_slugs: [@mz.slug])
        publish_fixture(@event)
        Decidim::Bih::KomsilukPost.where(id: @event.komsiluk_post_id_values).each { |post| post.update!(status: "expired") }
        entry = DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: @organization).entries.fetch(@event.id)
        assert_equal "finished", entry.status
        assert_equal "not_visible", entry.reason
        assert_not entry.delivery_action?
      end

      test "replacement versions are grouped under the current notice" do
        previous = create_event(source_fingerprint: "older-source", title: "Stara verzija")
        previous.update!(state: "superseded", superseded_by_id: @event.id)
        sign_in @admin
        get "/admin/bih/city-alerts"
        assert_select "#city-service-event-#{previous.id}", count: 0
        assert_select "#city-service-version-#{previous.id}", text: /Stara verzija/
        assert_select "#admin-city-alert-workflow-nav a", count: 3
        assert_select "#admin-city-alert-state-summary a", count: 4
        assert_select "[data-city-alert-state='finished'] strong", text: "0"
      end

      test "delivery failures and provider acceptance remain separate from board publication" do
        publish_fixture(@event)
        @event.update!(viber_dedupe_key: "delivery-display", viber_jobs_count: 1)
        notification = Decidim::Bih::AccountNotification.create!(organization: @organization, user: @recipient,
                                                                 topic: "city_service_alerts", status: "rejected", expires_at: @event.ends_at,
                                                                 deduplication_digest: Digest::SHA256.hexdigest("city_service_alerts:city-alert:delivery-display"),
                                                                 payload: { text: "Fixture", channels: ["viber"] })
        sign_in @admin
        %w(rejected accepted delivered).zip(%w(error accepted delivered)).each do |status, label|
          notification.update!(status: status)
          get "/admin/bih/city-alerts", params: { tab: "published" }
          assert_select "#city-service-event-#{@event.id}[data-city-service-event-state='published']"
          assert_select "#city-service-event-#{@event.id} .city-alerts-delivery-status",
                        text: I18n.t("decidim_app.admin.city_service_events.simplified.delivery.#{label}", locale: :sr)
        end
      end

      test "city receipt card separates active waiting from retired unacknowledged history" do
        incident = DecidimApp::Bijeljina::CityServiceIncident.create!(
          organization: @organization, identity_key: "receipt-card-#{SecureRandom.hex(4)}", service: "electricity_outages"
        )
        @event.update!(incident_id: incident.id)
        publish_fixture(@event)
        identity = DecidimApp::Bijeljina::CityServiceIncidentIdentity.delivery_identity(@event)
        _active, acknowledged, cancelled, expired = [@recipient, @citizen, @opted_out, @admin].map do |user|
          Decidim::Bih::PlatformDelivery.for!(user:, identity:, expires_at: 2.hours.from_now)
        end
        acknowledged.update!(acknowledged_at: Time.current, acknowledgment_kind: "browser_display")
        cancelled.update!(cancelled_at: Time.current, cancellation_reason: "notice_changed")
        expired.update!(expires_at: 1.minute.ago)

        sign_in @admin
        get "/admin/bih/city-alerts", params: { tab: "published" }
        assert_response :success
        card = Nokogiri::HTML(response.body).at_css("#city-alert-editor-#{@event.id} [data-city-platform-delivery]")
        assert card, "published event must show its incident receipt counts"
        counts = card.css("dt").map.with_index { |term, i| [term.text.strip, card.css("dd")[i].text.strip] }.to_h
        assert_equal "1", counts.fetch(I18n.t("decidim_app.admin.city_service_events.compact.delivery_awaiting_acknowledgment", locale: :sr))
        assert_equal "2", counts.fetch(I18n.t("decidim_app.admin.city_service_events.compact.delivery_retired_unacknowledged", locale: :sr))
        scope = Nokogiri::HTML(response.body).at_css("#city-alert-editor-#{@event.id} [data-city-platform-delivery-scope]")
        assert_equal I18n.t("decidim_app.admin.city_service_events.compact.delivery_scope", count: 4, locale: :sr), scope.text.strip
      end

      test "published incident with no receipt says that there is no delivery evidence" do
        incident = DecidimApp::Bijeljina::CityServiceIncident.create!(
          organization: @organization, identity_key: "empty-receipt-card-#{SecureRandom.hex(4)}", service: "electricity_outages"
        )
        @event.update!(incident_id: incident.id)
        publish_fixture(@event)
        sign_in @admin

        get "/admin/bih/city-alerts", params: { tab: "published" }

        assert_response :success
        card = Nokogiri::HTML(response.body).at_css("#city-alert-editor-#{@event.id} [data-city-platform-delivery-empty]")
        assert card, "published incident without receipts must have an explicit empty state"
        assert_equal I18n.t("decidim_app.admin.city_service_events.compact.delivery_empty", locale: :sr), card.text.strip
      end

      test "retry only queues confirmed failures and refuses expired notices" do
        publish_fixture(@event)
        @event.update!(state: "published", viber_dedupe_key: "safe-retry", extraction_metadata: { "publication_revision" => "retry-v1" })
        Decidim::Bih::CitizenProfile.for_user(@citizen, organization: @organization).assign_komsiluk!(@komsiluk, source: "dropdown", resolved_mz: @mz)
        notifications = [@recipient, @citizen, @opted_out, @admin].zip(%w(rejected failed accepted unknown)).map do |user, status|
          Decidim::Bih::AccountNotification.create!(organization: @organization, user:, topic: "city_service_alerts", status:, expires_at: @event.ends_at,
                                                    deduplication_digest: Digest::SHA256.hexdigest("city_service_alerts:city-alert:safe-retry"),
                                                    payload: { text: "Fixture", channels: ["viber"], context: { event_id: @event.id, event_revision: "retry-v1" } })
        end
        [@recipient, @citizen].zip(notifications.first(2)).each do |user, notification|
          receipt = Decidim::Bih::PlatformDelivery.for!(user:, identity: DecidimApp::Bijeljina::CityServiceIncidentIdentity.delivery_identity(@event),
                                                        expires_at: @event.ends_at)
          receipt.update!(deadline_at: 1.second.ago, fallback_requested_at: Time.current,
                          fallback_context: { event_id: @event.id, event_revision: "retry-v1", dedupe_key: "safe-retry" },
                          account_notification_id: notification.id)
        end
        sign_in @admin
        with_viber_ready do
          get "/admin/bih/city-alerts", params: { tab: "published" }
          assert_select "a.city-alert-retry-delivery[href*='retry_failed=1']"
          get decidim_app_admin_city_service_event_notification_preview_path(@event, retry_failed: "1")
          assert_response :success
          assert_select "input[name=retry_failed][value='1']"
          assert_includes response.body, "Podobni primaoci: 2"
          assert_enqueued_jobs 2, only: Decidim::Bih::AccountNotificationJob do
            post "/admin/bih/city-alerts/#{@event.id}/publish-viber",
                 params: { retry_failed: "1", viber_review_confirmed: "1", fallback_confirmed: "1", fallback_token: published_fallback_token(retry_failed: true),
                           review_token: @event.answer_review_token }
          end
          assert_equal(%w(pending pending accepted unknown), notifications.map { |notification| notification.reload.status })
          assert_no_enqueued_jobs do
            post "/admin/bih/city-alerts/#{@event.id}/publish-viber",
                 params: { retry_failed: "1", viber_review_confirmed: "1", fallback_confirmed: "1", fallback_token: published_fallback_token(retry_failed: true),
                           review_token: @event.answer_review_token }
          end
          notifications.first.update!(status: "rejected")
          @event.update!(starts_at: 2.hours.ago, ends_at: 1.hour.ago)
          assert_no_enqueued_jobs do
            post "/admin/bih/city-alerts/#{@event.id}/publish-viber",
                 params: { retry_failed: "1", viber_review_confirmed: "1", fallback_confirmed: "1", fallback_token: published_fallback_token(retry_failed: true),
                           review_token: @event.answer_review_token }
          end
          assert_equal "rejected", notifications.first.reload.status
        end
      end

      test "operator can compare an AI proposal with saved source facts without changing areas" do
        @event.update!(extraction_metadata: @event.extraction_metadata.merge("ai_classification" => {
          "status" => "review", "source_content_version" => @event.content_version,
          "model" => "model-fixture", "needs_review" => true, "reasons" => ["gemini_failed"],
          "event_type" => "planned_outage", "severity" => "service_outage",
          "suggested_title" => "AI predlaže naslov", "suggested_body" => "AI predlaže tekst"
        }))
        sign_in @admin
        get decidim_app_admin_city_service_events_path(tab: "review")

        assert_response :success
        assert_select "#city-alert-editor-#{@event.id} .city-alert-ai-review", text: /AI predlaže naslov/
        assert_select "#city-alert-editor-#{@event.id} .city-alert-ai-review", text: /Izmišljeno polje će biti bez struje/
        assert_equal [@komsiluk.slug], @event.reload.area_slugs
      end

      test "automatic publication is a distinct check lane and a check is bound to its publication revision" do
        publish_fixture(@event)
        @event.update!(extraction_metadata: @event.extraction_metadata.merge(
          "publication_revision" => "auto-revision-1",
          "automation_publication" => { "policy_version" => DecidimApp::Bijeljina::CityServiceAutomationPolicy::VERSION }
        ))
        decision = DecidimApp::Bijeljina::CityServiceAutomationDecision.create!(
          event: @event, policy_version: DecidimApp::Bijeljina::CityServiceAutomationPolicy::VERSION,
          content_version: @event.content_version, mode: "automatic", outcome: "published",
          publication_revision: "auto-revision-1", blockers: [], target_slugs: [@komsiluk.slug]
        )
        workflow = DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: @organization)
        assert_equal "automatic", workflow.entries.fetch(@event.id).tab
        assert_equal DecidimApp::Bijeljina::CityServiceWorkflow.review_count(organization: @organization), workflow.ids(tab: "review").size

        sign_in @admin
        get decidim_app_admin_city_service_events_path(tab: "automatic")
        assert_response :success
        assert_select "#city-service-event-#{@event.id}"
        assert_select "#city-service-event-#{@event.id} [data-city-decision-reason='auto_published']"
        assert_select "form[action='#{decidim_app_admin_city_service_event_check_automatic_path(@event)}']"

        post decidim_app_admin_city_service_event_check_automatic_path(@event), params: { publication_revision: "old-revision" }
        assert_nil decision.reload.checked_at
        post decidim_app_admin_city_service_event_check_automatic_path(@event), params: { publication_revision: "auto-revision-1", evidence_digest: DecidimApp::Bijeljina::CityServiceAutomationDecision.evidence_digest(@event) }
        assert_equal "ok", decision.reload.check_result
        assert_equal @admin.id, decision.checked_by_id
        assert_equal "auto-revision-1", decision.checked_publication_revision
        assert_equal "done", DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: @organization).entries.fetch(@event.id).tab
        assert_not decision.checked_for?(@event, policy_version: "new-policy")
        @event.update!(extraction_metadata: @event.extraction_metadata.merge("source_document_changed" => true))
        assert_not decision.checked_for?(@event), "new source evidence invalidates the old check"
        @event.update!(extraction_metadata: @event.extraction_metadata.except("source_document_changed"))
        @event.update!(extraction_metadata: @event.extraction_metadata.merge("ai_classification" => { "status" => "review", "needs_review" => true }))
        assert_not decision.checked_for?(@event), "a new AI decision invalidates the old check"
        @event.update!(extraction_metadata: @event.extraction_metadata.except("ai_classification"))
        @komsiluk.update!(boundary: { type: "Polygon", coordinates: [[[19.1, 44.7], [19.2, 44.7], [19.2, 44.8], [19.1, 44.8], [19.1, 44.7]]] })
        assert_equal "automatic", DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: @organization).entries.fetch(@event.id).tab,
                     "a changed boundary invalidates an earlier check"
        post decidim_app_admin_city_service_event_check_automatic_path(@event),
             params: { publication_revision: "auto-revision-1", evidence_digest: decision.checked_evidence_digest }
        assert_equal I18n.t("decidim_app.admin.city_service_events.auto_check.results.stale_review", locale: :sr), flash[:alert]
      end

      test "manual republication does not inherit the previous automatic check" do
        publish_fixture(@event)
        @event.update!(extraction_metadata: @event.extraction_metadata.merge("publication_revision" => "auto-old"))
        DecidimApp::Bijeljina::CityServiceAutomationDecision.create!(
          event: @event, policy_version: DecidimApp::Bijeljina::CityServiceAutomationPolicy::VERSION,
          content_version: @event.content_version, mode: "automatic", outcome: "published",
          publication_revision: "auto-old", blockers: [], target_slugs: [@komsiluk.slug]
        )
        @event.update!(extraction_metadata: @event.extraction_metadata.merge("publication_revision" => "manual-new"))
        entry = DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: @organization).entries.fetch(@event.id)
        assert_equal "done", entry.tab
        assert_nil entry.automatic_decision
      end

      private

      def publish_fixture(item)
        post = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @komsiluk, category: "safety", title: item.title, body: item.summary,
                                                  expires_at: item.ends_at)
        item.update!(state: "board_published", published_at: Time.current, komsiluk_post_ids: [post.id])
      end

      def bulk_receipts(*events)
        events.to_h { |event| [event.id.to_s, { "selected" => "1", "content_version" => event.content_version, "review_token" => event.answer_review_token }] }
      end

      def published_fallback_token(retry_failed: false)
        DecidimApp::Bijeljina::CityServiceApprovalPreview.new(event: @event.reload, actor: @admin, attributes: {}, retry_failed:).call.token
      end

      def with_viber_ready(&block)
        Decidim::Bih::GovernanceApproval.create!(
          organization: @organization,
          user: @admin,
          governance_kind: "viber_launch",
          approval_role: "admin",
          status: "approved",
          evidence_summary: "Live verification passed"
        )
        # Derive send_blocked? from the same status the double reports, so this
        # stub cannot quietly disagree with IntegrationHealth about what blocks
        # a send.
        health = Object.new
        health.define_singleton_method(:state) { |**| { status: :ok } }
        health.define_singleton_method(:send_blocked?) { |**| state[:status] == :failing }
        DecidimApp::Bijeljina::CityServiceSources.stub(:alerts_enabled?, true) do
          Decidim::Bih::IntegrationHealth.stub(:instance, health) do
            Decidim::Bih::Config.stub(
              :infobip,
              { base_url: "https://provider.example", api_key: "configured", viber_bm_sender: "configured" }
            ) do
              Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, "+12025550101", &block)
            end
          end
        end
      end

      def create_event(source_fingerprint: "fingerprint-synthetic-field", title: "Planirano isključenje struje: Izmišljeno polje")
        DecidimApp::Bijeljina::CityServiceEvent.create!(
          organization: @organization,
          source_key: "electricity_outages",
          source_label: "Izmišljeni pružalac planned outages",
          provider: "Izmišljeni pružalac",
          source_url: "https://example.test/outages",
          source_fingerprint:,
          parser_version: "test", lifecycle: "scheduled", content_version: "test-v1",
          event_type: "planned_outage",
          severity: "service_outage",
          targeting_level: "komsiluk",
          affected_area_slugs: ["komsiluk-synthetic-field"],
          title:,
          summary: "Izmišljeno polje će biti bez struje od 09:00 do 12:00.",
          viber_text: "Izmišljeno polje: struja 09-12.",
          starts_at: 1.hour.from_now,
          ends_at: 4.hours.from_now,
          confidence: 0.9,
          classifier_reasons: ["test"]
        )
      end
    end
  end
end
