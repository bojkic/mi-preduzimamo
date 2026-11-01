# frozen_string_literal: true

require_relative "parking_zones"

module DecidimApp
  module Bijeljina
    # Host-owned on-demand summaries for reviewed service sources. This gives MI!
    # a factual answer for source-backed questions before the generic service
    # directory falls back to "here is the link".
    class LiveServiceAnswers
      DEFAULT_TIMEOUT = 4
      DEFAULT_MAX_ITEMS = 8
      CACHE_TTL = 10.minutes
      CACHE_VERSION = 3
      PUBLIC_TRANSPORT_FARE_SOURCE_URL =
        "https://www.gradbijeljina.org/lat/news/novosti/-/7080.otvorena-nova-autobuska-stanica-u-bijeljini-%E2%80%93-gradski-prevoz-pocinje-od-1-juna-.html"
      INTERNAL_FALLBACK_TEXT = "Source document requires a source-specific parser"
      PARKING_KEYWORDS = %w(
        parking parkiranje parkiraliste parkiralište parkinga
        parkiram parkirati parkirna parkirne
      ).freeze
      UNAVAILABLE_ANSWERS = {
        air_quality: "Trenutno ne mogu dohvatiti očitanje kvaliteta vazduha. Pokušaj ponovo uskoro; podatak svakako tretiram kao informativan, ne medicinski savjet.",
        water_levels: "Trenutno ne mogu dohvatiti vodostaje Save i Drine. Ako postoji neposredna opasnost, prati zvanična upozorenja civilne zaštite.",
        public_transport: "Trenutno ne mogu dohvatiti važeći pregled javnog prevoza. Napiši mi konkretnu liniju kasnije, npr. G1 ili P1.",
        sistem48: "Trenutno ne mogu dohvatiti javni pregled Sistema 48. Za novu komunalnu prijavu koristi MI! obrazac za prijavu problema.",
        police: "Trenutno ne mogu dohvatiti javne policijske servisne informacije. Za hitne slučajeve zovi 122."
      }.freeze
      NO_REVIEWED_MATCH_ANSWERS = {
        air_quality: "U pregledanim izvorima trenutno nemam odgovarajući objavljeni podatak o kvalitetu vazduha. To nije potvrda da mjerenja nema.",
        water_levels: "U pregledanom izvoru trenutno nemam odgovarajući objavljeni podatak o vodostajima. To nije potvrda da se stanje nije promijenilo.",
        public_transport: "U pregledanom izvoru trenutno nemam odgovarajući važeći red vožnje. To nije potvrda da linija ne saobraća.",
        sistem48: "U pregledanom izvoru trenutno nemam odgovarajući javni pregled Sistema 48.",
        police: "U pregledanom izvoru trenutno nemam odgovarajuću policijsku servisnu informaciju. Za hitne slučajeve zovi 122."
      }.freeze
      UNREVIEWED_ANSWERS = {
        air_quality: "Izvor je dostupan, ali njegov sadržaj još nemam u pouzdano pregledanom obliku za odgovor o kvalitetu vazduha.",
        water_levels: "Izvor je dostupan, ali njegov sadržaj još nemam u pouzdano pregledanom obliku za odgovor o vodostajima.",
        public_transport: "Izvor je dostupan, ali red vožnje još nemam u pouzdano pregledanom obliku za ovaj odgovor.",
        sistem48: "Izvor je dostupan, ali javni pregled Sistema 48 još nemam u pouzdano pregledanom obliku.",
        police: "Izvor je dostupan, ali policijske servisne informacije još nemam u pouzdano pregledanom obliku. Za hitne slučajeve zovi 122."
      }.freeze

      TOPICS = [
        {
          key: :air_quality,
          source_keys: %w(air_quality_realtime air_quality),
          keywords: %w(vazduh zrak zagadjenje zagadjenost pm pm10 pm25 cestice),
          phrases: ["kvalitet vazduha", "kvaliteta zraka", "kakav je vazduh", "kakav je zrak"],
          formatter: :air_quality_answer,
          max_items: 4
        },
        {
          key: :water_levels,
          source_keys: %w(water_levels),
          keywords: %w(vodostaj vodostaji sava drina poplava poplave nasip),
          phrases: ["nivo rijeke", "nivo reke", "stanje rijeka", "stanje reka"],
          formatter: :water_levels_answer,
          max_items: 2
        },
        {
          key: :public_transport,
          source_keys: %w(public_transport),
          keywords: %w(autobus autobusi linija linije stajaliste stajalista prevoz prijevoz),
          phrases: [
            "red voznje", "red vožnje", "javni prevoz", "gradski prevoz", "javni prijevoz",
            "pocetna stanica", "početna stanica", "pocetnu stanicu", "početnu stanicu",
            "polazna stanica", "polaznu stanicu", "najbliza stanica", "najbliža stanica",
            "najblize stajaliste", "najbliže stajalište"
          ],
          formatter: :public_transport_answer,
          max_items: 30
        },
        {
          key: :sistem48,
          source_keys: %w(sistem48_public_archive),
          keywords: %w(sistem48),
          phrases: ["sistem 48", "pregled prijava", "javne prijave", "komunalne prijave"],
          formatter: :sistem48_answer,
          max_items: 2
        },
        {
          key: :police,
          source_keys: %w(police_service_information),
          keywords: %w(policij policija policije mup radar prekrsaj prekrsaji dokumenta dokumenti),
          phrases: ["licna karta", "lična karta", "nevažeci dokumenti", "nevažeći dokumenti", "policijska stanica"],
          formatter: :police_answer,
          max_items: 5
        }
      ].freeze

      class ResponseText < String
        attr_reader :quick_replies

        def initialize(text, quick_replies: [])
          super(text.to_s)
          @quick_replies = quick_replies
        end
      end

      CollectionOutcome = Struct.new(:checks, :notices, keyword_init: true)

      def initialize(collector: nil, transport_timetable: nil, parking_zones: nil, timeout: DEFAULT_TIMEOUT)
        @collector = collector || CityServiceSourceCheckStore.new
        @transport_timetable = transport_timetable || PublicTransportTimetable.new(timeout:)
        @parking_zones = parking_zones || ParkingZones.default
        @timeout = timeout
      end

      def answer(text:, locale: I18n.locale, location: nil, deadline: nil)
        if parking_topic?(text)
          response = parking_zones.answer(text:, locale:, location:)
          return response if response.present?
        end

        topic = topic_for(text)
        return nil unless topic

        return localize(public_transport_fare_answer, locale) if topic.fetch(:key) == :public_transport && public_transport_fare_intent?(text)

        outcome = collect_outcome(topic, deadline:)
        response = if outcome.notices.any?
                     value = send(topic.fetch(:formatter), outcome.notices, text, location, deadline)
                     append_partial_coverage(value, outcome.checks)
                   else
                     empty_outcome_answer(topic.fetch(:key), outcome.checks)
                   end
        localize(response, locale)
      end

      def match?(text:)
        parking_topic?(text) || topic_for(text).present?
      end

      private

      attr_reader :collector, :transport_timetable, :parking_zones, :timeout

      def topic_for(text)
        folded = fold(text)
        return if folded.blank?

        TOPICS.find { |topic| topic_match?(topic, folded) }
      end

      def topic_match?(topic, folded)
        keyword_or_phrase_match = topic.fetch(:keywords).any? { |keyword| folded.include?(fold(keyword)) } ||
                                  topic.fetch(:phrases).any? { |phrase| folded.include?(fold(phrase)) }
        return keyword_or_phrase_match unless topic.fetch(:key) == :public_transport

        keyword_or_phrase_match || folded.match?(PublicTransportTimetable::ROUTE_CODE_PATTERN)
      end

      def collect_outcome(topic, deadline:)
        return deadline_outcome(topic) if deadline_expired?(deadline)

        cache_fetch(topic) do
          checks = collector_checks(topic, deadline:)
          notices = checks.select { |check| check.status == :ok }
                          .flat_map(&:notices)
                          .select { |notice| usable_notice?(notice) }
          CollectionOutcome.new(checks:, notices:)
        end
      rescue CityServiceNoticeCollector::InvalidDeadline
        deadline_outcome(topic, error_code: :invalid_deadline)
      end

      def deadline_outcome(topic, error_code: :deadline_exceeded)
        checks = topic.fetch(:source_keys).map do |source_key|
          CityServiceNoticeCollector::SourceCheckResult.new(
            source_key:,
            status: :unavailable,
            notices: [],
            checked_at: nil,
            error_code:
          )
        end
        CollectionOutcome.new(checks:, notices: [])
      end

      def collector_checks(topic, deadline:)
        options = {
          keys: topic.fetch(:source_keys),
          timeout:,
          max_items: topic.fetch(:max_items, DEFAULT_MAX_ITEMS),
          deadline:
        }
        return collector.check(**options) if collector.respond_to?(:check)

        notices = collector.call(**options.except(:deadline))
        status = notices.any? ? :ok : :unavailable
        [CityServiceNoticeCollector::SourceCheckResult.new(
          source_key: topic.fetch(:source_keys).first,
          status:,
          notices:,
          checked_at: notices.filter_map(&:fetched_at).max,
          error_code: status == :unavailable ? :legacy_collector_ambiguous : nil
        )]
      end

      def cache_fetch(topic, &)
        # Durable prepared reads are already shared and bounded. A second TTL
        # would hide a corrected source version or a failed latest refresh.
        return yield if collector.is_a?(CityServiceSourceCheckStore)

        return yield unless defined?(Rails.cache) && Rails.cache

        cached = Rails.cache.read(cache_key(topic))
        return cached if cached

        outcome = yield
        Rails.cache.write(cache_key(topic), outcome, expires_in: CACHE_TTL) if cacheable_outcome?(outcome)
        outcome
      end

      def cacheable_outcome?(outcome)
        outcome.checks.none? { |check| [:unavailable, :malformed, :stale].include?(check.status) }
      end

      def cache_key(topic)
        "bijeljina/live-service-answers/v#{CACHE_VERSION}/#{topic.fetch(:key)}/#{topic.fetch(:source_keys).join("-")}/#{topic.fetch(:max_items, DEFAULT_MAX_ITEMS)}"
      end

      def usable_notice?(notice)
        notice.title.to_s.squish.present? &&
          notice.body.to_s.exclude?(INTERNAL_FALLBACK_TEXT)
      end

      def air_quality_answer(notices, _text = nil, _location = nil, _deadline = nil)
        measurements = notices.select { |notice| notice.source_key == "air_quality_realtime" }
        reports = notices.select { |notice| notice.source_key == "air_quality" }
        parts = public_measurement_text(measurements)
        if reports.any?
          titles = reports.first(2).map { |notice| clean_title(notice.title, "Kvalitet vazduha") }
          parts << "Gradski izvještaji: #{sentence_list(titles)}. To su poveznice na dokumente; vrijednosti i vrijeme mjerenja nisu izdvojeni iz PDF-a."
        end
        parts << source_sentence(notices)
        parts.join(" ")
      end

      def water_levels_answer(notices, _text = nil, _location = nil, _deadline = nil)
        (public_measurement_text(notices) + [source_sentence(notices)]).join(" ")
      end

      def public_measurement_text(notices)
        observations = Array(notices).flat_map { |notice| SourceMeasurement.observations(notice:, now: Time.current) }
        usable = observations.reject { |row| obsolete_observation?(row) }
        conflicts = SourceMeasurement.conflicting_observations(usable)
        return [I18n.t("decidim.bih.dialogue.read_warning_conflicting_facts")] + conflicts.map { |row| row.fetch("text") } if conflicts.any?

        parts = usable.first(DEFAULT_MAX_ITEMS).map { |row| row.fetch("text") }
        parts + measurement_availability_warnings(observations)
      end

      def measurement_availability_warnings(observations)
        parts = []
        parts << "Posljednje dostupno mjerenje je zastarjelo; nemam potvrđeno aktuelno očitanje." if observations.any? { |row| row["_stale"] }
        parts << "Vrijeme izvornog mjerenja nije pouzdano; podatak ne prikazujem kao aktuelan." if observations.any? { |row| row["_future"] }
        parts << "Nemam pouzdano izdvojeno mjerenje sa stanicom, jedinicom i vremenom; provjeri izvor." if observations.empty?
        parts
      end

      def obsolete_observation?(row)
        row["_stale"] || row["_future"]
      end

      def public_transport_answer(notices, text = nil, location = nil, deadline = nil)
        return public_transport_fare_answer if public_transport_fare_intent?(text)

        timetable = safe_transport_timetable_answer(text:, notices:, location:, deadline:)
        return response_text([timetable.to_s, source_sentence(notices)].join(" "), quick_replies: quick_replies_for(timetable)) if timetable.present?

        routes = notices.first(6).map { |notice| clean_title(notice.title, "Javni prevoz") }
        [
          "Našao sam ove redove vožnje/linije: #{sentence_list(routes)}.",
          "Ako napišeš oznaku linije, npr. G1 ili P1, mogu izdvojiti baš tu liniju iz pregleda koji imam.",
          source_sentence(notices)
        ].join(" ")
      end

      def sistem48_answer(notices, _text = nil, _location = nil, _deadline = nil)
        notice = notices.first
        [
          "Sistem 48 javni pregled trenutno mogu sažeti ovako: #{concise_body(notice.body)}",
          "Ne preuzimam sirove tekstove građanskih prijava u bot odgovor.",
          source_sentence(notices)
        ].join(" ")
      end

      def police_answer(notices, _text = nil, _location = nil, _deadline = nil)
        contact = notices.find { |notice| notice.title.include?("kontakti") }
        services = notices.reject { |notice| notice == contact }.first(3).map { |notice| clean_title(notice.title, "MUP RS servis") }
        parts = []
        parts << "Kontakti koje sam našao za PU Bijeljina: #{police_contact_text(contact.body)}." if contact
        parts << "Dostupni servisi: #{sentence_list(services)}." if services.any?
        parts << "Za hitne slučajeve zovi 122."
        parts << source_sentence(notices)
        parts.join(" ")
      end

      def unavailable_answer(key)
        UNAVAILABLE_ANSWERS.fetch(key)
      end

      def empty_outcome_answer(key, checks)
        statuses = checks.map(&:status)
        return UNAVAILABLE_ANSWERS.fetch(key) if statuses.any? { |status| [:unavailable, :malformed, :stale].include?(status) }
        return UNREVIEWED_ANSWERS.fetch(key) if statuses.include?(:unreviewed)

        NO_REVIEWED_MATCH_ANSWERS.fetch(key)
      end

      def append_partial_coverage(response, checks)
        return response unless checks.any? { |check| check.status != :ok || check.error_code.present? }

        response_text(
          "#{response} Dio traženih izvora nije dao pregledan, uspješan rezultat; odgovor je nepotpun.",
          quick_replies: quick_replies_for(response)
        )
      end

      def compact_air_quality(notice)
        title = notice.title.to_s.sub(/\AKvalitet vazduha uživo:\s*/i, "")
        title.presence || concise_body(notice.body)
      end

      def police_contact_text(body)
        body.to_s
            .sub(/\AKontakti sa zvanične stranice PU Bijeljina:\s*/i, "")
            .split("|")
            .map(&:strip)
            .first(3)
            .join("; ")
            .truncate(420, separator: " ")
      end

      def clean_title(title, prefix)
        title.to_s.sub(/\A#{Regexp.escape(prefix)}:\s*/i, "").squish
      end

      def concise_body(body)
        body.to_s.squish.truncate(520, separator: " ").presence
      end

      def sentence_list(values)
        values.map(&:presence).compact.first(6).join("; ")
      end

      def response_text(text, quick_replies: [])
        quick_replies = normalize_quick_replies(quick_replies)
        return text if quick_replies.empty?

        ResponseText.new(text, quick_replies:)
      end

      def quick_replies_for(response)
        return [] unless response.respond_to?(:quick_replies)

        response.quick_replies
      end

      def normalize_quick_replies(quick_replies)
        Array(quick_replies).filter_map do |reply|
          next if reply.blank?

          label = reply.respond_to?(:[]) ? (reply[:label] || reply["label"]) : nil
          url = reply.respond_to?(:[]) ? (reply[:url] || reply["url"]) : nil
          next if label.blank? || url.blank?

          { label:, url: }
        end
      end

      def source_sentence(notices)
        providers = notices.map(&:provider).compact_blank.uniq.first(3)
        checked_at = formatted_checked_at(latest_checked_at(notices))
        checked_text = checked_at ? "; provjereno #{checked_at}" : ""
        return "Izvor podataka: pregledani javni izvor#{checked_text}." if providers.empty?

        "Izvor podataka: #{providers.join("; ")}#{checked_text}."
      end

      def safe_transport_timetable_answer(text:, notices:, location:, deadline:)
        return if deadline_expired?(deadline)

        CityServiceNoticeCollector.send(:within_deadline, deadline) do
          options = { text:, notices:, location: }
          accepts_deadline = transport_timetable.method(:answer).parameters.any? { |kind, name| kind == :keyrest || ([:key, :keyreq].include?(kind) && name == :deadline) }
          options[:deadline] = deadline if accepts_deadline
          transport_timetable.answer(**options)
        end
      rescue StandardError => e
        Rails.logger.warn("[LiveServiceAnswers] public transport timetable failed (#{e.class}: #{e.message})") if defined?(Rails)
        nil
      end

      def deadline_expired?(deadline)
        seconds = CityServiceNoticeCollector.send(:remaining_seconds, deadline)
        seconds && seconds <= 0
      end

      def latest_checked_at(notices)
        Array(notices).filter_map(&:fetched_at).max
      end

      def formatted_checked_at(value)
        time = value.respond_to?(:in_time_zone) ? value : Time.zone.parse(value.to_s)
        return if time.nil? || time > Time.current

        time.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y. u %H:%M")
      rescue StandardError
        nil
      end

      def fold(value)
        Decidim::Bih::Text.fold(value.to_s)
      end

      def parking_topic?(text)
        folded = fold(text)
        return false if folded.blank?
        return true if PARKING_KEYWORDS.any? { |keyword| folded.include?(fold(keyword)) }

        folded.match?(/\bzon[aeui]?\b/) && parking_zones.lookup(text).present?
      end

      def public_transport_fare_intent?(text)
        folded = fold(text)
        return false if folded.blank?

        %w(koliko kosta cijena cena karta karte mjesecna mjesečna mjesecni mjesečni).any? do |keyword|
          folded.include?(fold(keyword))
        end
      end

      def public_transport_fare_answer
        [
          "Jedna vožnja javnim prevozom košta 1,00 KM u jednoj zoni, 2,00 KM za dvije zone i 2,50 KM za sve tri zone.",
          "Mjesečne karte su u rasponu od 24 do 90 KM, zavisno od kategorije.",
          "Izvor: #{PUBLIC_TRANSPORT_FARE_SOURCE_URL}."
        ].join(" ")
      end

      def localize(text, locale)
        return text unless locale.to_s == "sr-Cyrl"

        localized = Decidim::Bih::Transliterator.call(text.to_s)
        quick_replies = normalize_quick_replies(quick_replies_for(text)).map do |reply|
          reply.merge(label: Decidim::Bih::Transliterator.call(reply.fetch(:label).to_s))
        end
        response_text(localized, quick_replies:)
      end
    end
  end
end
