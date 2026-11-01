# frozen_string_literal: true

require_relative "city_service_time"

require "nokogiri"
require "digest"
require "time"
require "date"

module DecidimApp
  module Bijeljina
    # Bounded, public source facts. Personal lists and aggregate payment amounts
    # are not projected. No eligibility decision or individual arrival promise.
    module CitizenNoticePilotParser
      CROSSINGS = { "gp raca" => "bihamk:raca", "gp popovi" => "bihamk:popovi", "gp sepak" => "bihamk:sepak" }.freeze
      MONTHS = CityServiceTime::MONTHS.merge("januar" => 1, "februar" => 2, "mart" => 3, "april" => 4, "maj" => 5, "jun" => 6, "jul" => 7,
                                             "avgust" => 8, "august" => 8, "augusta" => 8, "septembar" => 9, "oktobar" => 10, "novembar" => 11, "decembar" => 12).merge(
        "juni" => 6, "juli" => 7, "sijecanj" => 1, "sijecnja" => 1, "veljaca" => 2, "veljace" => 2,
        "ozujak" => 3, "ozujka" => 3, "travanj" => 4, "travnja" => 4, "svibanj" => 5, "svibnja" => 5,
        "lipanj" => 6, "lipnja" => 6, "srpanj" => 7, "srpnja" => 7, "kolovoz" => 8, "kolovoza" => 8,
        "rujan" => 9, "rujna" => 9, "listopad" => 10, "listopada" => 10, "studeni" => 11, "studenog" => 11,
        "studenoga" => 11, "prosinac" => 12, "prosinca" => 12
      ).freeze

      module_function

      def borders(body, now:)
        document = Nokogiri::HTML(body)
        stamp = document.at_css("time[datetime]")&.[]("datetime")
        raise CitizenNoticePilots::InvalidSource, "border report timestamp missing" unless stamp.to_s.match?(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/)

        observed = Time.find_zone!("Europe/Sarajevo").strptime(stamp, "%Y-%m-%d %H:%M:%S")
        raise CitizenNoticePilots::InvalidSource, "future border report" if observed > now

        records = document.css("article").filter_map do |article|
          name = clean(article.at_css("h3")&.text)
          key = CROSSINGS[fold(name)]
          next unless key

          border_record(article, name:, key:, observed:)
        end
        raise CitizenNoticePilots::InvalidSource, "border rows missing" if records.empty?

        records
      end

      def border_record(article, name:, key:, observed:)
        paragraphs = article.css("p").map { |node| clean(node.text) }.reject(&:empty?)
        raise CitizenNoticePilots::InvalidSource, "border row empty" if paragraphs.empty?

        text = paragraphs.join(" ")
        ceiling = fold(text)[/zadrzavanja (?:za )?putnickih vozila nisu duza od (\d+) minuta/, 1]
        { "id" => key, "kind" => "border_report", "subject_id" => key, "subject_label" => name,
          "text" => text[0, 1000], "observed_at" => observed.iso8601, "source_timezone" => "Europe/Sarajevo",
          "source_timestamp_text" => observed.strftime("%Y-%m-%d %H:%M:%S"), "vehicle_scope" => "passenger_vehicles",
          "wait_ceiling_minutes" => ceiling&.to_i, "wait_measurement_minutes" => nil, "direction" => "as_stated_in_text",
          "standing_notice" => paragraphs.drop(1).join(" ")[0, 500], "personal_status" => false,
          "action" => { "kind" => "official_report", "url" => CitizenNoticePilots::SOURCES.fetch("bihamk_border")[:url] },
          "warnings" => %w(reported_ceiling_not_measured_wait no_opposite_border_authority_confirmation) }
      end

      def pension_feed(body, now:)
        raise CitizenNoticePilots::InvalidSource, "XML declaration prohibited" if body.match?(/<!DOCTYPE|<!ENTITY/i)

        document = Nokogiri::XML(body) { |config| config.strict.nonet }
        raise CitizenNoticePilots::InvalidSource, "pension feed shape changed" unless document.at_xpath("/rss/channel/title")

        document.xpath("/rss/channel/item").first(10).flat_map { |item| pension_item(item, now:) }
      rescue Nokogiri::XML::SyntaxError, ArgumentError
        raise CitizenNoticePilots::InvalidSource, "pension feed malformed"
      end

      def pension_item(item, now:)
        title = clean(item.at_xpath("title")&.text)
        return [] unless fold(title).match?(/penzij|skolov|potvrd/)

        published = Time.rfc2822(item.at_xpath("pubDate")&.text.to_s)
        url = CitizenNoticePilots.approved_url(item.at_xpath("link")&.text, "pio_notices")
        text = item.at_xpath("*[local-name()='encoded']")&.text || item.at_xpath("description")&.text
        benefit_records(text, details: { title:, url:, published: published.to_date, key: "pio_notices" }, now:)
      end

      def child_benefit(body, url:, now:)
        article = Nokogiri::HTML(body).at_css("article.mb-60")
        title = clean(article&.at_css("h1")&.text)
        published = source_date(article&.at_css("span.text-muted")&.text)
        raise CitizenNoticePilots::InvalidSource, "child benefit article shape changed" unless article && published && !title.empty?

        benefit_records(article.css("p").map(&:to_html).join, details: { title:, url:, published:, key: "jfdz_notices" }, now:)
      end

      def benefit_records(body, details:, now:)
        raise CitizenNoticePilots::InvalidSource, "future benefit publication" if details[:published] > now.in_time_zone("Europe/Sarajevo").to_date
        return [] if fold(details[:title]).match?(/lista|rezultat|odbijen|korisnic[ai].*imen/)

        document = Nokogiri::HTML.fragment(body.to_s)
        paragraphs = document.css("p").map { |node| clean(node.text) }
        paragraphs = [clean(document.text)] if paragraphs.empty?
        records = paragraphs.filter_map { |text| payment_record(text, details:) }
        records.concat(paragraphs.filter_map { |text| obligation_record(text, details:, now:) }) if details[:key] == "pio_notices"
        records.uniq { |record| record["id"] }
      end

      def payment_record(text, details:)
        folded = fold(text)
        return unless folded.match?(/isplat/) && folded.match?(/pocin|pocel/)

        start = source_date(folded.split(/pocin\w*|pocel\w*/, 2).last)
        start ||= details[:published] if folded.match?(/(?:pocin\w*|pocel\w*)[^.]{0,25}danas/)
        return unless start

        payment_fields(details, start:, period: benefit_period(folded))
      end

      def benefit_period(text)
        period = text.match(/za (?:mjesec\s+)?([a-z]+)\s+(20\d{2})/)
        month = period && MONTHS[period[1]]
        format("%s-%02d", period[2], month) if month
      end

      def payment_fields(details, start:, period:)
        key = details.fetch(:key)
        url = details.fetch(:url)
        { "id" => "#{key}:#{Digest::SHA256.hexdigest(url + start.iso8601)[0, 20]}", "kind" => "payment_start_notice",
          "subject_id" => key, "subject_label" => key == "pio_notices" ? "Fond PIO RS" : "Javni fond za dječiju zaštitu",
          "text" => details.fetch(:title)[0, 300], "payment_starts_on" => start.iso8601, "period_covered" => period,
          "source_published_on" => details.fetch(:published).iso8601, "source_url" => url, "personal_status" => false,
          "action" => { "kind" => "official_notice", "url" => url },
          "warnings" => %w(payment_start_not_individual_receipt no_personal_entitlement_assessment) }
      end

      def obligation_record(text, details:, now:)
        folded = fold(text)
        return unless folded.match?(/potvrd/) && folded.match?(/skolov/) && folded.match?(/do|rok/)

        audience = obligation_audience(folded)
        deadline = source_date(folded[/\bdo\s+(.+)/, 1] || folded[/\brok(?: je|:)?\s+(.+)/, 1])
        return unless audience && deadline

        { "id" => "pio_deadline:#{Digest::SHA256.hexdigest(details[:url] + audience + deadline.iso8601)[0, 20]}",
          "kind" => "obligation_deadline", "subject_id" => "pio_notices", "subject_label" => "Fond PIO RS",
          "text" => "Rok za potvrdu o školovanju", "audience" => audience, "deadline_on" => deadline.iso8601,
          "temporal_status" => deadline < now.in_time_zone("Europe/Sarajevo").to_date ? "expired" : "published_deadline",
          "source_published_on" => details[:published].iso8601, "source_url" => details[:url], "personal_status" => false,
          "action" => { "kind" => "check_official_submission_instructions", "url" => details[:url] },
          "warnings" => %w(audience_scoped_deadline no_personal_entitlement_assessment) }
      end

      def obligation_audience(text)
        school = text.match?(/srednj\w* skol/)
        university = text.match?(/student|fakultet/)
        return if school == university

        school ? "secondary_school_students" : "university_students"
      end

      def source_date(value)
        text = fold(value)
        dates = text.scan(/(\d{1,2})\.\s*(\d{1,2})\.\s*(20\d{2})/).map { |day, month, year| Date.new(year.to_i, month.to_i, day.to_i) }
        dates.concat(text.scan(/(\d{1,2})\.\s*([a-z]+)\s+(20\d{2})/).map { |day, month, year| Date.new(year.to_i, MONTHS.fetch(month), day.to_i) })
        dates.uniq.one? ? dates.first : nil
      rescue Date::Error, KeyError
        nil
      end

      def clean(value)
        value.to_s.gsub(/[[:space:]\u00a0]+/, " ").strip
      end

      def fold(value)
        latin = Decidim::Bih::Transliterator.to_latin(value.to_s.downcase)
        Decidim::Bih::Text::DIACRITICS.each { |from, to| latin = latin.gsub(from, to) }
        clean(latin)
      end
    end
  end
end
