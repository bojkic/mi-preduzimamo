# frozen_string_literal: true
require "test_helper"
require "capybara"

module Decidim
  module Bih
    class RewardCertificateTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Željka Test", nickname: "cert_#{SecureRandom.hex(6)}")
        Goodwill::Ledger.new.award(@user, 500, reason: "volunteer_hour")
        sign_in @user
        post "/biceriseno/nagrade/redeem/zahvalnica", params: { redemption_confirmed: "1", redemption_request_key: SecureRandom.uuid }
        @fulfillment = Goodwill::RewardFulfillment.find_by!(user: @user, reward_key: "zahvalnica")
        @path = "/biceriseno/nagrade/zahtjevi/#{@fulfillment.id}/zahvalnica"
      end

      test "private preview is read only and download records one honest handoff" do
        # Input validation rejects HTML names; legacy/corrupt stored values must
        # still be escaped by the private artifact renderer.
        @user.update_column(:name, "Željka <script>unsafe</script>")
        assert_no_difference("Decidim::Bih::Goodwill::RewardFulfillmentEvent.count") { get @path }
        assert_response :success
        assert_equal "requested", @fulfillment.reload.status
        assert_includes response.headers["Cache-Control"], "no-store"
        assert_not_includes response.body, "<script>unsafe</script>"
        assert_includes response.body, "Željka"
        assert_difference("Decidim::Bih::Goodwill::RewardFulfillmentEvent.count", 1) { post @path }
        assert_response :success
        assert_includes response.headers["Content-Disposition"], "attachment"
        assert_equal "fulfilled", @fulfillment.reload.status
        assert_equal "download_requested", @fulfillment.events.order(:id).last.metadata["delivery_evidence"]
        assert_no_difference("Decidim::Bih::Goodwill::RewardFulfillmentEvent.count") { post @path }
      end

      test "other citizens and other tenants cannot read or download the artifact" do
        other = FactoryBot.create(:user, :confirmed, organization: @organization)
        sign_out @user
        sign_in other
        # Commit the changed Warden identity through a successful response.
        # A raised 404 does not commit the integration helper's session cookie.
        get "/biceriseno/moj-doprinos"
        assert_response :success
        assert_equal other.id, @controller.send(:current_user).id
        assert_no_difference("Decidim::Bih::Goodwill::RewardFulfillmentEvent.count") do
          get @path
          assert_response :not_found
          post @path
          assert_response :not_found
        end
        assert_equal "requested", @fulfillment.reload.status

        sign_out other
        sign_in @user
        get "/biceriseno/moj-doprinos"
        assert_response :success
        assert_equal @user.id, @controller.send(:current_user).id
        host! create_organization.host
        assert_no_difference("Decidim::Bih::Goodwill::RewardFulfillmentEvent.count") do
          get @path
          assert_response :not_found
          post @path
          assert_response :not_found
        end
        assert_equal "requested", @fulfillment.reload.status
      end

      test "reversed requests cannot generate a certificate" do
        Goodwill::Ledger.new.reverse(@fulfillment.ledger_transaction)
        get @path
        assert_response :not_found
        post @path
        assert_response :not_found
      end
    end
  end
end
