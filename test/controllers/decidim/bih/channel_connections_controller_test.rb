# frozen_string_literal: true

require "test_helper"
require "capybara"

class ChannelConnectionsControllerTest < ActionDispatch::IntegrationTest
  include ::Devise::Test::IntegrationHelpers

  setup do
    @organization = create_organization
    host! @organization.host
    @user = FactoryBot.create(:user, :confirmed, organization: @organization)
  end

  test "connection mutations require a signed-in account" do
    assert_no_difference "Decidim::Bih::ChannelConnectionChallenge.count" do
      post "/biceriseno/moj-nalog/kanali", params: { channel: "messenger" }
    end
    assert_response :redirect
  end

  test "confirmation requires chat code and browser initiation" do
    sign_in @user
    Decidim::Bih::ChannelConnections.stub(:configured_sender, "business") do
      post "/biceriseno/moj-nalog/kanali", params: { channel: "messenger" }
      assert_response :success
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_includes response.headers["Cache-Control"], "private"
      assert_equal Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY, response.headers["Referrer-Policy"]
      filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter("channel_confirmation" => "SECRET", "channel_connection_command" => "SECRET")
      assert_equal "[FILTERED]", filtered["channel_confirmation"]
      assert_equal "[FILTERED]", filtered["channel_connection_command"]
      assert_select "textarea[name=channel_connection_command][readonly]", /POVEZI [a-f0-9]{32}/
      assert_select "input[name=channel_confirmation]"
      post "/biceriseno/moj-nalog/kanali/potvrdi", params: { channel_confirmation: "not-a-proof" }
      assert_response :redirect
      assert_equal 0, Decidim::Bih::ChannelConnection.count
    end
  end

  test "connection wording is available directly in Bosnian and Croatian" do
    %w(bs hr).each do |locale|
      assert I18n.exists?("decidim.bih.channel_connections.title", locale, fallback: false)
      assert I18n.exists?("decidim.bih.channel_connections.command_label", locale, fallback: false)
    end
  end

  test "disabled channels cannot initiate linking" do
    sign_in @user
    Decidim::Bih::ChannelConnections.stub(:configured_sender, nil) do
      assert_no_difference "Decidim::Bih::ChannelConnectionChallenge.count" do
        post "/biceriseno/moj-nalog/kanali", params: { channel: "instagram" }
      end
      assert_response :redirect
    end
  end
end
