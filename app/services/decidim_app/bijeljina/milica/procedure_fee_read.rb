# frozen_string_literal: true

require_relative "procedure_read"

module DecidimApp
  module Bijeljina
    module Milica
      # Reread the allowlisted procedure through its source-version/review gate;
      # never reuse an old answer, retained URL, or citizen-supplied fee.
      class ProcedureFeeRead
        PROCEDURE_ID = /\Aprocedure:([a-z][a-z0-9_]{0,79})\z/

        def initialize(directory: CityDirectory, procedure_reader: ProcedureRead.new)
          @directory = directory
          @procedure_reader = procedure_reader
        end

        def call(procedure_id:, focus:, now:, locale:)
          match = procedure_id.is_a?(String) && PROCEDURE_ID.match(procedure_id)
          return { status: "unavailable", warnings: ["unsupported_procedure_follow_up"] } unless focus == "fee" && match

          card = procedure_card(match[1])
          return { status: "empty", warnings: ["reviewed_procedure_not_found"] } unless card

          values = @procedure_reader.call(card:, locale:, now:)
          return values unless values[:status] == "ok"

          text = fee_text(card, locale:)
          return values if text.length > 1_000

          facts = values.fetch(:facts)
          return values unless facts.one? && facts.first.values_at("id", "source_id", "kind") == [procedure_id, procedure_id, "service_procedure"]

          values.merge(facts: [facts.first.merge("text" => text)])
        end

        private

        def procedure_card(key)
          card = @directory.procedure_for(key)
          card if card && card[:key].to_s == key && card[:record_kind] == "procedure"
        end

        def fee_text(card, locale:)
          fee = card[:fee].is_a?(Hash) ? card[:fee] : {}
          parts = [translate("fee_check", locale:, title: card.fetch(:title))]
          parts << amount_text(fee[:administrative_fee_bam], "fee", locale:)
          parts << amount_text(fee[:postage_amount_bam], "postage", locale:) if fee[:delivery_cost] == "postage"
          Decidim::Bih::Transliterator.localize(parts.join("\n"), locale:)
        end

        def amount_text(value, field, locale:)
          if value.is_a?(Numeric) && value.finite? && !value.negative?
            translate("#{field}_amount", locale:, amount: value)
          else
            translate("#{field}_unknown", locale:)
          end
        end

        def translate(key, locale:, **values)
          I18n.t("decidim.bih.dialogue.procedure_#{key}", locale:, raise: true, **values)
        end
      end
    end
  end
end
