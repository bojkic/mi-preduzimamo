# frozen_string_literal: true

require "yaml"
require "json"
require "digest"
require "date"
require "uri"

module DecidimApp
  module Bijeljina
    # Reviewed local reference atoms, independent of collector snapshot hashes.
    # No fetches or citizen-controlled source/subject IDs enter this catalogue.
    class CitizenReferenceCatalog
      PATH = ENV.fetch("MI_CITIZEN_REFERENCE_PATH", "").freeze
      AUTHORITIES = %w(service_owner public_authority owner_attributed_press).freeze
      ReviewError = Class.new(StandardError)

      attr_reader :subjects

      def self.default
        @default ||= new
      end

      def self.revision_for(row)
        Digest::SHA256.hexdigest(JSON.generate(canonical(row.except("reviewed_sha256"))))
      end

      def self.canonical(value)
        case value
        when Hash then value.sort.to_h.transform_values { |item| canonical(item) }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end

      def self.load_data
        return { "version" => 1, "sources" => [], "documents" => [], "subjects" => [], "facts" => [] } if PATH.empty?

        YAML.safe_load_file(PATH, aliases: false)
      end

      def initialize(data: self.class.load_data)
        raise ReviewError, "Unsupported reference catalogue version" unless data.fetch("version") == 1

        @sources = index(data.fetch("sources"))
        @documents = index(data.fetch("documents"))
        @subjects = index(data.fetch("subjects"))
        @facts = index(data.fetch("facts"))
        validate!
      end

      def matching(topic:, entities:)
        query = " #{Decidim::Bih::Text.fold(entities["query"])} "
        return [] if query.strip.empty?

        subjects.values.select do |subject|
          subject.fetch("topics").include?(topic.to_s) && reference_intent?(subject, query) && subject.fetch("match_groups").all? do |alternatives|
            alternatives.any? { |name| / #{Regexp.escape(Decidim::Bih::Text.fold(name))}\w* /.match?(query) }
          end
        end
      end

      def facts_for(subject)
        @facts.values.select { |row| row.fetch("subject_id") == subject.fetch("id") }
      end

      def document_for(row)
        @documents.fetch(row.fetch("document_id"))
      end

      def source_for(row)
        doc = document_for(row)
        @sources.fetch(doc.fetch("source_id")).merge("url" => doc.fetch("url"), "document_id" => doc.fetch("id"),
                                                     "document_revision_sha256" => doc.fetch("revision_sha256"))
      end

      # Dates here are exclusive upper bounds in Europe/Sarajevo. Review expiry
      # is our review policy, never presented as the publisher's effective date.
      def readiness(row, day:)
        return "revoked" if row.fetch("review_status") == "revoked"
        return "unreviewed" unless reviewed_now?(row, day:)
        return "expired" if row["effective_until"] && day >= Date.iso8601(row.fetch("effective_until"))
        return "review_expired" if day >= Date.iso8601(row.fetch("review_expires_on"))
        return "not_yet_effective" if row["effective_from"] && day < Date.iso8601(row.fetch("effective_from"))

        "ready"
      end

      private

      # A school or venue contact is owned by the existing directory reader.
      # These subjects cover calendars and dated announcements only.
      def reference_intent?(subject, query)
        case subject.fetch("domain")
        when "education" then /\b(?:raspust\w*|kalendar\w*)\b/.match?(query)
        when "culture" then /\b(?:brijun\w*|predstav\w*|sezon\w*|program\w*|veceras|danas|sutra|ulaznic\w*)\b/.match?(query)
        else true
        end
      end

      def reviewed_now?(row, day:)
        row.fetch("review_status") == "reviewed" && reviewed_chain?(row) && Date.iso8601(row.fetch("reviewed_on")) <= day
      end

      def reviewed_chain?(row)
        doc = document_for(row)
        chain = [row, doc, @sources.fetch(doc.fetch("source_id")), @subjects.fetch(row.fetch("subject_id"))]
        chain.all? { |item| item.fetch("reviewed_sha256") == self.class.revision_for(item) }
      end

      def index(rows)
        rows.index_by { |row| row.fetch("id") }.tap do |indexed|
          raise ReviewError, "Duplicate reference identities" unless indexed.size == rows.size
        end
      end

      def validate!
        [@sources, @documents, @subjects, @facts].each do |collection|
          collection.each_value do |row|
            raise ReviewError, "Missing reviewed revision" unless /\A[0-9a-f]{64}\z/.match?(row.fetch("reviewed_sha256"))
          end
        end
        @sources.each_value { |row| raise ReviewError, "Unknown reference authority" unless AUTHORITIES.include?(row.fetch("authority")) }
        @documents.each_value { |row| validate_document!(row) }
        @facts.each_value { |row| validate_fact!(row) }
      rescue KeyError, ArgumentError => e
        raise ReviewError, "Invalid citizen reference catalogue: #{e.class.name}"
      end

      def validate_document!(row)
        @sources.fetch(row.fetch("source_id"))
        uri = URI.parse(row.fetch("url"))
        raise ReviewError, "Reference requires public HTTPS citation" unless uri.scheme == "https" && uri.host && !uri.userinfo
        raise ReviewError, "Missing document revision" unless /\A[0-9a-f]{64}\z/.match?(row.fetch("revision_sha256"))

        Date.iso8601(row.fetch("reviewed_on"))
        Date.iso8601(row.fetch("published_on")) if row["published_on"]
      end

      def validate_fact!(row)
        @subjects.fetch(row.fetch("subject_id"))
        @documents.fetch(row.fetch("document_id"))
        %w(reviewed_on review_expires_on).each { |key| Date.iso8601(row.fetch(key)) }
        %w(effective_from effective_until occurs_from occurs_until).each { |key| Date.iso8601(row[key]) if row[key] }
        raise ReviewError, "Missing fact citation content" if row.fetch("text").empty? || row.fetch("next_action").empty?
      end
    end
  end
end
