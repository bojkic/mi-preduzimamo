# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Only fields already published by the public MZ directory, never a
      # citizen profile's contact data or an inferred current office-holder.
      module MzContactAnswer
        module_function

        def call(area:, query:, locale:)
          name = area.respond_to?(:translated_name) ? area.translated_name : area.name
          name = name[locale] || name["sr"] || name.values.first if name.is_a?(Hash)
          prefix = "decidim.bih.dialogue."
          options = { locale:, raise: true }
          parts = [I18n.t("#{prefix}mz_contact_heading", **options, area: name)]
          folded = Decidim::Bih::Text.fold(query.to_s)
          unless folded.match?(/\btelefon\b/)
            value = (area.respond_to?(:display_predsjednik) ? area.display_predsjednik : area.predsjednik).to_s.strip
            key = value.empty? ? "mz_president_missing" : "mz_president"
            parts << I18n.t("#{prefix}#{key}", **options, name: value)
          end
          phone = area.telefon.to_s.strip
          if folded.empty? || folded.match?(/\b(?:telefon|kontakt)\b/)
            key = phone.empty? ? "mz_phone_missing" : "mz_phone"
            parts << I18n.t("#{prefix}#{key}", **options, phone: phone)
          end
          parts << I18n.t("#{prefix}mz_contact_freshness", **options)
          text = ActionController::Base.helpers.strip_tags(parts.join("\n"))[0, 1000]
          text = Decidim::Bih::Transliterator.localize(text, locale:)
          suffix = area.slug.to_s.match?(/\Amz-[a-z0-9]+(?:-[a-z0-9]+)*\z/) ? "/#{area.slug}" : ""
          { "id" => "mz_contact:#{area.id}", "kind" => "public_mz_contact", "text" => text,
            "public_phone_published" => phone.present?, "public_phone" => phone.presence,
            "source_id" => "local_area_registry", "source_label" => I18n.t("#{prefix}mz_contact_source", **options),
            "destination" => Decidim::Bih.public_path("mjesne-zajednice#{suffix}"),
            "warning_codes" => ["public_directory_contact_not_live_verified"] }
        end
      end
    end
  end
end
