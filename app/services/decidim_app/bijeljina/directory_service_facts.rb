# frozen_string_literal: true

require "yaml"
require "date"
require "uri"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/time/zones"

module DecidimApp
  module Bijeljina
    # Reviewed public role/service contacts, separately cited by predicate and
    # office. An operator override owns its whole card and cannot inherit these.
    module DirectoryServiceFacts
      PATH = ENV.fetch("MI_DIRECTORY_FACTS_PATH", "").freeze
      REVIEWED_HOSTS = ENV.fetch("MI_DIRECTORY_FACTS_REVIEWED_HOSTS", "").split(",").map { |host| host.strip.downcase }.reject(&:empty?).freeze
      FACETS = {
        "phone" => /\b(?:telefon\w*|kontakt\w*|broj|phone|contact|pozov\w*)\b/,
        "address" => /\b(?:adres\w*|gdje|gde|nalazi|address|location)\b/,
        "hours" => /\b(?:radno vrijeme|radno vreme|kada radi|kad radi|do kada|do koliko|hours)\b/,
        "form" => /\b(?:obraz\w*|formular\w*|form|forms)\b/
      }.freeze
      UNSUPPORTED = /\b(?:e-?mail\w*|mejl\w*|stomatolog\w*|dezurn\w*|apot\w*|dijagno\w*|terap\w*|uslov\w*|uvjet\w*|rok\w*|taks\w*|iznos\w*|eligib\w*|deadline\w*)\b/

      module_function

      def all(key)
        Array(data[key.to_s]).map(&:deep_symbolize_keys)
      end

      def reviewed_source_url?(url)
        data.values.flatten.any? { |row| row.fetch("source_url") == url.to_s }
      end

      def select(entry:, query:, now:)
        return [] if entry[:content_origin] == "admin_override"

        question = Decidim::Bih::Text.fold(query.to_s)
        return [] if UNSUPPORTED.match?(question)

        facets = FACETS.select { |_key, pattern| pattern.match?(question) }.keys
        return [] if facets.empty?

        rows = requested_subjects(all(entry.fetch(:key)), question)
        subjects = rows.map { |row| row.fetch(:subject_id) }.uniq
        selected = eligible(rows, now:).select { |row| facets.include?(row.fetch(:predicate)) }
        return [] unless complete_facets?(selected, subjects:, facets:)
        return [] if selected.size > 8

        selected
      end

      # Explicit public-office role facts are a separate seam from free-text
      # query matching. Email is supplied as reviewed data, never extracted.
      def for_subject(entry:, subject_id:, predicate:, now:)
        return [] if entry[:content_origin] == "admin_override"
        return [] unless subject_id.is_a?(String) && !subject_id.empty? && (FACETS.keys + ["email"]).include?(predicate)

        rows = all(entry.fetch(:key)).select { |row| row[:subject_id] == subject_id && row[:predicate] == predicate }
        selected = eligible(rows, now:)
        selected.size > 8 ? [] : selected
      end

      def complete_facets?(rows, subjects:, facets:)
        by_subject = rows.group_by { |row| row.fetch(:subject_id) }
        subjects.all? { |subject| (facets - Array(by_subject[subject]).map { |row| row.fetch(:predicate) }).empty? }
      end

      def eligible(rows, now:)
        day = now.in_time_zone("Europe/Sarajevo").to_date
        rows.select do |row|
          reviewed = Date.iso8601(row.fetch(:source_checked_on))
          start = row[:effective_from] && Date.iso8601(row[:effective_from])
          finish = row[:effective_until] && Date.iso8601(row[:effective_until])
          row[:review_state] == "reviewed" && reviewed <= day && (!start || start <= day) && (!finish || finish >= day)
        end
      end

      def requested_subjects(rows, question)
        matches = rows.select { |row| Array(row[:aliases]).any? { |name| question.include?(Decidim::Bih::Text.fold(name)) } }
        subjects = matches.map { |row| row.fetch(:subject_id) }.uniq
        subjects.empty? ? rows.select { |row| row[:default_subject] } : rows.select { |row| subjects.include?(row[:subject_id]) }
      end

      def data
        @data ||= (File.file?(PATH) ? YAML.safe_load_file(PATH) : {}).tap do |entries|
          ids = entries.values.flatten.map { |row| row.fetch("id") }
          raise ArgumentError, "duplicate directory fact identity" unless ids.uniq.size == ids.size

          entries.values.flatten.each { |row| validate!(row) }
        end
      end

      def validate!(row)
        %w(id logical_id fact_revision document_id publisher_id source_document_sha256 subject_id predicate text source_url source_checked_on review_state
           source_locator).each do |key|
          row.fetch(key)
        end
        raise ArgumentError, "unsupported directory predicate" unless (FACETS.keys + ["email"]).include?(row.fetch("predicate"))
        source = URI.parse(row.fetch("source_url"))
        unless source.scheme == "https" && source.userinfo.nil? && source.port == 443 && REVIEWED_HOSTS.include?(source.host.to_s.downcase)
          raise ArgumentError, "unreviewed directory source"
        end

        Date.iso8601(row.fetch("source_checked_on"))
      end
    end
  end
end
