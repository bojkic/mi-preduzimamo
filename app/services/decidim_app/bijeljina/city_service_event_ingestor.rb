# frozen_string_literal: true

require "digest"
require "json"

module DecidimApp
  module Bijeljina
    class CityServiceEventIngestor
      # The stored identity of one source occurrence at one version. The
      # backfill re-keys existing rows with it, so it cannot live only inside
      # the upsert path.
      def self.fingerprint_for(source_key:, occurrence:, content_version:)
        Digest::SHA256.hexdigest([source_key, occurrence, content_version].join("\0"))
      end

      Result = Struct.new(:created, :updated, :unchanged, :events, :complete, keyword_init: true) do
        def complete? = complete != false
      end
      PARSER_SOURCE_KEYS = [
        ElectricityOutageParser::SOURCE_KEY,
        CityServiceWeatherParser::SOURCE_KEY,
        *CityServiceOfficialPostParser::SOURCE_KEYS
      ].freeze

      def self.parser_registered?(source_key)
        PARSER_SOURCE_KEYS.include?(source_key.to_s)
      end

      def initialize(organization:)
        @organization = organization
      end

      def ingest(source_key:, html:, source_url: nil, fetched_at: Time.current, weather_region: nil)
        return ingest_electricity(html:, source_url:, fetched_at:) if source_key.to_s == ElectricityOutageParser::SOURCE_KEY

        return ingest_weather(html:, source_url:, fetched_at:, region: weather_region) if source_key.to_s == CityServiceWeatherParser::SOURCE_KEY

        source = CityServiceSources.fetch(source_key)
        parser = CityServiceOfficialPostParser.new(organization:, source:)
        source_url = source_url.presence || source.fetch(:source_url)
        complete = parser.complete_snapshot?(html:, source_url:)
        candidates = parse(source_key:, html:, source_url:, fetched_at:)
        candidates.each do |candidate|
          candidate.extraction_metadata.merge!("source_snapshot_complete" => false, "source_document_complete" => false) unless complete
        end
        result = ingest_candidates(candidates)
        result.complete = false unless complete
        result
      end

      def ingest_article(source:, article:, fetched_at: Time.current)
        return Result.new(created: 0, updated: 0, unchanged: 0, events: [], complete: false) unless article.complete

        reconciler.with_document_lock(source_key: source.fetch(:key), document_url: article.source_url) do
          candidates = CityServiceOfficialPostParser.new(organization:, source:).call(article:, fetched_at:)
          result = persist(candidates)
          # An unresolved event does not make the source document partial, but
          # it cannot authorize withdrawal of previously approved facts.
          reconciler.reconcile_article(source:, article:, events: result.events,
                                       complete: result.complete? && candidates.none? { |candidate| incomplete_candidate?(candidate) },
                                       observed_at: fetched_at)
          result
        end
      end

      def ingest_candidates(candidates)
        persist(Array(candidates))
      end

      def dry_run(source_key:, html:, source_url: nil, fetched_at: Time.current)
        parse(source_key:, html:, source_url:, fetched_at:)
      end

      private

      attr_reader :organization

      def reconciler
        @reconciler ||= CityServiceSourceReconciler.new(organization:)
      end

      def ingest_electricity(html:, source_url:, fetched_at:)
        source = CityServiceSources.fetch(ElectricityOutageParser::SOURCE_KEY)
        source_url = source_url.presence || source.fetch(:source_url)
        parser = ElectricityOutageParser.new(organization:)
        complete = parser.complete_snapshot?(html:)
        document_complete = parser.structurally_complete_snapshot?(html:)
        version = Digest::SHA256.hexdigest(html.to_s)
        reconciler.with_document_lock(source_key: source.fetch(:key), document_url: source_url) do
          candidates = parser.call(html:, source_url:, fetched_at:)
          candidates.each do |candidate|
            candidate.extraction_metadata["source_snapshot_complete"] = complete
            candidate.extraction_metadata["source_document_complete"] = document_complete
          end
          if document_complete
            candidates.each do |candidate|
              candidate.extraction_metadata = candidate.extraction_metadata.merge(
                "source_document_url" => source_url, "source_document_version" => version, "source_snapshot_complete" => complete
              )
            end
          end
          result = persist(candidates)
          reconciler.reconcile_snapshot(source:, source_url:, content_version: version, events: result.events,
                                        complete:, observed_at: fetched_at)
          result
        end
      end

      def ingest_weather(html:, source_url:, fetched_at:, region: nil)
        source = CityServiceSources.fetch(CityServiceWeatherParser::SOURCE_KEY)
        source_url ||= source.fetch(:source_url)
        reconciler.with_document_lock(source_key: source.fetch(:key), document_url: source_url) do
          # WeatherCapFeed rejects malformed/incomplete source documents. Only
          # a successfully parsed authoritative feed may withdraw old members.
          parser = CityServiceWeatherParser.new(organization:, source:)
          candidates = parser.call(html:, source_url:, fetched_at:, region:)
          # Recheck after parsing, before any membership write or withdrawal.
          current_review = WeatherRegionConfiguration.for_source(source_url:,
            day: fetched_at.in_time_zone("Europe/Sarajevo").to_date)
          unless current_review.identity == parser.review_identity
            raise WeatherRegionConfiguration::InvalidConfiguration, WeatherRegionConfiguration::ERROR, cause: nil
          end
          raw_version = Digest::SHA256.hexdigest(html.to_s)
          # Membership depends on the operator's region review and board policy,
          # even when the provider body is byte-identical. Keep the raw digest
          # separately; a changed review cannot silently retain old board facts.
          version = Digest::SHA256.hexdigest(JSON.generate([
            "weather-source-review-v1", CityServiceWeatherParser::PARSER_VERSION,
            raw_version, parser.review_identity, CityServiceWeatherParser::BOARD_SEVERITIES
          ]))
          candidates.each do |candidate|
            candidate.extraction_metadata.merge!("source_document_url" => source_url, "source_document_version" => version,
                                                 "source_document_raw_sha256" => raw_version,
                                                 "source_document_version_basis" => "body_region_review_and_board_policy",
                                                 "source_snapshot_complete" => true, "source_document_complete" => true)
          end
          result = persist(candidates)
          reconciler.reconcile_snapshot(source:, source_url:, content_version: version, events: result.events, complete: true, observed_at: fetched_at)
          result
        end
      end

      def parse(source_key:, html:, source_url:, fetched_at:)
        case source_key.to_s
        when ElectricityOutageParser::SOURCE_KEY
          ElectricityOutageParser.new(organization:).call(
            html:,
            source_url: source_url.presence || CityServiceSources.fetch(source_key).fetch(:source_url),
            fetched_at:
          )
        when CityServiceWeatherParser::SOURCE_KEY
          CityServiceWeatherParser.new(organization:).call(html:, source_url: source_url.presence || CityServiceSources.fetch(source_key).fetch(:source_url), fetched_at:)
        when *CityServiceOfficialPostParser::SOURCE_KEYS
          source = CityServiceSources.fetch(source_key)
          CityServiceOfficialPostParser.new(organization:, source:).call(
            html:,
            source_url: source_url.presence || source.fetch(:source_url),
            fetched_at:
          )
        else
          raise KeyError, "no parser registered for city-service source: #{source_key}"
        end
      end

      def persist(candidates)
        CityServiceIncident.synchronize(organization) { persist_locked(candidates) }
      end

      def persist_locked(candidates)
        counts = { created: 0, updated: 0, unchanged: 0 }
        events = candidates.map do |candidate|
          event, state = upsert_candidate(candidate)
          CityServiceIncidentIdentity.attach!(event)
          counts[state] += 1
          event
        end

        Result.new(created: counts.fetch(:created), updated: counts.fetch(:updated),
                   unchanged: counts.fetch(:unchanged), events:,
                   complete: candidates.none? { |candidate| candidate.extraction_metadata["source_snapshot_complete"] == false })
      end

      def upsert_candidate(candidate)
        attributes = candidate_attributes(candidate)
        occurrence = candidate_value(candidate, :source_occurrence_id).presence
        version = candidate_value(candidate, :content_version).presence
        fingerprint = candidate_fingerprint(candidate, occurrence:, version:)

        CityServiceEvent.transaction do
          # Lock a source occurrence even on the first insertion, when there is
          # no row to lock yet. The key is a numeric hash of public identity.
          lock_key = Digest::SHA256.hexdigest([organization.id, candidate.source_key, occurrence || fingerprint].join(":"))[0, 15].to_i(16)
          CityServiceEvent.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key})")
          event = CityServiceEvent.find_or_initialize_by(organization:, source_key: candidate.source_key,
                                                         source_fingerprint: fingerprint)
          # A partial fetch cannot downgrade the retained evidence or approval
          # of an existing identical version, including its last-good timestamp.
          next [event, :unchanged] if event.persisted? && incomplete_candidate?(candidate)

          if returning_version?(event, occurrence:, version:)
            event = fresh_review_for_returning_version(event, candidate:, occurrence:, version:, fingerprint:)
          end
          if event.persisted? && city_article_evidence_changed?(event, candidate)
            article_metadata = candidate_value(candidate, :extraction_metadata).to_h
            article_fingerprint = Digest::SHA256.hexdigest([
              fingerprint, "article-evidence", article_metadata["article_content_version"].to_s,
              article_metadata["ai_source_text"].to_s
            ].join("\0"))
            event = CityServiceEvent.find_or_initialize_by(organization:, source_key: candidate.source_key,
                                                           source_fingerprint: article_fingerprint)
            if returning_version?(event, occurrence:, version:)
              event = fresh_review_for_returning_version(event, candidate:, occurrence:, version:, fingerprint: article_fingerprint)
            end
          end
          next refresh_existing(event, candidate) if event.persisted? && (!event.pending_review? || event.extraction_metadata["publication_correction_pending"] == true ||
                                               preserve_pending_review?(event, candidate, occurrence:, version:))

          save_candidate(event, candidate, attributes:, occurrence:, version:)
        end
      end

      # Local edits already reviewed against this exact complete provider body
      # remain reviewed facts when the provider merely re-publishes that body.
      def preserve_pending_review?(event, candidate, occurrence:, version:)
        version.present? && occurrence.present? && event.content_version == version && event.source_occurrence_id == occurrence &&
          event.source_url == candidate.source_url && event.reviewed_content_version == version &&
          event.reviewed_by_id.present? && event.reviewed_at.present? && complete_candidate_document?(candidate)
      end

      def complete_candidate_document?(candidate)
        metadata = candidate_value(candidate, :extraction_metadata).to_h
        metadata["source_document_complete"] == true && metadata["source_snapshot_complete"] == true
      end

      def returning_version?(event, occurrence:, version:)
        event.persisted? && event.superseded? && occurrence && version
      end

      def candidate_fingerprint(candidate, occurrence:, version:)
        return candidate.source_fingerprint unless occurrence && version

        self.class.fingerprint_for(source_key: candidate.source_key, occurrence:, content_version: version)
      end

      def retained_preparation(event, version, candidate)
        retained = event.extraction_metadata.to_h.slice("source_document_changed")
        same_city_article = candidate.source_key == "city_official_notices" && !city_article_evidence_changed?(event, candidate)
        if version.present? && event.content_version == version && same_city_article
          decision = event.extraction_metadata["ai_classification"]
          retained["ai_classification"] = decision if decision.present?
        end
        suggestions = event.extraction_metadata["area_review_suggestions"].to_h
        retained["area_review_suggestions"] = suggestions if version.present? && event.content_version == version && suggestions["source_content_version"] == version
        retained
      end

      def save_candidate(event, candidate, attributes:, occurrence:, version:)
        new_record = event.new_record?
        attributes[:extraction_metadata] = retained_preparation(event, version, candidate).merge(attributes[:extraction_metadata])
        event.assign_attributes(attributes)
        changed = event.changed?
        event.save! if changed
        reconcile_occurrence(event, candidate) if occurrence && version && event.source_evidence_complete? && (new_record || changed)
        [event, state_for(new_record:, changed:)]
      end

      def reconcile_occurrence(event, candidate)
        previous = CityServiceEvent.for_organization(organization)
                                   .where(source_key: event.source_key, source_occurrence_id: event.source_occurrence_id,
                                          superseded_by_id: nil, state: CityServiceSourceReconciler::WITHDRAWABLE_STATES)
                                   .where.not(id: event.id)
        previous.find_each do |old|
          metadata = event.extraction_metadata
          if metadata["canonical_article_url"].present? || metadata["source_occurrence_linkable"] == false
            # Ordinals do not prove a semantic one-to-one identity after reorder.
            event.update!(extraction_metadata: metadata.merge("source_document_changed" => true))
            old.withdraw_source_version!(document_url: event.source_url,
                                         document_version: metadata["article_content_version"] || metadata["source_document_version"] || event.content_version,
                                         observed_at: candidate.fetched_at, reason: "source_group_version_changed")
          else
            old.supersede_with!(event)
          end
        end
      end

      def fresh_review_for_returning_version(previous, candidate:, occurrence:, version:, fingerprint:)
        related = CityServiceEvent.for_organization(organization).where(source_key: previous.source_key, source_occurrence_id: occurrence)
        current = related.where(content_version: version).where.not(state: "superseded").order(id: :desc).first
        return current if current && !city_article_evidence_changed?(current, candidate)

        # A source can revert to an earlier body. Its historical approval remains
        # historical: create a fresh review generation, never revive old posts.
        generation = related.maximum(:id) || previous.id
        fresh_fingerprint = Digest::SHA256.hexdigest([fingerprint, "review-generation", generation].join("\0"))
        CityServiceEvent.find_or_initialize_by(organization:, source_key: previous.source_key, source_fingerprint: fresh_fingerprint)
      end

      def refresh_existing(event, candidate)
        # Re-observation never changes extracted facts or operator review. A
        # city article may have a new document version with identical AI text.
        # Changed AI text gets a fresh review generation before this method.
        keys = %w(source_document_url source_document_version source_snapshot_complete)
        if candidate.source_key == "city_official_notices"
          keys += %w(canonical_article_url article_content_version ai_source_text source_document_complete)
        end
        observed = candidate_value(candidate, :extraction_metadata).to_h.slice(*keys)
        event.update!(fetched_at: candidate.fetched_at, extraction_metadata: event.extraction_metadata.merge(observed))
        [event, :unchanged]
      end

      def city_article_evidence_changed?(event, candidate)
        return false unless candidate.source_key == "city_official_notices"

        observed = candidate_value(candidate, :extraction_metadata).to_h
        return false unless observed.key?("ai_source_text")

        retained = event.extraction_metadata
        retained["ai_source_text"].to_s != observed["ai_source_text"].to_s ||
          retained["article_content_version"].to_s != observed["article_content_version"].to_s
      end

      def candidate_value(candidate, key)
        candidate.public_send(key) if candidate.respond_to?(key)
      end

      def incomplete_candidate?(candidate)
        metadata = candidate_value(candidate, :extraction_metadata).to_h
        metadata["source_snapshot_complete"] == false || metadata["complete"] == false
      end

      def state_for(new_record:, changed:)
        return :created if new_record
        return :updated if changed

        :unchanged
      end

      def candidate_attributes(candidate)
        {
          source_occurrence_id: candidate_value(candidate, :source_occurrence_id),
          content_version: candidate_value(candidate, :content_version),
          source_published_at: candidate_value(candidate, :source_published_at),
          source_updated_at: candidate_value(candidate, :source_updated_at),
          extraction_metadata: candidate_value(candidate, :extraction_metadata) || {},
          lifecycle: candidate_value(candidate, :lifecycle).presence || "scheduled",
          source_label: candidate.source_label,
          provider: candidate.provider,
          source_url: candidate.source_url,
          fetched_at: candidate.fetched_at,
          parser_version: candidate.parser_version,
          event_type: candidate.event_type,
          severity: candidate.severity,
          targeting_level: candidate.targeting_level,
          affected_area_slugs: Array(candidate.affected_area_slugs),
          title: candidate.title,
          summary: candidate.summary,
          affected_text: candidate.affected_text,
          recommended_action: candidate.recommended_action,
          viber_text: candidate.viber_text,
          starts_at: candidate.starts_at,
          ends_at: candidate.ends_at,
          confidence: candidate.confidence,
          classifier_reasons: Array(candidate.classifier_reasons),
          state: "pending_review"
        }
      end
    end
  end
end
