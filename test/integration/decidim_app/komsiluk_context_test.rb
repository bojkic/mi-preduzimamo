# frozen_string_literal: true

require "test_helper"
require "capybara"
require_relative "../../support/synthetic_service_directory"

module DecidimApp
  class KomsilukContextTest < ActionDispatch::IntegrationTest
    include ::Devise::Test::IntegrationHelpers
    include SyntheticServiceDirectory

    setup do
      @organization = create_organization
      host! @organization.host
      @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "context-board", name: { sr: "Moj komšiluk" })
      @profile = Decidim::Bih::CitizenProfile.for_user(@user, organization: @organization)
      @profile.assign_komsiluk!(@area, source: "dropdown")
      @post = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @area, category: "general",
                                                 title: "Private notice title", body: "Private content never in query parameters")
    end

    test "private Milica reference requires login and current board membership" do
      get komsiluk_notice_help_path(@post)
      assert_response :redirect
      assert_not_includes response.body, @post.body
      sign_in @user
      get komsiluk_notice_help_path(@post)
      assert_response :success
      assert_select "button[data-mi-chat-open][data-mi-chat-draft]", count: 1
      assert_not_includes response.body, @post.body
      assert_select "a[href*=Private]", count: 0
      other = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "other-context", name: { sr: "Drugi" })
      @profile.assign_komsiluk!(other, source: "dropdown")
      get komsiluk_notice_help_path(@post)
      assert_response :not_found
    end

    test "an updating linked notice does not offer Milica its old wording" do
      sign_in @user
      DecidimApp::Bijeljina::KomsilukNoticePublicSource.stub(:call, { updating: true, url: nil }) do
        get komsiluk_notice_help_path(@post)
      end
      assert_response :redirect
      assert_not_includes response.body, @post.title
      assert_not_includes response.body, @post.body
    end

    test "hidden source content cannot be read through a help link" do
      sign_in @user
      @post.update!(status: "hidden")
      get komsiluk_notice_help_path(@post)
      assert_response :not_found
      assert_not_includes response.body, @post.title
    end

    test "reviewed directory opens from board context without publishing anything" do
      install_synthetic_service_directory
      sign_in @user
      assert_no_difference ["Decidim::Bih::KomsilukPost.count", "Decidim::Bih::Report.count"] do
        get komsiluk_services_path
      end
      assert_response :success
      assert_select "details[id^=service-]", minimum: 1
      assert_select "main form[action*=prijave]", count: 0
    ensure
      restore_synthetic_service_directory
    end
  end
end
