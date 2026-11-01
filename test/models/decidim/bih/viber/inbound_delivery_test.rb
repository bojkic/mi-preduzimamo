# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Viber
      class InboundDeliveryTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @message = InboundMessage.parse(
            "results" => [{
              "from" => "private-sender",
              "messageId" => "provider-message-1",
              "message" => { "type" => "TEXT", "text" => "Privatna poruka" }
            }]
          )
        end

        test "accept is tenant-scoped and idempotent without storing plaintext" do
          first = InboundDelivery.accept!(organization: @organization, message: @message)
          second = InboundDelivery.accept!(organization: @organization, message: @message)

          assert_equal first.id, second.id
          assert_equal 1, InboundDelivery.where(organization: @organization).count
          serialized = first.attributes.to_json
          assert_not_includes serialized, "private-sender"
          assert_not_includes serialized, "Privatna poruka"
          assert_equal 64, first.provider_message_key.length
          assert_equal 64, first.sender_digest.length
        end

        test "successful processing clears the encrypted envelope and sender digest" do
          delivery = InboundDelivery.accept!(organization: @organization, message: @message)
          received = nil

          result = delivery.process!(handler: ->(message) { received = message })

          assert_equal :processed, result
          assert_equal "Privatna poruka", received.text
          assert_equal "processed", delivery.reload.state
          assert_nil delivery.encrypted_payload
          assert_nil delivery.sender_digest
          assert_equal 1, delivery.attempts
          assert_not_nil delivery.processed_at
        end

        test "failed processing keeps the encrypted envelope for retry and stores only the error class" do
          delivery = InboundDelivery.accept!(organization: @organization, message: @message)

          error = assert_raises(StandardError) do
            delivery.process!(handler: ->(*) { raise StandardError, "token=secret private-sender" })
          end

          assert_equal "token=secret private-sender", error.message
          assert_equal "failed", delivery.reload.state
          assert_equal "StandardError", delivery.error_class
          assert delivery.encrypted_payload.present?
          assert_not_includes delivery.attributes.to_json, "token=secret"
          assert delivery.enqueueable?
        end

        test "same provider id is independent across organizations" do
          other = create_organization

          assert_difference("InboundDelivery.count", 2) do
            InboundDelivery.accept!(organization: @organization, message: @message)
            InboundDelivery.accept!(organization: other, message: @message)
          end
        end

        test "later receipt detects an earlier unfinished receipt from the same channel sender" do
          earlier = external_delivery(message_id: "ordered-1")
          later = external_delivery(message_id: "ordered-2")

          assert_not earlier.earlier_unfinished_for_sender?
          assert later.earlier_unfinished_for_sender?
        end

        test "received time then id determines sender order deterministically" do
          earlier = external_delivery(message_id: "same-time-1")
          later = external_delivery(message_id: "same-time-2")
          received_at = Time.current.change(usec: 0)
          earlier.update_columns(received_at:) # rubocop:disable Rails/SkipsModelValidations
          later.update_columns(received_at:) # rubocop:disable Rails/SkipsModelValidations

          assert_not earlier.reload.earlier_unfinished_for_sender?
          assert later.reload.earlier_unfinished_for_sender?
        end

        test "sender ordering ignores processed exhausted and expired receipts but blocks active processing" do
          earlier = external_delivery(message_id: "state-1")
          later = external_delivery(message_id: "state-2")

          earlier.update_columns(state: "processing", attempts: InboundDelivery::MAX_ATTEMPTS) # rubocop:disable Rails/SkipsModelValidations
          assert later.earlier_unfinished_for_sender?

          earlier.update_columns(state: "failed", attempts: InboundDelivery::MAX_ATTEMPTS) # rubocop:disable Rails/SkipsModelValidations
          assert_not later.earlier_unfinished_for_sender?

          earlier.update_columns(state: "pending", attempts: 0, expires_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations
          assert_not later.earlier_unfinished_for_sender?

          earlier.update_columns(state: "processed", expires_at: 1.day.from_now) # rubocop:disable Rails/SkipsModelValidations
          assert_not later.earlier_unfinished_for_sender?
        end

        test "sender ordering is scoped by organization channel and sender digest" do
          external_delivery(message_id: "scope-source")
          other_organization = create_organization

          assert_not external_delivery(
            message_id: "different-sender",
            sender: "different-private-sender"
          ).earlier_unfinished_for_sender?
          assert_not external_delivery(
            message_id: "different-channel",
            channel: "messenger"
          ).earlier_unfinished_for_sender?
          assert_not external_delivery(
            message_id: "different-organization",
            organization: other_organization
          ).earlier_unfinished_for_sender?
        end

        private

        def external_delivery(message_id:, sender: "private-whatsapp-sender", channel: "whatsapp",
                              organization: @organization)
          message = Decidim::Bih::Infobip::InboundMessage.parse(
            {
              "integrationType" => channel.upcase,
              "contact" => { "userId" => sender },
              "to" => "configured-#{channel}-sender",
              "messageId" => message_id,
              "message" => { "type" => "TEXT", "text" => "Private body" }
            },
            route_channel: channel
          )
          InboundDelivery.accept!(organization:, message:)
        end
      end
    end
  end
end
