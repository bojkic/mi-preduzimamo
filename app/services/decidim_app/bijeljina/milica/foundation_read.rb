# frozen_string_literal: true

require "date"
require "time"
require "yaml"
require "i18n"
require_relative "read/base"

module DecidimApp
  module Bijeljina
    module Milica
      # A reviewed institutional reference, not a current grant/project feed.
      # Ordinary chat performs no network request and never submits an idea.
      class FoundationRead
        include Read::Base

        TOPICS = %w(community public_calls donation).freeze
        SOURCE_IDS = %w(lfbn:about lfbn:idea_call).freeze
        NO_CALL_STATUS = [:identity, :contact].freeze
        METADATA_PATH = ENV.fetch("MI_FOUNDATION_METADATA_PATH", "").freeze
        NAME = /\b(?:lokaln(?:a|e|oj|u|om) fondacij(?:a|e|i|u|om) bijeljin\w*|lfbn|bijeljina local foundation|local foundation bijeljina)\b/
        FUNDING = /\b(?:finans\w*|financ\w*|podrz\w*|podrs\w*|pomaz\w*|grant\w*|support\w*|fund\w*)\b/
        PROJECTS = /\b(?:projekte|projekti|projekata|ideje|inicijative|projects|ideas|initiatives)\b/
        LISTING = /\b(?:koje|koji|prikazi|pokazi|spisak|lista|navedi|list|show)\b.{0,50}\b(?:projekte|projekti|akcij\w*|aktivnost\w*|udruzen\w*|partner\w*|projects|activities)\b/
        # How to REACH the foundation. Without this intent a phone question
        # matched NAME, fell through every branch and landed on the city-service
        # path — where the Gradska uprava contact card is a perfectly good match
        # for "telefon", which is how the municipality's switchboard came back
        # labelled as the foundation's.
        #
        # Only explicitly configured public contacts may enter the answer.
        # Private partner-profile contact fields are never read here.
        CONTACT = /\b(?:telefon\w*|broj|kontakt\w*|adres\w*|sjediste|sediste|kancelarij\w*|ured|mejl|mail|sajt|web)\b|\be[ ]mail\b|\b(?:gdje|gde)[ ](?:se[ ])?(?:nalaz\w*|ste)\b/
        APPLY = /\A(?:a[ ])?(?:
          (?:gdje|gde|kako)[ ](?:(?:mogu|mozemo|da|se)[ ])*(?:prijaviti|prijavim|prijavimo|podnijeti|podneti|posaljem|poslati)[ ]
          (?:svoju[ ]|svoj[ ]|nasu[ ]|nas[ ])?(?:ideju|projekat|projekt|prijavu)|
          where[ ]can[ ](?:i|we)[ ](?:apply|submit[ ](?:my[ ]|our[ ]|an[ ])?idea)|how[ ](?:can|do)[ ](?:i|we)[ ]apply
        )\z/x
        CALL_STATUS = /\A(?:a[ ])?(?:
          (?:da[ ]li[ ]je[ ]|je[ ]li[ ]|jel[ ])?(?:taj[ ]|ovaj[ ]|vas[ ])?(?:konkurs|poziv)[ ](?:jos[ ]|sada[ ]|trenutno[ ])?(?:otvoren|aktivan)|
          (?:da[ ]li[ ]|ima[ ]li[ ])?(?:jos[ ])?(?:ima[ ]|dostupnih[ ])?sredstava|
          is[ ](?:the[ ]|this[ ])?call[ ](?:still[ ])?open|are[ ]funds[ ](?:still[ ])?available
        )\z/x
        GENERIC_WORDS = /\b(?:
          da|li|ima|postoji|neka|koja|kakva|fondacija|za|u|i|iz|od|kod|nas|nase|nasa|nasi|naseg|lokaln\w*|bijeljin\w*|
          gradjan\w*|projek\w*|idej\w*|inicijativ\w*|finans\w*|financ\w*|podrz\w*|podrs\w*|pomaz\w*|novca|novac|zajednic\w*|se|
          is|there|a|any|some|foundation|that|supports?|funds?|funding|citizen|citizens|local|community|projects?|ideas?|initiatives?|in
        )\b/x

        def self.handles?(topic:, entities:, source_identity: nil)
          !intent(topic:, entities:, source_identity:).nil?
        end

        def self.intent(topic:, entities:, source_identity: nil)
          return unless TOPICS.include?(topic.to_s)

          text = folded_query(entities)
          return unless text
          return if text.match?(LISTING)
          return :apply if SOURCE_IDS.include?(source_identity) && (text.match?(APPLY) || text.match?(CALL_STATUS))
          return named_intent(text) if text.match?(NAME)

          :funding if generic_funding?(text)
        end

        def self.named_intent(text)
          return if text.match?(/\b(?:ili|versus|vs)\b/)
          return :funding if text.match?(FUNDING) && text.match?(PROJECTS)
          return :apply if application_question?(text)
          return :contact if text.match?(CONTACT)
          return :identity if text.gsub(NAME, "").strip.match?(/\A(?:a|o)?\z/)

          :identity if text.match?(/\b(?:sta je|sta radi|sta znas o|znas li|cime se bavi|ko je|ko su|reci mi|nesto o|informacije o|what is|what does|tell me about)\b/)
        end

        def self.application_question?(text)
          return true if text.match?(/\b(?:prijav\w*|apply|submit)\b/) && text.match?(/\b(?:idej\w*|projek\w*|konkurs\w*|poziv\w*|idea\w*|project\w*)\b/)

          text.match?(/\b(?:konkurs|poziv|call)\b/) && text.match?(/\b(?:otvoren|aktivan|open|rok|deadline)\b/)
        end

        def self.folded_query(entities)
          return unless entities.is_a?(Hash)

          query = entities["query"] || entities[:query]
          return unless query.is_a?(String) && query.valid_encoding? && query.length <= 1_000

          text = Decidim::Bih::Text.fold(query)
          text unless text.empty?
        end

        def self.generic_funding?(text)
          return false unless text.match?(FUNDING) && text.match?(PROJECTS)
          return false unless text.match?(/\b(?:(?:neka|koja|kakva) fondacija|fondacija koja|(?:postoji|ima)(?: li)? fondacija|(?:a|any|some) foundation)\b/)

          # A generic local question must not silently answer for a named
          # different foundation, municipality, applicant or specific project.
          remainder = text.gsub(GENERIC_WORDS, "")
          remainder.strip.empty?
        end

        # `status_override:` is the organization's APPROVED
        # FoundationStatusOverride (anything responding to current_open_status,
        # reviewed_on, review_expires_on and approved_at), `nil` to force the
        # shipped YAML, or :lookup (default) to read the approved row when the
        # model is loaded. The override wins over the YAML for the review dates
        # and the call status; nothing else changes.
        def initialize(organization:, metadata: nil, status_override: :lookup)
          @organization = organization
          @metadata = metadata || (METADATA_PATH.empty? ? nil : YAML.safe_load_file(METADATA_PATH, aliases: false))
          @status_override = status_override
        end

        def call(topic:, entities:, context:, locale:, source_identity: nil)
          selected = self.class.intent(topic:, entities:, source_identity:)
          return unless selected
          return not_authorized_result unless authorized?(context)

          read_facet(facet: selected.to_s, context:, locale:)
        end

        # Explicit capability selection for the model-led public registry.
        def read_facet(facet:, context:, locale:)
          selected = facet.to_sym
          return not_authorized_result unless authorized?(context)
          return { status: "unavailable", warnings: ["unsupported_foundation_facet"] } unless [:identity, :contact, :funding, :apply].include?(selected)

          return { status: "unavailable", warnings: ["foundation_reference_not_configured"] } unless @metadata

          review = review_window
          reviewed = review.fetch(:reviewed_on)
          expires = review.fetch(:expires_on)
          call_status = review.fetch(:call_status)
          today = context.now.to_date
          source = source_for(NO_CALL_STATUS.include?(selected) ? "about" : "idea_call", locale)
          validity = { "answer_shape" => "foundation_reference_v1", "current_call_status" => call_status,
                       "funds_available" => nil, "reviewed_on" => reviewed.iso8601, "review_expires_on" => expires.iso8601 }
          coverage = { "organization_id" => @organization.id, "scope" => "foundation_public_reference", "access" => "public",
                       "complete_inventory" => false, "current_call_verified" => call_status != "unverified" }
          if context.now < review.fetch(:reviewed_at) || today < reviewed || today > expires
            return { status: "stale", source:, coverage:, validity:, warnings: ["foundation_reference_review_due"] }
          end

          { status: "ok", facts: facts_for(selected, locale, reviewed, call_status), source:, coverage:,
            validity:, checked_at: review.fetch(:reviewed_at), warnings: [] }
        end

        private

        def facts_for(selected, locale, reviewed, call_status)
          facts = selected == :apply ? [] : [fact("about", "identity", locale, reviewed)]
          facts << fact("about", "contact", locale, reviewed, **contact_values) if selected == :contact && contact_values
          # A contact question is not a question about the idea call, so it does
          # not drag the call's status along with it.
          return facts if NO_CALL_STATUS.include?(selected)

          facts << fact("idea_call", "call_status", locale, reviewed, text_key: call_status_text_key(call_status))
        end

        def source_for(key, locale)
          value = @metadata.fetch("sources").fetch(key)
          { "id" => value.fetch("id"), "url" => value.fetch("url"), "label" => translate("source_#{key}", locale) }
        end

        # The fact id stays keyed on +fact_key+ ("call_status") even when the
        # rendered text comes from a status-specific copy key, so follow-ups
        # and evaluation fixtures keep addressing the same fact.
        # +options+ carries an optional :text_key (a status-specific copy key)
        # and any interpolations that copy needs. Keeping them in one splat is
        # what holds this signature to four named parameters.
        def fact(source_key, fact_key, locale, reviewed, **options)
          text_key = options.delete(:text_key) || fact_key
          source = source_for(source_key, locale)
          { "id" => "#{source.fetch("id")}:#{fact_key}", "kind" => "foundation_reference", "text" => translate(text_key, locale, **options),
            "source_id" => source.fetch("id"), "source_url" => source.fetch("url"), "source_label" => source.fetch("label"),
            "reviewed_on" => reviewed.iso8601 }
        end

        # The organisation's PUBLISHED contact facts, interpolated rather than
        # typed into the copy: an e-mail address and a domain are the two things
        # the Latin->Cyrillic generator must never touch, and %{...} is exactly
        # what it preserves. nil when the host has not configured them, in which
        # case the contact fact is omitted rather than guessed at.
        def contact_values
          return @contact_values if defined?(@contact_values)

          values = { name: Decidim::Bih.public_support_name, address: Decidim::Bih.public_support_address,
                     email: Decidim::Bih.public_support_email, website: Decidim::Bih.public_support_website }
          @contact_values = values.values.all? { |value| !value.to_s.strip.empty? } ? values.transform_values { |value| value.to_s.strip } : nil
        end

        # Review dates and call status: the APPROVED operator override when one
        # exists, otherwise the shipped YAML. The override's approval time plays
        # the YAML's `reviewed_at` role in the "not before review" check.
        def review_window
          override = status_override
          if override
            { reviewed_on: override.reviewed_on.to_date, expires_on: override.review_expires_on.to_date,
              reviewed_at: (override.approved_at || override.reviewed_on.to_time).to_time,
              call_status: override.current_open_status.to_s }
          else
            { reviewed_on: Date.iso8601(@metadata.fetch("reviewed_on")), expires_on: Date.iso8601(@metadata.fetch("review_expires_on")),
              reviewed_at: Time.iso8601(@metadata.fetch("reviewed_at")),
              call_status: (@metadata.dig("sources", "idea_call", "current_open_status") || "unverified").to_s }
          end
        end

        # nil (shipped YAML) whenever the model is not loaded — the standalone
        # contract tests — or the database cannot answer; never an exception.
        def status_override
          return @status_override unless @status_override == :lookup
          return unless defined?(DecidimApp::Bijeljina::FoundationStatusOverride)

          DecidimApp::Bijeljina::FoundationStatusOverride.approved_for(@organization)
        rescue StandardError
          nil
        end

        def call_status_text_key(status)
          %w(open closed).include?(status) ? "call_status_#{status}" : "call_status"
        end

        def translate(key, locale, **values)
          I18n.t("decidim_app.milica.foundation_answers.#{key}", locale:, raise: true, **values)
        end
      end
    end
  end
end
