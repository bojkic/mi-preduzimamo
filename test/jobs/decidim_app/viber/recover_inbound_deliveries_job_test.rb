# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Viber
    class RecoverInboundDeliveriesJobTest < ActiveJob::TestCase
      setup do
        @organization = create_organization
      end

      test "re-enqueues pending and stale-processing receipts without private job arguments" do
        pending = delivery(message_id: "pending")
        stale = delivery(message_id: "stale")
        stale.update_columns( # rubocop:disable Rails/SkipsModelValidations
          state: "processing",
          updated_at: Decidim::Bih::Viber::InboundDelivery::STALE_PROCESSING_AFTER.ago - 1.minute
        )

        assert_enqueued_jobs 2, only: ProcessInboundDeliveryJob do
          RecoverInboundDeliveriesJob.perform_now
        end

        arguments = enqueued_jobs.filter_map do |job|
          job[:args] if job[:job] == ProcessInboundDeliveryJob
        end
        assert_equal [[pending.id], [stale.id]], arguments.sort
        assert_equal "failed", stale.reload.state
        assert_equal "StaleProcessing", stale.error_class
        assert_not_includes arguments.to_json, "private-sender"
      end

      test "deletes expired encrypted receipts and does not retry exhausted rows" do
        expired = delivery(message_id: "expired")
        expired.update_columns(expires_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations
        exhausted = delivery(message_id: "exhausted")
        exhausted.update_columns(state: "failed", attempts: 5) # rubocop:disable Rails/SkipsModelValidations

        assert_no_enqueued_jobs only: ProcessInboundDeliveryJob do
          RecoverInboundDeliveriesJob.perform_now
        end

        assert_not Decidim::Bih::Viber::InboundDelivery.exists?(expired.id)
        assert Decidim::Bih::Viber::InboundDelivery.exists?(exhausted.id)
      end

      test "does not purge an expired receipt while a fresh worker claim is active" do
        active = delivery(message_id: "expired-active")
        active.update_columns( # rubocop:disable Rails/SkipsModelValidations
          state: "processing",
          expires_at: 1.minute.ago,
          updated_at: 1.minute.ago
        )
        stale = delivery(message_id: "expired-stale")
        stale.update_columns( # rubocop:disable Rails/SkipsModelValidations
          state: "processing",
          expires_at: 1.minute.ago,
          updated_at: Decidim::Bih::Viber::InboundDelivery::STALE_PROCESSING_AFTER.ago - 1.minute
        )

        RecoverInboundDeliveriesJob.perform_now

        assert Decidim::Bih::Viber::InboundDelivery.exists?(active.id)
        assert_not Decidim::Bih::Viber::InboundDelivery.exists?(stale.id)
      end

      test "scrubs due effect payloads on the five-minute sweep even before a worker claim is stale" do
        effect_delivery = due_effect_delivery(message_id: "effect-scrub", deadline: 1.minute.ago)
        effect_delivery.update_columns(updated_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations

        RecoverInboundDeliveriesJob.perform_now

        effects = Decidim::Bih::Viber::InboundDelivery.decrypt_effects(
          effect_delivery.reload.encrypted_effects
        )
        assert_equal [Decidim::Bih::DurableEffects.tombstone], effects
        assert_equal "processing", effect_delivery.state
        assert_equal 0, effect_delivery.effects_cursor
      end

      test "drains due effect payloads across ordered query batches" do
        deliveries = [3, 1, 2].map do |minutes_ago|
          due_effect_delivery(message_id: "effect-batch-#{minutes_ago}", deadline: minutes_ago.minutes.ago)
        end
        job = RecoverInboundDeliveriesJob.new

        job.stub(:scrub_batch_size, 2) do
          job.send(:scrub_due_effect_payloads)
        end

        deliveries.each do |effect_delivery|
          effects = Decidim::Bih::Viber::InboundDelivery.decrypt_effects(
            effect_delivery.reload.encrypted_effects
          )
          assert_equal [Decidim::Bih::DurableEffects.tombstone], effects
          assert_nil effect_delivery.next_effect_scrub_at
        end
      end

      test "fails loudly after scrubbing the oldest deadlines when the safety cap is exceeded" do
        oldest = due_effect_delivery(message_id: "effect-cap-oldest", deadline: 3.minutes.ago)
        newer = due_effect_delivery(message_id: "effect-cap-newer", deadline: 1.minute.ago)
        job = RecoverInboundDeliveriesJob.new

        error = assert_raises(RecoverInboundDeliveriesJob::EffectScrubBacklogError) do
          job.stub(:scrub_batch_size, 1) do
            job.stub(:scrub_max_rows, 1) do
              job.send(:scrub_due_effect_payloads)
            end
          end
        end

        assert_equal "due effect scrub backlog exceeds safety cap", error.message
        assert_equal [Decidim::Bih::DurableEffects.tombstone],
                     Decidim::Bih::Viber::InboundDelivery.decrypt_effects(oldest.reload.encrypted_effects)
        assert_not_equal [Decidim::Bih::DurableEffects.tombstone],
                         Decidim::Bih::Viber::InboundDelivery.decrypt_effects(newer.reload.encrypted_effects)
      end

      test "discards an unreadable effects envelope without starving later privacy scrubs" do
        poison = due_effect_delivery(message_id: "effect-poison", deadline: 3.minutes.ago)
        poison.update_columns(encrypted_effects: "unreadable-private-ciphertext") # rubocop:disable Rails/SkipsModelValidations
        later = due_effect_delivery(message_id: "effect-after-poison", deadline: 1.minute.ago)
        provider_message_key = poison.provider_message_key

        error = assert_raises(RecoverInboundDeliveriesJob::EffectScrubCorruptionError) do
          RecoverInboundDeliveriesJob.perform_now
        end

        assert_equal "unreadable effect envelopes discarded", error.message
        poison.reload
        assert_equal "discarded", poison.state
        assert_equal "complete", poison.phase
        assert_equal "UnreadableEffects", poison.error_class
        assert_nil poison.encrypted_payload
        assert_nil poison.encrypted_effects
        assert_nil poison.next_effect_scrub_at
        assert_nil poison.sender_digest
        assert_equal provider_message_key, poison.provider_message_key

        effects = Decidim::Bih::Viber::InboundDelivery.decrypt_effects(later.reload.encrypted_effects)
        assert_equal [Decidim::Bih::DurableEffects.tombstone], effects
        assert_nil later.next_effect_scrub_at
      end

      test "dispatches abandoned external-chat receipts only to the guidance processor" do
        whatsapp = external_delivery(message_id: "whatsapp-pending")

        RecoverInboundDeliveriesJob.perform_now

        matching_jobs = enqueued_jobs.filter do |job|
          Array(job[:args]).first == whatsapp.id
        end
        assert_equal 1, matching_jobs.length
        assert_equal DecidimApp::Infobip::ProcessInboundDeliveryJob, matching_jobs.first[:job]
        assert_not_equal DecidimApp::Viber::ProcessInboundDeliveryJob, matching_jobs.first[:job]
      end

      test "the Viber processor refuses a non-Viber receipt" do
        whatsapp = external_delivery(message_id: "wrong-viber-handler")
        called = false

        DecidimApp::Bijeljina::Concierge.stub(:process_message, ->(*) { called = true }) do
          DecidimApp::Viber::ProcessInboundDeliveryJob.perform_now(whatsapp.id)
        end

        assert_not called
        assert_equal "pending", whatsapp.reload.state
        assert_equal 0, whatsapp.attempts
      end

      private

      def delivery(message_id:)
        message = Decidim::Bih::Viber::InboundMessage.parse(
          "results" => [{
            "from" => "private-sender",
            "messageId" => message_id,
            "message" => { "type" => "TEXT", "text" => "Private body" }
          }]
        )
        Decidim::Bih::Viber::InboundDelivery.accept!(organization: @organization, message: message)
      end

      def external_delivery(message_id:)
        message = Decidim::Bih::Infobip::InboundMessage.parse(
          {
            "integrationType" => "WHATSAPP",
            "contact" => { "userId" => "private-whatsapp-sender" },
            "to" => "configured-whatsapp-account",
            "messageId" => message_id,
            "message" => { "type" => "TEXT", "text" => "Private body" }
          },
          route_channel: "whatsapp"
        )
        Decidim::Bih::Viber::InboundDelivery.accept!(organization: @organization, message: message)
      end

      def due_effect_delivery(message_id:, deadline:)
        delivery(message_id:).tap do |effect_delivery|
          effect_delivery.update!(
            state: "processing",
            phase: "effects",
            encrypted_payload: nil,
            encrypted_effects: Decidim::Bih::Viber::InboundDelivery.encrypt_effects(
              [{
                "type" => "active_job",
                "job_class" => "Decidim::Bih::ReportProcessingJob",
                "arguments" => [123],
                "deadline_at_ms" => (deadline.to_f * 1000).to_i
              }]
            ),
            effects_count: 1,
            effects_cursor: 0,
            next_effect_scrub_at: deadline
          )
        end
      end
    end
  end
end
