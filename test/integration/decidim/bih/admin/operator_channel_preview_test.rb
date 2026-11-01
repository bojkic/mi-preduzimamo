# frozen_string_literal: true

require "test_helper"
require "nokogiri"

module Decidim
  module Bih
    module Admin
      class OperatorChannelPreviewTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in @admin
          @attributes = { recipient_id: @citizen.id, subject: "Okupljanje komšija", body: "Sastanak je u subotu.", external_copy: "1", message_reviewed: "1" }
        end

        test "external copies need a preview of the exact recipient and content" do
          assert_no_difference -> { OperatorMessage.count } do
            post "/admin/bih/messages", params: @attributes
          end
          assert_response :unprocessable_entity

          assert_no_difference -> { OperatorMessage.count } do
            post "/admin/bih/messages", params: @attributes.merge(delivery_preview: "1")
          end
          assert_response :success
          token = Nokogiri::HTML(response.body).at_css('input[name="delivery_token"]')["value"]
          assert_no_difference -> { OperatorMessage.count } do
            post "/admin/bih/messages", params: @attributes.merge(delivery_token: token, body: "Promijenjena poruka")
          end
          assert_response :unprocessable_entity
          assert_difference -> { OperatorMessage.count }, 1 do
            post "/admin/bih/messages", params: @attributes.merge(delivery_token: token)
          end
          assert_response :redirect
          assert_no_difference -> { OperatorMessage.count } do
            post "/admin/bih/messages", params: @attributes.merge(delivery_token: token)
          end
        end

        test "operator message and external intent are atomic and recover after queue failure" do
          attributes = { organization: @organization, sender: @admin, recipient: @citizen, subject: "Novost", body: "Detalji",
                         external_notification: { topic: :community_news, text: "Detalji", deduplication_key: "operator-durable-test" } }
          AccountNotifications.stub(:enqueue!, ->(**_kwargs) { raise ActiveRecord::RecordInvalid }) do
            assert_no_difference -> { OperatorMessage.count } do
              assert_raises(ActiveRecord::RecordInvalid) { OperatorMessenger.call(**attributes) }
            end
          end
          AccountNotificationJob.stub(:perform_later, ->(*) { raise IOError, "queue unavailable" }) do
            assert_difference -> { OperatorMessage.count }, 1 do
              assert_difference -> { AccountNotification.count }, 1 do
                OperatorMessenger.call(**attributes)
              end
            end
          end
          assert_no_difference -> { OperatorMessage.count } do
            assert_no_difference -> { AccountNotification.count } do
              OperatorMessenger.call(**attributes)
            end
          end
        end

        test "preview cannot resolve a recipient from another organization" do
          outsider = FactoryBot.create(:user, :confirmed, organization: create_organization)
          assert_no_difference -> { AccountNotification.count } do
            post "/admin/bih/messages", params: @attributes.merge(recipient_id: outsider.id, delivery_preview: "1")
          end
          assert_response :redirect
        end
      end
    end
  end
end
