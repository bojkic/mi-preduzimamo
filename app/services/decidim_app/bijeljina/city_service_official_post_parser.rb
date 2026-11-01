# frozen_string_literal: true

require "digest"
require "nokogiri"

module DecidimApp
  module Bijeljina
    class CityServiceOfficialPostParser
      SOURCE_KEYS = %w(water_service city_official_notices heating_service road_conditions civil_protection bulky_waste).freeze
      # v4 preserves end-only dates as incomplete windows. Heating keeps its
      # separate full-article revision (v5) rather than reusing listing teasers.
      PARSER_VERSIONS = SOURCE_KEYS.index_with { |key| "#{key}_official_post_parser_v4" }
                                   .merge("heating_service" => "heating_service_official_post_parser_v5",
                                          "road_conditions" => "road_conditions_official_post_parser_v5",
                                          "water_service" => "water_service_official_post_parser_v5",
                                          "city_official_notices" => "city_official_notices_official_post_parser_v5").freeze
      WATER_SUBJECTS = %w(vod vodovod vodosnabd).freeze
      WATER_TRIGGERS = %w(prekid obustav iskljuc kvar havar radov sanac normaliz redukc).freeze
      HEATING_SUBJECTS = %w(grijanj grejanje toplan toplot).freeze
      HEATING_TRIGGERS = %w(prekid obustav iskljuc kvar havar radov sanac normaliz isporuk energent).freeze
      CITYWIDE_PHRASES = ["podrucju grada", "cijelom gradu", "svi gradani", "grad bijeljina"].freeze
      Event = ElectricityOutageParser::Event

      def initialize(organization:, source:, area_matcher: nil)
        raise KeyError, "unsupported official-post source: #{source.fetch(:key)}" unless SOURCE_KEYS.include?(source.fetch(:key))

        @organization = organization
        @source = source
        @area_matcher = area_matcher || CityServiceAreaMatcher.new(organization:)
      end

      # Empty extraction is trustworthy only for a recognized complete source
      # document. Error pages and truncated article/feed bodies are not silence.
      def complete_snapshot?(html:, source_url: source.fetch(:source_url))
        return complete_feed?(html:, source_url:) if source.fetch(:key) == "civil_protection"

        document = Nokogiri::HTML(html.to_s)
        return false unless document.at_css("article, .post, .entry, .news, .vijest, .single-post-wrap.entry-content")

        articles = source_articles(html:, source_url:)
        articles.any? && articles.all?(&:complete)
      rescue Nokogiri::XML::SyntaxError
        false
      end

      # Explicit keyword compatibility for callers supplying parsed or raw source evidence.
      # rubocop:disable Metrics/ParameterLists
      def call(html: nil, article: nil, source_url: source.fetch(:source_url), fetched_at: Time.current,
               source_published_at: nil, content_version: nil)
        full_article_input = !article.nil?
        articles = article ? [article] : source_articles(html:, source_url:)
        articles.flat_map do |article|
          article.source_published_at ||= source_published_at
          article.content_version = content_version if content_version
          next [] unless article.complete

          full_article = source.fetch(:key) == "city_official_notices" && full_article_input && article.complete
          events = groups_for(article).each_with_index.filter_map do |group, index|
            event_from_group(group, article:, fetched_at:, index:, full_article:)
          end
          mark_source_completeness(events)
        end.uniq(&:source_fingerprint)
      end

      # rubocop:enable Metrics/ParameterLists

      private

      attr_reader :organization, :source, :area_matcher

      def complete_feed?(html:, source_url:)
        document = Nokogiri::XML(html.to_s) { |config| config.strict.nonet }
        return false unless document.root&.name == "rss" && document.at_xpath("/rss/channel")

        items = document.xpath("/rss/channel/item")
        return true if items.empty?

        articles = source_articles(html:, source_url:)
        items.size <= 30 && articles.size == items.size && articles.all?(&:complete)
      end

      def source_articles(html:, source_url:)
        return CityServiceArticle.extract(html:, source_url:) unless source.fetch(:key) == "civil_protection"

        document = Nokogiri::XML(html.to_s) { |config| config.strict.nonet }
        document.remove_namespaces!
        document.css("item").first(30).filter_map do |item|
          url = CityServiceArticle.approved_url(item.at_css("link")&.text, source_url)
          next unless url

          feed_article(item, url)
        end
      rescue Nokogiri::XML::SyntaxError
        raise CityServiceNoticeCollector::ParserError, "invalid civil protection feed"
      end

      def feed_article(item, url)
        body = item.at_css("encoded")&.text.presence || item.at_css("description")&.text.to_s
        title = item.at_css("title")&.text.to_s
        published = begin
          Time.rfc2822(item.at_css("pubDate")&.text.to_s)
        rescue ArgumentError
          nil
        end
        article = CityServiceArticle.extract(html: "<article>#{body}</article>", source_url: url).first
        article.title = title
        article.source_published_at = published
        article
      end

      def mark_source_completeness(events)
        # The article was read in full. An unresolved event window still needs
        # review, but cannot make every other event in that document partial.
        events.each { |event| event.extraction_metadata["source_snapshot_complete"] = true }
      end

      # A paragraph/bullet state machine must clear or carry the date and place
      # context together; keep these source grammar transitions visible.
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def groups_for(article)
        document = Nokogiri::HTML.fragment(article.html)
        nodes = document.css("p, li, tr")
        nodes = [document] if nodes.empty?
        date = CityServiceTime.date(article.title, reference: article.source_published_at)
        temporal_context = article.title.to_s
        groups = []
        current = nil
        nodes.each do |node|
          next if node.ancestors.any? { |ancestor| nodes.include?(ancestor) }

          line = affected_notice_text(clean(node.text))
          next if line.empty? || normal_elsewhere?(line)

          explicit = CityServiceTime.explicit_date?(line)
          parsed_date = CityServiceTime.date(line, reference: article.source_published_at)
          if source.fetch(:key) == "road_conditions"
            # The aggregate report contains independent paragraphs. A deadline
            # or report heading belonging to one item cannot date another.
            date = parsed_date
            temporal_context = line
          else
            date = parsed_date if explicit || parsed_date
            temporal_context = line if explicit && !profile_for(fold(line))
          end
          if node.name == "li" && current
            current[:places] << line
            next
          end
          ranges = CityServiceTime.ranges(line)
          if ranges.size > 1
            groups.concat(range_groups(line, ranges:, date:, article:, temporal_context:))
            current = nil
          elsif (profile = profile_for(fold(line)))
            current = { text: line, date:, range: ranges.first, profile:, places: [], temporal_text: [temporal_context, line].join(" ") }
            groups << current
          else
            current = nil
          end
        end
        expand_group_windows(groups, article:)
      end

      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def range_groups(line, ranges:, date:, article:, temporal_context:)
        folded = fold(line)
        ranges.each_with_index.filter_map do |range, offset|
          # Each range owns only its following affected span.
          finish = ranges[offset + 1]&.begin(0) || folded.length
          segment = folded[(offset.zero? ? 0 : range.begin(0))...finish]
          profile = profile_for(segment) || profile_for(folded)
          next unless profile

          range_date = date_before_range(folded, range:, fallback: date, article:)
          { text: segment, date: range_date, range:, profile:, places: [], temporal_text: [temporal_context, segment].join(" ") }
        end
      end

      def date_before_range(folded, range:, fallback:, article:)
        prior_dates = [CityServiceTime::DATE_PATTERN, CityServiceTime::NAMED_DATE_PATTERN].flat_map do |pattern|
          folded[0...range.begin(0)].to_enum(:scan, pattern).map { Regexp.last_match.dup }
        end
        last_date = prior_dates.max_by { |match| match.begin(0) }
        last_date ? CityServiceTime.date(last_date[0], reference: article.source_published_at) : fallback
      end

      def expand_group_windows(groups, article:)
        groups.flat_map do |group|
          group_windows(group, article:).map { |window| group.merge(date: window[:starts_at]&.to_date || group[:date], window:) }
        end
      end

      def group_windows(group, article:)
        range = group[:range]
        windows = CityServiceTime.schedule(group[:temporal_text], date: group[:date], reference: article.source_published_at,
                                                                  from: range&.[](:from), to: range&.[](:to))
        attempted_clock = range.nil? && fold(group[:text]).match?(%r{\d{1,2}:\d|\bod \d{1,2}\b(?![./-])})
        windows = [] if attempted_clock && windows.none? { |window| window[:recurrence] == "continuous" }
        return windows if windows.any?

        [CityServiceTime.unresolved_window(group[:date], text: group[:temporal_text], from: range&.[](:from), to: range&.[](:to))]
      end

      def affected_notice_text(line)
        # Mixed prose often appends reassurance about every OTHER location. Keep
        # the affected clause and exclude that suffix before classification/map.
        line = line.split(/(?:[.;]\s*)?(?:На свим осталим|На осталим|Na svim ostalim|Na ostalim)\s/i, 2).first.to_s
        sentences = line.split(/(?<=[.!?;])\s+(?=[[:alpha:]])/)
        selected = sentences.reject { |sentence| normal_elsewhere?(sentence) }
        selected.join(" ")
      end

      def normal_elsewhere?(line)
        folded = fold(line)
        folded.match?(/(?:ostalim|drugim|preostalim) lokacij|(?:ostalim|drugim|preostalim) naselj/) ||
          folded.match?(/(?:snabdijevanje|vodosnabdijevanje|grijanje) (?:ce biti |je )?uredno/) ||
          folded.match?(/nece (?:biti|doci do) prekid|nema (?:najavljenih )?prekida|bez prekida/)
      end

      def event_from_group(group, article:, fetched_at:, index:, full_article: false)
        return unless valid_group_window?(group, fetched_at:)

        window = group[:window]
        line = clean(([group[:text]] + group[:places]).join(" "))
        affected = affected_span(group)
        area = if source.fetch(:key) == "water_service" && area_matcher.respond_to?(:match_water_clauses)
                 area_matcher.match_water_clauses(affected)
               else
                 area_matcher.match(affected)
               end
        target = target_for(affected, area)
        identity = Digest::SHA256.hexdigest([source.fetch(:key), article.source_url, group[:date]&.iso8601 || "unresolved-date", index].join("|"))[0, 24]
        lifecycle = { "restoration_update" => "resolved", "cancellation_update" => "cancelled" }.fetch(group[:profile][:event_type], "scheduled")
        Event.new(
          source_key: source.fetch(:key), source_label: source.fetch(:label), provider: source.fetch(:provider),
          source_url: article.source_url, source_fingerprint: identity, source_occurrence_id: identity,
          content_version: content_version_for(group, window:, line:, target:, lifecycle:),
          source_published_at: article.source_published_at, source_updated_at: article.source_updated_at,
          lifecycle:,
          extraction_metadata: { "canonical_article_url" => article.source_url, "article_content_version" => article.content_version,
                                 "source_updated_at" => article.source_updated_at&.iso8601, "temporal_precision" => window[:precision],
                                 "timezone" => CityServiceTime::ZONE, "complete" => window[:complete] != false, "source_document_complete" => article.complete,
                                 "temporal_status" => window[:temporal_status] || "resolved",
                                 "source_date" => window[:source_date], "raw_from" => window[:raw_from], "raw_to" => window[:raw_to],
                                 "recurrence" => window[:recurrence], "temporal_evidence" => window[:temporal_evidence],
                                 "coverage" => (area.respond_to?(:coverage) ? (area.coverage || {}) : {}),
                                 "service" => CityServiceSourceProfiles.fetch(source.fetch(:key))[:topic],
                                 "affected_phrase" => affected, "source_quotation" => line,
                                 **(full_article ? { "ai_source_text" => full_article_text(article) } : {}),
                                 "requires_human_review" => %w(road_conditions civil_protection bulky_waste).include?(source.fetch(:key)),
                                 "confidence_by_field" => { "type" => "matched_service_profile", "time" => window[:precision],
                                                            "place" => area.unknown? ? "unknown" : "reviewed_alias" } },
          fetched_at:, parser_version: PARSER_VERSIONS.fetch(source.fetch(:key)),
          event_type: group[:profile].fetch(:event_type), severity: group[:profile].fetch(:severity),
          targeting_level: target.fetch(:level), affected_area_slugs: target.fetch(:slugs),
          title: title_for(group[:profile], line), summary: summary_for(line), affected_text: affected,
          recommended_action: group[:profile].fetch(:action), viber_text: viber_text_for(line),
          starts_at: window[:starts_at], ends_at: window[:ends_at], confidence: confidence_for(target),
          classifier_reasons: classifier_reasons_for(target)
        )
      end

      def full_article_text(article)
        clean(Nokogiri::HTML.fragment(article.html).text)[0, 8_000]
      end

      # One formula, shared with the backfill — see CityServiceFactVersion for
      # why the carrying document is deliberately not part of it. The document
      # version stays in `article_content_version`, which is where the
      # changed-source reconciliation reads it.
      def content_version_for(group, window:, line:, target:, lifecycle:)
        CityServiceFactVersion.digest(
          parser_version: PARSER_VERSIONS.fetch(source.fetch(:key)), quotation: line,
          event_type: group[:profile].fetch(:event_type), severity: group[:profile].fetch(:severity),
          lifecycle:, targeting_level: target.fetch(:level), area_slugs: target.fetch(:slugs),
          starts_at: window[:starts_at], ends_at: window[:ends_at],
          precision: window[:precision], temporal_status: window[:temporal_status],
          complete: window[:complete], recurrence: window[:recurrence],
          raw_from: window[:raw_from], raw_to: window[:raw_to], source_date: window[:source_date]
        )
      end

      def valid_group_window?(group, fetched_at:)
        window = group[:window]
        return false unless window
        return true if window[:complete] == false
        return false if window[:ends_at] < fetched_at && %w(restoration_update cancellation_update).exclude?(group[:profile][:event_type])
        # Missing promised location bullets cannot become affected facts.
        return false if group[:places].empty? && fold(group[:text]).match?(/(?:sljedecoj|sledecoj|sljedecim|sledecim) lokacij[^:]*:\s*\z/)

        true
      end

      def affected_span(group)
        return group[:places].join("; ") if group[:places].any?

        text = fold(group[:text])
        # Prefer the actual affected-location clause over worksite/provider names
        # earlier in a mixed notice (e.g. the pipe for Janja is in Ljeskovac).
        explicit = text.match(/
          (?:nece\ biti\ vode|prekid(?:a)?\ vodosnabdijevanja|prekid\ grijanja|prekida\ grijanja|obustav[^.]*?saobracaja)\s+(?:u|
          na)\s+(?:naseljima|naselju|lokacijama|lokaciji)?\s*:?\s*(.+)
        /x)
        explicit ? explicit[1] : group[:text]
      end

      def profile_for(folded)
        case source.fetch(:key)
        when "water_service"
          water_profile(folded)
        when "heating_service"
          heating_profile(folded)
        when "city_official_notices"
          city_notice_profile(folded)
        when "road_conditions"
          civic_profile(folded, :roads)
        when "civil_protection"
          civic_profile(folded, :civil)
        when "bulky_waste"
          civic_profile(folded, :waste)
        end
      end

      def civic_profile(folded, kind)
        # A regional listing must name Bijeljina in the same notice. Provider
        # location, page navigation and generic regional risk are not coverage.
        return unless folded.match?(/bijeljin|semberij/) || (kind == :waste && folded.match?(/dvorov|janj|batkov|brodac/))
        return if folded.match?(/javna nabavka|tender|politick|svecan|promocij|nece biti obustav|bez obustave/)

        send("#{kind}_profile", folded)
      end

      def roads_profile(folded)
        return unless folded.match?(/saobrac|put|ulic|most/) && folded.match?(/obustav|zatvoren|zatvar|odron|zabrana|izmjena rezima/)

        profile(event_type: cancellation?(folded) ? "cancellation_update" : "road_closure", severity: "safety",
                action: "Pratite uputstva nadležnih službi i objavljeni režim saobraćaja.")
      end

      def civil_profile(folded)
        return unless folded.match?(/upozoren|evakuac|opasnost|poplav|vanred/) && !folded.match?(/vjezb|obuk|sastan|posjet/)

        profile(event_type: cancellation?(folded) ? "cancellation_update" : "emergency_notice", severity: "emergency",
                action: "Pratite zvanična uputstva civilne zaštite.")
      end

      def waste_profile(folded)
        return unless folded.match?(/kabast|krupn.*otpad/) && folded.match?(/odvoz|prikuplj|akcij|preuzim/)

        profile(event_type: cancellation?(folded) ? "cancellation_update" : "bulky_waste_collection", severity: "info",
                action: "Provjerite objavljene lokacije i termine odvoza kabastog otpada.")
      end

      def water_profile(folded)
        return unless any_token?(folded, WATER_SUBJECTS) || folded.match?(/\bvode\b/)
        return unless water_trigger?(folded)
        return if normal_elsewhere?(folded)

        event_type = if cancellation?(folded)
                       "cancellation_update"
                     elsif restored?(folded)
                       "restoration_update"
                     elsif folded.match?(/kvar|havar/)
                       "unplanned_interruption"
                     else
                       "planned_interruption"
                     end
        profile(event_type:, severity: "service_outage",
                action: update_action(event_type, "Pripremite rezervu vode i pratite naredna obavještenja Vodovoda."))
      end

      def water_trigger?(folded)
        any_token?(folded, WATER_TRIGGERS) || folded.include?("nece biti vode") || cancellation?(folded)
      end

      def heating_profile(folded)
        return unless any_token?(folded, HEATING_SUBJECTS) && (any_token?(folded, HEATING_TRIGGERS) || cancellation?(folded))
        return if normal_elsewhere?(folded)

        event_type = if cancellation?(folded)
                       "cancellation_update"
                     elsif restored?(folded)
                       "restoration_update"
                     elsif folded.match?(/energent|gas|mazut|goriv/)
                       "fuel_supply_warning"
                     else
                       "heating_interruption"
                     end
        profile(event_type:, severity: "service_outage",
                action: update_action(event_type, "Pratite obavještenja Toplane i planirajte grijanje prostora dok traje prekid."))
      end

      def city_notice_profile(folded)
        # A funding call about health measures is not itself an actionable
        # health warning. PublicCallsPreparation handles that source surface.
        funding_call = folded.match?(/\b(?:tender|javna nabavka|raspodjel[au] sredstava|grantov[ai])\b/) ||
                       (folded.match?(/\bjavn[ia] (?:poziv|konkurs)\b/) && !folded.match?(/evakuac|upozoren|opasnost|poplav/))
        return if funding_call
        return if folded.match?(/nece (?:biti|doci do) (?:obustav|zatvar)|bez obustave/)

        if cancellation?(folded) && folded.match?(/obustav|zatvar|komar|dezinsek|zapras/)
          profile(event_type: "cancellation_update", severity: "safety", action: "Provjerite izmijenjeno zvanično obavještenje; raniji termin je otkazan.")
        elsif folded.match?(/upozoren|vanred|opasnost|evakuac|civiln/)
          profile(event_type: "emergency_notice", severity: "emergency", action: "Pratite uputstva nadležnih službi i zvanične kanale Grada.")
        elsif folded.match?(/komar|dezinsek|zapras/)
          profile(event_type: "mosquito_spraying", severity: "safety", action: "Pratite termin tretmana i zaštitite pčele, hranu i osjetljive osobe.")
        elsif folded.match?(/zdrav|deratiz|dezinfek|higijen/)
          profile(event_type: "public_health_notice", severity: "safety", action: "Pratite uputstva nadležne službe i zvanično gradsko obavještenje.")
        elsif folded.match?(/saobrac|\bput|ulic|most/) && folded.match?(/zatvar|obustav|zatvoren|zabrana|izmjena rezima|radov/)
          profile(event_type: "road_closure", severity: "safety", action: "Koristite alternativne pravce i pratite gradska obavještenja.")
        end
      end

      def cancellation?(text)
        text.match?(/otkazan|otkazuje|odgodjen|odlaze se|ponisten/)
      end

      def restored?(text)
        text.match?(/
          (?:je\ |su\ )(?:normalizovan|normalizirano|saniran|uspostavljen)|
          (?:grijanje|vodosnabdijevanje)\ (?:je\ )?normalizovano|
          (?:nastavljena|obnovljena)\ (?:isporuka|snabdijevanje)
        /x) &&
          !text.match?(/ocekuje|ocekuju|trebalo|planira|do normaliz/)
      end

      def update_action(event_type, fallback)
        return "Raniji termin je otkazan. Pratite izmijenjeno zvanično obavještenje." if event_type == "cancellation_update"
        return "Prema obavještenju usluga je obnovljena. Pratite naredne informacije nadležne službe." if event_type == "restoration_update"

        fallback
      end

      def profile(event_type:, severity:, action:)
        { event_type:, severity:, action: }
      end

      def target_for(line, area_match)
        return { level: "citywide", slugs: [] } if source.dig(:viber, :target) == CityServiceSources::CITYWIDE_ALLOWED &&
                                                   citywide?(line)

        { level: area_match.targeting_level, slugs: area_match.slugs }
      end

      def citywide?(line)
        folded = fold(line)
        CITYWIDE_PHRASES.any? { |phrase| folded.include?(phrase) }
      end

      def title_for(profile, line)
        prefix =
          case profile.fetch(:event_type)
          when "planned_interruption", "unplanned_interruption"
            "Prekid vodosnabdijevanja"
          when "heating_interruption"
            "Prekid grijanja"
          when "road_closure"
            "Saobraćajno obavještenje"
          when "mosquito_spraying"
            "Tretman komaraca"
          when "public_health_notice"
            "Javno-zdravstveno obavještenje"
          when "emergency_notice"
            "Hitno obavještenje"
          else
            source.fetch(:label)
          end
        "#{prefix}: #{truncate(line, 90)}"
      end

      def summary_for(line)
        truncate(line, 500)
      end

      def viber_text_for(line)
        truncate(line, CityServiceNoticeClassifier::VIBER_LIMIT)
      end

      def confidence_for(target)
        return 0.82 if target.fetch(:level) == "citywide"

        target.fetch(:slugs).any? ? 0.86 : 0.65
      end

      def classifier_reasons_for(target)
        reasons = ["deterministic_#{source.fetch(:key)}_parser"]
        reasons << "location_not_matched" if target.fetch(:level) == "unknown"
        reasons << "citywide_notice" if target.fetch(:level) == "citywide"
        reasons
      end

      def any_token?(folded, tokens)
        tokens.any? { |token| folded.include?(token) }
      end

      def clean(value)
        value.to_s.gsub(/[[:space:]\u00a0]+/, " ").strip
      end

      def fold(value)
        CityServiceTime.fold(value)
      end

      def truncate(value, limit)
        text = value.to_s
        return text if text.length <= limit

        text[0, limit].rstrip
      end
    end
  end
end
