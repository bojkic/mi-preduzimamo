# frozen_string_literal: true

module DecidimApp
  module Viber
    # Re-enqueues durable messaging receipts left pending by a queue outage and
    # processing rows abandoned by a worker restart. Viber and external chat
    # receipts are dispatched to distinct processors. It also removes envelopes
    # whose fixed seven-day retry window has elapsed.
    class RecoverInboundDeliveriesJob < ApplicationJob
      self.log_arguments = false

      queue_as :integrations

      BATCH_SIZE = 200
      SCRUB_BATCH_SIZE = 200
      SCRUB_MAX_ROWS = 10_000
      EffectScrubBacklogError = Class.new(StandardError)
      EffectScrubCorruptionError = Class.new(StandardError)

      def perform
        Decidim::Bih::AccountNotifications.recover_pending!
        Decidim::Bih::Komsiluk::NoticePublishing.recover_pending!
        DecidimApp::Bijeljina::CityServiceEffect.recover_pending!
        DecidimApp::Bijeljina::CityServiceFallbackJob.recover_pending!
        discarded_effect_envelopes = scrub_due_effect_payloads
        purge_expired_receipts

        Decidim::Bih::Viber::InboundDelivery.recovery_candidates.limit(BATCH_SIZE).find_each do |delivery|
          job = processing_job(delivery)
          next unless job
          next unless delivery.recoverable_for_enqueue!

          job.perform_later(delivery.id)
        end

        return unless discarded_effect_envelopes.positive?

        Rails.logger.error("[Inbound delivery recovery] unreadable effect envelopes discarded")
        raise EffectScrubCorruptionError, "unreadable effect envelopes discarded"
      end

      private

      # Effect payloads can have much shorter privacy deadlines than the
      # seven-day provider-message replay receipt. Scan a bounded set of live
      # effects rows every five minutes so a fresh/stuck worker cannot retain
      # expired chat context, OTP material, or reply ciphertext until the
      # 15-minute stale-claim threshold. Drain oldest deadlines in small query
      # batches; if the hard safety cap is exceeded, fail the cron run loudly
      # instead of silently reporting a successful retention sweep. Row
      # locking/fencing lives in the model.
      def scrub_due_effect_payloads
        cutoff = Time.current
        visited = 0
        discarded = 0

        loop do
          remaining_capacity = scrub_max_rows - visited
          break unless remaining_capacity.positive?

          ids = due_effect_payloads(cutoff)
                .limit([scrub_batch_size, remaining_capacity].min)
                .pluck(:id)
          break if ids.empty?

          ids.each do |id|
            result = Decidim::Bih::Viber::InboundDelivery.find_by(id:)&.scrub_expired_effects!(now: cutoff)
            discarded += 1 if result == :discarded
          end
          visited += ids.size
        end

        return discarded unless due_effect_payloads(cutoff).exists?

        Rails.logger.error("[Inbound delivery recovery] due effect scrub backlog exceeds safety cap")
        raise EffectScrubBacklogError, "due effect scrub backlog exceeds safety cap"
      end

      def due_effect_payloads(cutoff)
        Decidim::Bih::Viber::InboundDelivery
          .where(phase: "effects", next_effect_scrub_at: ..cutoff)
          .where.not(encrypted_effects: nil)
          .reorder(next_effect_scrub_at: :asc, id: :asc)
      end

      def scrub_batch_size
        SCRUB_BATCH_SIZE
      end

      def scrub_max_rows
        SCRUB_MAX_ROWS
      end

      # Never delete a live claim at the retention boundary. A currently
      # processing row may have committed its civic handler and still own
      # outbound effects. Only non-processing or demonstrably stale claims are
      # eligible for purge; stale workers are fenced by their claim generation.
      def purge_expired_receipts
        delivery = Decidim::Bih::Viber::InboundDelivery
        delivery.expired.where.not(state: "processing").delete_all
        delivery.expired
                .where(state: "processing")
                .where(updated_at: ...delivery::STALE_PROCESSING_AFTER.ago)
                .delete_all
      end

      def processing_job(delivery)
        return DecidimApp::Viber::ProcessInboundDeliveryJob if delivery.channel.to_s == "viber"
        return DecidimApp::Infobip::ProcessInboundDeliveryJob if
          Decidim::Bih::Infobip::InboundMessage::CHANNELS.include?(delivery.channel.to_s)

        Rails.logger.warn("[Inbound delivery recovery] unsupported delivery channel")
        nil
      end
    end
  end
end
