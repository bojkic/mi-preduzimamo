# frozen_string_literal: true

require "date"
require "uri"
require "active_support/core_ext/time/zones"
require_relative "../service_procedures"

module DecidimApp
  module Bijeljina
    module Milica
      class ProcedureRead
        def initialize(source_store: CityServiceSourceCheckStore.new)
          @source_store = source_store
        end

        def call(card:, locale:, now: Time.current)
          unless valid_card?(card) && card[:review_status] == "reviewed"
            return assessment(card:, now:)
          end

          snapshot = @source_store.snapshot(source_key: "reference:procedure:#{card.fetch(:key)}")
          readiness = assessment(card:, now:, snapshot:)
          return readiness unless readiness.fetch(:status) == "ok"

          source = readiness.fetch(:source)
          validity = readiness.fetch(:validity)
          text = procedure_text(card)
          warnings = %w(reviewed_procedure_not_form_submission unspecified_fees_documents_deadlines_remain_unknown)
          warnings << "procedure_text_truncated_use_structured_steps" if text.length > 1_000
          warnings.concat(readiness.fetch(:warnings))
          text = Decidim::Bih::Transliterator.call(text) if locale == "sr-Cyrl"
          { status: "ok", source:, validity:, warnings:, facts: [{
            "id" => source.fetch("id"), "kind" => "service_procedure", "text" => text[0, 1_000],
            "source_id" => source.fetch("id"), "source_label" => source.fetch("label"), "source_url" => source.fetch("url"),
            "reviewed_on" => validity.fetch("reviewed_on"), "required_documents" => card[:required_documents],
            "processing_time" => card[:processing_time], "fee" => normalized_fee(card[:fee]),
            "steps" => card.fetch(:steps), "channel" => card[:channel], "document_kind" => card[:document_kind],
            "delivery" => card[:delivery], "fee_exemptions" => card[:fee_exemptions],
            "form_download_url" => card[:form_download_url],
            "provider_procedure_code" => card[:provider_procedure_code], "source_page_id" => card[:source_page_id],
            "legal_basis" => card[:legal_basis], "current_legal_status" => card[:current_legal_status],
            "warning_codes" => warnings,
            "coverage" => { "scope" => card.fetch(:location_scope), "eligibility" => card[:eligibility] }
          }] }
        rescue ArgumentError, KeyError, TypeError, URI::InvalidURIError
          { status: "unavailable", warnings: ["procedure_configuration_invalid"] }
        end

        # Shared, side-effect-free eligibility policy. Health supplies its
        # already-read snapshot; no DB lookup, translation or prose is built.
        def assessment(card:, now:, snapshot: nil)
          return { status: "unavailable", warnings: ["procedure_configuration_invalid"] } unless valid_card?(card)
          return { status: "unreviewed", warnings: ["procedure_review_not_approved"] } unless card[:review_status] == "reviewed"

          source = { "id" => "procedure:#{card.fetch(:key)}", "label" => card.fetch(:owner), "url" => card.fetch(:source_url) }
          status = snapshot&.check_payload&.fetch("status", nil)
          checked_on = Date.iso8601(card.fetch(:source_checked_on))
          day = now.in_time_zone("Europe/Sarajevo").to_date
          first_day = Date.iso8601(card[:effective_from]) if card[:effective_from]
          last_day = Date.iso8601(card[:effective_until]) if card[:effective_until]
          validity = { "reviewed_on" => checked_on.iso8601, "effective_from" => card[:effective_from], "effective_until" => card[:effective_until] }.compact
          return { status: "unreviewed", source:, validity:, warnings: ["procedure_source_changed_review_required"] } if review_blocked?(snapshot, card, status)
          return { status: "stale", source:, validity:, warnings: ["procedure_review_expired"] } if checked_on > day || checked_on < day - 365

          if (first_day && day < first_day) || (last_day && day > last_day)
            return { status: "stale", source:, validity:, warnings: ["procedure_not_effective_on_requested_day"] }
          end

          warnings = []
          warnings << "latest_source_check_unavailable" if status && %w(ok empty).exclude?(status)
          { status: "ok", source:, validity:, warnings: }
        rescue ArgumentError, KeyError, TypeError, URI::InvalidURIError
          { status: "unavailable", warnings: ["procedure_configuration_invalid"] }
        end

        private

        def valid_card?(card)
          return false unless card.is_a?(Hash) && card[:record_kind] == "procedure"
          return false unless card[:key].is_a?(String) && /\A[a-z][a-z0-9_-]{0,79}\z/.match?(card[:key])
          return false unless %i(title owner location_scope).all? { |key| bounded_text?(card[key]) }
          return false unless card[:steps].is_a?(Array) && card[:steps].size <= 20 && card[:steps].all? { |step| bounded_text?(step) }
          return false unless card[:reviewed_content_hash].is_a?(String) && /\A[a-f0-9]{64}\z/i.match?(card[:reviewed_content_hash])
          return false unless reviewed_url?(card[:source_url]) && (!card[:form_download_url] || reviewed_url?(card[:form_download_url]))
          return false unless valid_channel_metadata?(card)
          documents = card[:required_documents]
          return false if documents && !(documents.is_a?(Array) && documents.size <= 20 && documents.all? { |value| bounded_text?(value) })
          return false if card[:processing_time] && !card[:processing_time].is_a?(Hash)
          return false if card[:processing_time].is_a?(Hash) && card[:processing_time][:text] && !bounded_text?(card[:processing_time][:text])
          return false if card[:fee] && !card[:fee].is_a?(Hash)
          return false if card[:eligibility] && !bounded_text?(card[:eligibility])

          dates = %i(source_checked_on effective_from effective_until).to_h do |key|
            value = card[key]
            next [key, nil] if key != :source_checked_on && value.nil?
            return false unless value.is_a?(String) && /\A\d{4}-\d{2}-\d{2}\z/.match?(value)

            [key, Date.iso8601(value)]
          end
          return false if dates[:effective_from] && dates[:effective_until] && dates[:effective_from] > dates[:effective_until]

          true
        end

        def valid_channel_metadata?(card)
          return false if card[:channel] && !%w(online counter).include?(card[:channel])
          return false if card[:document_kind] && !(card[:document_kind].is_a?(String) && /\A[a-z][a-z0-9_]{0,79}\z/.match?(card[:document_kind]))
          if card[:organization_host]
            host = card[:organization_host]
            return false unless host.is_a?(String) && host.length <= 253 && /\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/i.match?(host)
          end
          return false if card[:fee_exemptions] && !bounded_text?(card[:fee_exemptions])

          delivery = card[:delivery]
          return true if delivery.nil?
          return false unless delivery.is_a?(Hash) && (delivery.keys - %i(document_method instructions_method delivery_time_text)).empty?
          return false if delivery[:document_method] && !%w(postal electronic counter unknown).include?(delivery[:document_method])
          return false if delivery[:instructions_method] && !%w(email portal counter unknown).include?(delivery[:instructions_method])
          return false if delivery[:delivery_time_text] && !bounded_text?(delivery[:delivery_time_text])

          true
        end

        def bounded_text?(value)
          value.is_a?(String) && value.valid_encoding? && !value.strip.empty? && value.length <= 1_000 &&
            !value.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f]/)
        end

        def reviewed_url?(value)
          return false unless value.is_a?(String) && value.length <= 2_000

          uri = URI.parse(value)
          uri.scheme == "https" && uri.port == 443 && uri.userinfo.nil? && ServiceProcedures::REVIEWED_HOSTS.include?(uri.host.to_s.downcase)
        end

        def normalized_fee(value)
          return unless value.is_a?(Hash)

          value.merge(administrative_fee_bam: known_amount(value[:administrative_fee_bam]), postage_amount_bam: known_amount(value[:postage_amount_bam]))
        end

        def known_amount(value)
          value if value.is_a?(Numeric) && value.finite? && !value.negative?
        end

        def review_blocked?(snapshot, card, status)
          review_required = snapshot&.check_payload&.fetch("review_required_for_hash", nil)
          current_review_blocked = review_required == card.fetch(:reviewed_content_hash) &&
                                   snapshot.check_payload["source_url"] == card.fetch(:source_url)
          current_review_blocked || (status == "unreviewed" && review_required.nil?)
        end

        def procedure_text(card)
          text = [card.fetch(:title), card[:eligibility], *card.fetch(:steps)].compact.join("\n")
          fee = normalized_fee(card[:fee])
          if fee && (amount = fee[:administrative_fee_bam])
            text += "\nAdministrativna taksa: #{amount} KM."
          end
          if fee && fee[:delivery_cost] == "postage"
            postage = fee[:postage_amount_bam]
            text += postage ? "\nPoštarina: #{postage} KM." : "\nIznos poštarine nije potvrđen; provjerite uputstvo službe."
          end
          "#{text}\nLične podatke unosite samo u službeni obrazac."
        end
      end
    end
  end
end
