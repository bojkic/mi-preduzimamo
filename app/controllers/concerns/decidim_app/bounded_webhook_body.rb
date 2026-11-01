# frozen_string_literal: true

module DecidimApp
  # Rejects oversized provider callbacks before Rails parses or persists them.
  # The limit is deliberately well below the host's general upload allowance;
  # messaging webhooks contain bounded JSON primitives, never file uploads.
  module BoundedWebhookBody
    # Accommodates the parser's bounded 2,000-item provider bucket even when
    # individual text/media fields approach their limits, while remaining far
    # below the host's general 100 MB upload allowance.
    MAX_WEBHOOK_BODY_BYTES = 16.megabytes

    private

    def webhook_body_too_large?
      declared = request.content_length.to_i
      return true if declared > MAX_WEBHOOK_BODY_BYTES
      return false if declared.positive?

      # Chunked requests have no Content-Length. Sample one byte beyond the
      # bound and rewind so Rails can parse an accepted JSON body normally.
      sample = request.body.read(MAX_WEBHOOK_BODY_BYTES + 1).to_s
      request.body.rewind
      sample.bytesize > MAX_WEBHOOK_BODY_BYTES
    end

    def reject_oversized_webhook
      return false unless webhook_body_too_large?

      head :payload_too_large
      true
    end
  end
end
