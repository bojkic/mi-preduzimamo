# frozen_string_literal: true

require "test_helper"
require "yaml"
require "decidim/bih/transliterator"

module DecidimApp
  module Bijeljina
    module Milica
      class DialogueLocalesTest < ActiveSupport::TestCase
        HOST_COPY = Rails.root.join("config/locales/decidim_bih_bijeljina_copy.yml")
        ENGINE_LOCALES = Decidim::Bih::Engine.root.join("config/locales")
        # The host blocks the chat widget and Milica's legacy replies read from.
        WIDGET_BLOCKS = %w(concierge mi_bot).freeze
        # Latin ekavian forms (ijekavian counterpart in the comment); mirrors
        # the engine's LocaleCompletenessTest guard so the host copy cannot
        # regress on its own.
        EKAVIAN = [
          /\bbezbedn/i, # bezbjedn-
          /\bpre\s/i, # prije
          /\bovde\b/i, /\bgde\b/i, /\bnegde\b/i, /\bnigde\b/i, /\bsvugde\b/i, # ovdje, gdje, ...
          /\bvreme\b/i, # vrijeme
          /\breč\b/i, /\breči\b/i, # riječ, riječi
          /\buspeh/i, /\buspešn/i, # uspjeh, uspješn-
          /\bceo\b/i, /\bcel[aou]\b/i, /\bcelokupn/i, # cio, cijel-, cjelokupn-
          /\bsledeć/i, /\bposle\b/i, /\bposlednj/i, # sljedeć-, poslije, posljednj-
          /\bčovek\b/i, /\bdeo\b/i, # čovjek, dio
          /\bmesto\b/i, /\bmest[aou]\b/i, /\bumesto\b/i, # mjesto, umjesto
          /\bsvet\b/i, /\bsvetu\b/i, # svijet
          /\bobavešt/i, # obavješt-
          /\bnedelj/i, /\bmesec/i, /\bsreda\b/i, # nedjelj-, mjesec, srijeda
          /\bcen[aeiu]\b/i, /\bcenovnik/i, /\bocen/i, # cijena, cjenovnik, ocjen-
          /\brešenj/i, /\brešav/i, /\breši(?:ti|o|la|mo|)\b/i, # rješenj-, rješav-, riješi-
          /\bzahtev/i, /\bizveštaj/i, /\bprover/i, /\bprimer/i, # zahtjev, izvještaj, provjer-, primjer
          /\bsused/i, /\bpromen/i, /\bsavet/i, /\bvredn/i, /\bvredi\b/i, # susjed, promjen-, savjet, vrijedn-, vrijedi
          /\bdve\b/i, /\bhteo\b/i, /\bhtela\b/i, /\bželeo\b/i, /\bsmeo\b/i, # dvije, htio, htjela, želio, smio
          /\brazume/i, /\bvide(?:o|la|li|ti)\b/i, # razumije-, vidio/vidjela/vidjeti
          /\bdelimičn/i, /\bsvež/i # djelimičn-, svjež-
        ].freeze

        test "dialogue templates have complete keys placeholders and generated Cyrillic parity" do
          data = YAML.safe_load_file(ENGINE_LOCALES.join("decidim_bih_dialogue.yml"))
          sr = data.fetch("sr").fetch("decidim").fetch("bih").fetch("dialogue")
          %w(sr sr-Cyrl bs hr en).each do |locale|
            localized = data.fetch(locale).fetch("decidim").fetch("bih").fetch("dialogue")
            assert_equal sr.keys.sort, localized.keys.sort, locale
            sr.each do |key, text|
              assert localized.fetch(key).present?, "#{locale}:#{key}"
              assert_equal text.scan(/%\{([^}]+)\}/).sort, localized.fetch(key).scan(/%\{([^}]+)\}/).sort, "#{locale}:#{key}"
              values = text.scan(/%\{([^}]+)\}/).flatten.to_h { |placeholder| [placeholder.to_sym, "Sample #{placeholder}"] }
              rendered = I18n.t("decidim.bih.dialogue.#{key}", locale:, **values)
              assert_no_match(/translation missing/i, rendered)
            end
          end
          assert_equal Decidim::Bih::Transliterator.deep(data.fetch("sr")), data.fetch("sr-Cyrl")
        end

        test "the engine concierge copy has every Serbian key in Cyrillic Bosnian Croatian and English" do
          sr = leaves(engine_concierge("sr"))
          %w(sr-Cyrl bs hr en).each do |locale|
            localized = leaves(engine_concierge(locale))
            # English has only `one`/`other` plural categories.
            expected = locale == "en" ? sr.keys.reject { |key| %w(few many).include?(key.split(".").last) } : sr.keys
            assert_empty expected - localized.keys, "#{locale} is missing engine concierge keys"
            expected.each do |key|
              assert localized.fetch(key).present?, "#{locale}:concierge.#{key}"
              assert_equal placeholders(sr.fetch(key)), placeholders(localized.fetch(key)), "#{locale}:concierge.#{key}"
            end
          end
          assert_equal Decidim::Bih::Transliterator.deep(engine_concierge("sr")), engine_concierge("sr-Cyrl")
        end

        test "the host widget copy has every Serbian key in Cyrillic Bosnian Croatian and English" do
          WIDGET_BLOCKS.each do |block|
            sr = leaves(host_block("sr", block))
            assert sr.any?, "host sr #{block} block is empty"
            %w(sr-Cyrl bs hr en).each do |locale|
              localized = leaves(host_block(locale, block))
              assert_empty sr.keys - localized.keys, "#{locale} is missing host #{block} keys"
              sr.each do |key, text|
                assert localized.fetch(key).present?, "#{locale}:#{block}.#{key}"
                assert_equal placeholders(text), placeholders(localized.fetch(key)), "#{locale}:#{block}.#{key}"
              end
            end
          end
        end

        test "the Serbian chat copy is ijekavian in the host and in the engine" do
          latin = {}
          WIDGET_BLOCKS.each { |block| latin.merge!(prefixed(leaves(host_block("sr", block)), "host.#{block}")) }
          latin.merge!(prefixed(leaves(engine_concierge("sr")), "engine.concierge"))
          latin.merge!(prefixed(engine_dialogue("sr"), "engine.dialogue"))
          assert_empty ekavian_hits(latin), "ekavian forms in Serbian Latin copy"

          cyrillic = {}
          WIDGET_BLOCKS.each { |block| cyrillic.merge!(prefixed(leaves(host_block("sr-Cyrl", block)), "host.#{block}")) }
          cyrillic.merge!(prefixed(leaves(engine_concierge("sr-Cyrl")), "engine.concierge"))
          cyrillic.merge!(prefixed(engine_dialogue("sr-Cyrl"), "engine.dialogue"))
          latinized = cyrillic.transform_values { |text| Decidim::Bih::Transliterator.to_latin(text.to_s) }
          assert_empty ekavian_hits(latinized), "ekavian forms in Serbian Cyrillic copy"
        end

        test "an English reply can say that its facts are quoted in Serbian" do
          note = I18n.t("decidim.bih.dialogue.facts_in_source_language", locale: :en)

          assert_includes note, "Serbian"
          %w(sr sr-Cyrl bs hr).each do |locale|
            assert_no_match(/translation missing/i, I18n.t("decidim.bih.dialogue.facts_in_source_language", locale:))
            assert_not_equal note, I18n.t("decidim.bih.dialogue.facts_in_source_language", locale:), locale
          end
        end

        test "the safety reply names the emergency numbers and no longer offers a non-urgent report" do
          %w(sr sr-Cyrl bs hr en).each do |locale|
            text = I18n.t("decidim.bih.dialogue.safety", locale:)

            %w(122 1264 124 123).each { |number| assert_includes text, number, locale }
            assert_no_match(/nehitn|нехитн|non-emergency/i, text, locale)
          end
        end

        test "the registration hand-off keeps the link and promises to resume the conversation" do
          text = I18n.t("decidim.bih.dialogue.handoff_register", locale: :sr, url: "/registracija")

          assert_includes text, "/registracija"
          assert_includes text, "vrati se u razgovor"
          assert_no_match(/ne završava registraciju/, text)
        end

        test "the empty and unavailable replies are honest about what Milica cannot see" do
          assert_no_match(/translation missing/i, I18n.t("decidim.bih.dialogue.no_match", locale: :sr))
          assert_includes I18n.t("decidim.bih.dialogue.unavailable", locale: :sr, url: "/podrska"), "/podrska"
          assert_includes I18n.t("decidim.bih.dialogue.supplied_area_choice", locale: :sr, area: "Janja", choices: "komšiluk Janja ili mjesna zajednica Janja"),
                          "komšiluk Janja ili mjesna zajednica Janja"
        end

        private

        def host_copy
          @host_copy ||= YAML.safe_load_file(HOST_COPY)
        end

        def host_block(locale, block)
          host_copy.fetch(locale).dig("decidim", "bih", block) || {}
        end

        def engine_concierge(locale)
          YAML.safe_load_file(ENGINE_LOCALES.join("#{locale}.yml")).fetch(locale).dig("decidim", "bih", "concierge") || {}
        end

        def engine_dialogue(locale)
          @engine_dialogue ||= YAML.safe_load_file(ENGINE_LOCALES.join("decidim_bih_dialogue.yml"))
          @engine_dialogue.fetch(locale).dig("decidim", "bih", "dialogue") || {}
        end

        def leaves(node, prefix = nil, out = {})
          node.each do |key, value|
            path = [prefix, key].compact.join(".")
            value.is_a?(Hash) ? leaves(value, path, out) : out[path] = value
          end
          out
        end

        def prefixed(hash, prefix)
          hash.transform_keys { |key| "#{prefix}.#{key}" }
        end

        def placeholders(text)
          text.to_s.scan(/%\{([^}]+)\}/).flatten.sort
        end

        def ekavian_hits(copy)
          copy.flat_map do |key, text|
            EKAVIAN.filter_map { |pattern| "#{key}: #{text.to_s[pattern]}" if text.to_s.match?(pattern) }
          end
        end
      end
    end
  end
end
