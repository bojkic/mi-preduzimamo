# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      # Round 25 (W4.3) — admin editor for local-area contacts. Global-admin
      # gated; org-scoped; CSRF-protected. Only predsjednik/telefon/metadata-note
      # are editable — the boundary stays rake-imported.
      class LocalAreasControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @mz = Decidim::Bih::LocalArea.create!(
            decidim_organization_id: @organization.id,
            kind: "mz", slug: "centar", name: { "sr" => "Centar" },
            metadata: { "povrsina_m2" => 12_345 }
          )
          @komsiluk = Decidim::Bih::LocalArea.create!(
            decidim_organization_id: @organization.id,
            kind: "komsiluk",
            slug: "trg",
            name: { "sr" => "Trg" },
            primary_mz_slug: "centar",
            overlapping_mz_slugs: ["centar"]
          )
        end

        test "a non-admin is denied access" do
          sign_in @citizen
          get "/admin/bih/local-areas"

          assert_response :redirect
        end

        test "an admin sees the index focused on MZ contacts by default" do
          sign_in @admin
          get "/admin/bih/local-areas"

          assert_response :success
          assert_select "#local-areas-header[data-local-areas-active-tab='mz']"
          assert_select "#local-areas-workflow-nav a[aria-current='page'][href='/admin/bih/local-areas?tab=mz']"
          assert_select "#local-areas-workflow-nav a[href='/admin/bih/local-areas?tab=komsiluk']"
          assert_select "#local-areas-workflow-nav a[href='/admin/bih/local-areas?tab=routing']"
          assert_select "#local-areas-mz-list"
          assert_select "#local-areas-komsiluk-list", false
          assert_select "#local-areas-routing-impact", false
          assert_includes response.body, "Centar"
          assert_not_includes response.body, "Trg"
        end

        test "the index keeps the legacy kind=mz filter compatible" do
          sign_in @admin
          get "/admin/bih/local-areas", params: { kind: "mz" }

          assert_response :success
          assert_select "#local-areas-header[data-local-areas-active-tab='mz']"
          assert_includes response.body, "Centar"
          assert_not_includes response.body, "Trg"
        end

        test "the index separates komsiluk routing and aggregate routing impact" do
          sign_in @admin

          get "/admin/bih/local-areas", params: { tab: "komsiluk" }

          assert_response :success
          assert_select "#local-areas-header[data-local-areas-active-tab='komsiluk']"
          assert_select "#local-areas-komsiluk-list"
          assert_select "#local-areas-mz-list", false
          assert_includes response.body, "Trg"
          assert_includes response.body, "Centar"

          get "/admin/bih/local-areas", params: { tab: "routing" }

          assert_response :success
          assert_select "#local-areas-header[data-local-areas-active-tab='routing']"
          assert_select "#local-areas-routing-impact"
          assert_includes response.body, I18n.t("decidim.bih.admin.local_areas.index.summary_mz_count")
          assert_includes response.body, I18n.t("decidim.bih.admin.local_areas.index.summary_missing_primary")

          get "/admin/bih/local-areas", params: { tab: "unknown" }

          assert_response :success
          assert_select "#local-areas-header[data-local-areas-active-tab='mz']"
        end

        test "an admin sees the edit form prefilled" do
          @mz.update!(predsjednik: "Marko Marković", telefon: "055-111-222")
          sign_in @admin
          get "/admin/bih/local-areas/#{@mz.id}/edit"

          assert_response :success
          assert_includes response.body, "Marko Marković"
          assert_includes response.body, "055-111-222"
          assert_select "input[name='approval_rationale']"
        end

        test "an admin edits predsjednik and telefon" do
          sign_in @admin
          patch "/admin/bih/local-areas/#{@mz.id}", params: {
            local_area: { predsjednik: "Ana Anić", telefon: "065-333-444" },
            approval_rationale: "Savjet MZ potvrdio nove kontakte"
          }

          assert_response :redirect
          assert_redirected_to "/admin/bih/local-areas?tab=mz"
          @mz.reload
          assert_equal "Ana Anić", @mz.predsjednik
          assert_equal "065-333-444", @mz.telefon
          assert_equal "Savjet MZ potvrdio nove kontakte",
                       Decidim::Bih::OperatorAuditEvent.where(event_type: "local_area_updated").last.metadata["approval_rationale"]
        end

        test "editing preserves the rake-imported GIS metadata" do
          sign_in @admin
          patch "/admin/bih/local-areas/#{@mz.id}", params: {
            local_area: { predsjednik: "Ana", telefon: "065", napomena: "interna" },
            approval_rationale: "Interna napomena za operatere"
          }

          assert_response :redirect
          @mz.reload
          assert_equal 12_345, @mz.metadata["povrsina_m2"]
          assert_equal "interna", @mz.metadata["napomena"]
        end

        test "a metadata save with blank napomena preserves a pre-existing nil-valued GIS key" do
          @mz.update!(metadata: { "povrsina_m2" => 12_345, "izvor" => nil })
          sign_in @admin
          patch "/admin/bih/local-areas/#{@mz.id}", params: {
            local_area: { predsjednik: "Ana", telefon: "065" },
            approval_rationale: "Kontakt potvrđen bez interne napomene"
          }

          assert_response :redirect
          @mz.reload
          assert @mz.metadata.has_key?("izvor"), "nil-valued GIS key 'izvor' must be preserved"
          assert_nil @mz.metadata["izvor"]
          assert_equal 12_345, @mz.metadata["povrsina_m2"]
          assert_not @mz.metadata.has_key?("napomena"), "blank napomena should not be persisted"
        end

        test "editing does not touch the boundary" do
          @mz.update!(boundary: { "type" => "Polygon", "coordinates" => [] })
          sign_in @admin
          patch "/admin/bih/local-areas/#{@mz.id}", params: {
            local_area: { predsjednik: "X", boundary: { "type" => "Point" } },
            approval_rationale: "Kontakt ažuriran bez izmjene granice"
          }

          assert_response :redirect
          @mz.reload
          assert_equal "Polygon", @mz.boundary["type"]
        end

        test "a changing local-area save requires an approval rationale" do
          sign_in @admin
          patch "/admin/bih/local-areas/#{@mz.id}", params: {
            local_area: { predsjednik: "Bez odobrenja" }
          }

          assert_response :unprocessable_entity
          assert_includes response.body, I18n.t("decidim.bih.admin.local_areas.update.approval_rationale_required")
          assert_nil @mz.reload.predsjednik
        end

        test "an admin cannot edit another organization's area" do
          other = create_organization
          foreign = Decidim::Bih::LocalArea.create!(
            decidim_organization_id: other.id,
            kind: "mz", slug: "tudja", name: { "sr" => "Tuđa" }, predsjednik: "Original"
          )
          sign_in @admin
          patch "/admin/bih/local-areas/#{foreign.id}", params: {
            local_area: { predsjednik: "Napadač" },
            approval_rationale: "Ne smije proći"
          }

          assert_response :redirect
          assert_redirected_to "/admin/bih/local-areas"
          assert_equal "Original", foreign.reload.predsjednik
        end

        test "editing a non-existent area redirects, not 500" do
          sign_in @admin
          get "/admin/bih/local-areas/999999/edit"

          assert_response :redirect
          assert_redirected_to "/admin/bih/local-areas"
        end

        test "update rejects a missing CSRF token when forgery protection is on" do
          sign_in @admin
          with_forgery_protection do
            patch "/admin/bih/local-areas/#{@mz.id}", params: {
              local_area: { predsjednik: "CSRF" }
            }
          end
          assert_response :unprocessable_entity
        end

        private

        def with_forgery_protection
          previous = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = true
          yield
        ensure
          ActionController::Base.allow_forgery_protection = previous
        end
      end
    end
  end
end
