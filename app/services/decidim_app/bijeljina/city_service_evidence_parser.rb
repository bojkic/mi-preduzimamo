# frozen_string_literal: true

require "digest"
require "json"
require "nokogiri"
require "time"
require_relative "weather_cap_feed"
require_relative "weather_region_configuration"

module DecidimApp
  module Bijeljina
    # Source-declared facts, independent of operator approval or outbound alerts.
    # XML feeds supply full warning text and clocks; the AMS report is the exact
    # iframe embedded by the official site, not its navigation-only wrapper.
    module CityServiceEvidenceParser
      VERSION = "2026-09-15.1"
      NS = { "atom" => "http://www.w3.org/2005/Atom", "cap" => "urn:oasis:names:tc:emergency:cap:1.2",
             "content" => "http://purl.org/rss/1.0/modules/content/" }.freeze
      # Compatibility constants have no inherited community data. Weather
      # parsing requires an explicit, currently eligible source-bound review.
      WEATHER_AREA_CODE = "".freeze
      WEATHER_AREA_EVIDENCE = "".freeze
      LOCAL_ROADS = /\b(?:bijeljin\w*|janj[aeiu]|raca|sremska raca|patkovac\w*|glavicic\w*|balatun\w*|trnjac\w*|vrsan\w*|velika obarska)\b/
      SHORT_DATE_SPAN = /(?<first_day>\d{1,2})\.(?<first_month>\d{1,2})\.\s*(?:do|[-–—])\s*(?<last_day>\d{1,2})\.(?<last_month>\d{1,2})\.(?<year>20\d{2})\b/
      # The RUCZ RS feed is rebuilt only when the agency publishes; days without
      # a post say nothing about a warning whose own window is still running
      # (the two-day feed-age rule hid the 03.–09.09.2026 heat warning from
      # 05.09. on). A feed untouched for a month is abandoned; an undated
      # warning older than the currency window cannot be claimed current.
      CIVIL_FEED_ABANDONED_AFTER = 30.days
      CIVIL_UNDATED_CURRENCY = 2.days

      module_function

      def call(source:, body:, url:, now:, weather_region: nil)
        case source.fetch(:key)
        when "waste_schedule"
          waste_program(body, url:, now:)
        when "civil_protection"
          civil_feed(body, url:, now:)
        when "weather_warnings"
          body.lstrip.start_with?("{") ? WeatherCapFeed.call(body:, url:, now:, region: weather_region) : weather_feed(body, url:, now:, region: weather_region)
        when "road_conditions"
          roads(body, url:, now:) if body.include?("article-container")
        when "bulky_waste"
          bulky_waste(body, url:, now:) if body.include?("categoryBlog")
        end
      end

      def waste_program_registry
        return if WasteSchedule::ROUTE_REGISTRY_PATH.empty?

        JSON.parse(File.read(WasteSchedule::ROUTE_REGISTRY_PATH))
      end

      # Accept only the exact PDF whose route tables were reviewed. A changed
      # annual programme remains unreviewed until its routes are reconciled.
      def waste_program(body, url:, now:)
        return unless body.start_with?("%PDF-")

        registry = waste_program_registry
        return unless registry
        return unless Digest::SHA256.hexdigest(body) == registry.fetch("source_sha256")
        return unless url == registry.fetch("source_url")

        first = Date.iso8601(registry.fetch("valid_from"))
        last = Date.iso8601(registry.fetch("valid_until"))
        return unless (first..last).cover?(now.in_time_zone("Europe/Sarajevo").to_date)

        metadata = base_metadata("regular_waste_program", published: nil, area: "Bijeljina", geographic: "reviewed_schedule_routes")
        metadata.merge!("temporal_status" => "active", "valid_from" => first.iso8601, "valid_until" => last.iso8601,
                        "coverage" => registry.fetch("coverage"), "source_sha256" => registry.fetch("source_sha256"),
                        "exceptions_verified" => false)
        [{ title: "Program odvoza komunalnog otpada za #{first.year}. godinu",
           body: "Redovni godišnji program; pregledane kućne rute dostupne su u lokalnom rasporedu. Izuzeci nisu potvrđeni.", url:, metadata: }]
      end

      def xml(body)
        raise CityServiceNoticeCollector::ParserError, "XML declarations are not allowed" if body.match?(/<!DOCTYPE|<!ENTITY/i)

        Nokogiri::XML(body) { |config| config.strict.nonet }
      end

      def civil_feed(body, url:, now:)
        return unless body.match?(/<rss\b/)

        document = xml(body)
        channel = document.at_xpath("/rss/channel")
        raise CityServiceNoticeCollector::ParserError, "unrecognized civil-protection feed" unless channel && channel.at_xpath("link")&.text.to_s.match?(%r{\Ahttps://ruczrs\.org/?\z})

        validate_feed_alive!(parse_rfc_time(channel.at_xpath("lastBuildDate")&.text), now)
        raise CityServiceNoticeCollector::ParserError, "missing civil feed items" if document.xpath("/rss/channel/item").empty?

        document.xpath("/rss/channel/item").filter_map { |item| civil_item(item, url:, now:) }
      end

      def civil_item(item, url:, now:)
        title = clean(item.at_xpath("title")&.text)
        return unless CityServiceContentFilter.relevant?("civil_protection", title, now:)

        text = clean(item.at_xpath("content:encoded", NS)&.text)
        published = parse_rfc_time(item.at_xpath("pubDate")&.text)
        window = civil_window(text)
        area, local = civil_area(text)
        return if civil_excluded?(window, area, local, now)

        validate_publication!(published, now)
        return if civil_undated_old?(window, published, now)

        metadata = base_metadata("official_warning", published:, area:, geographic: local ? "source_declared_region" : "unverified")
        metadata.merge!(window_metadata(window, now))
        { title:, body: text, url: same_host_url(url, item.at_xpath("link")&.text), metadata: }
      end

      # A labelled single calendar day is explicit evidence, not a duration
      # inferred from publication time. Do not widen unsupported ranges/clocks.
      def civil_window(text)
        span = day_span(text)
        return span if span

        field = CityServiceTime.fold(text).split(/\bvrijeme:\s*/, 2)[1]
        match = field&.match(/\A(?<day>\d{1,2})\s*\.\s*(?<month>\d{1,2})\s*\.\s*(?<year>20\d{2})\.?(?<rest>.*)\z/)
        return unless match
        return if match[:rest].match?(/\A\s*(?:[-–—]|\d|(?:od|do|i)\b)/)

        date = Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i)
        { "starts_at" => CityServiceTime.clock(date, "00:00").iso8601,
          "ends_at" => CityServiceTime.clock(date + 1, "00:00").iso8601, "time_precision" => "day" }
      rescue Date::Error
        nil
      end

      def civil_excluded?(window, area, local, now)
        expired_window?(window, now) || (area.present? && !local)
      end

      # An undated warning older than the currency window cannot be claimed
      # current, however recently the feed itself was rebuilt.
      def civil_undated_old?(window, published, now)
        window.nil? && published < now - CIVIL_UNDATED_CURRENCY
      end

      def validate_fresh_feed!(published, now)
        validate_publication!(published, now)
        raise CityServiceNoticeCollector::StaleSourceError, "stale source feed" if published < now - 2.days
      end

      def validate_feed_alive!(published, now)
        validate_publication!(published, now)
        raise CityServiceNoticeCollector::StaleSourceError, "stale source feed" if published < now - CIVIL_FEED_ABANDONED_AFTER
      end

      def civil_area(text)
        area = text[/ЛОКАЦИЈА:\s*(.+?)(?=ВРИЈЕМЕ:|\z)/i, 1] || text[/LOKACIJA:\s*(.+?)(?=VRIJEME:|\z)/i, 1]
        area = clean(area)
        [area, fold(area).match?(/\b(?:cijela republika srpska|bijeljin\w*|semberij\w*)\b/)]
      end

      def validate_publication!(published, now)
        raise CityServiceNoticeCollector::ParserError, "invalid source publication timestamp" unless published && published <= now
      end

      def expired_window?(window, now)
        window && temporal_status(window, now) == "expired"
      end

      def window_metadata(window, now)
        window ? window.merge("temporal_status" => temporal_status(window, now)) : { "temporal_status" => "unknown" }
      end

      def weather_feed(body, url:, now:, region: nil)
        day = now.in_time_zone("Europe/Sarajevo").to_date
        region = WeatherRegionConfiguration.for_source(source_url: url, day:) if region.nil?
        unless region.is_a?(WeatherRegionConfiguration) && region.valid_on?(day) &&
               region.bound_to?(organization_host: region.organization_host, source_url: url)
          raise WeatherRegionConfiguration::InvalidConfiguration, WeatherRegionConfiguration::ERROR, cause: nil
        end
        document = xml(body)
        raise CityServiceNoticeCollector::ParserError, "unrecognized weather feed" unless document.at_xpath("/atom:feed/atom:id", NS)&.text == "tag:meteoalarm.org,2021-02-19:BA"

        validate_fresh_feed!(parse_iso_time(document.at_xpath("/atom:feed/atom:updated", NS)&.text), now)
        raise CityServiceNoticeCollector::ParserError, "weather feed lacks entry evidence" if document.xpath("/atom:feed/atom:entry", NS).empty?

        entries = document.xpath("/atom:feed/atom:entry", NS)
        replaced = weather_references(entries, now:)
        notices = entries.filter_map do |entry|
          identity = weather_entry_identity(entry)
          weather_item(entry, url:, now:, region:) unless replaced.include?(identity)
        end
        latest_equivalent_weather_notices(notices)
      rescue WeatherRegionConfiguration::InvalidConfiguration
        raise CityServiceNoticeCollector::ParserError, "Weather region review is not configured or eligible", cause: nil
      end

      def weather_entry_identity(entry)
        [entry.at_xpath("cap:identifier", NS)&.text, parse_iso_time(entry.at_xpath("cap:sent", NS)&.text)&.utc&.iso8601]
      end

      def weather_references(entries, now:)
        entries.flat_map do |entry|
          values = %w(status scope message_type sent effective references).index_with { |key| entry.at_xpath("cap:#{key}", NS)&.text }
          next [] unless values["status"] == "Actual" && values["scope"] == "Public"
          next [] unless %w(Update Cancel).include?(values["message_type"])

          validate_publication!(parse_iso_time(values["sent"]), now)
          alert = values.merge("msgType" => values["message_type"], "info" => [{ "effective" => values["effective"] }])
          WeatherCapFeed.replaced_identities(alert, now:).map { |identity| identity.last(2) }
        end
      end

      # Providers can issue the same warning repeatedly with distinct IDs. Only
      # collapse identical event content, severity, region and exact window;
      # changed warnings and separate daily occurrences remain distinct.
      def latest_equivalent_weather_notices(notices)
        grouped = notices.group_by do |notice|
          metadata = notice.fetch(:metadata)
          [notice.fetch(:title), notice.fetch(:body), *metadata.values_at("provider_area_code", "provider_severity", "starts_at", "ends_at")]
        end
        grouped.values.map do |equivalent|
          equivalent.max_by { |notice| Time.iso8601(notice.fetch(:metadata).fetch("source_published_at")) }
        end
      end

      def weather_item(entry, url:, now:, region:)
        values = %w(areaDesc event sent onset expires severity status scope message_type identifier).index_with { |key| entry.at_xpath("cap:#{key}", NS)&.text.to_s }
        return unless actual_weather_alert?(values)
        return unless weather_geocode(entry) == region.provider_area_code

        published = parse_iso_time(values["sent"])
        validate_publication!(published, now)
        start, finish = weather_window(values)
        effective = weather_effective(entry, values)
        return if finish <= now || effective > now

        area = values.fetch("areaDesc")
        metadata = base_metadata("official_warning", published:, area:, geographic: "source_declared_region")
        metadata.merge!("starts_at" => start.iso8601, "ends_at" => finish.iso8601, "temporal_status" => start > now ? "upcoming" : "active",
                        "effective_at" => effective.iso8601, "provider_severity" => values["severity"], "provider_identifier" => values["identifier"],
                        "provider_area_code" => weather_geocode(entry))
        metadata.merge!(region.metadata)
        { title: clean(entry.at_xpath("atom:title", NS)&.text), body: "#{values["event"]}; #{area}; #{start.iso8601} – #{finish.iso8601}",
          url: "#{url}##{Digest::SHA256.hexdigest(values["identifier"])[0, 20]}", metadata: }
      end

      def weather_geocode(entry)
        entry.at_xpath("cap:geocode[atom:valueName='EMMA_ID']/atom:value", NS)&.text
      end

      def weather_effective(entry, values)
        WeatherCapFeed.timestamp(entry.at_xpath("cap:effective", NS)&.text.presence || values["sent"])
      end

      def actual_weather_alert?(values)
        values["status"] == "Actual" && values["scope"] == "Public" && %w(Alert Update).include?(values["message_type"])
      end

      def weather_window(values)
        start = parse_iso_time(values["onset"])
        finish = parse_iso_time(values["expires"])
        raise CityServiceNoticeCollector::ParserError, "invalid weather interval" unless start && finish && finish > start

        [start, finish]
      end

      def roads(body, url:, now:)
        validate_html_complete!(body)
        document = Nokogiri::HTML(body)
        published = road_published_at(document)
        raise CityServiceNoticeCollector::ParserError, "missing or stale road-report timestamp" unless published && published <= now && published >= now - 2.days
        raise CityServiceNoticeCollector::ParserError, "missing road report content" if document.css("#article-container p").empty?

        document.css("#article-container p").filter_map do |paragraph|
          text = clean(paragraph.text)
          next unless fold(text).match?(LOCAL_ROADS) && CityServiceContentFilter.relevant?("road_conditions", text, now:)

          metadata = base_metadata("road_condition", published:, area: clean(paragraph.css("strong").map(&:text).join("; ")), geographic: "source_declared_local_places")
          metadata["temporal_status"] = "as_reported"
          { title: text[0, 220], body: text, url:, metadata: }
        end
      end

      def road_published_at(document)
        stamp = clean(document.at_css("article header h2")&.text)[/\d{2}\.\d{2}\.20\d{2} \d{2}:\d{2}:\d{2}/]
        stamp && Time.find_zone!(CityServiceTime::ZONE).strptime(stamp, "%d.%m.%Y %H:%M:%S")
      end

      def bulky_waste(body, url:, now:)
        validate_html_complete!(body)
        document = Nokogiri::HTML(body)
        items = document.css(".categoryBlog").filter_map { |item| bulky_item(item, url:, now:) }
        current = items.reject { |item| item[:metadata]["temporal_status"] == "expired" }
        return current if current.any? || items.empty?

        # This describes the checked listing, never absence of unannounced work.
        latest = items.max_by { |item| item[:metadata]["source_published_at"].to_s }
        latest[:metadata]["temporal_status"] = "no_current_campaign_listed"
        latest[:metadata]["last_campaign_starts_at"] = latest[:metadata].delete("starts_at")
        latest[:metadata]["last_campaign_ends_at"] = latest[:metadata].delete("ends_at")
        latest[:title] = "Kabasti otpad: posljednja objavljena akcija je završena"
        latest[:body] = "Na provjerenoj listi Komunalca nije navedena nova aktuelna akcija odvoza kabastog otpada. Posljednja objavljena akcija: #{latest[:body]}"
        [latest]
      end

      def bulky_item(item, url:, now:)
        title = clean(item.at_css("h2")&.text)
        return unless fold(title).match?(CityServiceContentFilter::TOPICS.fetch("bulky_waste"))

        text = clean(item.at_css(".categoryIntro")&.text)
        window = day_span(text)
        published_on = CityServiceTime.date(clean(item.at_css(".categoryIntro > div")&.text), reference: nil)
        metadata = base_metadata("campaign_status", published: published_on && CityServiceTime.clock(published_on, "00:00"), area: "Bijeljina",
                                                    geographic: "source_declared_region")
        metadata.merge!(window_metadata(window, now))
        { title:, body: text, url: same_host_url(url, item.at_css("h2 a")&.[]("href")), metadata: }
      end

      def validate_html_complete!(body)
        # The provider has isolated invalid bytes in unrelated archived snippets.
        # Check the ASCII closing marker before Nokogiri repairs text encoding.
        raise CityServiceNoticeCollector::ParserError, "incomplete source HTML" unless body.b.match?(%r{</html>\s*\z}in)
      end

      def base_metadata(kind, published:, area:, geographic:)
        { "kind" => kind, "content_role" => "source_fact", "source_published_at" => published&.iso8601,
          "affected_area_text" => area.to_s[0, 900], "geographic_status" => geographic, "review_required" => true, "parser_version" => VERSION }
      end

      def day_span(text)
        match = CityServiceTime.fold(text).match(SHORT_DATE_SPAN)
        return unless match

        first = Date.new(match[:year].to_i, match[:first_month].to_i, match[:first_day].to_i)
        last = Date.new(match[:year].to_i, match[:last_month].to_i, match[:last_day].to_i)
        return unless last >= first

        { "starts_at" => CityServiceTime.clock(first, "00:00").iso8601,
          "ends_at" => CityServiceTime.clock(last + 1, "00:00").iso8601, "time_precision" => "day" }
      rescue Date::Error
        nil
      end

      def temporal_status(window, now)
        return "expired" if Time.iso8601(window.fetch("ends_at")) <= now

        Time.iso8601(window.fetch("starts_at")) > now ? "upcoming" : "active"
      end

      def clean(text)
        Nokogiri::HTML.fragment(text.to_s).text.gsub(/[[:space:]\u00a0]+/, " ").strip
      end

      def fold(text)
        Decidim::Bih::Text.fold(text.to_s)
      end

      def same_host_url(base, href)
        candidate = URI.join(base, href.to_s)
        raise CityServiceNoticeCollector::ParserError, "unexpected source link" unless candidate.scheme == "https" && candidate.host == URI(base).host && candidate.userinfo.nil?

        candidate.to_s
      end

      def parse_iso_time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def parse_rfc_time(value)
        Time.rfc2822(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
