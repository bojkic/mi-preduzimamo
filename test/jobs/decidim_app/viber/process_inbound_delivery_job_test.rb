# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Viber
    class ProcessInboundDeliveryJobTest < ActiveJob::TestCase
      include ActiveJob::TestHelper

      setup do
        clear_enqueued_jobs
        clear_performed_jobs
        @organization = create_organization
      end

      test "later same-sender receipt is deferred without being claimed or exposing identity" do
        viber_delivery(message_id: "viber-order-1")
        later = viber_delivery(message_id: "viber-order-2")

        assert_enqueued_with(job: ProcessInboundDeliveryJob, args: [later.id]) do
          ProcessInboundDeliveryJob.perform_now(later.id)
        end

        assert_equal "pending", later.reload.state
        assert_equal 0, later.attempts
        serialized_arguments = enqueued_jobs.filter_map do |job|
          job[:args] if job[:job] == ProcessInboundDeliveryJob
        end.to_json
        assert_includes serialized_arguments, later.id.to_s
        assert_not_includes serialized_arguments, "private-viber-sender"
        assert_not_includes serialized_arguments, "Private Viber body"
      end

      test "later receipt processes after the earlier receipt becomes terminal" do
        earlier = viber_delivery(message_id: "viber-terminal-1")
        later = viber_delivery(message_id: "viber-terminal-2")
        earlier.update_columns( # rubocop:disable Rails/SkipsModelValidations
          state: "processed",
          processed_at: Time.current,
          encrypted_payload: nil,
          sender_digest: nil
        )
        received = nil

        DecidimApp::Bijeljina::Concierge.stub(:process_message, ->(message) { received = message }) do
          ProcessInboundDeliveryJob.perform_now(later.id)
        end

        assert_equal "processed", later.reload.state
        assert_equal "Private Viber body", received.text
      end

      test "different Viber sender is not blocked by an earlier receipt" do
        viber_delivery(message_id: "viber-sender-1")
        later = viber_delivery(message_id: "viber-sender-2", sender: "other-private-viber-sender")
        called = false

        DecidimApp::Bijeljina::Concierge.stub(:process_message, ->(*) { called = true }) do
          ProcessInboundDeliveryJob.perform_now(later.id)
        end

        assert called
        assert_equal "processed", later.reload.state
      end

      test "an effects-phase receipt recovers without rebuilding the Viber handler" do
        delivery = viber_delivery(message_id: "viber-effects-only")
        delivery.update!(
          state: "failed",
          phase: "effects",
          encrypted_payload: nil,
          encrypted_effects: nil,
          effects_cursor: 0,
          effects_count: 0
        )

        forbidden = ->(*) { flunk "effects recovery must not rerun the Viber handler" }
        DecidimApp::Bijeljina::Concierge.stub(:process_message, forbidden) do
          ProcessInboundDeliveryJob.perform_now(delivery.id)
        end

        assert_equal "processed", delivery.reload.state
        assert_equal "complete", delivery.phase
      end

      private

      def viber_delivery(message_id:, sender: "private-viber-sender")
        message = Decidim::Bih::Viber::InboundMessage.parse(
          "from" => sender,
          "to" => "configured-viber-sender",
          "messageId" => message_id,
          "message" => { "type" => "TEXT", "text" => "Private Viber body" }
        )
        Decidim::Bih::Viber::InboundDelivery.accept!(organization: @organization, message:)
      end
    end
  end
end
