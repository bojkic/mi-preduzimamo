# frozen_string_literal: true

require_relative "chat_report_intake"

module DecidimApp
  module Bijeljina
    module Milica
      # Deterministic public guidance for platform capabilities whose answer is
      # owned by code and configuration. It selects reviewed copy and routes;
      # it never reads a private account or performs the described action.
      class PublicCapabilityCatalog
        Dialogue = Decidim::Bih::Concierge::Dialogue
        Capability = Data.define(:key, :text, :answer_intent, :context_kind, :context_subject, :source_refs)

        MAX_TEXT = 300
        REGISTRATION = /(?:kako|gdje|gde|zelim|hocu).{0,55}(?:registr\w*|otvor\w*.{0,12}(?:nalog|racun)).{0,55}(?:telefon\w*|broj\w*)|(?:registr\w*).{0,55}(?:telefon\w*|broj\w*)/
        ACCOUNT_STATUS = /(?:prijav\w*\s+na\s+(?:platformu|sajt|mi\s+platformu)|registr\w*\s+(?:na\s+platform\w*|nalog\w*|racun\w*)).{0,90}(?:uspj\w*|uspe\w*|potvrd\w*|provjer\w*|prover\w*)|(?:kako|gdje|gde).{0,45}(?:provjer\w*|prover\w*).{0,55}(?:registr\w*|nalog\w*|racun\w*)/
        WHATSAPP_REPORT = /(?:(?:whatsapp\w*).{0,90}(?:prijav\w*|problem\w*|prije\s+slanj\w*)|(?:prijav\w*|problem\w*).{0,90}(?:whatsapp\w*))/
        TIMETABLE_LINK = /(?:link|poveznic\w*|url|dokument\w*|izvor\w*|gdje|gde|postoji|dostupan|sluzben\w*|zvanicn\w*).{0,80}(?:red\w*\s+voznj\w*|vozn\w*\s+red)|(?:red\w*\s+voznj\w*|vozn\w*\s+red).{0,80}(?:link|poveznic\w*|url|dokument\w*|izvor\w*)/
        MZ_DIRECTORY = /\bkontakt\w*\s+(?:za\s+)?(?:mz|mjesn\w*\s+zajednic\w*)(?=\s*(?:\?|[.!]|$|ako\b|je\b|postoje\b|dostupn\w*\b))/
        NEIGHBORHOOD_STREET = /(?=.*\b(?:komsiluk\w*|neighbou?rhood\w*)\b)(?=.*\b(?:ulic\w*|street\w*)\b)/
        AIR_SOURCE = /(?=.*\b(?:kvalitet\w*\s+vazduh\w*|air\s+quality)\b)(?=.*\b(?:sluzben\w*|zvanicn\w*|izvor\w*|link\w*|official|source)\b)/
        SCRIPT = /(?:latinic\w*|cirilic\w*|pism\w*|prikaz\w*).{0,70}(?:prebac\w*|promjen\w*|promen\w*|mijenj\w*|menj\w*|nalog\w*|racun\w*|prikaz\w*)|(?:prebac\w*|promjen\w*|promen\w*).{0,70}(?:latinic\w*|cirilic\w*|pism\w*)/
        RESPONSE_SCRIPT = /\b(?:napisi|pisi|odgovori)\b.{0,70}\b(?:latinic\w*|cirilic\w*)/
        REPORT_ANONYMOUS = /(?:(?:moram|treba\w*).{0,35}(?:nalog\w*|racun\w*).{0,65}(?:opis\w*|prijav\w*|problem\w*)|anonimn\w*.{0,65}(?:prijav\w*|pristup\w*|problem\w*))/
        REPORT_VISIBILITY = /(?=.{0,220}\b(?:prijav\w*|problem\w*)\b)(?:javn\w*.{0,55}(?:opis\w*|podat\w*)|privatn\w*.{0,55}(?:dokaz\w*|podat\w*|opis\w*|fotograf\w*)|(?:prijav\w*|problem\w*).{0,80}(?:javn\w*|privatn\w*).{0,55}(?:opis\w*|podat\w*|dokaz\w*|fotograf\w*))/
        REPORT_SUPPLEMENT = /(?:dopun\w*|dodat\w*.{0,20}(?:podat\w*|broj\w*|informacij\w*)).{0,90}(?:prijav\w*|predmet\w*|status\w*|zgrad\w*)|(?:prijav\w*|predmet\w*).{0,90}(?:dopun\w*|dodat\w*.{0,20}(?:podat\w*|informacij\w*))/
        CHANNEL_OPT_OUT = /(?:(?:odjav\w*|iskljuc\w*|zaustav\w*|stop|odjava).{0,80}(?:viber\w*|obavjestenj\w*|obavestenj\w*|poruk\w*)|(?:viber\w*).{0,80}(?:odjav\w*|iskljuc\w*|stop|odjava|supres\w*))/
        POINTS = /(?:kako.{0,30}(?:racun\w*|dobij\w*|dodjel\w*|dodel\w*)|objasn\w*.{0,20})(?:bodov\w*|poen\w*)|(?:bodov\w*|poen\w*).{0,50}(?:glas\w*|odluc\w*|uces\w*|sudjel\w*)/
        GUIDANCE_ONLY = /(?:ne|nemoj|bez).{0,35}(?:slanj\w*|posalj\w*|kreir\w*|naprav\w*|izvrs\w*).{0,45}(?:prijav\w*|nalog\w*|racun\w*|odjav\w*|promjen\w*|promen\w*)/
        CONTINUATIONS = {
          "account_status" => /(?:vidljiv\w*|znak\w*|potvrd\w*|nalog\w*|racun\w*|status\w*|uspj\w*|uspe\w*|registr\w*)/,
          "whatsapp_report" => /(?:pregled\w*|potvrd\w*|prijav\w*|whatsapp\w*)/,
          "timetable_link" => /(?:link\w*|dokument\w*|izvor\w*|red\w*\s+voznj\w*|url)/,
          "neighborhood_street" => /(?:broj\w*|objekt\w*|preciz\w*|lokacij\w*|mjesn\w*\s+zajednic\w*|komsiluk\w*)/,
          "air_source" => /(?:izvor\w*|podat\w*|indeks\w*|zdravstven\w*|mjerenj\w*|merenj\w*|pouzdan\w*)/,
          "registration" => /(?:stranic\w*|otvor\w*|potvrd\w*|kod\w*|lozink\w*|nalog\w*|racun\w*)/,
          "script" => /(?:pism\w*|prikaz\w*|latinic\w*|cirilic\w*|nalog\w*|racun\w*)/,
          "account_deletion" => /(?:bris\w*|zatvor\w*|ukid\w*|nalog\w*|racun\w*|promjen\w*|promen\w*)/,
          "report_anonymous" => /(?:anonimn\w*|nalog\w*|racun\w*|prijav\w*|javn\w*|privatn\w*)/,
          "report_visibility" => /(?:javn\w*|privatn\w*|opis\w*|fotograf\w*|kontakt\w*|prijav\w*)/,
          "report_supplement" => /(?:dopun\w*|predmet\w*|pristup\w*|status\w*|otvor\w*|promjen\w*|promen\w*)/,
          "channel_opt_out" => /(?:stop|odjava|odjav\w*|supres\w*|viber\w*|tem\w*|poruk\w*)/,
          "points" => /(?:bodov\w*|poen\w*|glas\w*|odluc\w*|priznanj\w*)/
        }.freeze

        SOURCE_REFS = {
          "account_status" => ["engine:app/controllers/decidim/bih/registrations_controller.rb", "engine:app/controllers/decidim/bih/welcome_controller.rb"],
          "whatsapp_report" => ["app:app/services/decidim_app/bijeljina/milica/chat_report_intake.rb"],
          "timetable_link" => ["app:config/bijeljina/public_transport/2026-09-01/manifest.json"],
          "mz_directory" => ["app:app/services/decidim_app/bijeljina/milica/mz_contact_answer.rb", "engine:config/routes.rb"],
          "neighborhood_street" => ["app:db/geo/komsiluci_finalno.geojson", "engine:app/controllers/decidim/bih/welcome_controller.rb"],
          "air_source" => ["app:app/services/decidim_app/bijeljina/city_service_sources.rb"],
          "registration" => ["app:config/routes.rb", "app:app/services/decidim_app/bijeljina/milica/registration_port.rb"],
          "script" => ["app:app/views/decidim/bih/shared/_mobile_bottom_nav.html.erb", "decidim-core:app/controllers/decidim/locales_controller.rb"],
          "account_deletion" => ["engine:app/views/decidim/bih/account/_settings.html.erb", "decidim-core:app/commands/decidim/destroy_account.rb"],
          "report_anonymous" => ["engine:app/controllers/decidim/bih/reports_controller.rb", "engine:app/services/decidim/bih/report_intake.rb"],
          "report_visibility" => ["engine:app/views/decidim/bih/reports/new.html.erb", "engine:app/controllers/decidim/bih/reports_controller.rb"],
          "report_supplement" => ["engine:app/controllers/decidim/bih/reports_controller.rb", "engine:config/routes.rb"],
          "channel_opt_out" => ["app:app/services/decidim_app/bijeljina/channel_notification_opt_out.rb"],
          "points" => ["engine:app/services/decidim/bih/goodwill/earning_rules.rb", "engine:app/services/decidim/bih/concierge/goodwill_earning_answer.rb"]
        }.freeze

        def initialize(organization:)
          @organization = organization
        end

        def resolve(text:, locale:, state:, channel:)
          return unless text.is_a?(String) && text.strip.length.between?(1, MAX_TEXT)

          raw = text.strip
          query = Decidim::Bih::Text.fold(raw)
          # A requested reply script belongs to composition, including after
          # earlier guidance about the platform language selector.
          return if RESPONSE_SCRIPT.match?(query)

          retained = state[Dialogue::AnswerContext::KEY]
          account_followup = retained.is_a?(Hash) && retained["subject"] == "cap_account_status" &&
            query.match?(/\b(?:nalog\w*|racun\w*|registr\w*|platform\w*)\b/) &&
            !query.match?(/\b(?:prijav\w*\s+problem\w*|komunaln\w*\s+prijav\w*)\b/)
          key = account_followup ? "account_status" : (cold_key(raw, query) || continuation_key(query, state))
          return if key.nil?
          return if key == "neighborhood_street" && state.dig(Dialogue::ConversationSlots::KEY, "location", "kind") == "exact"

          build(key, locale:, channel:)
        end

        private

        def cold_key(raw, query)
          return "account_status" if ACCOUNT_STATUS.match?(query)
          return "whatsapp_report" if WHATSAPP_REPORT.match?(query)
          return "timetable_link" if TIMETABLE_LINK.match?(query)
          return "mz_directory" if MZ_DIRECTORY.match?(query)
          return "neighborhood_street" if NEIGHBORHOOD_STREET.match?(query)
          return "air_source" if AIR_SOURCE.match?(query)
          return "script" if SCRIPT.match?(query)
          return "registration" if REGISTRATION.match?(query)
          return "channel_opt_out" if CHANNEL_OPT_OUT.match?(query)
          return "report_supplement" if REPORT_SUPPLEMENT.match?(query)
          return "report_anonymous" if REPORT_ANONYMOUS.match?(query)
          return "report_visibility" if REPORT_VISIBILITY.match?(query)
          return "account_deletion" if Dialogue::AccountQuestion.facet(raw) == "deletion"
          return "points" if points_question?(query, raw)

          card = Dialogue::ReportGuidance.card(raw)
          "report_card:#{card.name}" if card
        end

        def continuation_key(query, state)
          retained = state[Dialogue::AnswerContext::KEY]
          return unless retained.is_a?(Hash)

          subject = retained["subject"].to_s
          if subject.start_with?("report_") &&
             query.match?(/(?:javn\w*|privatn\w*).{0,80}(?:opis\w*|podat\w*|dokaz\w*|fotograf\w*)|(?:opis\w*|podat\w*|dokaz\w*|fotograf\w*).{0,80}(?:javn\w*|privatn\w*)/)
            return "report_visibility"
          end
          return unless subject.start_with?("cap_")

          key = subject.delete_prefix("cap_")
          key if GUIDANCE_ONLY.match?(query) || CONTINUATIONS.fetch(key, /\A\b\B/).match?(query)
        end

        def points_question?(query, raw)
          return true if POINTS.match?(query)

          defined?(Dialogue::PointsExplainerRoute) && Dialogue::PointsExplainerRoute.explanation?(query, raw)
        end

        def build(key, locale:, channel:)
          return report_card(key.delete_prefix("report_card:"), locale:) if key.start_with?("report_card:")

          text = case key
                 when "account_status" then translate(key, locale:, url: public_url("/users/sign_in"))
                 when "whatsapp_report"
                   return unless ChatReportIntake.enabled?("whatsapp")

                   translate(key, locale:)
                 when "timetable_link"
                   translate(key, locale:, url: "https://www.gradbijeljina.org/lat/news/novosti/7243.od-1-septembra-novi-red-voznje-gradskog-prevoza.html")
                 when "mz_directory" then translate(key, locale:, url: public_url(Decidim::Bih.public_path("mjesne-zajednice")))
                 when "neighborhood_street" then translate(key, locale:, url: public_url(Decidim::Bih.public_path("komsiluk")))
                 when "air_source"
                   translate(key, locale:, url: CityServiceSources.fetch("air_quality").fetch(:source_url))
                 when "registration" then translate(key, locale:, url: public_url(registration_path))
                 when "script" then translate(key, locale:, url: public_url("/"))
                 when "account_deletion" then I18n.t("decidim.bih.dialogue.account_deletion", locale:, url: public_url("/account"))
                 when "report_anonymous" then translate(key, locale:, url: public_url(report_path(:new_report_path, "prijave/new")))
                 when "report_visibility" then report_visibility(locale:)
                 when "report_supplement"
                   translate(key, locale:, mine_url: public_url(report_path(:reports_path, "prijave", view: "mine")),
                             public_url: public_url(report_path(:reports_path, "prijave")))
                 when "channel_opt_out"
                   translate(key, locale:, settings_url: public_url("/notifications_settings"), channel: channel.to_s)
                 when "points"
                   Decidim::Bih::Concierge::GoodwillEarningAnswer.call(organization: @organization, locale:, url: public_url(Decidim::Bih.public_path("zajednistvo?tab=kako")))
                 end
          return if text.to_s.strip.empty?

          Capability.new(key:, text:, answer_intent: intent_for(key), context_kind: "public_card",
                         context_subject: "cap_#{key}", source_refs: SOURCE_REFS.fetch(key))
        end

        def report_card(name, locale:)
          card = Dialogue::ReportGuidance.constants.filter_map do |constant|
            value = Dialogue::ReportGuidance.const_get(constant)
            value if value.is_a?(Dialogue::ReportGuidance::Card) && value.name == name
          end.first
          return if card.nil?

          Capability.new(key: "report_card:#{name}", text: Dialogue::ReportGuidance.answer(card, locale:),
                         answer_intent: card.answer_intent, context_kind: "report_card",
                         context_subject: name,
                         source_refs: ["engine:app/services/decidim/bih/concierge/dialogue/report_guidance.rb"])
        end

        def report_visibility(locale:)
          Dialogue::ReportGuidance.answer(Dialogue::ReportGuidance::VISIBILITY, locale:)
        end

        def translate(key, locale:, **values)
          I18n.t("decidim_app.milica.public_capabilities.#{key}", locale:, raise: true, **values)
        end

        def intent_for(key)
          return "goodwill" if key == "points"
          return "report_guidance" if key.start_with?("report_")

          "service"
        end

        def registration_path
          Decidim::Bih.respond_to?(:registration_path) ? Decidim::Bih.registration_path : "/registracija"
        end

        def report_path(helper, fallback, **options)
          routes = Decidim::Bih::Engine.routes.url_helpers
          mount = Decidim::Bih.normalized_public_mount_path
          routes.respond_to?(helper) ? routes.public_send(helper, script_name: mount, **options) : "#{mount}/#{fallback}"
        end

        def public_url(path)
          host = @organization.host.to_s
          return path unless host.match?(/\A[a-z0-9][a-z0-9.-]*(?::\d+)?\z/i)
          return path unless path.is_a?(String) && path.start_with?("/") && !path.start_with?("//")

          "https://#{host}#{path}"
        end
      end
    end
  end
end
