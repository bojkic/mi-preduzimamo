# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_service_directory"
require_relative "../../../support/synthetic_foundation_reference"
require "capybara"

module DecidimApp
  module Admin
    class CityServiceEntriesControllerTest < ActionDispatch::IntegrationTest
      include SyntheticServiceDirectory
      include SyntheticFoundationReference
      setup do
        install_synthetic_service_directory
        install_synthetic_foundation_reference
      end
      teardown do
        restore_synthetic_foundation_reference
        restore_synthetic_service_directory
      end
      include ::Devise::Test::IntegrationHelpers

      NEW_BODY = "Kabasti otpad se od oktobra 2040. odvozi svakog prvog ponedjeljka u mjesecu; raspored po naseljima je na https://waste.example.invalid/kabasti."

      setup do
        @organization = create_organization
        host! @organization.host
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        @shipped = DecidimApp::Bijeljina::CityServicesData::ENTRIES.find { |entry| entry.fetch(:key) == :otpad }
      end

      test "admin sees every shipped FAQ answer as shipped and a link to the foundation status" do
        sign_in @admin

        get "/admin/bih/city-faq"

        assert_response :success
        assert_select "#admin-city-service-entries-table"
        assert_select "tr[data-city-service-entry-state='shipped']", count: DecidimApp::Bijeljina::CityServicesData::ENTRIES.size
        assert_select "#city-service-entry-otpad td", text: @shipped.fetch(:title)
        assert_select "#admin-foundation-status-link[href='/admin/bih/foundation-status']"
        assert_includes response.body, I18n.t("decidim_app.admin.city_service_entries.states.shipped", locale: :sr)
        assert_select "form.form-defaults", count: 0
      end

      test "non-admin and an operator without the city-alert permission are denied" do
        sign_in @citizen
        get "/admin/bih/city-faq"
        assert_response :redirect

        operator = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::OperatorRole.create!(organization: @organization, user: operator, created_by: @admin,
                                           role: "komsiluk_moderator", expires_at: 1.month.from_now)
        sign_in operator
        get "/admin/bih/city-faq"
        assert_response :redirect
        get "/admin/bih/city-faq/otpad/edit"
        assert_response :redirect
        patch "/admin/bih/city-faq/otpad", params: { city_service_entry: { body: NEW_BODY } }
        assert_response :redirect
        assert_nil DecidimApp::Bijeljina::CityServiceEntry.for_organization(@organization).find_by(key: "otpad")
        get "/admin/bih/foundation-status"
        assert_response :redirect
      end

      test "an unknown FAQ key is not found" do
        sign_in @admin

        get "/admin/bih/city-faq/nepostojeci/edit"

        assert_response :not_found
      end

      test "editing saves a draft that never reaches the chat, and the preview renders the draft through the real renderer" do
        sign_in @admin

        get "/admin/bih/city-faq/otpad/edit"
        assert_response :success
        assert_select "#admin-city-service-entry-edit[data-city-service-entry-state='shipped']"
        assert_select "form.mi-admin-record-editor textarea[name='city_service_entry[body]']", text: @shipped.fetch(:answer)

        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "city_service_entry_drafted").count }, 1 do
          patch "/admin/bih/city-faq/otpad",
                params: { city_service_entry: { title: "Odvoz smeća i kabastog otpada (novi raspored)", body: NEW_BODY,
                                                source_url: "https://waste.example.invalid/kabasti", source_checked_on: Date.current.iso8601 } }
        end
        assert_redirected_to "/admin/bih/city-faq/otpad/edit"

        entry = DecidimApp::Bijeljina::CityServiceEntry.for_organization(@organization).find_by!(key: "otpad")
        assert_predicate entry, :draft?
        assert_equal @shipped.fetch(:answer), DecidimApp::Bijeljina::CityDirectory.find(:otpad, organization: @organization).fetch(:answer),
                     "a draft must never reach the chat"

        get "/admin/bih/city-faq/otpad/preview", params: { query: "kabasti otpad", answer_locale: "sr-Cyrl" }
        assert_response :success
        assert_select "#admin-city-service-entry-preview[data-preview-locale='sr-Cyrl']"
        assert_select "#city-service-entry-draft-answer", text: Decidim::Bih::Transliterator.localize(NEW_BODY, locale: "sr-Cyrl")
        assert_select "#city-service-entry-shipped-answer", text: Decidim::Bih::Transliterator.localize(@shipped.fetch(:answer), locale: "sr-Cyrl")
        assert_includes response.body, I18n.t("decidim_app.admin.city_service_entries.states.draft", locale: :sr)
      end

      test "an invalid draft is re-rendered with errors and nothing is saved" do
        sign_in @admin

        patch "/admin/bih/city-faq/otpad",
              params: { city_service_entry: { title: "", body: NEW_BODY, source_url: "ftp://x", source_checked_on: Date.current.iso8601 } }

        assert_response :unprocessable_entity
        assert_select "#city-service-entry-errors li", minimum: 2
        assert_nil DecidimApp::Bijeljina::CityServiceEntry.for_organization(@organization).find_by(key: "otpad")
      end

      test "approve makes the override live for the chat and rollback restores the shipped constant" do
        sign_in @admin
        patch "/admin/bih/city-faq/otpad",
              params: { city_service_entry: { title: @shipped.fetch(:title), body: NEW_BODY,
                                              source_url: "https://waste.example.invalid/kabasti", source_checked_on: Date.current.iso8601 } }

        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "city_service_entry_approved").count }, 1 do
          post "/admin/bih/city-faq/otpad/approve"
        end
        assert_redirected_to "/admin/bih/city-faq"
        follow_redirect!
        assert_select "#city-service-entry-otpad[data-city-service-entry-state='approved']"

        live = DecidimApp::Bijeljina::CityDirectory.find(:otpad, organization: @organization)
        assert_equal NEW_BODY, live.fetch(:answer)
        assert_equal "https://waste.example.invalid/kabasti", live.fetch(:source_url)
        assert_equal Date.current.iso8601, live.fetch(:source_checked_on)
        assert_equal "admin_override", live.fetch(:content_origin)
        assert_equal "https://waste.example.invalid/kabasti", live.fetch(:facts).first.fetch(:source_url)

        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "city_service_entry_rolled_back").count }, 1 do
          post "/admin/bih/city-faq/otpad/rollback"
        end
        assert_redirected_to "/admin/bih/city-faq"
        assert_equal @shipped.fetch(:answer), DecidimApp::Bijeljina::CityDirectory.find(:otpad, organization: @organization).fetch(:answer)
        assert_equal @shipped.fetch(:source_url), DecidimApp::Bijeljina::CityDirectory.find(:otpad, organization: @organization).fetch(:source_url)
        assert_predicate DecidimApp::Bijeljina::CityServiceEntry.for_organization(@organization).find_by!(key: "otpad"), :rolled_back?

        post "/admin/bih/city-faq/otpad/rollback"
        assert_redirected_to "/admin/bih/city-faq"
        assert_equal I18n.t("decidim_app.admin.city_service_entries.rollback.not_approved", locale: :sr), flash[:alert]
      end

      test "approving an entry that was never drafted is refused" do
        sign_in @admin

        post "/admin/bih/city-faq/otpad/approve"

        assert_redirected_to "/admin/bih/city-faq/otpad/edit"
        assert_nil DecidimApp::Bijeljina::CityServiceEntry.for_organization(@organization).find_by(key: "otpad")
      end

      test "the foundation call status is drafted, approved and rolled back, and only the approved row reaches FoundationRead" do
        sign_in @admin

        get "/admin/bih/foundation-status"
        assert_response :success
        assert_select "#admin-foundation-status[data-foundation-status-state='none']"
        assert_includes response.body, I18n.t("decidim_app.admin.foundation_status.show.effective_source_yaml", locale: :sr)

        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "foundation_status_drafted").count }, 1 do
          patch "/admin/bih/foundation-status",
                params: { foundation_status_override: { current_open_status: "open", reviewed_on: Date.current.iso8601,
                                                        review_expires_on: (Date.current + 60).iso8601 } }
        end
        assert_redirected_to "/admin/bih/foundation-status"
        assert_nil DecidimApp::Bijeljina::FoundationStatusOverride.approved_for(@organization)
        assert_equal "unverified", foundation_call_status, "a draft must not change the chat"

        post "/admin/bih/foundation-status/approve"
        assert_redirected_to "/admin/bih/foundation-status"
        follow_redirect!
        assert_select "#admin-foundation-status[data-foundation-status-state='approved']"
        assert_includes response.body, I18n.t("decidim_app.admin.foundation_status.show.effective_source_override", locale: :sr)
        assert_equal "open", foundation_call_status

        post "/admin/bih/foundation-status/rollback"
        assert_redirected_to "/admin/bih/foundation-status"
        assert_nil DecidimApp::Bijeljina::FoundationStatusOverride.approved_for(@organization)
        assert_equal "unverified", foundation_call_status
      end

      test "an invalid foundation status re-renders with errors" do
        sign_in @admin

        patch "/admin/bih/foundation-status",
              params: { foundation_status_override: { current_open_status: "open", reviewed_on: Date.current.iso8601,
                                                      review_expires_on: (Date.current - 1).iso8601 } }

        assert_response :unprocessable_entity
        assert_select "#foundation-status-errors li", minimum: 1
        assert_nil DecidimApp::Bijeljina::FoundationStatusOverride.find_by(decidim_organization_id: @organization.id)
      end

      test "cyrillic admin copy is generated from the maintained serbian locale" do
        %w(decidim_app.admin.city_service_entries decidim_app.admin.foundation_status
           activerecord.attributes.decidim_app/bijeljina/city_service_entry
           activerecord.errors.models.decidim_app/bijeljina/city_service_entry).each do |scope|
          latin = I18n.t(scope, locale: "sr")
          cyrillic = I18n.t(scope, locale: "sr-Cyrl")
          assert_equal transliterate_deep(latin), cyrillic, scope
        end
      end

      private

      def foundation_call_status
        context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
          organization_id: @organization.id, conversation_key: "a" * 64, capabilities: ["public_reads"], now: Time.current
        )
        result = DecidimApp::Bijeljina::Milica::FoundationRead.new(organization: @organization)
                                                              .call(topic: "community", entities: { "query" => "Da li Lokalna fondacija Bijeljina finansira projekte građana?" },
                                                                    context:, locale: "sr")
        result.fetch(:validity).fetch("current_call_status")
      end

      def transliterate_deep(value)
        case value
        when Hash then value.transform_values { |inner| transliterate_deep(inner) }
        when String then Decidim::Bih::Transliterator.call(value)
        else value
        end
      end
    end
  end
end
