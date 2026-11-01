# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Operator resolution can finish extraction of a complete raw document.
    # Reconcile that document, never a guessed pairing of its reordered groups.
    class CityServiceReviewedSourceReconciliation
      def initialize(event)
        @event = event
        @identity = document_identity
        @reconciler = CityServiceSourceReconciler.new(organization: event.organization)
      end

      def with_document_lock
        return yield unless @identity

        @reconciler.with_document_lock(source_key: @event.source_key, document_url: @identity.fetch(:url)) { yield }
      end

      def reconcile!
        return unless @identity
        raise ArgumentError, "reviewed source document changed" unless @identity == document_identity

        source = CityServiceSources.fetch(@event.source_key)
        if @identity.fetch(:kind) == :article
          article = CityServiceArticle::Article.new(source_url: @identity.fetch(:url), content_version: @identity.fetch(:version), complete: true)
          @reconciler.reconcile_article(source:, article:, events: [@event], complete: true)
        else
          @reconciler.reconcile_snapshot(source:, source_url: @identity.fetch(:url), content_version: @identity.fetch(:version),
                                         events: [@event], complete: true)
        end
      end

      private

      def document_identity
        metadata = @event.extraction_metadata
        return unless @event.operator_corrected_facts? && metadata["source_document_complete"] == true

        if metadata["canonical_article_url"].present? && metadata["article_content_version"].present?
          { kind: :article, url: metadata.fetch("canonical_article_url"), version: metadata.fetch("article_content_version") }
        elsif metadata["source_document_url"].present? && metadata["source_document_version"].present?
          { kind: :snapshot, url: metadata.fetch("source_document_url"), version: metadata.fetch("source_document_version") }
        end
      end
    end
  end
end
