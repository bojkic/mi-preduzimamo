# frozen_string_literal: true

require "test_helper"
require "capybara"
require_relative "../../../support/komsiluk_notice_source_fixtures"

module Decidim
  module Bih
    class KomsilukNoticeSourceLinksTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      include KomsilukNoticeSourceFixtures

      setup do
        setup_notice_sources
        host! @organization.host
        @original_provider = Komsiluk::NoticeComposer.source_provider
        Komsiluk::NoticeComposer.source_provider = DecidimApp::Bijeljina::KomsilukNoticeSources
        sign_in @admin
      end

      teardown do
        Komsiluk::NoticeComposer.source_provider = @original_provider
      end

      test "reviewed report detail links to composer with identity only" do
        report = reviewed_report
        get "/admin/bih/reports/#{report.reference}"
        assert_response :success
        assert_select "a[data-prepare-board-notice='report']" do |links|
          uri = URI.parse(links.first["href"])
          assert_equal "/admin/bih/board-notices/new", uri.path
          assert_equal({ "source_kind" => "report", "source_id" => report.id.to_s }, Rack::Utils.parse_nested_query(uri.query))
        end
        report.update!(review_state: "pending")
        get "/admin/bih/reports/#{report.reference}"
        assert_select "a[data-prepare-board-notice]", count: 0
      end

      test "approved current activity detail offers preparation and paused activity does not" do
        activity = public_activity
        get "/admin/bih/volunteering/opportunities/#{activity.id}"
        assert_response :success
        assert_select "a[data-prepare-board-notice='activity']"
        activity.update!(applications_paused_at: Time.current)
        get "/admin/bih/volunteering/opportunities/#{activity.id}"
        assert_select "a[data-prepare-board-notice]", count: 0
      end

      test "public project preparation is limited to authorized staff" do
        project = public_project
        get "/biceriseno/projekti/#{project.id}"
        assert_response :success
        assert_select "a[data-prepare-board-notice='project']"
        sign_out @admin
        get "/biceriseno/projekti/#{project.id}"
        assert_response :success
        assert_select "a[data-prepare-board-notice]", count: 0
      end
    end
  end
end
