# frozen_string_literal: true

require "net/http"
require "uri"
require "digest"
require "json"
require "nokogiri"
require "timeout"
require "openssl"
require_relative "city_notice_discovery"

module DecidimApp
  module Bijeljina
    # Background-only selected public-call extraction from the existing city
    # notice source. Its own projection never enters outage notification flows.
    class PublicCallsPreparation
      SOURCE_KEY = "public_calls"
      PARENT_SOURCE_KEY = "city_official_notices"
      PARSER_VERSION = "public-calls-v3"
      MAX_ARTICLES = 8
      MAX_BYTES = 262_144
      MAX_TOTAL_BYTES = (MAX_ARTICLES + 1) * MAX_BYTES
      MAX_SECONDS = 20
      MONTHS = CityServiceTime::MONTHS
      CALL_PATTERN = /\b(?:javn\w* (?:poziv\w*|konkurs\w*|rasprav\w*|uvid\w*)|konsultacij\w*)\b/
      AMENDMENT_PATTERN = /\b(?:izmjen\w*|izmen\w*|dopun\w*|produz\w*|produlj\w*|isprav\w*)\b/
      CANCELLATION_PATTERN = /\b(?:ponist\w*|otkaz\w*|obustav\w*)\b/
      RESULTS_PATTERN = /\b(?:rezultat\w*|rang(?:iranje|iran\w*| list\w*)|lista (?:korisnik\w*|dobitnik\w*|kandidat\w*))\b/
      ASSESSMENT_PATTERN = /\b(?:ocjenjiv\w*|ocenjiv\w*|bodov\w*|evaluacij\w*|rangir\w*|obrada prijav\w*)\b/
      CLOSED_PATTERN = /\b(?:ponist\w*|otkaz\w*|obustav\w*|zatvoren\w*|konacn\w* rang list\w*|rezultat\w*)\b/
      NUMERIC_WINDOW_PATTERN = %r{\bod\s+(\d{1,2}[./-]\d{1,2}[./-]\d{4})\.?\s+do\s+(\d{1,2}[./-]\d{1,2}[./-]\d{4})}
      WINDOW_PATTERN = /\bod\s+(\d{1,2})\.\s*([a-z]+)(?:\s+(\d{4})\.?)?\s+do\s+(\d{1,2})\.\s*([a-z]+)\s+(\d{4})\b/
      FULL_DATE_PATTERN = %r{(?:(\d{1,2})[./-](\d{1,2})[./-](\d{4})|(\d{1,2})\.\s*([a-z]+)\s+(\d{4}))\b}
      class InvalidSource < StandardError; end

      def initialize(organization:, source_store: nil, fetcher: nil, area_matcher: nil, rss_fetcher: nil)
        @organization = organization
        @store = source_store || CityServiceSourceCheckStore.new
        @fetcher = fetcher || method(:fetch_article)
        @rss_fetcher = rss_fetcher || (method(:fetch_article) if fetcher.nil?)
        @matcher = area_matcher || CityServiceAreaMatcher.new(organization:)
      end

      def self.snapshot_key(organization)
        "#{SOURCE_KEY}:#{organization.id}"
      end

      def self.version_for(store: CityServiceSourceCheckStore.new)
        source = CityServiceSources.fetch(PARENT_SOURCE_KEY)
        Digest::SHA256.hexdigest(JSON.generate([PARSER_VERSION, store.version_for(source), (File.file?(PlaceAliasRegistry::CONFIG_PATH) ? Digest::SHA256.file(PlaceAliasRegistry::CONFIG_PATH).hexdigest : "local_reference_not_configured")]))
      end

      # Keep bounded fetch checks and atomic preparation outcome in the same background operation.
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def call(html:, source_url:, fetched_at:, deadline: nil, rss_body: nil)
        raise InvalidSource, "local reference data is not configured" unless File.file?(PlaceAliasRegistry::CONFIG_PATH)
        source = CityServiceSources.fetch(PARENT_SOURCE_KEY)
        raise InvalidSource, "unapproved listing URL" unless approved_url(source_url, source.fetch(:source_url))

        @expires_at = monotonic + [MAX_SECONDS, deadline ? deadline.remaining_seconds.to_f : MAX_SECONDS].min
        @total_bytes = 0
        @rss_error = nil
        rss_body ||= fetch_rss if @rss_fetcher
        links = CityNoticeDiscovery.call(html:, source_url:, rss_body:)
        items = []
        links.first(MAX_ARTICLES).each do |url|
          response = Timeout.timeout(remaining!) { @fetcher.call(url:, timeout: remaining!, max_bytes: MAX_BYTES) }
          final_url = approved_url(response.fetch(:final_url, url), url, article: true)
          body = response.fetch(:body).to_s
          @total_bytes += body.bytesize
          unless response.fetch(:http_status).to_i == 200 && final_url && body.bytesize <= MAX_BYTES && @total_bytes <= MAX_TOTAL_BYTES
            raise InvalidSource, "incomplete article fetch"
          end
          raise InvalidSource, "unexpected article type" unless response.fetch(:content_type, "text/html").start_with?("text/html")

          items << extract(body, final_url, fetched_at)
          remaining!
        end
        unresolved_updates = reconcile_updates(items)
        status = items.empty? ? "empty" : "ok"
        status = "unreviewed" if unresolved_updates
        payload = { "status" => status,
                    "error_code" => ("public_call_update_target_unreviewed" if unresolved_updates), "items" => items, "checked_at" => fetched_at.iso8601,
                    "parser_version" => PARSER_VERSION, "parent_source_key" => PARENT_SOURCE_KEY,
                    "organization_id" => @organization.id, "coverage" => { "listing_candidates" => links.size, "prepared_articles" => items.size,
                                                                           "complete_inventory" => false, "scope" => "selected_official_city_listing_calls",
                                                                           "rss_discovery_checked" => rss_body.present?, "rss_discovery_error" => @rss_error } }
        @store.promote(source_key: self.class.snapshot_key(@organization), source_version: self.class.version_for(store: @store), payload:, success: !unresolved_updates,
                       attempted_at: fetched_at, checked_at: fetched_at, content_hash: Digest::SHA256.hexdigest(JSON.generate(items)))
        payload
      rescue InvalidSource, Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError
        payload = { "status" => "unreviewed", "organization_id" => @organization.id, "items" => [], "checked_at" => nil, "error_code" => "public_calls_preparation_incomplete",
                    "parser_version" => PARSER_VERSION, "parent_source_key" => PARENT_SOURCE_KEY }
        @store.promote(source_key: self.class.snapshot_key(@organization), source_version: self.class.version_for(store: @store), payload:, success: false,
                       attempted_at: fetched_at)
        payload
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # Keep source evidence and explicit unknown fields together; link and coverage rules have dedicated helpers.
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def extract(html, source_url, fetched_at)
        doc = Nokogiri::HTML(html)
        article = doc.at_css(".blog__content article")
        body = article&.at_css(".entry__article")
        title = clean(article&.at_css(".single-post__entry-header .single-post__entry-title, .single-post__entry-header .entry-title")&.text)
        raise InvalidSource, "primary public call unavailable" unless body && title.present? && lexical(title).match?(CALL_PATTERN)

        published = parse_date(lexical(article.at_css(".single-post__entry-header .entry__meta")&.text))
        update_role = document_role(title)
        return result_notice(title, source_url, published, fetched_at, html) if update_role == "results"

        body.css("script, style, nav, aside, footer, .related, .related-posts, .post-gallery").remove
        body.css("br").each { |node| node.replace("\n") }
        lines = body.text.split(/\n+/).map { |line| clean(line) }.reject(&:empty?)
        assessment_lines = lines.select { |line| lexical(line).match?(ASSESSMENT_PATTERN) }
        time_lines = (lines - assessment_lines).select { |line| lexical(line).match?(/\b(?:prijav\w*|podnos\w*|rok\w*|otvoren\w*|rasprav\w*|uvid\w*)\b/) }
        window = application_window(time_lines)
        assessment_window = application_window(assessment_lines)
        eligible = lines.select { |line| lexical(line).match?(/\b(?:pravo (?:ucesca|prijave)|uslov\w*|namijenjen\w*|namenjen\w*|prebivalist\w*)\b/) }.first(3)
        # A venue mentioned in a title is not a residency/eligibility rule.
        area_evidence = eligible.join(" ")
        area_match = @matcher.match(area_evidence)
        citywide = lexical(area_evidence).match?(/prebivalist\w*.{0,35}(?:grada|gradu) bijeljin/)
        attachments = public_attachments(body, source_url)
        related_urls = related_calls(body, source_url)
        documents = lines.select { |line| lexical(line).match?(/\b(?:dokumentacij\w*|dokaz\w*|uvjerenj\w*|potvrd\w*|priloz\w*|prilag\w*)\b/) }.first(4)
        application = lines.select do |line|
          lexical(line).match?(/
            \b(?:prijav\w*|zahtjev\w*|zahtev\w*)\b.*\b(?:podnos\w*|dostav\w*|salj\w*|predaj\w*|obraz\w*)\b|
            \b(?:podnos\w*|dostav\w*|predaj\w*)\b.*\bprijav\w*\b
          /x)
        end.first(3)
        closed = lexical(title).match?(CLOSED_PATTERN) || lines.any? { |line| lexical(line).match?(/javni (?:poziv|konkurs).{0,20}(?:ponisten|otkazan|obustavljen|zatvoren)/) }
        {
          "id" => "public_call:grad-bijeljina:#{CityNoticeDiscovery.article_id(source_url)}",
          "provider_document_id" => CityNoticeDiscovery.article_id(source_url), "title" => title[0, 400],
          "kind" => lexical(title).match?(/rasprav|uvid|konsultacij/) ? "public_consultation" : "public_call",
          "notice_type" => notice_type(title),
          "source_url" => source_url, "source_published_on" => published&.iso8601, "observed_at" => fetched_at.iso8601,
          "content_hash" => Digest::SHA256.hexdigest(html), "opens_on" => window[:opens_on]&.iso8601,
          "closes_on" => window[:closes_on]&.iso8601, "closes_at" => window[:closes_at]&.iso8601, "deadline_evidence" => window[:evidence],
          "temporal_status" => temporal_status(window, closed),
          "assessment_opens_on" => assessment_window[:opens_on]&.iso8601, "assessment_closes_on" => assessment_window[:closes_on]&.iso8601,
          "assessment_period_evidence" => assessment_window[:evidence],
          "eligibility_evidence" => eligible.map { |line| redact(line)[0, 700] }, "eligibility_complete" => false,
          "issuer" => "Grad Bijeljina", "document_role" => update_role || "original", "related_source_urls" => related_urls,
          "required_documents_evidence" => documents.map { |line| redact(line)[0, 500] }, "required_documents_complete" => false,
          "application_evidence" => application.map { |line| redact(line)[0, 500] }, "application_url" => source_url,
          "attachments" => attachments,
          "coverage" => eligibility_coverage(area_match, citywide),
          "warnings" => ["eligibility_must_be_checked_in_official_call", *(window[:warning] ? [window[:warning]] : []),
                         *(published ? [] : ["publication_date_unknown"])]
        }
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      private

      def fetch_rss
        response = Timeout.timeout(remaining!) { @rss_fetcher.call(url: CityNoticeDiscovery::RSS_URL, timeout: remaining!, max_bytes: MAX_BYTES) }
        body = response.fetch(:body).to_s
        @total_bytes += body.bytesize
        valid = response.fetch(:http_status).to_i == 200 && response.fetch(:final_url, CityNoticeDiscovery::RSS_URL) == CityNoticeDiscovery::RSS_URL
        raise InvalidSource, "city RSS unavailable" unless valid && body.bytesize <= MAX_BYTES

        CityNoticeDiscovery.rss_links(body)
        body
      rescue InvalidSource, Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError
        @rss_error = "city_rss_discovery_unavailable"
        nil
      end

      def notice_type(title)
        folded = lexical(title)
        return "results" if folded.match?(RESULTS_PATTERN)
        return "public_hearing" if folded.match?(/rasprav|konsultacij/)
        return "public_display" if folded.match?(/uvid/)

        "public_call"
      end

      # Keep only a notice that results exist. Neither named result bodies nor
      # attachments or eligibility fields are projected into civic knowledge.
      def result_notice(title, source_url, published, fetched_at, html)
        identifier = CityNoticeDiscovery.article_id(source_url)
        { "id" => "public_call:grad-bijeljina:#{identifier}", "provider_document_id" => identifier,
          "title" => title[0, 400], "kind" => "public_call", "notice_type" => "results", "document_role" => "results",
          "temporal_status" => "closed", "source_url" => source_url, "source_published_on" => published&.iso8601,
          "observed_at" => fetched_at.iso8601, "content_hash" => Digest::SHA256.hexdigest(html),
          "coverage" => { "area_slugs" => [], "geographic_scope" => "unknown" }, "attachments" => [],
          "privacy_status" => "result_body_excluded", "warnings" => ["personal_results_not_indexed"] }
      end

      def public_attachments(body, source_url)
        body.css("a[href]").filter_map do |anchor|
          url = approved_url(anchor["href"], source_url)
          next unless url && URI.parse(url).path.match?(/\.(?:pdf|docx?|xlsx?|odt)\z/i)

          { "url" => url, "label" => clean(anchor.text)[0, 250], "content_reviewed" => false }
        end.first(8)
      end

      def related_calls(body, source_url)
        body.css("a[href]").filter_map do |anchor|
          next unless lexical(anchor.text).match?(CALL_PATTERN) || lexical(anchor.text).match?(/\b(?:izvorn\w*|originaln\w*|prethodn\w*)\b/)

          approved_url(anchor["href"], source_url, article: true)
        end.uniq - [source_url]
      end

      def document_role(title)
        if lexical(title).match?(RESULTS_PATTERN)
          "results"
        elsif lexical(title).match?(CANCELLATION_PATTERN)
          "cancellation"
        elsif lexical(title).match?(AMENDMENT_PATTERN)
          "amendment"
        end
      end

      def temporal_status(window, closed)
        return "cancelled" if closed
        return "unknown" unless window[:closes_on]

        window[:opens_on] ? "bounded_window" : "deadline_only"
      end

      def eligibility_coverage(area_match, citywide)
        scope = area_match.slugs.any? ? area_match.targeting_level : "unknown"
        scope = "citywide_eligibility" if citywide
        { "area_slugs" => area_match.slugs, "geographic_scope" => scope,
          "relation" => "eligibility_area", "status" => area_match.coverage&.fetch("status", "unknown"),
          "unresolved_places" => area_match.coverage&.fetch("unresolved_places", []),
          "ambiguous_places" => area_match.coverage&.fetch("ambiguous_places", []), "alias_revision" => area_match.coverage&.fetch("alias_revision", nil) }
      end

      # Only explicit canonical links establish a lifecycle relation. An update
      # without its target must be reviewed, rather than leaving an old deadline
      # looking authoritative. Do not guess identity from similar headlines.
      def reconcile_updates(items)
        unresolved = false
        items.each do |update|
          next unless %w(amendment cancellation).include?(update["document_role"])

          targets = Array(update["related_source_urls"])
          unless targets.one?
            unresolved = true
            update["warnings"] << "public_call_update_target_unreviewed"
            next
          end
          items.each do |original|
            next unless targets.any? { |url| CityNoticeDiscovery.article_id(url) == original["provider_document_id"] }

            original["temporal_status"] = update["document_role"] == "cancellation" ? "cancelled" : "superseded"
            original["superseded_by"] = update["source_url"]
          end
        end
        unresolved
      end

      # Retain the precedence of numeric windows, named-month windows and explicit deadlines.
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def application_window(lines)
        windows = lines.filter_map do |line|
          folded = lexical(line)
          if (numeric = folded.match(NUMERIC_WINDOW_PATTERN))
            opening = parse_date(numeric[1])
            closing = parse_date(numeric[2])
            if opening && closing && opening <= closing
              { opens_on: opening, closes_on: closing, evidence: redact(line)[0, 500] }
            else
              { opens_on: nil, closes_on: nil, evidence: redact(line)[0, 500], warning: "application_window_contradictory" }
            end
          elsif (match = folded.match(WINDOW_PATTERN))
            closing = date_parts(match[6], MONTHS[match[5]], match[4])
            opening = date_parts(match[3] || match[6], MONTHS[match[2]], match[1])
            next({ opens_on: nil, closes_on: nil, evidence: redact(line)[0, 500], warning: "application_window_contradictory" }) unless opening && closing && opening <= closing

            { opens_on: opening, closes_on: closing, evidence: redact(line)[0, 500] }
          elsif (deadline_match = folded.match(/\b(?:rok(?: za (?:prijavu|prijave|podnosenje prijava))?\s*(?:je|:|do)|(?:otvoren\w*|prijav\w*)\b.{0,80}\bdo\b)\s*(.+)/))
            closing_text = deadline_match[1]
            closing = parse_date(closing_text)
            { opens_on: nil, closes_on: closing, evidence: redact(line)[0, 500], warning: closing ? nil : "application_deadline_unknown" }
          end
        end
        windows = windows.map { |window| with_closing_clock(window) }
        distinct = windows.map { |window| window.slice(:opens_on, :closes_on, :closes_at) }.uniq
        return { opens_on: nil, closes_on: nil, evidence: nil, warning: "application_deadline_conflicting" } if distinct.size > 1

        windows.first || { opens_on: nil, closes_on: nil, evidence: nil, warning: "application_deadline_unknown" }
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # Keep conflicting clock and invalid local-time guards next to the evidence they reject.
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def with_closing_clock(window)
        return window unless window[:closes_on] && window[:evidence]

        evidence = lexical(window[:evidence])
        date_match = evidence.to_enum(:scan, FULL_DATE_PATTERN).map { Regexp.last_match.dup }.reverse.find do |match|
          parse_date(match[0]) == window[:closes_on]
        end
        return window unless date_match

        suffix = evidence[date_match.end(0)..]
        clocks = suffix.scan(/\b(\d{1,2})[:.](\d{2})(?!\d|\.\d)/).map { |parts| parts.map(&:to_i) }
        clocks += suffix.scan(/\b(\d{1,2})\s*(?:sati|casova|h)\b/).map { |parts| [parts.first.to_i, 0] }
        clocks.uniq!
        return window if clocks.empty?
        return { opens_on: nil, closes_on: nil, evidence: window[:evidence], warning: "application_deadline_clock_conflicting" } if clocks.size > 1

        day = window[:closes_on]
        hour, minute = clocks.first
        return { opens_on: nil, closes_on: nil, evidence: window[:evidence], warning: "application_deadline_clock_invalid" } if hour > 23 || minute > 59

        deadline = ActiveSupport::TimeZone["Europe/Sarajevo"].local(day.year, day.month, day.day, hour, minute)
        return { opens_on: nil, closes_on: nil, evidence: window[:evidence], warning: "application_deadline_clock_invalid" } unless deadline.hour == hour && deadline.min == minute

        window.merge(closes_at: deadline)
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def parse_date(value)
        match = value.to_s.match(FULL_DATE_PATTERN)
        return unless match

        match[1] ? date_parts(match[3], match[2], match[1]) : date_parts(match[6], MONTHS[match[5]], match[4])
      end

      def date_parts(year, month, day)
        return unless year && month && day

        Date.new(year.to_i, month.to_i, day.to_i)
      rescue Date::Error
        nil
      end

      def approved_url(value, base, article: false)
        return if value.to_s.bytesize > 2_000

        uri = URI.join(base, value.to_s)
        expected = URI.parse(CityServiceSources.fetch(PARENT_SOURCE_KEY).fetch(:source_url))
        return unless uri.scheme == "https" && uri.host == expected.host && uri.port == 443 && uri.userinfo.nil?
        return if article && !uri.path.match?(CityNoticeDiscovery::ARTICLE_PATH)

        uri.fragment = nil
        uri.query = nil
        uri.to_s
      rescue URI::InvalidURIError
        nil
      end

      def fetch_article(url:, timeout:, max_bytes:)
        uri = URI.parse(url)
        timeout = CitySourceRequestPolicy.default.before_request(uri, timeout:)
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: timeout, read_timeout: timeout) do |http|
          request = Net::HTTP::Get.new(uri)
          request["User-Agent"] = CitySourceRequestPolicy::USER_AGENT
          http.request(request) do |response|
            CitySourceRequestPolicy.default.observe_response(uri, response)
            # Redirects are not followed implicitly, keeping the fetch origin
            # contract narrow. A moved source is surfaced for source review.
            body = +""
            response.read_body do |chunk|
              body << chunk
              raise InvalidSource, "article too large" if body.bytesize > max_bytes
            end
            return { http_status: response.code.to_i, final_url: url, content_type: response["content-type"].to_s, body: }
          end
        end
      rescue CitySourceRequestPolicy::PolicyError
        raise InvalidSource, "source request policy refused"
      end

      def clean(text)
        text.to_s.gsub(/[\u200b\uFEFF]/, "").gsub(/\s+/, " ").strip
      end

      def redact(text)
        text.gsub(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i, "[kontakt u izvoru]")
            .gsub(%r{(?:\+387|0\d{2})[\s/-]*\d{3}[\s/-]*\d{3,4}\b}, "[kontakt u izvoru]")
      end

      def lexical(text)
        value = Decidim::Bih::Transliterator.to_latin(text.to_s.downcase)
        Decidim::Bih::Text::DIACRITICS.each { |from, to| value = value.gsub(from, to) }
        value.gsub(/\s+/, " ")
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def remaining!
        seconds = @expires_at - monotonic
        raise Timeout::Error, "public call deadline" unless seconds.positive?

        seconds
      end
    end
  end
end
