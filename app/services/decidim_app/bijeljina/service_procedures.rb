# frozen_string_literal: true

require "json"

module DecidimApp
  module Bijeljina
    # Reviewed instructions, not delegated form submission. Unverified fields
    # stay nil instead of becoming invented fees, documents or processing times.
    module ServiceProcedures
      PATH = ENV.fetch("MI_SERVICE_PROCEDURES_PATH", "").freeze
      REVIEWED_HOSTS = ENV.fetch("MI_SERVICE_PROCEDURES_REVIEWED_HOSTS", "").split(",").map { |host| host.strip.downcase }.reject(&:empty?).freeze

      class InvalidConfiguration < StandardError; end

      class << self
        def all
          @all ||= load_cards
        end

        def find(key)
          exact = all.find { |card| card.fetch(:key).to_s == key.to_s }
          return exact if exact

          all.find { |card| identifiers(card).include?(key.to_s) }
        end

        # Narrow explicit phrases only; broad words such as tax or documents
        # cannot choose a procedure or manufacture eligibility.
        def match_query(query)
          needle = Decidim::Bih::Text.fold(query.to_s)
          return if needle.empty?

          matches = all.select do |card|
            terms = [card[:provider_procedure_code], *Array(card[:aliases])].compact
            terms.any? { |term| needle.match?(/(?<![[:alnum:]])#{Regexp.escape(Decidim::Bih::Text.fold(term))}(?![[:alnum:]])/) }
          end
          matches.one? ? matches.first : nil
        end

        private

        def load_cards
          return [].freeze if PATH.empty?

          document = JSON.parse(File.read(PATH))
          raise InvalidConfiguration unless document.is_a?(Hash) && document["procedures"].is_a?(Array)

          cards = document.fetch("procedures")
          raise InvalidConfiguration unless cards.all? { |card| card.is_a?(Hash) && card["key"].is_a?(String) && !card["key"].empty? }
          raise InvalidConfiguration unless cards.map { |card| card.fetch("key") }.uniq.size == cards.size

          cards.map { |card| card.deep_symbolize_keys.freeze }.freeze
        rescue JSON::ParserError, KeyError, TypeError, Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::EISDIR, InvalidConfiguration
          raise InvalidConfiguration, "procedure configuration is invalid", cause: nil
        end

        def identifiers(card)
          [card[:provider_procedure_code], *Array(card[:aliases]), *Array(card[:source_aliases])].compact
        end
      end
    end
  end
end
