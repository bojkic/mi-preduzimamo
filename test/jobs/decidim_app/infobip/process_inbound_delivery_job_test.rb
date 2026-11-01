# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Infobip
    class ProcessInboundDeliveryJobTest < ActiveJob::TestCase
      include ActiveJob::TestHelper

      setup do
        clear_enqueued_jobs
        clear_performed_jobs
        @organization = create_organization
      end

      test "later same-sender receipt is deferred without being claimed or exposing identity" do
        external_delivery(message_id: "job-order-1")
        later = external_delivery(message_id: "job-order-2")

        assert_enqueued_with(job: ProcessInboundDeliveryJob, args: [later.id]) do
          ProcessInboundDeliveryJob.perform_now(later.id)
        end

        assert_equal "pending", later.reload.state
        assert_equal 0, later.attempts
        serialized_arguments = enqueued_jobs.filter_map do |job|
          job[:args] if job[:job] == ProcessInboundDeliveryJob
        end.to_json
        assert_includes serialized_arguments, later.id.to_s
        assert_not_includes serialized_arguments, "private-whatsapp-sender"
        assert_not_includes serialized_arguments, "Private body"
      end

      test "later receipt processes after the earlier receipt becomes terminal" do
        earlier = external_delivery(message_id: "job-terminal-1")
        later = external_delivery(message_id: "job-terminal-2")
        earlier.update_columns( # rubocop:disable Rails/SkipsModelValidations
          state: "processed",
          processed_at: Time.current,
          encrypted_payload: nil,
          sender_digest: nil
        )
        received = nil

        DecidimApp::Bijeljina::ExternalChatConcierge.stub(:call, ->(**args) { received = args.fetch(:message) }) do
          ProcessInboundDeliveryJob.perform_now(later.id)
        end

        assert_equal "processed", later.reload.state
        assert_equal "Private body", received.text
      end

      test "different sender is not blocked by an earlier receipt" do
        external_delivery(message_id: "job-sender-1")
        later = external_delivery(message_id: "job-sender-2", sender: "another-private-sender")
        called = false

        DecidimApp::Bijeljina::ExternalChatConcierge.stub(:call, ->(**) { called = true }) do
          ProcessInboundDeliveryJob.perform_now(later.id)
        end

        assert called
        assert_equal "processed", later.reload.state
      end

      test "an effects-phase receipt recovers without rebuilding the external handler" do
        delivery = external_delivery(message_id: "chat-effects-only")
        delivery.update!(
          state: "failed",
          phase: "effects",
          encrypted_payload: nil,
          encrypted_effects: nil,
          effects_cursor: 0,
          effects_count: 0
        )

        forbidden = ->(**) { flunk "effects recovery must not rerun the external-chat handler" }
        DecidimApp::Bijeljina::ExternalChatConcierge.stub(:call, forbidden) do
          ProcessInboundDeliveryJob.perform_now(delivery.id)
        end

        assert_equal "processed", delivery.reload.state
        assert_equal "complete", delivery.phase
      end

      private

      def external_delivery(message_id:, sender: "private-whatsapp-sender")
        message = Decidim::Bih::Infobip::InboundMessage.parse(
          {
            "integrationType" => "WHATSAPP",
            "contact" => { "userId" => sender },
            "to" => "configured-whatsapp-sender",
            "messageId" => message_id,
            "message" => { "type" => "TEXT", "text" => "Private body" }
          },
          route_channel: "whatsapp"
        )
        Decidim::Bih::Viber::InboundDelivery.accept!(organization: @organization, message:)
      end
    end
  end
end
