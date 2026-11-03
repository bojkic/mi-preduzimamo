# frozen_string_literal: true

require "test_helper"
require "json"

module Decidim
  module Bih
    module Admin
      class UpgradeLocalizationTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization, admin_terms_accepted_at: Time.current)
          sign_in @admin
        end

        %w(sr sr-Cyrl bs hr).each do |locale|
          test "#{locale} dashboard renders current upstream titles and localized statistics" do
            get "/#{locale}/admin"
            assert_response :success
            assert_select "h1", text: /#{Regexp.escape(I18n.t("decidim.admin.dashboard.show.title", locale:))}/
            assert_select "title", text: /#{Regexp.escape(I18n.t("decidim.admin.dashboard.show.title", locale:))}/
            assert_select "h2", text: I18n.t("decidim.admin.titles.statistics", locale:)
            assert_select "a", text: I18n.t("decidim.admin.admin_terms.show.title", locale:)
            assert_select ".translation_missing", count: 0
          end

          test "#{locale} process forms and navigation use native translations" do
            get "/#{locale}/admin/participatory_processes/new"
            assert_response :success
            %w(
              decidim.participatory_processes.admin.participatory_processes.new.title
              activemodel.attributes.participatory_process.title
              activemodel.attributes.participatory_process.start_date
              decidim.admin.menu.settings
              decidim.forms.upload.labels.validation_error
            ).each do |key|
              assert I18n.exists?(key, locale, fallback: false), "Missing native translation: #{locale}/#{key}"
              assert_includes response.body, I18n.t(key, locale:)
            end
            assert_no_match(/New participatory process|General Information|Title is required!/, response.body)
          end

          test "#{locale} process date inputs receive the complete datepicker dictionary" do
            get "/#{locale}/admin/participatory_processes/new"
            assert_response :success
            assert_select "input[data-controller~='date-picker']", minimum: 2
            assert_select "input[data-controller~='date-picker']" do |inputs|
              inputs.each do |input|
                assert input["data-date-label"].present?
                assert input["data-button-date-label"].present?
                assert_no_match(/undefined|translation missing/i, input["data-button-date-label"])
              end
            end
            config = response.body.match(/Decidim\.config\.set\((\{.*?\})\);/m)
            assert config, "Actual layout must export the JS configuration"
            messages = JSON.parse(config[1]).fetch("messages")
            assert_equal "d-m-y", messages.dig("date", "formats", "order")
            assert_equal ".", messages.dig("date", "formats", "separator")
            assert_equal 24, messages.dig("time", "clock_format")
            %w(date time).each do |kind|
              assert messages.dig(kind, "formats", "help", "#{kind}_format").present?
              assert messages.dig(kind, "buttons", "close").present?
              assert messages.dig(kind, "buttons", "select").present?
            end
          end
        end
      end
    end
  end
end
