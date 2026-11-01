# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class GiftsPageTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
      end

      test "GET podrzi explains point gifts are not money votes or ranking boosts" do
        get "/biceriseno/podrzi"
        assert_redirected_to %r{/biceriseno/zajednistvo\?locale=sr&tab=podrzi\z}
        follow_redirect!

        assert_response :success
        assert_includes response.body, "Poklonjeni bodovi"
        assert_includes response.body, "nisu novac"
        assert_includes response.body, "rangiranje prijedloga"
      end

      test "GET podrzi does not offer blocked or deleted groups as recipients" do
        active_group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                            name: "Aktivna grupa",
                                                            extended_data: { "group" => true })
        blocked_group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                             name: "Blokirana grupa",
                                                             blocked: true, blocked_at: Time.current,
                                                             extended_data: { "group" => true })
        deleted_group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                             name: "Obrisana grupa",
                                                             deleted_at: Time.current,
                                                             extended_data: { "group" => true })
        create_profile("Aktivna grupa", "aktivna-grupa", active_group)
        create_profile("Blokirana grupa", "blokirana-grupa", blocked_group)
        create_profile("Obrisana grupa", "obrisana-grupa", deleted_group)

        get "/biceriseno/podrzi"
        assert_redirected_to %r{/biceriseno/zajednistvo\?locale=sr&tab=podrzi\z}
        follow_redirect!

        assert_response :success
        assert_includes response.body, "Aktivna grupa"
        assert_not_includes response.body, "Blokirana grupa"
        assert_not_includes response.body, "Obrisana grupa"
      end

      test "POST podrzi by signed-in user from another organization is treated as anonymous" do
        recipient_group = FactoryBot.create(:user, :confirmed,
                                            organization: @organization,
                                            name: "Primaoci bodova",
                                            extended_data: { "group" => true })
        recipient = create_profile("Primaoci bodova", "primaoci-bodova", recipient_group)
        other_organization = create_organization
        outsider = FactoryBot.create(:user, :confirmed, organization: other_organization)
        ledger = Decidim::Bih::Goodwill::Ledger.new
        ledger.award(outsider, 100, reason: "proposal")

        sign_in outsider

        assert_no_difference("Decidim::Bih::Goodwill::Transaction.count") do
          post "/biceriseno/podrzi", params: { recipient_id: recipient.id, amount: 20 }
        end

        assert_response :redirect
        assert_equal 100, ledger.account_for(outsider).balance
        assert_equal 0, ledger.account_for(recipient_group).balance
      end

      test "gift preview spends nothing and signed confirmation replays exactly once" do
        citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        group = FactoryBot.create(:user, :confirmed, organization: @organization, extended_data: { "group" => true })
        recipient = create_profile("Komšije", "gift-confirm", group)
        ledger = Goodwill::Ledger.new
        ledger.award(citizen, 100, reason: "volunteer_hour")
        sign_in citizen
        assert_no_difference("Decidim::Bih::Goodwill::Transaction.count") do
          post "/biceriseno/podrzi", params: { recipient_id: recipient.id, amount: 20, request_key: SecureRandom.uuid }
        end
        assert_response :success
        confirmation = Capybara.string(response.body).find('input[name="confirmation"]', visible: false)[:value]
        2.times { post "/biceriseno/podrzi", params: { confirmation:, recipient_id: citizen.id, amount: 99 } }
        assert_equal 80, ledger.account_for(citizen).reload.balance
        assert_equal 20, ledger.account_for(Goodwill::PartnerOwner.owner_for(recipient)).reload.balance
        assert_equal 100, ledger.account_for(citizen).contribution_score
      end

      test "tampered and expired gift confirmation cannot transfer points" do
        citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        group = FactoryBot.create(:user, :confirmed, organization: @organization, extended_data: { "group" => true })
        recipient = create_profile("Komšije", "gift-expiry", group)
        ledger = Goodwill::Ledger.new
        ledger.award(citizen, 100, reason: "volunteer_hour")
        sign_in citizen
        post "/biceriseno/podrzi", params: { recipient_id: recipient.id, amount: 20, request_key: SecureRandom.uuid }
        confirmation = Capybara.string(response.body).find('input[name="confirmation"]', visible: false)[:value]
        assert_no_difference("Decidim::Bih::Goodwill::Transaction.count") do
          post "/biceriseno/podrzi", params: { confirmation: "#{confirmation}x" }
          travel 16.minutes do
            post "/biceriseno/podrzi", params: { confirmation: }
          end
        end
        assert_equal 100, ledger.account_for(citizen).reload.balance
      end

      private

      def create_profile(display_name, slug, legacy_group)
        Decidim::Bih::PartnerProfile.create!(
          organization: @organization,
          display_name:,
          slug:,
          kind: "association",
          verification_status: "verified",
          legacy_user_group: legacy_group,
          verified_at: Time.current
        )
      end
    end
  end
end
