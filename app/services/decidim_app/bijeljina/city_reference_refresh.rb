# frozen_string_literal: true

require "digest"
require "json"
require "nokogiri"
require "net/http"
require "uri"

require_relative "city_source_request_policy"
require_relative "gazette_source_identity"

module DecidimApp
  module Bijeljina
    # Scheduled preparation for the year archive and reviewed procedure cards.
    # Fetching a changed procedure is not editorial approval of its new facts.
    class CityReferenceRefresh
      VERSION = "city-reference-v1"
      GAZETTE_KEY = "reference:gazette:2026"
      GAZETTE_URL = Gazette.source_url.freeze
      MAX_ISSUES = 30
      MAX_HTML_BYTES = 1_000_000
      MAX_PDF_BYTES = 4_000_000

      def initialize(store: CityServiceSourceCheckStore.new, fetcher: nil, clock: -> { Time.current })
        @store = store
        @fetcher = fetcher || method(:fetch_public_source)
        @clock = clock
      end

      def call(deadline: nil)
        deadline ||= SourceRefreshBudget.new(timeout: 180)
        { gazette: refresh_gazette(deadline:), procedures: refresh_procedures(deadline:) }
      end

      def refresh_gazette(deadline: nil)
        return { status: :disabled, reason: "gazette_source_not_configured" } if GAZETTE_URL.empty?

        deadline ||= SourceRefreshBudget.new(timeout: 120)
        with_reference_lock(GAZETTE_KEY) do
          response = fetch(url: GAZETTE_URL, max_bytes: MAX_HTML_BYTES, deadline:)
          index = Decidim::Bih::City::GazetteIndex.from_index_html(response.fetch(:body), base_url: GAZETTE_URL)
          entries = index.all.select { |entry| entry.fetch(:number).end_with?("/2026") }
          raise ArgumentError, "unexpected gazette archive coverage" unless entries.size.between?(1, MAX_ISSUES)

          validate_gazette_coverage!(entries)

          checked_at = clock.call
          prepared = entries.map { |entry| prepare_gazette_entry(entry, index, checked_at, deadline) }
          prepared += GazetteData.entries_for_source(GAZETTE_URL).reject { |entry| entry.fetch(:number).end_with?("/2026") }
          payload = { "status" => "ok", "checked_at" => checked_at.iso8601,
                      "source_url" => GazetteSourceIdentity.canonical_url(GAZETTE_URL), "source_identity" => GazetteSourceIdentity.for_url(GAZETTE_URL),
                      "entries" => JSON.parse(JSON.generate(prepared)),
                      "coverage" => { "archive_year" => 2026, "observed_issue_count" => entries.size, "full_text_indexed" => false,
                                      "archive_links_complete_at_check" => true, "full_year_complete" => false,
                                      "reviewed_act_count" => prepared.sum { |entry| Array(entry[:reviewed_acts]).size }, "complete_act_coverage" => false } }
          store.promote(source_key: GAZETTE_KEY, source_version: VERSION, payload:, success: true,
                        attempted_at: checked_at, checked_at:, content_hash: Digest::SHA256.hexdigest(JSON.generate(prepared)))
          { status: :ok, count: entries.size, checked_at: }
        end || { status: :refresh_in_progress }
      end

      def refresh_procedures(deadline: nil)
        deadline ||= SourceRefreshBudget.new(timeout: 60)
        ServiceProcedures.all.map do |card|
          source_key = "reference:procedure:#{card.fetch(:key)}"
          outcome = with_reference_lock(source_key) do
            uri = URI.parse(card.fetch(:source_url))
            raise ArgumentError, "unapproved procedure source" unless approved_reference_origin?(uri, hosts: ServiceProcedures::REVIEWED_HOSTS)

            response = fetch(url: card.fetch(:source_url), max_bytes: MAX_HTML_BYTES, deadline:)
            hash = self.class.procedure_content_hash(response.fetch(:body), selector: card.fetch(:source_fragment))
            unchanged = hash == card.fetch(:reviewed_content_hash)
            now = clock.call
            payload = { "status" => unchanged ? "ok" : "unreviewed", "checked_at" => now.iso8601,
                        "source_url" => card.fetch(:source_url), "content_hash" => hash,
                        "reviewed_on" => card.fetch(:source_checked_on), "error_code" => unchanged ? nil : "procedure_content_changed" }
            payload["review_required_for_hash"] = card.fetch(:reviewed_content_hash) unless unchanged
            store.promote(source_key:, source_version: VERSION, payload:, success: unchanged, attempted_at: now,
                          checked_at: unchanged ? now : nil, content_hash: hash)
            { key: card.fetch(:key), status: payload.fetch("status"), checked_at: now, reviewed_on: card.fetch(:source_checked_on) }
          end
          (outcome || { status: :refresh_in_progress }).merge(key: card.fetch(:key))
        end
      end

      def self.procedure_content_hash(html, selector:)
        document = Nokogiri::HTML(html)
        selectors = { "entry__article" => ".entry__article", "body" => "body", "registry_detail" => "main .col-lg-9 .card" }
        root = document.at_css(selectors.fetch(selector))
        raise ArgumentError, "procedure content region missing" unless root

        root.css("script, style, nav, header, footer, form, input").remove
        text = root.text.gsub(/\s+/, " ").strip
        raise ArgumentError, "procedure content empty" if text.empty?

        Digest::SHA256.hexdigest(text)
      end

      private

      attr_reader :store, :fetcher, :clock

      def validate_gazette_coverage!(entries)
        previous = store.snapshot(source_key: GAZETTE_KEY)
        matching = previous && previous.source_version == VERSION && GazetteSourceIdentity.matches_payload?(previous.last_good_payload, source_url: GAZETTE_URL)
        observed_count = matching ? Array(previous.last_good_payload["entries"]).count { |entry| entry["number"].end_with?("/2026") } : 0
        reviewed_count = GazetteData.entries_for_source(GAZETTE_URL).count { |entry| entry.fetch(:number).end_with?("/2026") }
        known_count = [observed_count, reviewed_count, 1].max
        raise ArgumentError, "gazette archive unexpectedly lost issues" if entries.size < known_count
      end

      def prepare_gazette_entry(entry, index, checked_at, deadline)
        uri = URI.parse(entry.fetch(:url))
        archive = URI.parse(GAZETTE_URL)
        unless reviewed_reference_url?(uri) && uri.host.to_s.downcase == archive.host.to_s.downcase && uri.path.end_with?(".pdf")
          raise ArgumentError, "unexpected gazette document URL"
        end

        pdf = fetch(url: entry.fetch(:url), max_bytes: MAX_PDF_BYTES, deadline:)
        hash = Digest::SHA256.hexdigest(pdf.fetch(:body))
        entry.merge(gazette_summary_metadata(entry, hash)).merge(source_checked_on: checked_at.to_date.iso8601,
                                                                 published_on: index.send(:parse_date, entry[:date])&.iso8601,
                                                                 content_hash: hash, full_text_indexed: false, archive_year: 2026,
                                                                 reviewed_acts: GazetteActs.for_issue(number: entry.fetch(:number), content_hash: hash))
      end

      def gazette_summary_metadata(entry, hash)
        baseline = GazetteData.entries_for_source(GAZETTE_URL).find { |known| known.fetch(:number) == entry.fetch(:number) && known[:content_hash] == hash }
        return baseline.slice(:summary, :source_pdf_pages, :summary_source_url, :summary_provenance) if baseline

        { summary: nil, source_pdf_pages: [], summary_provenance: "issue_metadata_only" }
      end

      def with_reference_lock(key)
        store.with_refresh_lock(key) do
          yield
        rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
          raise
        rescue StandardError => e
          # Keep failure promotion inside the same lock as the attempted
          # fetch, so it cannot overwrite a newer worker's successful check.
          record_failure(key, e)
        end
      end

      def fetch(url:, max_bytes:, deadline:)
        raise ArgumentError, "unapproved reference source" unless reviewed_reference_url?(URI.parse(url.to_s))

        response = CityServiceNoticeCollector.send(:within_deadline, deadline) do
          fetcher.call(source: { key: "city_reference", source_url: url }, timeout: 8, max_bytes:,
                       user_agent: CityServiceNoticeCollector::DEFAULT_USER_AGENT, deadline:)
        end
        raise ArgumentError, "reference source HTTP failure" unless response.fetch(:http_status).to_i.between?(200, 299)
        raise ArgumentError, "reference source empty or oversized" unless response.fetch(:body).to_s.bytesize.between?(1, max_bytes)

        final = URI.parse(response.fetch(:final_url, url))
        original = URI.parse(url)
        unless final.scheme == original.scheme && final.host == original.host && final.port == original.port && final.path == original.path && final.userinfo.nil?
          raise ArgumentError,
                "reference URL changed authority"
        end
        raise ArgumentError, "invalid PDF document" if original.path.end_with?(".pdf") && !response.fetch(:body).start_with?("%PDF-")

        response
      end

      def configured_archive_host
        archive = URI.parse(GAZETTE_URL)
        archive.host if archive.scheme == "https" && archive.port == 443 && archive.userinfo.nil?
      rescue URI::InvalidURIError
        nil
      end

      def reviewed_reference_url?(uri)
        hosts = [configured_archive_host, *ServiceProcedures::REVIEWED_HOSTS].compact.map(&:downcase)
        approved_reference_origin?(uri, hosts:)
      end

      def approved_reference_origin?(uri, hosts:)
        uri.scheme == "https" && uri.port == 443 && uri.userinfo.nil? && hosts.map(&:downcase).include?(uri.host.to_s.downcase)
      end

      def fetch_public_source(source:, timeout:, max_bytes:, user_agent:, deadline:)
        uri = URI.parse(source.fetch(:source_url))
        raise ArgumentError, "unapproved reference host" unless reviewed_reference_url?(uri)

        seconds = [timeout, CityServiceNoticeCollector.send(:remaining_seconds, deadline)].compact.min
        policy = CitySourceRequestPolicy.default
        seconds = policy.before_request(uri, timeout: seconds)
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: seconds, read_timeout: seconds) do |http|
          request = Net::HTTP::Get.new(uri)
          request["User-Agent"] = user_agent
          body = +""
          result = nil
          http.request(request) do |response|
            policy.observe_response(uri, response)
            # These reviewed canonical URLs resolve without redirects. A changed
            # endpoint is an explicit review event, never a cross-host fetch.
            raise ArgumentError, "reference source HTTP failure" unless response.code.to_i.between?(200, 299)
            raise ArgumentError, "oversized reference source" if response["Content-Length"].to_i > max_bytes

            response.read_body do |chunk|
              raise ArgumentError, "oversized reference source" if body.bytesize + chunk.bytesize > max_bytes

              body << chunk
            end
            result = { http_status: response.code.to_i, body:, final_url: uri.to_s }
          end
          result
        end
      end

      def record_failure(key, error)
        previous = store.snapshot(source_key: key)&.check_payload || {}
        error_code = error.is_a?(CitySourceRequestPolicy::PolicyError) ? error.code.to_s : "reference_refresh_failed"
        payload = { "status" => "unavailable", "error_code" => error_code }
        payload.merge!(previous.slice("review_required_for_hash", "source_url")) if previous["review_required_for_hash"]
        store.promote(source_key: key, source_version: VERSION,
                      payload:,
                      success: false, attempted_at: clock.call)
        { status: :unavailable, error_code: error.class.name }
      end
    end
  end
end
